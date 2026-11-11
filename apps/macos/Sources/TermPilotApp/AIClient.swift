import AppKit
import Combine
import Foundation
import TermPilotDomain
import TermPilotRemote
import TermPilotTerminal

private actor AIWriter {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func send(_ data: Data) throws { try handle.write(contentsOf: data + Data([10])) }
}

@MainActor
final class AIClient: ObservableObject {
    @Published var ready = false { didSet { for chat in chats.values { chat.ready = ready } } }
    @Published var error: String? { didSet { for chat in chats.values { chat.error = error } } }
    @Published var settings: [String: Any] = [:] { didSet { for chat in chats.values { chat.settings = settings } } }
    @Published var presets: [[String: Any]] = [] { didSet { for chat in chats.values { chat.presets = presets } } }
    @Published var agentCatalog: [[String: Any]] = [] { didSet { for chat in chats.values { chat.agentCatalog = agentCatalog } } }
    @Published var configuration: [String: Any] = [:] { didSet { for chat in chats.values { chat.configuration = configuration } } }
    @Published var history: [[String: Any]] = []
    @Published var conversation: [String: Any] = [:] { didSet { schedulePresentation() } }
    @Published var interactions: [[String: Any]] = [] { didSet { schedulePresentation() } }
    @Published var streaming = "" { didSet { schedulePresentation() } }
    @Published var presentation: [[String: Any]] = []
    @Published var presentationRevision = 0
    private var presentationTask: Task<Void, Never>?
    private var presentationGeneration = 0
    @Published var reasoning = ""
    @Published var activity: [String] = []
    @Published var externalStatus = ""
    let boundScope: String?
    let targetLabel: String
    @Published var draft = ""
    @Published var selectedAgent = ""
    @Published var selectedModel = ""
    @Published var attachments: [URL] = []
    @Published var selectedSkills: Set<String> = []
    var onAttention: ((String) -> Void)?
    private weak var coordinator: AIClient?
    private var chats: [String: AIClient] = [:]

    func schedulePresentation() {
        guard boundScope != nil, ready else { return }
        presentationGeneration += 1
        guard presentationTask == nil else { return }
        presentationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self else { return }
            let generation = presentationGeneration
            let renderedConversationID = conversationID
            let input: [String: Any] = ["messages": conversation["messages"] ?? [], "status": conversation["status"] ?? "idle", "streaming": streaming, "interactions": interactions]
            do {
                let value = try await request("chat.render", input) as? [String: Any] ?? [:]
                if !Task.isCancelled, renderedConversationID == conversationID {
                    presentation = value["rows"] as? [[String: Any]] ?? []
                    presentationRevision += 1
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            presentationTask = nil
            if generation != presentationGeneration { schedulePresentation() }
        }
    }

    func fetchModels(for provider: [String: Any]) async throws -> [String] {
        let response = try await request("provider.models", ["provider": provider]) as? [String: Any] ?? [:]
        return response["modelIds"] as? [String] ?? []
    }

    init(scope: String? = nil, label: String = "") {
        boundScope = scope
        targetLabel = label
    }

    static func scope(for descriptor: SessionDescriptor, host: TermPilotDomain.Host) -> String {
        descriptor.kind == .ssh ? "host:" + host.id.uuidString.lowercased() : descriptor.id.uuidString
    }

    func chat(for descriptor: SessionDescriptor, host: TermPilotDomain.Host) -> AIClient {
        let key = Self.scope(for: descriptor, host: host)
        if let existing = chats[key] { return existing }
        let chat = AIClient(scope: key, label: host.label)
        chat.coordinator = self
        chat.ready = ready; chat.settings = settings; chat.presets = presets
        chat.agentCatalog = agentCatalog; chat.configuration = configuration; chat.error = error
        chats[key] = chat
        return chat
    }

    func openChat(for sessionID: UUID, selection: String? = nil) {
        guard let state, let descriptor = state.sessions[sessionID], let host = state.sessionHost(for: descriptor),
              let workspace = state.workspaces.first(where: { $0.root.sessionIDs.contains(sessionID) }) else { return }
        let chat = chat(for: descriptor, host: host)
        if let selection { chat.draft += "\n<terminal-selection>\n" + selection + "\n</terminal-selection>" }
        state.activeWorkspaceID = workspace.id
        state.openTerminalSidePanel(in: workspace.id, for: sessionID, tab: .ai)
    }

    private func requestAttention(for chat: AIClient) {
        guard let state, let scope = chat.boundScope,
              let descriptor = state.sessions.values.first(where: { descriptor in
                  state.sessionHost(for: descriptor).map { Self.scope(for: descriptor, host: $0) == scope } ?? false
              }) else { return }
        openChat(for: descriptor.id)
        onAttention?(scope)
    }

    private var contextObservers = Set<AnyCancellable>()
    private var runtimeContextObservers: [UUID: Set<AnyCancellable>] = [:]
    private var observedRuntimes: [UUID: ObjectIdentifier] = [:]
    private var contextUpdateTask: Task<Void, Never>?
    private var lastContextData: Data?
    private var contextUpdating = false
    private var contextDirty = false

    private func observeContext(_ state: AppState) {
        contextObservers.removeAll()
        state.$runtimes.sink { [weak self] runtimes in
            guard let self else { return }
            for id in self.runtimeContextObservers.keys where runtimes[id].map(ObjectIdentifier.init) != self.observedRuntimes[id] {
                self.runtimeContextObservers.removeValue(forKey: id)
                self.observedRuntimes.removeValue(forKey: id)
            }
            for (id, runtime) in runtimes where self.runtimeContextObservers[id] == nil {
                var subscriptions = Set<AnyCancellable>()
                runtime.$title.combineLatest(runtime.$currentDirectory, runtime.$currentUser, runtime.$lifecycle)
                    .sink { [weak self] _ in self?.scheduleContextUpdate() }.store(in: &subscriptions)
                runtime.$generation.sink { [weak self] _ in self?.scheduleContextUpdate() }.store(in: &subscriptions)
                self.runtimeContextObservers[id] = subscriptions
                self.observedRuntimes[id] = ObjectIdentifier(runtime)
            }
            self.scheduleContextUpdate()
        }.store(in: &contextObservers)
        state.$hosts.sink { [weak self] _ in self?.scheduleContextUpdate() }.store(in: &contextObservers)
        $settings.dropFirst().sink { [weak self] _ in self?.scheduleContextUpdate() }.store(in: &contextObservers)
    }

    private func scheduleContextUpdate() {
        guard coordinator == nil, contextUpdateTask == nil else { return }
        contextUpdateTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self else { return }
            self.contextUpdateTask = nil
            await self.updateContext()
        }
    }

    private var process: Process?
    private var writer: AIWriter?
    private var reader: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<Data, any Error>] = [:]
    private weak var state: AppState?
    private var starting = false
    private var registered: [String: TerminalSessionRuntime] = [:]
    private var fileClients: [String: SSH2SFTPBridgeClient] = [:]
    private var toolTasks: [String: Task<Void, Never>] = [:]
    var conversationID: String { conversation["id"] as? String ?? "" }
    var running: Bool { conversation["status"] as? String == "running" }
    static let toolNames = ["host_open", "session_close", "portforward_start", "portforward_stop", "portforward_tunnels_list", "terminal_execute", "terminal_start", "terminal_poll", "terminal_stop", "terminal_read_context", "sftp_list", "sftp_read_file", "sftp_write_file", "sftp_download", "sftp_upload", "sftp_stat", "sftp_home", "sftp_mkdir", "sftp_delete", "sftp_rename", "sftp_chmod"]

    func start(state: AppState) async {
        if let coordinator { await coordinator.start(state: state); return }
        self.state = state
        observeContext(state)
        guard process == nil, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            guard let resource = Bundle.main.resourceURL,
                  let runtime = SSH2BridgeRuntimeLocator.bundledRuntime(in: resource) else { throw AIError.message("找不到 TermPilot Rust 引擎，请使用打包后的应用。") }
            let p = Process(); p.executableURL = runtime.executable; p.arguments = ["ai"]
            let input = Pipe(), output = Pipe(); p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
            try p.run(); process = p; writer = AIWriter(input.fileHandleForWriting)
            let handle = output.fileHandleForReading
            reader = Task.detached { [weak self] in
                do {
                    try await ProcessPipeLines.read(from: handle) { [weak self] frame in
                        await self?.receive(frame)
                    }
                    await self?.closed()
                } catch { await self?.closed() }
            }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TermPilot").path
            _ = try await request("initialize", ["directory": directory, "context": context(), "tools": Self.toolNames])
            try await loadSettings(); try await refreshHistory()
            ready = true
            await updateContext()
        } catch { self.error = error.localizedDescription; process?.terminate(); process = nil }
    }
    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> Any {
        if let coordinator { return try await coordinator.request(method, params) }
        guard let writer else { throw AIError.message("AI 引擎未启动") }
        let id = UUID().uuidString
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.pending.removeValue(forKey: id)?.resume(throwing: AIError.message("AI 请求超时；请检查任务状态后再重试。"))
        }
        defer { timeout.cancel() }
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { do { try await writer.send(data) } catch { pending.removeValue(forKey: id)?.resume(throwing: error) } }
        }
        return try JSONSerialization.jsonObject(with: response)
    }
    private func receive(_ data: Data) {
        guard let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let id = frame["id"] as? String, let c = pending.removeValue(forKey: id) {
            if frame["ok"] as? Bool == true { c.resume(returning: (try? JSONSerialization.data(withJSONObject: frame["result"] ?? [:], options: [.fragmentsAllowed])) ?? Data("{}".utf8)) }
            else { c.resume(throwing: AIError.message(frame["error"] as? String ?? "AI 请求失败")) }
            return
        }
        dispatchEvent(frame)
    }
    func dispatchEvent(_ frame: [String: Any]) {
        if coordinator == nil {
            for chat in Array(chats.values) { chat.receiveEvent(frame) }
        }
        receiveEvent(frame)
    }
    func receiveEvent(_ frame: [String: Any]) {
        let type = frame["type"] as? String ?? ""
        let current = frame["conversationId"] as? String == conversationID
        switch type {
        case "vaultChanged": guard coordinator == nil else { return }; Task { await state?.refreshHosts(); await state?.refreshCredentials(); await state?.refreshProxyProfiles(); try? await state?.refreshLocalWorkflows() }
        case "conversation":
            if let c = frame["conversation"] as? [String: Any], current { conversation = c; streaming = "" }
            if boundScope == nil || (frame["conversation"] as? [String: Any])?["scope"] as? String == boundScope { Task { try? await refreshHistory() } }
        case "delta": if current { streaming += frame["text"] as? String ?? "" }
        case "reasoning": if current { reasoning += frame["text"] as? String ?? "" }
        case "approval", "question", "form":
            if current { interactions.append(frame); coordinator?.requestAttention(for: self) }
            else if coordinator == nil && !chats.values.contains(where: { $0.conversationID == frame["conversationId"] as? String }) {
                // External MCP requests can arrive without a visible chat. Present
                // their explicit approval in the relevant server's existing sidebar.
                let args = (frame["payload"] as? [String: Any])?["arguments"] as? [String: Any] ?? [:]
                let runtime = registered[args["sessionId"] as? String ?? ""]
                    ?? registered.values.first(where: { $0.descriptor.hostID?.uuidString.lowercased() == (args["hostId"] as? String)?.lowercased() })
                    ?? state?.activeWorkspace.flatMap { state?.runtimes[$0.focusedSessionID] }
                if let runtime, let host = state?.sessionHost(for: runtime.descriptor) {
                    let chat = chat(for: runtime.descriptor, host: host)
                    chat.interactions.append(frame); requestAttention(for: chat)
                } else { interactions.append(frame) }
            }
        case "scriptActivity", "scriptRun": if current { activity.append(String(describing: frame["run"] ?? frame["arguments"] ?? "")); if activity.count > 200 { activity.removeFirst() } }
        case "interactionClosed":
            let id = frame["requestId"] as? String ?? ""
            interactions.removeAll { $0["requestId"] as? String == id }
            toolTasks.removeValue(forKey: id)?.cancel()
        case "toolRequest":
            guard coordinator == nil else { return }
            let id = frame["requestId"] as? String ?? ""
            toolTasks[id] = Task { await performTool(frame) }
        case "toolCall", "toolResult", "externalActivity":
            if current { activity.append((try? String(data: JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys]), encoding: .utf8)) ?? type); if activity.count > 200 { activity.removeFirst() } }
        case "error", "commandTimeout": if current || frame["conversationId"] == nil { error = frame["message"] as? String }
        default: break
        }
    }
    private func closed() {
        ready = false; process = nil; writer = nil; lastContextData = nil
        for c in pending.values { c.resume(throwing: AIError.message("AI 引擎已结束；未完成操作需要核实结果。")) }; pending.removeAll()
        for t in toolTasks.values { t.cancel() }; toolTasks.removeAll(); interactions.removeAll()
    }
    func shutdown() {
        guard coordinator == nil else { return }
        for chat in chats.values { chat.interactions.removeAll(); chat.presentationTask?.cancel(); chat.presentationTask = nil }
        contextUpdateTask?.cancel(); contextUpdateTask = nil
        contextObservers.removeAll(); runtimeContextObservers.removeAll(); observedRuntimes.removeAll()
        reader?.cancel(); reader = nil
        for runtime in registered.values { runtime.aiOutput = nil; runtime.aiAddSelection = nil }
        process?.terminate(); closed()
    }
    func loadSettings() async throws { if let coordinator { try await coordinator.loadSettings(); return }; let v = try await request("settings.get") as? [String: Any] ?? [:]; settings = v["settings"] as? [String: Any] ?? [:]; presets = v["presets"] as? [[String: Any]] ?? []; agentCatalog = v["agents"] as? [[String: Any]] ?? []; configuration = v["configuration"] as? [String: Any] ?? [:] }
    func saveSettings(_ value: [String: Any]) async throws { _ = try await request("settings.save", ["settings": value]); try await loadSettings() }
    func refreshHistory() async throws { history = try await request("conversation.list", boundScope.map { ["scope": $0] } ?? [:]) as? [[String: Any]] ?? [] }
    func select(_ id: String) async throws { let selected = try await request("conversation.get", ["conversationId": id]) as? [String: Any] ?? [:]; guard boundScope == nil || selected["scope"] as? String == boundScope else { throw AIError.message("该对话属于另一台服务器") }; conversation = selected; streaming = ""; reasoning = ""; activity = [] }
    func create(agent: String, scope: String) async throws { guard boundScope == nil || boundScope == scope else { throw AIError.message("对话目标与服务器不一致") }; conversation = try await request("conversation.create", ["agent": agent, "scope": scope]) as? [String: Any] ?? [:]; streaming = ""; reasoning = ""; activity = []; try await refreshHistory() }
    func send(_ text: String, agent: String, model: String = "", scope: String, attachments: [URL], skills: [String]) async throws {
        if conversationID.isEmpty { try await create(agent: agent, scope: scope) }
        _ = try await request("conversation.draft", ["conversationId": conversationID, "draft": text, "agent": agent, "model": model, "attachments": attachments.map { ["path": $0.path, "name": $0.lastPathComponent] }, "skills": skills])
        streaming = ""; reasoning = ""; activity = []
        _ = try await request("turn.start", ["conversationId": conversationID, "text": text])
    }
    func respond(_ frame: [String: Any], value: [String: Any]) async {
        do { _ = try await request("interaction.reply", ["requestId": frame["requestId"] ?? "", "value": value]) } catch { self.error = error.localizedDescription }
    }
    private func context() -> [String: Any] {
        guard let state else { return ["sessions": []] }
        registered = Dictionary(uniqueKeysWithValues: state.runtimes.values.filter { $0.lifecycle == .connected }.map { ($0.surfaceIdentity, $0) })
        return ["sessions": registered.sorted { $0.key < $1.key }.map { id, r -> [String: Any] in
            let host = state.sessionHost(for: r.descriptor)
            return ["sessionId": id, "label": r.title, "hostId": host?.id.uuidString ?? "", "hostname": host?.hostname ?? "", "scope": r.descriptor.id.uuidString, "cwd": r.currentDirectory ?? "", "username": r.currentUser ?? "", "kind": r.descriptor.kind.rawValue]
        }]
    }
    func updateContext() async {
        guard ready else { return }
        guard !contextUpdating else { contextDirty = true; return }
        contextUpdating = true
        defer {
            contextUpdating = false
            if contextDirty { contextDirty = false; scheduleContextUpdate() }
        }
        let value = context()
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data != lastContextData {
            do { _ = try await request("context.update", value); lastContextData = data } catch {}
        }
        for (id, runtime) in registered {
            let descriptorID = runtime.descriptor.id
            if settings["selectionShortcut"] as? Bool != false { runtime.aiAddSelection = { [weak self] text in self?.openChat(for: descriptorID, selection: text) } }
            else { runtime.aiAddSelection = nil }
            runtime.aiOutput = { [weak self] bytes in
                guard let self, self.ready, let writer = self.writer else { return }
                let frame: [String: Any] = ["method": "terminal.output", "params": ["sessionId": id, "data": bytes.base64EncodedString()]]
                guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
                Task { try? await writer.send(data) }
            }
        }
        for id in fileClients.keys where registered[id] == nil { let c = fileClients.removeValue(forKey: id); await c?.close() }
    }
    var scopedTargets: [(String, String)] {
        let root = coordinator ?? self
        return root.registered.values.filter { runtime in
            guard let scope = boundScope, let host = root.state?.sessionHost(for: runtime.descriptor) else { return false }
            return Self.scope(for: runtime.descriptor, host: host) == scope
        }.map { ($0.surfaceIdentity, $0.title) }
    }
    func selection() -> String {
        let root = coordinator ?? self
        return scopedTargets.compactMap { root.registered[$0.0]?.aiSelection() }.first(where: { !$0.isEmpty }) ?? ""
    }
    private func performTool(_ frame: [String: Any]) async {
        do {
            try Task.checkCancellation()
            let p = frame["payload"] as? [String: Any] ?? [:], args = p["arguments"] as? [String: Any] ?? [:]
            let name = p["name"] as? String ?? "", id = args["sessionId"] as? String ?? ""
            if name == "host_open" {
                if (settings["toolAccess"] as? [String: Any])?["activateOnHostOpen"] as? Bool != false { NSApplication.shared.activate(ignoringOtherApps: true) }
                guard let state, let hostID = UUID(uuidString: args["hostId"] as? String ?? ""), let host = state.hosts.first(where: { $0.id == hostID }), host.connectionKind == .ssh else { throw AIError.message("AI 终端工具仅支持已保存的 SSH 主机") }
                if let existing = state.runtimes.values.first(where: { $0.descriptor.hostID == hostID && $0.lifecycle == .connected }) {
                    await respond(frame, value: ["ok": true, "result": ["sessionId": existing.surfaceIdentity, "created": false]]); return
                }
                let before = Set(state.runtimes.keys)
                await state.connect(host: host)
                guard let runtime = state.runtimes.first(where: { !before.contains($0.key) && $0.value.descriptor.hostID == hostID })?.value else { throw AIError.message(state.presentedError ?? "无法创建 SSH 会话") }
                for _ in 0..<300 { try Task.checkCancellation(); if runtime.lifecycle == .connected { break }; try await Task.sleep(for: .milliseconds(200)) }
                guard runtime.lifecycle == .connected else { throw AIError.message("SSH 连接尚未就绪，请在终端查看认证或主机密钥提示") }
                await updateContext()
                await respond(frame, value: ["ok": true, "result": ["sessionId": runtime.surfaceIdentity, "created": true]]); return
            }
            if name.hasPrefix("portforward_") {
                guard let state else { throw AIError.message("应用已关闭") }
                try await state.refreshLocalWorkflows()
                try Task.checkCancellation()
                if name == "portforward_tunnels_list" {
                    let scope = p["scope"] as? String ?? "workspace"
                    let hostIDs = Set(registered.values.filter { scope == "workspace" || $0.surfaceIdentity == scope || $0.descriptor.id.uuidString == scope || $0.descriptor.hostID.map { "host:" + $0.uuidString.lowercased() == scope } == true }.compactMap { $0.descriptor.hostID })
                    let data = try JSONEncoder().encode(state.portForwardRules.filter { ($0.status == .active || $0.status == .connecting) && (scope == "workspace" || $0.hostID.map { hostIDs.contains($0) } == true) })
                    await respond(frame, value: ["ok": true, "result": try JSONSerialization.jsonObject(with: data)]); return
                }
                guard let ruleID = UUID(uuidString: args["ruleId"] as? String ?? ""), let rule = state.portForwardRules.first(where: { $0.id == ruleID }) else { throw AIError.message("找不到转发规则") }
                if name == "portforward_start" {
                    await state.startPortForward(rule)
                    for _ in 0..<150 { try Task.checkCancellation(); if state.portForwardRules.first(where: { $0.id == ruleID })?.status != .connecting { break }; try await Task.sleep(for: .milliseconds(200)) }
                    guard state.portForwardRules.first(where: { $0.id == ruleID })?.status == .active else { throw AIError.message(state.portForwardRules.first(where: { $0.id == ruleID })?.error ?? "转发尚未就绪") }
                } else { await state.stopPortForward(rule) }
                await respond(frame, value: ["ok": true, "result": ["ruleId": ruleID.uuidString, "status": name == "portforward_start" ? "active" : "inactive"]]); return
            }
            guard let runtime = registered[id], runtime.surfaceIdentity == id, runtime.lifecycle == .connected else { throw AIError.message("目标终端已断开或重连") }
            let result: Any
            if name == "session_close" {
                guard let state, let workspace = state.workspaces.first(where: { $0.root.sessionIDs.contains(runtime.descriptor.id) }) else { throw AIError.message("找不到目标工作区") }
                await state.close(sessionID: runtime.descriptor.id, in: workspace.id); await updateContext(); result = ["closed": true]
            }
            else if name == "terminal_write" { runtime.sendText(args["text"] as? String ?? ""); result = [:] }
            else if name == "terminal_read_context" { result = runtime.aiReadContext(range: args["range"] as? String ?? "viewport", startLine: args["startLine"] as? Int ?? 0, maxLines: args["maxLines"] as? Int ?? 80) }
            else {
                guard runtime.descriptor.kind == .ssh, let state, let host = state.sessionHost(for: runtime.descriptor) else { throw AIError.message("文件工具需要已连接的 SSH 会话") }
                let client: SSH2SFTPBridgeClient
                if let existing = fileClients[id] { client = existing }
                else { client = try await state.makeSFTPClient(for: host, sourceConnectionID: runtime.descriptor.sshConnectionID, sourceSessionID: runtime.descriptor.id); try await client.waitUntilReady(); fileClients[id] = client }
                func str(_ key: String) -> String { args[key] as? String ?? "" }
                func encoded<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
                try Task.checkCancellation()
                switch name {
                case "sftp_list": result = try encoded(await client.listDirectory(at: str("path")))
                case "sftp_stat": result = try encoded(await client.stat(str("path")))
                case "sftp_home": result = ["path": try await client.realPath(".")]
                case "sftp_read_file": result = ["text": try await client.readTextFile(at: str("path"))]
                case "sftp_write_file": try await client.writeTextFile(str("content"), at: str("path"), overwrite: true); result = [:]
                case "sftp_mkdir": try await client.createDirectory(at: str("path")); result = [:]
                case "sftp_delete": let entry = try await client.stat(str("path")); try await client.delete(path: str("path"), kind: entry.kind); result = [:]
                case "sftp_rename": try await client.rename(from: str("oldPath"), to: str("newPath")); result = [:]
                case "sftp_chmod": guard let mode = UInt32(str("mode"), radix: 8), mode <= 0o7777 else { throw AIError.message("无效的权限值") }; try await client.setPermissions(mode, at: str("path")); result = [:]
                case "sftp_upload": _ = try await client.upload(localURL: URL(fileURLWithPath: str("localPath")), to: str("remotePath"), overwrite: false); result = [:]
                case "sftp_download": _ = try await client.download(remotePath: str("remotePath"), to: URL(fileURLWithPath: str("localPath")), overwrite: false); result = [:]
                default: throw AIError.message("当前原生界面未实现此工具")
                }
            }
            await respond(frame, value: ["ok": true, "result": result])
        } catch { if !Task.isCancelled { await respond(frame, value: ["ok": false, "error": error.localizedDescription]) } }
    }
}
enum AIError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let m) = self { return m }; return nil } }
