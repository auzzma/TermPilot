import SwiftTerm
import SwiftUI
import UIKit

@MainActor final class MobileSession: ObservableObject, Identifiable {
  let id: UInt64
  let host: JSON
  let protocolKind: String
  let terminalID: String
  let terminalView = MobileTerminalView(
    frame: .zero, font: .monospacedSystemFont(ofSize: 14, weight: .regular))
  @Published var status = "连接中"
  @Published var path = "."
  @Published var entries: [JSON] = []
  @Published var transfers: [String: JSON] = [:]
  @Published var toolsOutput = ""
  @Published var conversations: [JSON] = []
  @Published var conversation: JSON = [:]
  @Published var partial = ""
  @Published var performance: JSON = [:]
  @Published var renderedFPS = 0.0
  var videoDiagnostics = RemoteVideoDiagnostics()
  private var transferSamples: [String: (Date, Int)] = [:]
  func transferRate(_ id: String, bytes: Int) -> Double {
    let now = Date()
    defer { transferSamples[id] = (now, bytes) }
    guard let (time, done) = transferSamples[id] else { return 0 }
    return Double(max(0, bytes - done)) / max(0.01, now.timeIntervalSince(time))
  }
  let historyStarted = Date().timeIntervalSinceReferenceDate
  var historySucceeded = false
  @Published var touchpad = false
  // Kept with the session when switching panels recreates the Metal surface.
  var remoteCursorPoint: CGPoint?
  @Published var dragLocked = false
  @Published var audioEnabled = true
  @Published var controlKey = false
  @Published var altKey = false
  @Published var connected = false
  @Published var latencyMilliseconds: Int?
  func receiveLatency(status: String, message: String) -> Bool {
    guard protocolKind == "ssh", status == "latency" || status == "latency-unavailable" else { return false }
    latencyMilliseconds = status == "latency" ? SSHLatency.parse(message) : nil
    return true
  }
  @Published var keyboardVisible = false
  weak var remoteKeyboard: RemoteKeyboard.InputView?
  @Published var isClosing = false
  var frames: [Int: MobilePacket] = [:]
  @Published var frameRevision = 0
  @Published var desktopSize = CGSize(width: 1920, height: 1080)
  var ai: UInt64?
  var filesReady = false
  var execReady = false
  var terminalDelegate: TerminalAdapter?
  @Published var previewFiles: [URL] = []
  @Published var remoteFiles: [String] = []
  @Published var remoteClipboard = ""
  @Published var activePanel = "terminal"
  @Published var selectedTool = "monitor"
  var toolsReturnPanel = "terminal"
  var remoteDownloads: [String: URL] = [:]
  var localDragPaths: [String] = []
  let remoteAudio = RemoteAudio()
  init(id: UInt64, host: JSON, kind: String, terminal: String) {
    self.id = id
    self.host = host
    protocolKind = kind
    terminalID = terminal
    #if DEBUG
    // UI tests exercise interaction, not the caret's repeating UIKit animation.
    // Keep XCTest's idle/hit testing usable; release builds retain normal blinking.
    if ProcessInfo.processInfo.environment["TERMPILOT_UI_TEST_STEADY_CURSOR"] == "1" {
      terminalView.getTerminal().setCursorStyle(.steadyBlock)
      terminalView.cursorStyleChanged(source: terminalView.getTerminal(), newStyle: .steadyBlock)
    }
    #endif
    terminalView.inputAccessoryView = TerminalKeyboardAccessory(session: self)
    terminalView.focusChanged = { [weak self] visible in
      guard let self, self.protocolKind == "ssh", self.keyboardVisible != visible else { return }
      self.keyboardVisible = visible
    }
  }
  var aiScope: String {
    "host:" + host.text("id", host.text("hostname") + ":" + host.text("username"))
  }
  var label: String { host.text("label", host.text("hostname")) }
}
struct Interaction: Identifiable {
  let id = UUID()
  let session: UInt64
  let event: JSON
}

@MainActor final class AppModel: ObservableObject {
  @Published var records: [String: [JSON]] = [:]
  @Published var sessions: [MobileSession] = []
  @Published var selected: UInt64?
  @Published var error: String?
  @Published var interaction: Interaction?
  @Published var aiSettings: JSON = [:]
  @Published var transferHistory: [JSON] = []
  @Published var ready = false
  @Published var controllingWindow: String?
  func claimWindow(_ id: String, preferredSession: UInt64?) {
    for session in sessions {
      session.dismissKeyboard()
      session.controlKey = false
      session.altKey = false
      if session.protocolKind != "ssh" {
        session.dragLocked = false
        attempt { try await self.send(session.id, ["kind": "release"]) }
      }
    }
    controllingWindow = id
    selected = sessions.contains { $0.id == preferredSession } ? preferredSession : selected
    lifecycle(.active)
  }
  var settingsSession: MobileSession?
  var runtime: MobileRuntime?
  private var dataSyncTask: Task<Void, Never>?
  private var pending: [String: CheckedContinuation<JSON, Error>] = [:]
  // IDs are never reused by the runtime. Keep closed IDs so delayed view/input
  // callbacks cannot send to a session after its UI has been removed.
  private var closedSessionIDs = Set<UInt64>()
  #if DEBUG
  var keyboardFixtureCommand: ((JSON) -> Void)?
  #endif
  private var interactionQueue: [Interaction] = []
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  var current: MobileSession? { sessions.first { $0.id == selected } }
  func start() async {
    guard runtime == nil else { return }
    do {
      let engine = try MobileRuntime()
      runtime = engine
      engine.start { [weak self] packet in Task { @MainActor in self?.receive(packet) } }
      var initial:JSON=[:]
      for (field,key) in ["theme":"TermPilot.theme","language":"TermPilot.language","fontSize":"TermPilot.fontSize","fps":"TermPilot.fps","videoCodec":"TermPilot.videoCodec"] {if let value=UserDefaults.standard.object(forKey:key){initial[field]=value}}
      _ = try await call(["method":"sync.preferences","initial":true,"values":initial])
      await reload()
      transferHistory = try await call(["method": "mobile.transfers", "recover": true]).array(
        "items")
      ready = true
      dataSyncTask = Task { [weak self] in
        while !Task.isCancelled {
          if UIApplication.shared.applicationState == .active, let self {
            if let result = try? await self.call(["method":"sync.tick"]), result["skipped"] as? Bool != true {
              await self.reload()
            }
          }
          try? await Task.sleep(for:.seconds(5))
        }
      }
    } catch { self.error = error.localizedDescription }
  }
  func call(_ request: JSON) async throws -> JSON {
    guard let runtime else { throw MobileError(message: "连接引擎未启动") }
    let result=try await runtime.call(request)
    if let preferences=result["preferences"] as? JSON {
      for (field,key) in ["theme":"TermPilot.theme","language":"TermPilot.language","fontSize":"TermPilot.fontSize","fps":"TermPilot.fps","videoCodec":"TermPilot.videoCodec"] {
        if let value=preferences[field] {UserDefaults.standard.set(value,forKey:key)}
      }
    }
    return result
  }
  func attempt(_ work: @escaping () async throws -> Void) {
    Task {
      do { try await work() }
      catch is CancellationError { }
      catch { self.error = error.localizedDescription }
    }
  }
  func reload() async {
    do {
      for collection in [
        "hosts", "groups", "credentials", "proxies", "scripts", "notes", "forwards", "history",
      ] {
        records[collection] = try await call(["method": "vault.list", "collection": collection])
          .array("items")
      }
    } catch { self.error = error.localizedDescription }
  }
  func save(_ collection: String, item: JSON) async throws {
    _ = try await call(["method": "vault.save", "collection": collection, "item": item])
    await reload()
  }
  func delete(_ collection: String, id: String) async throws {
    _ = try await call(["method": "vault.delete", "collection": collection, "id": id])
    await reload()
  }
  func connect(_ saved: JSON) async throws {
    let resolved = try await call([
      "method": "resolveConnection", "host": saved, "credentials": records["credentials"] ?? [],
      "proxyProfiles": records["proxies"] ?? [],
    ]).object("host")
    var config = resolved
    if resolved.text("connectionKind", "ssh") != "ssh",
      let profile = try await call([
        "method": "vault.get", "collection": "screenSharing", "id": resolved.text("id"),
      ])["item"] as? JSON
    {
      config.merge(profile) { _, b in b }
    }
    if !resolved.text("credentialID").isEmpty {
      config["username"] = resolved["username"]
      config["password"] = resolved["password"]
    }
    let connection = resolved.text("connectionKind", "ssh")
    let kind = connection == "screenSharing" ? "screen" : connection
    let host = resolved.text("hostname")
    config["knownHostsFile"] = runtime!.directory.appendingPathComponent("known_hosts").path
    config["proxy"] = resolved["proxyConfiguration"] ?? NSNull()
    config["sessionID"] = UUID().uuidString
    config["privateKey"] = resolved["identityKey"]
    config["host"] = host
    config["videoCodec"] = UserDefaults.standard.string(forKey: "TermPilot.videoCodec") == "h265" ? "h265" : "h264"
    config["frameRate"] = UserDefaults.standard.integer(forKey: "TermPilot.fps") == 30 ? 30 : 60
    config["lockDirectory"] = runtime!.directory.appendingPathComponent("screen-lock").path
    config["clipboardDirectory"] =
      runtime!.directory.appendingPathComponent("Transfers", isDirectory: true).path
    config["cacheDirectory"] = config["clipboardDirectory"]
    config["audio"] = true
    config["clipboardSync"] = true
    config["mode"] = config.text("mode", "standardVNC")
    if kind == "rdp" { config["port"] = resolved.number("port", 3389) }
    if kind == "screen" { config["port"] = resolved.number("port", 5900) }
    let command: JSON =
      kind == "ssh"
      ? ["type": "connect", "config": config, "cols": 80, "rows": 24]
      : config.merging(["kind": "connect"]) { _, b in b }
    let result = try await call(["method": "session.open", "protocol": kind, "command": command])
    let session = MobileSession(
      id: UInt64(result.number("session")), host: config, kind: kind,
      terminal: result.text("terminal"))
    session.terminalDelegate = TerminalAdapter(session: session, model: self)
    session.terminalView.terminalDelegate = session.terminalDelegate
    sessions.append(session)
    selected = session.id
    try await recordConnection(session, ended: false)
  }
  func recordConnection(_ s: MobileSession, ended: Bool) async throws {
    let hostID =
      (records["hosts"] ?? []).contains { $0.text("id") == s.host.text("id") }
      ? s.host["id"] ?? NSNull() : NSNull()
    let row: JSON = [
      "id": s.host.text("sessionID"), "hostID": hostID, "startedAt": s.historyStarted,
      "succeeded": s.historySucceeded,
      "endedAt": ended ? Date().timeIntervalSinceReferenceDate : NSNull(),
    ]
    _ = try await call(["method": "vault.save", "collection": "history", "item": row])
    records["history"] = try await call(["method": "vault.list", "collection": "history"]).array(
      "items")
  }
  func send(_ session: UInt64, _ command: JSON) async throws {
    guard !closedSessionIDs.contains(session) else { throw CancellationError() }
    #if DEBUG
    if let keyboardFixtureCommand { keyboardFixtureCommand(command); return }
    #endif
    do {
      _ = try await call(["method": "session.send", "session": session, "command": command])
    } catch {
      if closedSessionIDs.contains(session) { throw CancellationError() }
      // The worker can close its command channel just before sessionEnded is
      // delivered. A late resize/input callback must not replace its real error.
      if (error as? MobileError)?.message == "Session is closed" { throw CancellationError() }
      throw error
    }
  }
  func sendText(_ session: MobileSession, _ text: String) {
    attempt {
      try await self.send(
        session.id,
        session.protocolKind == "ssh"
          ? ["type": "data", "data": Data(text.utf8).base64EncodedString()]
          : ["kind": "text", "text": text])
    }
  }
  func reconnect(_ session: MobileSession) async throws {
    let saved =
      (records["hosts"] ?? []).first { $0.text("id") == session.host.text("id") } ?? session.host
    try await close(session)
    try await connect(saved)
  }
  func close(_ session: MobileSession) async throws {
    guard !session.isClosing else { return }
    session.isClosing = true
    session.dismissKeyboard()
    let ids = Set([session.id] + (session.ai.map { [$0] } ?? []))
    closedSessionIDs.formUnion(ids)
    for key in pending.keys.filter({ key in ids.contains { key.hasPrefix("\($0):") } }) {
      pending.removeValue(forKey: key)?.resume(throwing: CancellationError())
    }
    interactionQueue.removeAll { ids.contains($0.session) }
    if let interaction, ids.contains(interaction.session) {
      self.interaction = interactionQueue.isEmpty ? nil : interactionQueue.removeFirst()
    }
    sessions.removeAll { $0.id == session.id }
    if selected == session.id { selected = sessions.last?.id }
    try? await recordConnection(session, ended: true)
    endRemoteTransfers(session)
    session.remoteAudio.stop()
    var failure: Error?
    for id in ids {
      do { _ = try await call(["method": "session.close", "session": id]) }
      catch { if failure == nil { failure = error } }
    }
    if let failure { throw failure }
  }
  func request(_ session: UInt64, _ command: JSON, id: String, timeout: Double = 180) async throws
    -> JSON
  {
    guard !closedSessionIDs.contains(session) else { throw CancellationError() }
    return try await withCheckedThrowingContinuation { continuation in
      let key = "\(session):\(id)"
      pending[key] = continuation
      Task {
        do { try await send(session, command) } catch {
          pending.removeValue(forKey: key)?.resume(throwing: error)
        }
      }
      Task {
        try? await Task.sleep(for: .seconds(timeout))
        pending.removeValue(forKey: key)?.resume(
          throwing: MobileError(message: "请求超时，请检查当前会话；不会自动重放操作。"))
      }
    }
  }
  func files(_ session: MobileSession, _ request: JSON) async throws -> JSON {
    guard session.filesReady else { throw MobileError(message: "文件通道尚未就绪") }
    var r = request
    let id = UUID().uuidString
    r["id"] = id
    return try await self.request(
      session.id, ["type": "sftpRequest", "channel": "files", "request": r], id: id)
  }
  func exec(_ session: MobileSession, command: String) async throws -> JSON {
    guard session.execReady else { throw MobileError(message: "工具通道尚未就绪") }
    let id = UUID().uuidString
    return try await request(
      session.id,
      [
        "type": "sftpRequest", "channel": "exec",
        "request": ["id": id, "action": "exec", "command": command, "timeoutMS": 120000],
      ], id: id)
  }
  func list(_ session: MobileSession, path: String? = nil) async throws {
    let path = path ?? session.path
    let resolved = try await files(session, ["action": "realpath", "path": path]).text("path", path)
    let result = try await files(session, ["action": "list", "path": resolved])
    session.path = resolved
    session.entries = result.array("entries").sorted { a, b in
      if (a.text("kind") == "directory") != (b.text("kind") == "directory") {
        return a.text("kind") == "directory"
      }
      return a.text("name").localizedStandardCompare(b.text("name")) == .orderedAscending
    }
  }
  func transfer(
    _ session: MobileSession, upload: Bool, local: URL, remote: String, restoring: JSON = [:]
  ) async throws {
    let id = restoring.text("id", UUID().uuidString)
    guard !["传输中", "已暂停"].contains(session.transfers[id]?.text("status") ?? "") else {
      throw MobileError(message: "该任务已在运行")
    }
    let regular: Bool
    if upload {
      regular = (try local.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
    } else {
      regular =
        try await files(session, ["action": "stat", "path": remote]).object("entry").text("kind")
        == "file"
    }
    let resumeDirectory =
      regular
      ? restoring.text(
        "resumeDirectory",
        runtime!.directory.appendingPathComponent("Transfers/Checkpoints/" + id).path) : ""
    session.transfers[id] = [
      "id": id, "name": local.lastPathComponent, "status": "传输中", "localPath": local.path,
      "upload": upload, "total": 0, "transferred": 0, "remotePath": remote,
      "resumeDirectory": resumeDirectory,
      "hostID": session.host.text("id"), "label": session.label, "protocol": "ssh",
    ]
    try await recordTransfer(session.transfers[id]!, status: "active")
    TransferBackground.shared.begin(id, title: local.lastPathComponent) { [weak self] in
      self?.attempt { try await self?.controlTransfer(session, id: id, action: "cancel") }
    }
    var successful = false
    defer { TransferBackground.shared.end(id, success: successful) }
    do {
      _ = try await request(
        session.id,
        [
          "type": "sftpRequest", "channel": "files",
          "request": [
            "id": id, "action": upload ? "upload" : "download", "localPath": local.path,
            "remotePath": remote, "overwrite": false, "resumeDirectory": resumeDirectory,
          ],
        ], id: id, timeout: 86400)
      successful = true
      session.transfers[id]?["status"] = upload ? "已完成" : "已下载，待导出"
      try await recordTransfer(session.transfers[id]!, status: upload ? "completed" : "downloaded")
      if !upload { session.previewFiles.append(local) }
      try await list(session)
    } catch {
      let cancelled = session.transfers[id]?["cancelRequested"] as? Bool == true
      session.transfers[id]?["status"] = cancelled ? "已取消" : "失败：\(error.localizedDescription)"
      try? await recordTransfer(
        session.transfers[id]!, status: cancelled ? "cancelled" : "interrupted",
        error: cancelled ? "" : error.localizedDescription)
      throw error
    }
  }
  func recordTransfer(_ item: JSON, status: String, error: String = "") async throws {
    var item = item
    item["status"] = status
    item["error"] = error
    item["updated"] = Date().timeIntervalSince1970
    transferHistory = try await call(["method": "mobile.transfer.save", "item": item]).array(
      "items")
  }
  func retryTransfer(_ record: JSON) async throws {
    guard
      let s = sessions.first(where: {
        $0.host.text("id") == record.text("hostID") && $0.connected && $0.protocolKind == "ssh"
      })
    else {
      throw MobileError(message: "请先连接这台主机，再恢复传输。不会自动连接或重放命令。")
    }
    try await transfer(
      s, upload: record["upload"] as? Bool == true,
      local: URL(fileURLWithPath: record.text("localPath")), remote: record.text("remotePath"),
      restoring: record)
  }
  func receive(_ packet: MobilePacket) {
    let event = packet.header
    let id = UInt64(event.number("session"))
    guard !closedSessionIDs.contains(id) else { return }
    guard
      let session = sessions.first(where: { $0.id == id || $0.ai == id })
        ?? (settingsSession?.ai == id ? settingsSession : nil)
    else { return }
    let type = event.text("type", event.text("kind"))
    if let responseID = event["id"] as? String, event["ok"] != nil {
      complete(id, responseID, event)
    }
    switch type {
    case "data":
      if let data = Data(base64Encoded: event.text("data")) {
        session.terminalView.feed(byteArray: Array(data)[...])
        if let ai = session.ai {
          attempt {
            try await self.send(
              ai,
              [
                "id": UUID().uuidString, "method": "terminal.output",
                "params": ["sessionId": String(session.id), "data": data.base64EncodedString()],
              ])
          }
        }
      }
    case "log":
      if id == session.id && session.receiveLatency(status: event.text("status"), message: event.text("message")) { break }
      if event.text("status") == "connected" && event.text("channel") == "terminal" {
        if !session.connected {
          session.historySucceeded = true
          attempt { try await self.recordConnection(session, ended: false) }
        }
        session.connected = true
        session.status = "已连接"
        attempt {
          try await self.send(id, ["type": "sftpOpen", "config": [:]])
          try await self.send(id, ["type": "execOpen", "config": [:]])
        }
      }
    case "sftpReady":
      session.filesReady = true
      attempt { try await self.list(session) }
    case "execReady": session.execReady = true
    case "sftpResponse":
      let response = event.object("message")
      let rid = response.text("id")
      if response.text("event") == "progress" {
        TransferBackground.shared.update(
          rid, done: Int64(response.number("transferred")), total: Int64(response.number("total")))
        session.transfers[rid]?["rate"] = session.transferRate(
          rid, bytes: response.number("transferred"))
        session.transfers[rid]?["transferred"] = response["transferred"]
        session.transfers[rid]?["total"] = response["total"]
      } else {
        complete(id, rid, response)
      }
    case "hostKeyPrompt", "credentialPrompt", "certificate", "approval", "form":
      enqueue(Interaction(session: id, event: event))
    case "status":
      session.status = event.text("stage")
      if session.status == "connected" { session.connected = true }
    case "frame":
      session.frames[event.number("tile")] = packet
      session.videoDiagnostics.received(now: ProcessInfo.processInfo.systemUptime)
      session.frameRevision += 1
      if !session.connected {
        session.historySucceeded = true
        attempt { try await self.recordConnection(session, ended: false) }
      }
      session.connected = true
      session.status = "已连接"
      if session.protocolKind == "rdp" || session.host.text("mode", "standardVNC") == "standardVNC"
      {
        session.desktopSize = CGSize(width: event.number("width"), height: event.number("height"))
      }
    case "clipboardChanged":
      attempt {
        try await self.send(id, ["kind": "clipboardFetch", "requestID": UUID().uuidString])
      }
    case "clipboard":
      session.remoteClipboard =
        event["text"] as? String ?? String(decoding: packet.data, as: UTF8.self)
    case "remoteDrag": session.remoteFiles = event["paths"] as? [String] ?? []
    case "clipboardFiles":
      if let paths = event["paths"] as? [String]
        ?? (try? JSONSerialization.jsonObject(with: packet.data) as? [String])
      {
        session.previewFiles = paths.map { URL(fileURLWithPath: $0) }
        recordReceivedFiles(session, paths)
      }
    case "fileTransfer":
      noteRemoteTransfer(session, event)
      let rid = event.text("id", event.text("requestID"))
      var progress = session.transfers[rid] ?? [:]
      progress.merge([
        "id": rid, "name": event.text("name", progress.text("name", "文件")),
        "status": event.text("stage"), "total": event.number("totalBytes"),
        "transferred": event.number("completedBytes"),
      ]) { _, b in b }
      progress["rate"] =
        event.text("stage") == "transferring"
        ? session.transferRate(rid, bytes: event.number("completedBytes")) : 0
      session.transfers[rid] = progress
      if event.text("stage") == "completed",
        let file = session.remoteDownloads.removeValue(forKey: rid)
      {
        session.previewFiles.append(file)
      }
    case "audio":
      if UIApplication.shared.applicationState == .active && session.id == selected
        && session.audioEnabled
      {
        session.remoteAudio.append(packet.data)
      }
    case "performance": session.performance = event
    case "mediaDiagnostics":
      if let data = try? JSONSerialization.data(withJSONObject: event),
         let media = try? JSONDecoder().decode(RemoteMediaDiagnostics.self, from: data) {
        session.videoDiagnostics.media = media
      }
    case "conversation":
      session.conversation = event.object("conversation")
      session.partial = ""
    case "delta": session.partial += event.text("text")
    case "toolRequest": attempt { try await self.aiTool(session, event: event) }
    case "error": error = event.text("message", event.text("code", "连接失败"))
    case "sessionEnded", "disconnected", "exit":
      closedSessionIDs.insert(id)
      interactionQueue.removeAll { $0.session == id }
      if interaction?.session == id {
        interaction = interactionQueue.isEmpty ? nil : interactionQueue.removeFirst()
      }
      for key in pending.keys.filter({ $0.hasPrefix("\(id):") }) {
        pending.removeValue(forKey: key)?.resume(
          throwing: MobileError(message: event.text("error", "连接已断开")))
      }
      // AI workers have a separate lifetime; their exit must not disconnect SSH/RDP.
      if session.ai == id { session.ai = nil; return }
      attempt { try await self.recordConnection(session, ended: true) }
      endRemoteTransfers(session)
      session.dismissKeyboard()
      session.remoteAudio.stop()
      session.connected = false
      session.latencyMilliseconds = nil
      session.filesReady = false
      session.execReady = false
      session.renderedFPS = 0
      session.status = "已断开"
    default: break
    }
  }
  private func complete(_ session: UInt64, _ id: String, _ response: JSON) {
    guard let continuation = pending.removeValue(forKey: "\(session):\(id)") else { return }
    if response["ok"] as? Bool == true {
      continuation.resume(
        returning: response["result"] as? JSON ?? ["items": response["result"] ?? []])
    } else {
      continuation.resume(throwing: MobileError(message: response.text("error", "操作失败")))
    }
  }
  private func enqueue(_ item: Interaction) {
    if interaction == nil { interaction = item } else { interactionQueue.append(item) }
  }
  func answer(_ item: Interaction, allow: Bool, value: String = "", fields: JSON = [:]) async throws
  {
    let event = item.event
    let type = event.text("type", event.text("kind"))
    let command: JSON
    switch type {
    case "hostKeyPrompt":
      command = ["type": "hostKeyResponse", "promptID": event.text("promptID"), "accepted": allow]
    case "credentialPrompt":
      command = [
        "type": "credentialResponse", "promptID": event.text("promptID"),
        "value": allow ? value : NSNull(),
      ]
    case "form":
      command = [
        "id": UUID().uuidString, "method": "interaction.reply",
        "params": [
          "requestId": event.text("requestId"), "value": ["cancelled": !allow, "values": fields],
        ],
      ]
    case "certificate":
      command = ["kind": "certificateDecision", "id": event.text("id"), "accept": allow]
    default:
      command = [
        "id": UUID().uuidString, "method": "interaction.reply",
        "params": [
          "requestId": event.text("requestId"), "value": ["allow": allow, "always": false],
        ],
      ]
    }
    try await send(item.session, command)
    interaction = interactionQueue.isEmpty ? nil : interactionQueue.removeFirst()
  }
  func lifecycle(_ phase: ScenePhase) {
    guard runtime != nil else { return }
    if phase == .active {
      for s in sessions where s.protocolKind != "ssh" {
        attempt {
          try await self.send(
            s.id, ["kind": "audio", "enabled": s.id == self.selected && s.audioEnabled])
        }
      }
      for s in sessions where s.protocolKind == "rdp" {
        attempt {
          try await self.send(s.id, ["kind": "clipboardActive", "active": s.id == self.selected])
        }
      }
      if backgroundTask != .invalid {
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
      }
    } else if phase == .background {
      for s in sessions { s.dismissKeyboard() }
      for s in sessions where s.protocolKind == "rdp" {
        attempt { try await self.send(s.id, ["kind": "clipboardActive", "active": false]) }
      }
      for s in sessions where s.protocolKind != "ssh" {
        s.remoteAudio.stop()
        s.dragLocked = false
        attempt {
          try await self.send(s.id, ["kind": "release"])
          try await self.send(s.id, ["kind": "audio", "enabled": false])
        }
      }
      backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "TermPilot transfers") {
        [weak self] in
        Task { @MainActor in
          guard let self else { return }
          if !TransferBackground.shared.hasActiveTask {
            for s in self.sessions { try? await self.close(s) }
          }
          if self.backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
          }
        }
      }
    }
  }
}
