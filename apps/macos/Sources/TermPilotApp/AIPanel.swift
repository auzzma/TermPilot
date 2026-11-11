import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AIPanel: View {
    @ObservedObject var client: AIClient
    var openSettings: (() -> Void)? = nil
    private var model: String { get { client.selectedModel } nonmutating set { client.selectedModel = newValue } }
    @State private var choosingModel = false
    private var draft: String { get { client.draft } nonmutating set { client.draft = newValue } }
    private var agent: String { get { client.selectedAgent } nonmutating set { client.selectedAgent = newValue } }
    private var scope: String { client.boundScope ?? "unbound" }
    private var attachments: [URL] { get { client.attachments } nonmutating set { client.attachments = newValue } }
    @State private var skills: [[String: Any]] = []
    private var selectedSkills: Set<String> { get { client.selectedSkills } nonmutating set { client.selectedSkills = newValue } }
    @State private var showingSettings = false
    @State private var followOutput = true
    @State private var draftTask: Task<Void, Never>?

    private var providers: [[String: Any]] { (client.settings["providers"] as? [[String: Any]] ?? []).filter { $0["enabled"] as? Bool != false } }
    private var externalAgents: [[String: Any]] { (client.settings["agents"] as? [[String: Any]] ?? []).filter { item in client.agentCatalog.first { $0["kind"] as? String == item["kind"] as? String }?["available"] as? Bool != false } }
    private var agents: [[String: Any]] { providers + externalAgents }
    private var isBuiltin: Bool { !externalAgents.contains { $0.aiID == agent } }
    private var agentName: String { isBuiltin ? "TermPilot Agent" : externalAgents.first { $0.aiID == agent }?["name"] as? String ?? "Agent" }
    private var modelName: String { let p = providers.first { $0.aiID == agent }; let name = p?["name"] as? String ?? "选择提供商"; let selected = model.isEmpty ? p?["model"] as? String ?? "" : model; return selected.isEmpty ? name : name + " · " + selected }
    private var slashItems: [[String: Any]] { let query = draft.dropFirst().lowercased(); return (client.settings["quickMessages"] as? [[String: Any]] ?? []).filter { query.isEmpty || ($0["slug"] as? String ?? "").lowercased().contains(query) } }

    private var messages: [[String: Any]] { client.conversation["messages"] as? [[String: Any]] ?? [] }
    @State private var composerHeight: CGFloat = 58
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !agent.isEmpty && client.ready && !client.running && client.boundScope != nil }
    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            transcript
            if let error = client.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button { client.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(10).background(Color.red.opacity(0.06))
            }
            composer.padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showingSettings) { AISettingsView(client: client) }
        .onChange(of: client.ready) { if client.ready { prepare() } }
        .task { prepare() }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                Button("TermPilot Agent") { agent = providers.first?.aiID ?? ""; model = "" }
                Divider()
                ForEach(externalAgents, id: \.aiID) { item in Button(item["name"] as? String ?? "Agent") { agent = item.aiID; model = "" } }
                Divider(); Button("Agent 设置") { settings() }
            } label: { Label(agentName, systemImage: "sparkles").font(.system(size: 12, weight: .semibold)).lineLimit(1) }
                .menuStyle(.borderlessButton).disabled(client.running)
            Spacer(minLength: 0)
            Menu {
                ForEach(client.history, id: \.aiID) { c in Button(c["title"] as? String ?? "对话") { run { try await client.select(c.aiID); restore() } } }
                if client.history.isEmpty { Text("暂无历史对话") }
                Divider()
                Button("删除当前对话", role: .destructive) { run { _ = try await client.request("conversation.delete", ["conversationId": client.conversationID]); client.conversation = [:]; try await client.refreshHistory(); draft = "" } }.disabled(client.running || client.conversationID.isEmpty)
            } label: { Image(systemName: "clock.arrow.circlepath") }.menuStyle(.borderlessButton).frame(width: 21).help("此服务器的历史对话")
            Button { run { try await client.create(agent: agent, scope: scope); restore() } } label: { Image(systemName: "square.and.pencil") }.disabled(client.running).help("新对话")
            Button { settings() } label: { Image(systemName: "gearshape") }.help("AI 设置")
        }.buttonStyle(.plain).foregroundStyle(.secondary)
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty && client.streaming.isEmpty && client.interactions.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(.tertiary)
                            Text("与 \(client.targetLabel) 对话").font(.system(size: 14, weight: .medium))
                            Text("询问服务器状态、分析终端输出或获取配置帮助").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                    ForEach(client.presentation, id: \.aiID) { row in
                        if row["kind"] as? String == "tools" {
                            AIChatToolGroup(client: client, tools: row["tools"] as? [[String: Any]] ?? [])
                        } else if row["role"] as? String == "user" {
                            HStack { Spacer(minLength: 30); Text(row["text"] as? String ?? "").font(.system(size: 13)).lineSpacing(4).textSelection(.enabled).padding(10)
                                .background(Color.secondary.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12))) }
                        } else {
                            AIChatMarkdown(blocks: AIChatBlock.parse(row["blocks"] as? [[String: Any]] ?? []))
                                .contextMenu { Button("复制回复") { AIChatClipboard.copy(row["text"] as? String ?? "") } }
                        }
                    }
                    if !client.reasoning.isEmpty {
                        DisclosureGroup("推理摘要") { Text(client.reasoning).font(.system(size: 12)).textSelection(.enabled) }.font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(client.interactions.filter { $0["type"] as? String != "approval" }, id: \.requestID) { frame in
                        if frame["type"] as? String == "form" { AIScriptForm(client: client, frame: frame) }
                        else { AIInteraction(client: client, frame: frame) }
                    }
                    if client.running { HStack(spacing: 8) { ProgressView().controlSize(.mini); Text(client.interactions.isEmpty ? "正在处理…" : "等待你的确认").font(.caption).foregroundStyle(.secondary) } }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(12)
                    .background(AIChatScrollObserver { atBottom in followOutput = atBottom }.frame(width: 0, height: 0))
            }
            .onChange(of: client.presentationRevision) { if followOutput { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: client.conversationID) { followOutput = true; proxy.scrollTo("bottom", anchor: .bottom) }
            .overlay(alignment: .bottom) {
                if !followOutput { Button { followOutput = true; proxy.scrollTo("bottom", anchor: .bottom) } label: { Label("回到最新", systemImage: "arrow.down") }.controlSize(.small).buttonStyle(.bordered).background(.regularMaterial, in: Capsule()).padding(8) }
            }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !attachments.isEmpty {
                ScrollView(.horizontal) { HStack { ForEach(attachments, id: \.self) { url in Button { attachments.removeAll { $0 == url } } label: { Label(url.lastPathComponent, systemImage: "xmark.circle") }.font(.caption).buttonStyle(.borderless) } } }
            }
            if draft.hasPrefix("/") && !draft.contains("\n") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(slashItems, id: \.aiID) { item in Button("/" + (item["slug"] as? String ?? "") + "  " + (item["name"] as? String ?? "")) { draft = item["content"] as? String ?? "" } }
                    Button("/compact  压缩上下文") { draft = "/compact" }; Button("/stop  停止任务") { draft = "/stop" }
                }.font(.caption).buttonStyle(.plain).padding(8)
            }
            if draft.hasSuffix("@") { Menu("引用上下文") { ForEach(client.scopedTargets, id: \.0) { id, label in Button(label) { draft.removeLast(); draft += "[终端：\(label)，sessionId：\(id)] " } }; Button("当前终端选区") { draft.removeLast(); draft += client.selection() } } }
            ZStack(alignment: .topLeading) {
                if draft.isEmpty { Text(client.running ? "任务进行中…" : "询问服务器…  @ 引用 · / 快捷消息").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 10).allowsHitTesting(false) }
                AIChatComposer(text: $client.draft, height: $composerHeight) { if canSend { send() } }.frame(height: composerHeight)
            }.onChange(of: draft) { saveDraft() }
            if isBuiltin {
                Button { choosingModel = true } label: { HStack { Text(modelName).lineLimit(1).truncationMode(.middle); Image(systemName: "chevron.down").font(.system(size: 8)); Spacer(minLength: 0) } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).disabled(client.running).padding(.horizontal, 10)
                    .popover(isPresented: $choosingModel) { AIModelPicker(client: client, providerID: $client.selectedAgent, model: $client.selectedModel).frame(width: 400, height: 430) }
            }
            HStack(spacing: 10) {
                Menu {
                    Button("添加文件或图片…") { let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; if panel.runModal() == .OK { attachments += panel.urls } }
                    Button("附上终端选区") { let selected = client.selection(); if !selected.isEmpty { draft += "\n<terminal-selection>\n\(selected)\n</terminal-selection>" } }
                    ForEach(skills, id: \.aiID) { skill in let id = skill.aiID; Button((selectedSkills.contains(id) ? "✓ " : "") + (skill["name"] as? String ?? id)) { if !selectedSkills.insert(id).inserted { selectedSkills.remove(id) } } }
                } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).frame(width: 22).help("添加附件或上下文")
                Menu {
                    ForEach([("observe", "观察者"), ("confirm", "确认"), ("auto", "自动")], id: \.0) { key, label in Button(label) { run { var settings = client.settings; settings["mode"] = key; try await client.saveSettings(settings) } } }
                } label: { Label(["observe":"观察者","confirm":"确认","auto":"自动"][client.settings["mode"] as? String ?? "confirm"] ?? "确认", systemImage: "checkmark.shield").font(.system(size: 11)) }.menuStyle(.borderlessButton).fixedSize()
                Menu {
                    Button("压缩上下文") { run { _ = try await client.request("conversation.compact", ["conversationId": client.conversationID]) } }.disabled(client.running || messages.isEmpty)
                    ForEach(["md", "json", "txt"], id: \.self) { format in Button("导出 \(format.uppercased())…") { export(format) } }
                    Button("工具接入设置") { settings() }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24).help("更多操作")
                Spacer(minLength: 0)
                if client.running { Button { run { _ = try await client.request("turn.stop", ["conversationId": client.conversationID]) } } label: { Image(systemName: "stop.fill").font(.system(size: 10)) }.help("停止任务") }
                else { Button { send() } label: { Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)) }.disabled(!canSend).help("发送 · Enter（Shift+Enter 换行）").keyboardShortcut(.return, modifiers: .command) }
            }.buttonStyle(.borderless).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
        }.background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.18)))
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers { _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in attachments.append(url) } } } }; return true
            }
    }
    private func prepare() {
        if agent.isEmpty { let preferred = client.settings["selected"] as? String ?? ""; agent = preferred.isEmpty ? agents.first?.aiID ?? "" : preferred }
        if client.ready { client.schedulePresentation(); run { try await client.refreshHistory(); skills = (try await client.request("skills.list")) as? [[String: Any]] ?? [] } }
    }
    private func settings() { if let openSettings { openSettings() } else { showingSettings = true } }
    private func restore() { draft = client.conversation["draft"] as? String ?? ""; if let a = client.conversation["agent"] as? String { agent = a }; model = client.conversation["model"] as? String ?? ""; attachments = (client.conversation["attachments"] as? [[String: Any]] ?? []).compactMap { ($0["path"] as? String).map { URL(fileURLWithPath: $0) } }; selectedSkills = Set(client.conversation["skills"] as? [String] ?? []) }
    private func saveDraft() { draftTask?.cancel(); guard !client.conversationID.isEmpty, !client.running else { return }; let id = client.conversationID, value = draft; draftTask = Task { try? await Task.sleep(for: .milliseconds(400)); guard !Task.isCancelled else { return }; _ = try? await client.request("conversation.draft", ["conversationId": id, "draft": value]) } }
    private func send() { guard canSend else { return }; draftTask?.cancel(); let value = draft; if value == "/stop" { run { _ = try await client.request("turn.stop", ["conversationId": client.conversationID]); draft = "" }; return }; if value == "/compact" { run { _ = try await client.request("conversation.compact", ["conversationId": client.conversationID]); draft = "" }; return }; run { try await client.send(value, agent: agent, model: model, scope: scope, attachments: attachments, skills: Array(selectedSkills)); draft = ""; attachments = [] } }
    private func run(_ body: @escaping @MainActor () async throws -> Void) { Task { do { try await body() } catch { client.error = error.localizedDescription } } }
    private func export(_ format: String) { run { let value = try await client.request("conversation.export", ["conversationId": client.conversationID, "format": format]) as? [String: Any]; let panel = NSSavePanel(); panel.nameFieldStringValue = "TermPilot-对话.\(format)"; if panel.runModal() == .OK, let url = panel.url { try (value?["text"] as? String ?? "").write(to: url, atomically: true, encoding: .utf8) } } }
}
extension Dictionary where Key == String, Value == Any { var aiID: String { self["id"] as? String ?? "" }; var requestID: String { self["requestId"] as? String ?? "" } }

private struct AIScriptForm: View {
    @ObservedObject var client: AIClient
    let frame: [String: Any]
    @State private var values: [String: Any] = [:]
    private var spec: [String: Any] { frame["payload"] as? [String: Any] ?? [:] }
    private var fields: [[String: Any]] { spec["fields"] as? [[String: Any]] ?? [] }
    var body: some View {
        GroupBox(spec["title"] as? String ?? "脚本需要输入") {
            VStack(alignment: .leading) {
                if let message = spec["message"] as? String { Text(message) }
                if let error = spec["error"] as? String { Text(error).foregroundStyle(.red) }
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                            if visible(field) && spec["kind"] as? String != "confirm" {
                                let name = field["name"] as? String ?? ""
                                let title = field["label"] as? String ?? name
                                switch field["type"] as? String ?? "text" {
                                case "checkbox": Toggle(title, isOn: Binding(get: { values[name] as? Bool ?? false }, set: { values[name] = $0 }))
                                case "password": SecureField(title, text: text(name))
                                case "select", "radio":
                                    Picker(title, selection: text(name)) { Text("请选择").tag(""); ForEach(Array((field["options"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, option in Text(option["label"] as? String ?? option["value"] as? String ?? "").tag(option["value"] as? String ?? "").disabled(option["disabled"] as? Bool == true) } }
                                case "textarea": Text(title); TextEditor(text: text(name)).frame(height: 80)
                                default: TextField(title, text: text(name))
                                }
                            }
                        }
                    }
                }.frame(maxHeight: 260)
                HStack { Button("取消") { Task { await client.respond(frame, value: ["cancelled": true]) } }; Button(spec["kind"] as? String == "confirm" ? "是" : "提交") { let submitted: [String: Any] = spec["kind"] as? String == "confirm" ? ["value": true] : values; Task<Void, Never> { await client.respond(frame, value: ["values": submitted]) } } }
            }
        }.onAppear { values = spec["values"] as? [String: Any] ?? [:]; for field in fields { let name = field["name"] as? String ?? ""; if values[name] == nil, let initial = field["default"], !(initial is NSNull) { values[name] = initial } } }
    }
    private func text(_ name: String) -> Binding<String> { Binding(get: { if let value = values[name] as? String { return value }; if let number = values[name] as? NSNumber { return number.stringValue }; return "" }, set: { values[name] = $0 }) }
    private func visible(_ field: [String: Any]) -> Bool {
        guard let condition = field["visibleWhen"] as? [String: Any] else { return true }
        let value = values[condition["field"] as? String ?? ""] ?? NSNull()
        if let equal = condition["equals"] { return NSDictionary(dictionary: ["v": value]).isEqual(to: ["v": equal]) }
        if let different = condition["notEquals"] { return !NSDictionary(dictionary: ["v": value]).isEqual(to: ["v": different]) }
        let truth = !(value is NSNull) && (value as? Bool ?? true) && (value as? String != "")
        return condition["falsy"] as? Bool == true ? !truth : truth
    }
}

private struct AIInteraction: View {
    @ObservedObject var client: AIClient
    let frame: [String: Any]
    @State private var answers: [String: String] = [:]
    @State private var selections: [String: Set<String>] = [:]
    @State private var remember = false
    private var payload: [String: Any] { frame["payload"] as? [String: Any] ?? [:] }
    private var questions: [[String: Any]] { payload["questions"] as? [[String: Any]] ?? [] }
    var body: some View {
        GroupBox(frame["type"] as? String == "approval" ? "操作需要批准" : "Agent 需要补充信息") {
            VStack(alignment: .leading) {
                if frame["type"] as? String == "approval" {
                    if payload["external"] as? Bool != true { Toggle("一小时内记住相同目标和操作", isOn: $remember) }
                    HStack { Button("拒绝") { Task { await client.respond(frame, value: ["allow": false]) } }; Button("允许") { Task { await client.respond(frame, value: ["allow": true, "remember": remember]) } } }
                } else {
                    ForEach(questions, id: \.aiID) { q in
                        let id = q.aiID
                        Text(q["question"] as? String ?? q["header"] as? String ?? "回答").font(.callout)
                        let options = q["options"] as? [[String: Any]] ?? []
                        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                            let label = option["label"] as? String ?? ""
                            Toggle(label, isOn: Binding(get: { selections[id, default: []].contains(label) }, set: { enabled in
                                if enabled { if q["multiSelect"] as? Bool != true { selections[id] = [] }; selections[id, default: []].insert(label) } else { selections[id]?.remove(label) }
                            })).toggleStyle(.checkbox)
                            if let description = option["description"] as? String { Text(description).font(.caption).foregroundStyle(.secondary) }
                        }
                        if q["isSecret"] as? Bool == true { SecureField("回答", text: Binding(get: { answers[id, default: ""] }, set: { answers[id] = $0 })) }
                        else { TextField("补充回答", text: Binding(get: { answers[id, default: ""] }, set: { answers[id] = $0 })) }
                    }
                    HStack {
                        Button("取消任务") { Task { _ = try? await client.request("turn.stop", ["conversationId": frame["conversationId"] ?? ""]) } }
                        Button("提交") {
                            var values: [String: Any] = [:]
                            for q in questions { let id = q.aiID; var list = selections[id, default: []].sorted(); if let text = answers[id], !text.isEmpty { list.append(text) }; values[id] = ["answers": list] }
                            Task { await client.respond(frame, value: ["answers": values]) }
                        }
                    }
                }
            }
        }
    }
}
