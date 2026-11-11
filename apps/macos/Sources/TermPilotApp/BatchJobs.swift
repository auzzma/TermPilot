import AppKit
import Foundation
import SwiftUI
import TermPilotCore
import TermPilotDomain
import TermPilotPersistence
import TermPilotRemote

struct BatchScript: Codable, Equatable {
    var body = ""
    var shell = "/bin/bash"
    var cwd = ""
    var args: [String] = []
    var environment: [String: String] = [:]
    var elevation = ""
}
struct BatchJob: Codable, Equatable {
    var kind = "execute"
    var executionMode = "foreground"
    var concurrency = 5
    var connectTimeout = 120
    var stepTimeout = 600
    var stopOnFailure = false
    var script = BatchScript()
    var before = BatchScript()
    var after = BatchScript()
    var cleanupPolicy = "success"
    var localPaths: [String] = []
    var remoteDirectory = ""
    var overwrite = "skip"
    var fileMode = "0644"
    var directoryMode = "0755"
    var recursivePermissions = false
    var owner = ""
    var group = ""
    var remotePaths: [String] = []
    var localDirectory = ""
    var remoteWorkDirectory = ""
    var sourceTaskId = ""
}
struct BatchBackgroundTask: Codable, Identifiable {
    var targetId: String
    var remoteTaskId: String
    var hostname: String
    var port: Int
    var username: String
    var credentialId: String?
    var proxyProfileId: String?
    var elevation: String
    var id: String { remoteTaskId }
}
struct BatchTarget: Identifiable {
    var host: TermPilotDomain.Host
    var elevation = "none"
    var elevationPassword = ""
    var savedHostID: UUID?
    var id: UUID { host.id }
}
struct BatchEvent: Identifiable {
    var id = UUID()
    var value: [String: Any]
    func text(_ key: String) -> String { value[key] as? String ?? "" }
}
struct BatchPrompt: Identifiable {
    var id: String
    var ip: String
    var targetId: String
    var value: [String: Any]
}
private actor BatchWriter {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func send(_ data: Data) throws { try handle.write(contentsOf: data + Data([10])) }
}

@MainActor
final class BatchJobController: ObservableObject, Identifiable {
    let id: UUID
    let number: Int
    private let resources: URL?
    @Published var section = "configuration"
    @Published var targetDefaults = BatchTargetDefaults()
    @Published var job = BatchJob()
    @Published var targets: [BatchTarget] = []
    @Published var events: [BatchEvent] = []
    @Published var conflicts: [BatchEvent] = []
    @Published var steps: [String: BatchEvent] = [:]
    @Published var checks: [String: BatchEvent] = [:]
    @Published var progress: [String: BatchEvent] = [:]
    @Published var prompts: [BatchPrompt] = []
    @Published var running = false
    @Published private var workerFailed = false
    @Published var error = ""
    @Published var reportDirectory = ""
    @Published var history: [[String: Any]] = []
    @Published var backgroundTasks: [BatchBackgroundTask] = []
    @Published var historyJobId = ""
    @Published private(set) var isHistoryReport = false
    private var hostStates: [String: BatchEvent] = [:]
    private var process: Process?
    private var writer: BatchWriter?
    private var reader: Task<Void, Never>?
    private var generation = UUID()
    private var receivedFinish = false
    private var closed = false

    init(id: UUID = UUID(), number: Int = 1, resources: URL? = Bundle.main.resourceURL) {
        self.id = id
        self.number = number
        self.resources = resources
    }

    @Published var customTitle: String?
    @Published var savedJobID: UUID?
    @Published var savedJobRevision: Int?
    var title: String { customTitle ?? String(format: AppLocalization.string("Job %lld"), Int64(number)) }

    func rename(to value: String) {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && name != title { customTitle = name }
    }
    var statusLabel: String {
        if !prompts.isEmpty { return "Waiting for confirmation" }
        if running { return "running" }
        if workerFailed { return "failed" }
        let final = checks.values.filter { $0.text("stage") == "finished" }
        if final.contains(where: { $0.text("status") == "running" }) { return "Background running" }
        if final.contains(where: { $0.text("status") == "unknown" }) { return "unknown" }
        if final.contains(where: { $0.text("status") == "failed" }) { return "failed" }
        if final.contains(where: { $0.text("status") == "cancelled" }) { return "cancelled" }
        return reportDirectory.isEmpty ? "Draft" : "Completed"
    }

    func append(_ incoming: [BatchTarget]) {
        var keys = Set(targets.map { "\($0.host.hostname.lowercased()):\($0.host.port)" })
        for t in incoming where keys.insert("\(t.host.hostname.lowercased()):\(t.host.port)").inserted { targets.append(t) }
    }
    func addIPs(_ input: String, port: Int, credential: UUID?, elevation: String, password: String) throws {
        guard let credential else { throw BatchError.message("Select a credential for temporary IPs.") }
        let value = try SharedCore.call(["method": "batch.parseTargets", "text": input, "port": port])
        try checkError(value)
        let parsed = value["targets"] as? [[String: Any]] ?? []
        append(parsed.map { v in
            let ip = v["hostname"] as? String ?? ""
            return BatchTarget(host: TermPilotDomain.Host(label: ip, hostname: ip, port: v["port"] as? Int ?? port, username: "", authentication: .password, credentialID: credential), elevation: elevation, elevationPassword: password)
        })
    }
    var downloadRetryError: String {
        do { _ = try batchDownloadRetryPlan(job: job, events: events + Array(steps.values) + Array(hostStates.values), targets: targets); return "" }
        catch { return error.localizedDescription }
    }
    func start(state: AppState, kind: String? = nil, retry: String? = nil, backgroundAction: String? = nil) async {
        guard !closed, !running else { return }
        let current = UUID()
        generation = current
        running = true
        receivedFinish = false
        workerFailed = false
        error = ""
        do {
            var definition = job
            if let kind { definition.kind = kind; definition.executionMode = "foreground" }
            if backgroundAction != nil { definition = BatchJob(); definition.script.body = ":" }
            definition.remotePaths = definition.remotePaths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            var selected = backgroundAction == nil ? targets : restoredBackgroundTargets(state: state)
            if let retry {
                let retryEvents = events + Array(steps.values) + Array(hostStates.values)
                let failed = Set(retryEvents.filter { $0.text("stage") == "finished" && ["failed", "cancelled"].contains($0.text("status")) }.map { $0.text("targetId") })
                selected = selected.filter { failed.contains($0.id.uuidString) }
                if retry == "download" {
                    let plan = try batchDownloadRetryPlan(job: definition, events: retryEvents, targets: selected)
                    definition.kind = "collect"; definition.before = BatchScript(); definition.remoteWorkDirectory = plan.directory
                    definition.sourceTaskId = plan.sourceTaskID
                }
            }
            guard !selected.isEmpty else { throw BatchError.message("Select at least one target host.") }
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(definition))
            try checkError(SharedCore.call(["method": "batch.validate", "job": object]))
            let directory = try VaultStore.applicationSupportDirectory()
            var resolved: [[String: Any]] = []
            for target in selected {
                var source = target.host
                if backgroundAction == nil, let savedID = target.savedHostID {
                    guard let latest = state.hosts.first(where: { $0.id == savedID }),
                          latest.connectionKind == .ssh,
                          latest.hostname.lowercased() == source.hostname.lowercased(), latest.port == source.port else {
                        throw BatchError.message("A saved host is missing or its address changed. Remove it and add the intended host again.")
                    }
                    source = latest
                    if let credential = target.host.credentialID { source.credentialID = credential; source.username = "" }
                }
                let host = try await state.prepareConnection(source)
                guard current == generation else { return }
                try SharedCore.validateConnection(["protocol": "ssh", "host": host.hostname, "port": host.port, "username": host.username])
                let config = try Self.connectionConfiguration(for: target, resolvedHost: host,
                    knownHostsFile: directory.appendingPathComponent("known_hosts"))
                resolved.append(["id": target.id.uuidString, "config": config])
            }
            guard let resources, let runtime = SSH2BridgeRuntimeLocator.bundledRuntime(in: resources) else { throw BatchError.message("TermPilot Rust engine is missing. Run the packaged application.") }
            let request: [String: Any] = ["job": object, "targets": resolved, "historyDirectory": directory.appendingPathComponent("batch-history").path, "historyJobId": backgroundAction == nil ? "" : historyJobId, "backgroundAction": backgroundAction ?? ""]
            let data = try JSONSerialization.data(withJSONObject: request)
            let p = Process(); p.executableURL = runtime.executable; p.arguments = ["batch"]
            let input = Pipe(), output = Pipe(); p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
            try p.run()
            process = p; writer = BatchWriter(input.fileHandleForWriting)
            let handle = output.fileHandleForReading
            if backgroundAction == nil { backgroundTasks = []; historyJobId = ""; isHistoryReport = false }
            checks = Dictionary(uniqueKeysWithValues: selected.map { target in
                ("\(target.id.uuidString):authenticate", BatchEvent(value: ["type":"batchHost", "targetId":target.id.uuidString, "ip":target.host.hostname, "port":target.host.port, "stage":"authenticate", "status":"pending"]))
            })
            if backgroundAction == nil { steps = [:]; events = []; conflicts = []; hostStates = [:]; reportDirectory = "" }
            section = "results"; progress = [:]; prompts = []
            reader = Task.detached { [weak self] in
                do {
                    try await ProcessPipeLines.read(from: handle) { [weak self] frame in
                        await self?.receive(frame, generation: current)
                    }
                    await self?.ended(generation: current)
                } catch { await self?.ended(generation: current) }
            }
            try await writer?.send(data)
        } catch {
            guard current == generation else { return }
            self.error = error.localizedDescription
            workerFailed = true
            stopWorker()
        }
    }
    static func connectionConfiguration(
        for target: BatchTarget,
        resolvedHost host: TermPilotDomain.Host,
        knownHostsFile: URL
    ) throws -> [String: Any] {
        var config = try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as! [String: Any]
        config["privateKey"] = host.identityKey
        config["proxy"] = try host.proxyConfiguration.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        config["knownHostsFile"] = knownHostsFile.path
        config["autoAcceptHostKeys"] = AppPreferences.isAutoAcceptSSHHostKeysEnabled
        config["batchCredentialId"] = target.host.credentialID?.uuidString
        config["batchProxyProfileId"] = target.host.proxyProfileID?.uuidString
        config["batchElevation"] = target.elevation
        if !target.elevationPassword.isEmpty { config["elevationPassword"] = target.elevationPassword }
        else if target.elevation == "sudo", host.elevationPassword?.isEmpty != false { config["elevationPassword"] = host.password }
        return config
    }

    private func receive(_ data: Data, generation: UUID) {
        guard generation == self.generation, let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let event = v["event"] as? [String: Any], let type = event["type"] as? String, ["hostKeyPrompt", "credentialPrompt"].contains(type), let id = event["promptID"] as? String {
            prompts.append(BatchPrompt(id: id, ip: v["ip"] as? String ?? "", targetId: v["targetId"] as? String ?? "", value: event))
        }
        if let tasks = v["backgroundTasks"] as? [[String: Any]], let data = try? JSONSerialization.data(withJSONObject: tasks), let decoded = try? JSONDecoder().decode([BatchBackgroundTask].self, from: data) {
            backgroundTasks = decoded
        }
        if let id = v["jobId"] as? String { historyJobId = id }
        let event = BatchEvent(value: v)
        batchUpdateSteps(&steps, event)
        if event.text("type") == "batchHost", batchCheckEventStages.contains(event.text("stage")) { checks["\(event.text("targetId")):\(event.text("stage"))"] = event }
        if event.text("stage") == "finished" { prompts.removeAll { $0.targetId == event.text("targetId") } }
        if ["finished", "workspace"].contains(event.text("stage")) { let key = event.text("targetId"); let merged = (hostStates[key]?.value ?? [:]).merging(v) { _, new in new }; hostStates[key] = BatchEvent(value: merged) }
        if event.text("stage") == "conflict", !conflicts.contains(where: { $0.text("targetId") == event.text("targetId") && $0.text("remotePath") == event.text("remotePath") }) { conflicts.append(event) }
        if event.text("stage") == "upload", event.text("status") != "running", let i = conflicts.firstIndex(where: { $0.text("targetId") == event.text("targetId") && $0.text("remotePath") == event.text("remotePath") }) { conflicts[i].value["status"] = v["status"]; conflicts[i].value["backupPath"] = v["backupPath"] }
        if let raw = v["event"] as? [String: Any], raw["type"] as? String == "sftpResponse" { progress[event.text("targetId")] = event }
        if event.text("type") != "batchEvent" { events.append(event); if events.count > 3000 { events.removeFirst(events.count - 3000) } }
        if let path = v["reportDirectory"] as? String { reportDirectory = path }
        if let e = v["error"] as? String { error = e }
        if v["type"] as? String == "batchFinished" {
            receivedFinish = true
            workerFailed = !event.text("error").isEmpty
            prompts = []
        }
    }
    private func ended(generation: UUID) {
        guard generation == self.generation else { return }
        if !receivedFinish {
            workerFailed = true
            error = AppLocalization.string("Batch process ended unexpectedly. Check history; remote state may be unknown.")
        }
        running = false; prompts = []; process = nil; writer = nil; reader = nil
    }
    func cancel() async {
        guard running else { return }
        if writer == nil { stopWorker(); return }
        await send(["type": "cancel"])
    }
    func reply(_ prompt: BatchPrompt, accepted: Bool, secret: String) async {
        guard prompts.contains(where: { $0.id == prompt.id }) else { return }
        prompts.removeAll { $0.id == prompt.id }
        if prompt.value["type"] as? String == "hostKeyPrompt" { await send(["type": "hostKeyResponse", "promptID": prompt.id, "accepted": accepted]) }
        else { await send(["type": "credentialResponse", "promptID": prompt.id, "value": accepted ? secret as Any : NSNull()]) }
    }
    private func send(_ value: [String: Any]) async {
        let current = generation
        do { try await writer?.send(JSONSerialization.data(withJSONObject: value)) }
        catch { if generation == current { self.error = error.localizedDescription } }
    }
    private func stopWorker() {
        generation = UUID()
        if let process, process.isRunning { process.terminate() }
        reader?.cancel()
        reader = nil; writer = nil; process = nil; prompts = []; running = false
    }
    func shutdown() {
        guard !closed else { return }
        closed = true
        stopWorker()
    }
    func loadHistory(_ id: String? = nil) {
        guard id == nil || !running else { return }
        do {
            var request: [String: Any] = ["method": "batch.history", "directory": try VaultStore.applicationSupportDirectory().appendingPathComponent("batch-history").path]
            if let id { request["jobId"] = id }
            let result = try SharedCore.call(request); try checkError(result)
            if id != nil { hostStates = [:]; reportDirectory = try VaultStore.applicationSupportDirectory().appendingPathComponent("batch-history").appendingPathComponent(id!).path; events = (result["events"] as? [[String: Any]] ?? []).map { BatchEvent(value: $0) }; conflicts = (result["conflicts"] as? [[String: Any]] ?? []).map { BatchEvent(value: $0) } }
            else { history = result["jobs"] as? [[String: Any]] ?? [] }
            if let id {
                historyJobId = id
                isHistoryReport = true
                workerFailed = !(events.last(where: { $0.text("type") == "batchFinished" })?.text("error") ?? "").isEmpty
                backgroundTasks = (try? JSONDecoder().decode([BatchBackgroundTask].self, from: JSONSerialization.data(withJSONObject: result["backgroundTasks"] ?? []))) ?? []
                progress = [:]; running = false; error = ""
                steps = [:]
                for event in (result["steps"] as? [[String: Any]]).map({ $0.map { BatchEvent(value: $0) } }) ?? events { batchUpdateSteps(&steps, event) }
                let saved = (result["checks"] as? [[String: Any]]).map { $0.map { BatchEvent(value: $0) } } ?? events
                checks = [:]
                for e in saved where batchCheckEventStages.contains(e.text("stage")) { checks["\(e.text("targetId")):\(e.text("stage"))"] = e }
            }
        } catch { self.error = error.localizedDescription }
    }
    func restoredBackgroundTargets(state: AppState) -> [BatchTarget] {
        backgroundTasks.compactMap { task in
            guard let id = UUID(uuidString: task.targetId) else { return nil }
            let current = targets.first { $0.id == id }
            var host = current?.host ?? state.hosts.first { $0.id == id }
                ?? TermPilotDomain.Host(id: id, label: task.hostname, hostname: task.hostname, username: task.username, authentication: .password, credentialID: task.credentialId.flatMap(UUID.init(uuidString:)), proxyProfileID: task.proxyProfileId.flatMap(UUID.init(uuidString:)))
            host.hostname = task.hostname; host.port = task.port; host.username = task.username
            return BatchTarget(host: host, elevation: task.elevation, elevationPassword: current?.elevationPassword ?? "")
        }
    }
    func restoreBackgroundTargets(state: AppState) { targets = restoredBackgroundTargets(state: state) }
    private func checkError(_ value: [String: Any]) throws { if let error = value["error"] as? String { throw BatchError.message(error) } }
}
enum BatchError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return AppLocalization.string(text) }; return nil }
}

struct BatchPromptView: View {
    @ObservedObject var controller: BatchJobController
    @State private var secret = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let prompt = controller.prompts.first {
                Text(controller.title + " · " + prompt.ip).font(.headline)
                if let detail = prompt.value["detail"] as? [String: Any] {
                    Text(detail["hasHostPattern"] as? Bool == true ? "Server key changed. Verify the fingerprint." : "First connection. Verify the fingerprint.")
                    Text(detail["hostPattern"] as? String ?? "").textSelection(.enabled)
                    Text(detail["fingerprint"] as? String ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                } else { Text(prompt.value["message"] as? String ?? "Authentication"); SecureField("Password", text: $secret) }
                HStack { Button("Cancel") { secret = ""; Task { await controller.reply(prompt, accepted: false, secret: "") } }; Spacer(); Button("Continue") { let value = secret; secret = ""; Task { await controller.reply(prompt, accepted: true, secret: value) } }.buttonStyle(.borderedProminent) }
            }
        }.padding(18).frame(width: 392)
        .onChange(of: controller.prompts.first?.id) { _, _ in secret = "" }
    }
}
