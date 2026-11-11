import AppKit
import TermPilotRemoteDiagnostics
import TermPilotCore
import AVFoundation
import Combine
import Darwin
import Foundation
import OSLog
import TermPilotDomain

public struct ScreenSharingEngineLaunch: Sendable {
    public var executable: URL
    public var lockDirectory: URL
    public init(executable: URL, lockDirectory: URL) {
        self.executable = executable; self.lockDirectory = lockDirectory
    }
}

private final class ScreenSharingProcess: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    private let writer = DispatchQueue(label: "termpilot.screen-sharing.input")
    let exited = DispatchGroup()
    init() {
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        exited.enter()
        process.terminationHandler = { [exited] _ in exited.leave() }
    }
    func waitForExit() async {
        await withCheckedContinuation { continuation in
            exited.notify(queue: .global()) { continuation.resume() }
        }
    }
    func write(_ data: Data) {
        writer.async { [input] in try? input.fileHandleForWriting.write(contentsOf: data) }
    }
    func stop() {
        write(Data("{\"kind\":\"disconnect\"}\n".utf8))
        writer.async { [input] in try? input.fileHandleForWriting.close() }
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) {
            if process.isRunning { process.terminate() }
        }
    }
    deinit { if process.isRunning { process.terminate() } }
}

@MainActor
public final class ScreenSharingSessionRuntime: ObservableObject {
    private static let fileLogger = Logger(subsystem: "com.termpilot.app", category: "ScreenSharingFiles")
    func recordFileDrag(_ stage: String, count: Int = 0) {
        Self.fileLogger.notice("\(stage, privacy: .public); items=\(count, privacy: .public)")
    }
    public let descriptor: SessionDescriptor
    public let proxyConfiguration: SSHProxyConfiguration?
    public var isStandardVNC: Bool { descriptor.screenSharingMode == .standardVNC }
    public var isRDP: Bool { descriptor.screenSharingMode == .rdp }
    public var supportsFileTransfer: Bool { !isStandardVNC && !isRDP }
    @Published public var certificatePrompt: RDPCertificatePrompt?
    @Published public private(set) var desktopSize = CGSize(width: 1920, height: 1080)
    @Published public private(set) var highPerformanceResolution: HighPerformanceResolution = .fullHD
    @Published public private(set) var lifecycle: SessionLifecycle = .disconnected
    @Published public private(set) var hasReceivedFrame = false
    @Published public private(set) var decoderName = ""
    @Published public private(set) var status = ""
    @Published public private(set) var connectionDiagnostics = ""
    @Published public private(set) var isEnteringLoginPassword = false
    @Published public private(set) var loginPasswordStatus = ""
    @Published public var audioEnabled: Bool
    public var onMediaServiceInterrupted: (() -> Void)?
    public var onFileTransferChange: ((ScreenSharingFileTransfer) -> Void)?
    @Published public private(set) var fileTransfers: [ScreenSharingFileTransfer] = []
    @Published public private(set) var performance = ScreenSharingPerformance.unavailable
    @Published public private(set) var frameRate = RemoteDesktopPreferences.frameRate()
    var videoDiagnostics = RemoteVideoDiagnostics()
    private var performanceMeter = ScreenSharingPerformanceMeter(now: ProcessInfo.processInfo.systemUptime)
    private var performanceTask: Task<Void, Never>?
    var remoteDragPaths: [String] = []
    var remoteDragChanged: (() -> Void)?
    private var fileCompletions: [String: ((any Error)?) -> Void] = [:]
    var mailbox = ScreenSharingMailbox()
    private let quickConnectPassword: String?
    let loginInput = ScreenSharingLoginInput()
    private var connection: ScreenSharingProcess?
    private var stoppingHelper: DispatchGroup?
    private var generation = UUID()
    private let clipboardSync: ScreenSharingClipboardSync
    private let rdpClipboard: RDPClipboardSync
    private var clipboardPollTask: Task<Void, Never>?
    private var commandKeys = Set<UInt32>()
    private var waitingForClipboard = false
    private var deferredKeys: [ScreenSharingKeyStroke] = []
    private var watchdog: Task<Void, Never>?
    private var mediaRecoveryTask: Task<Void, Never>?
    private var mediaRecoveryFailures: [Date] = []
    private var firstFrameRetries = 0
    var firstFrameTimeout: Duration = .seconds(15)
    private(set) var mediaBrokerProcessID: Int32?
    private var visible = true
    private let audioPlayer = ScreenSharingAudioPlayer()

    public init(descriptor: SessionDescriptor, pasteboard: NSPasteboard = .general, proxyConfiguration: SSHProxyConfiguration? = nil, quickConnectPassword: String? = nil) {
        self.quickConnectPassword = quickConnectPassword
        self.descriptor = descriptor
        self.proxyConfiguration = proxyConfiguration
        self.audioEnabled = descriptor.screenSharingMode != .standardVNC && (descriptor.screenSharingAudio ?? true)
        self.clipboardSync = ScreenSharingClipboardSync(pasteboard: pasteboard)
        self.rdpClipboard = RDPClipboardSync(pasteboard: pasteboard)
        clipboardSync.send = { [weak self] in self?.send($0) ?? false }
        clipboardSync.status = { [weak self] in self?.status = $0 }
        clipboardSync.pasteReady = { [weak self] in self?.flushPendingPaste() }
        clipboardSync.cancelPaste = { [weak self] in self?.cancelPendingPaste() }
        rdpClipboard.send = { [weak self] in self?.send($0) ?? false }
        rdpClipboard.status = { [weak self] in self?.status = $0 }
        rdpClipboard.ready = { [weak self] in self?.flushPendingPaste() }
        rdpClipboard.rejected = { [weak self] in self?.cancelPendingPaste() }
        loginInput.send = { [weak self] in self?.send($0) ?? false }
        loginInput.isAvailable = { [weak self] in self?.canSendLoginPassword == true }
        loginInput.changed = { [weak self] in
            guard let self else { return }
            self.isEnteringLoginPassword = self.loginInput.isRunning
            self.loginPasswordStatus = self.loginInput.message
        }
    }

    public func disconnectedCopy(for descriptor: SessionDescriptor) -> ScreenSharingSessionRuntime {
        let copy = ScreenSharingSessionRuntime(descriptor: descriptor, proxyConfiguration: proxyConfiguration, quickConnectPassword: quickConnectPassword)
        copy.highPerformanceResolution = highPerformanceResolution
        return copy
    }

    public var isActive: Bool {
        if case .connecting = lifecycle { return true }
        if case .connected = lifecycle { return true }
        return false
    }

    public var canSendLoginPassword: Bool {
        !isStandardVNC && !isRDP && lifecycle == .connected && hasReceivedFrame && visible
    }
    public func beginLoginPasswordInput() -> UUID? {
        guard canSendLoginPassword, !isEnteringLoginPassword else { return nil }
        releaseInput()
        return loginInput.begin()
    }
    public func enterLoginPassword(_ password: String?, operation: UUID) async {
        await loginInput.perform(password: password ?? quickConnectPassword, operation: operation)
    }
    public func loginPasswordInputFailed(_ message: String, operation: UUID) {
        loginInput.fail(message, operation: operation)
    }

    public func connectionFailed(_ message: String) { disconnect(); connectionDiagnostics = ""; fail(message) }

    public func connect(password: String, launch: ScreenSharingEngineLaunch) {
        connect(password: password, launch: launch, proxyConfiguration: self.proxyConfiguration)
    }

    public func connect(password: String?, launch: ScreenSharingEngineLaunch, proxyConfiguration proxy: SSHProxyConfiguration?) {
        disconnect()
        loginInput.reset()
        connectionDiagnostics = ""
        let id = generation
        // Wait for this session's old helper to release its broker lease before
        // reconnecting the same remote endpoint. Other sessions remain active.
        if let stoppingHelper, stoppingHelper.wait(timeout: .now()) == .timedOut {
            status = "Connecting"
            lifecycle = .connecting
            stoppingHelper.notify(queue: .main) { [weak self] in
                guard let self, self.generation == id else { return }
                self.start(password: password, launch: launch, proxy: proxy)
            }
        } else {
            start(password: password, launch: launch, proxy: proxy)
        }
    }

    private func start(password: String?, launch: ScreenSharingEngineLaunch, proxy: SSHProxyConfiguration?) {
        stoppingHelper = nil
        if (descriptor.proxyProfileID != nil || descriptor.customProxyConfigured == true), proxy == nil {
            fail("The proxy configuration is unavailable. Reopen Quick Connect and select the proxy again."); return
        }
        do {
            var policy: [String: Any] = ["protocol": (descriptor.screenSharingMode ?? .highPerformance).rawValue,
                "host": descriptor.hostname ?? "", "port": descriptor.port ?? 5900, "username": descriptor.username ?? "",
                "proxyRequired": descriptor.proxyProfileID != nil || descriptor.customProxyConfigured == true]
            if let proxy { policy["proxy"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proxy)) }
            try SharedCore.validateConnection(policy)
            try ScreenSharingEndpoint.validateProxy(profileID: descriptor.proxyProfileID,
                configuration: proxy, mode: descriptor.screenSharingMode ?? .highPerformance)
        } catch { fail(error.localizedDescription); return }
        guard ScreenSharingEndpoint.isValid(host: descriptor.hostname ?? "", port: descriptor.port ?? 5900,
                                             username: descriptor.username ?? "", mode: descriptor.screenSharingMode ?? .highPerformance) else {
            fail("Screen Sharing requires a host, username, and password."); return
        }
        guard let password = password ?? quickConnectPassword, isStandardVNC || !password.isEmpty else {
            fail("No desktop credential is available. Update the saved host or open Quick Connect again."); return
        }
        let executable = isRDP ? launch.executable.deletingLastPathComponent().appendingPathComponent("termpilot-rdp") : launch.executable
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            fail("Screen Sharing runtime is missing. Rebuild the app with its bundled runtime."); return
        }
        let id = UUID(); generation = id
        hasReceivedFrame = false; decoderName = ""; status = "Connecting"
        videoDiagnostics = RemoteVideoDiagnostics()
        connectionDiagnostics = "stage=startup"
        mailbox = ScreenSharingMailbox()
        let mailbox = mailbox
        let client = ScreenSharingProcess()
        do {
            let plan = try SharedCore.engineLaunch(engine: "screenSharing", runtime: executable.path)
            client.process.executableURL = URL(fileURLWithPath: plan.executable)
            client.process.arguments = plan.arguments
        } catch { fail(error.localizedDescription); return }
        // Do not inherit Python injection, packet-capture, or debug settings.
        client.process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        client.process.standardInput = client.input
        client.process.standardOutput = client.output
        client.process.standardError = FileHandle.nullDevice
        do {
            try client.process.run()
            connection = client
            lifecycle = .connecting
            var configuration: [String: Any] = ["kind": "connect", "host": descriptor.hostname ?? "", "port": descriptor.port ?? 5900,
                  "username": descriptor.username ?? "", "password": password, "audio": audioEnabled && visible,
                  "mode": (descriptor.screenSharingMode ?? .highPerformance).rawValue, "frameRate": frameRate,
            "videoCodec": RemoteDesktopPreferences.videoCodec(),
                  "lockDirectory": launch.lockDirectory.path]
            if !isStandardVNC && !isRDP {
                configuration["width"] = highPerformanceResolution.width
                configuration["height"] = highPerformanceResolution.height
            }
            if var proxy {
                proxy.credentialID = nil
                configuration["proxy"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proxy))
            }
            send(configuration)
            let handle = client.output.fileHandleForReading
            Task.detached(priority: .userInitiated) { [weak self] in
                var parser = ScreenSharingPacketDecoder()
                var receivedFrame = false
                do {
                    var storage = [UInt8](repeating: 0, count: 262_144)
                    while true {
                        // FileHandle.read(upToCount:) may wait for a full buffer
                        // on a pipe. Read available packets without delaying a
                        // small status message or the last frame of a still screen.
                        let count = Darwin.read(handle.fileDescriptor, &storage, storage.count)
                        if count == 0 { break }
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw ScreenSharingWireError.invalidMessage
                        }
                        let bytes = Data(storage.prefix(count))
                        for (header, data) in try parser.append(bytes) {
                            if header.kind == "frame" {
                                mailbox.put(ScreenSharingFrame(header: header, data: data))
                                if !receivedFrame {
                                    receivedFrame = true
                                    await self?.receivedFirstFrame(generation: id)
                                }
                            } else if header.kind == "audio" { mailbox.putAudio(data) }
                            else { await self?.receive(header, payload: data, generation: id) }
                        }
                    }
                    if parser.hasIncompletePacket { throw ScreenSharingWireError.invalidMessage }
                } catch {
                    await self?.invalidStream(generation: id)
                }
                try? handle.close()
                await client.waitForExit()
                await self?.processEnded(status: client.process.terminationStatus, generation: id)
            }
            armConnectionWatchdog(generation: id)
        } catch {
            fail("Screen Sharing runtime could not start.")
        }
    }

    // Drain the helper's final error packet before assigning a generic exit state.
    private func processEnded(status: Int32, generation id: UUID) {
        guard generation == id else { return }
        watchdog?.cancel()
        audioPlayer.stop()
        connection = nil
        stopClipboardSync()
        stopPerformanceUpdates()
        finishFilePromises()
        if case .failed = lifecycle { return }
        if status != 0 { fail("Screen Sharing connection failed.") }
        else if isRDP && !hasReceivedFrame && lifecycle != .disconnected {
            fail("RDP connection ended before a desktop was received. Reconnect or update the application.")
        } else { lifecycle = .disconnected }
    }

    private func armConnectionWatchdog(generation id: UUID) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self, self.generation == id, !self.hasReceivedFrame else { return }
            self.disconnect()
            self.fail(self.isRDP ? "RDP 未收到桌面画面，请检查账户、服务器及代理连接。" : self.isStandardVNC
                ? "No VNC display received. Check the server, account, and proxy connection."
                : "No video received. Check Screen Sharing permissions and UDP ports 5900–5902.")
        }
    }

    private func armFirstFrameWatchdog(generation id: UUID) {
        guard !isStandardVNC, !isRDP, !hasReceivedFrame else { return }
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            guard let delay = self?.firstFrameTimeout else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.generation == id,
                  self.lifecycle == .connected, !self.hasReceivedFrame else { return }
            // A successful control handshake is not proof of working media.
            // Recreate only this session once, retaining the shared broker and
            // other Macs. This budget does not expire during a slow retry.
            if self.firstFrameRetries == 0 {
                self.firstFrameRetries += 1
                if self.recoverMediaService(reason: "firstFrameRecovery") { return }
            }
            self.disconnect()
            self.connectionDiagnostics = "stage=video; code=firstFrameTimeout"
            self.fail("The remote Mac connected but no video arrived. Reconnect or check the remote sharing service and network.")
        }
    }

    /// Explicit user reconnects get a fresh budget; automatic retries do not.
    public func resetAutomaticRecovery() {
        firstFrameRetries = 0
        mediaRecoveryFailures.removeAll()
    }

    public func disconnect() {
        finishFilePromises()
        generation = UUID()
        watchdog?.cancel(); watchdog = nil
        mediaRecoveryTask?.cancel(); mediaRecoveryTask = nil
        mediaBrokerProcessID = nil
        certificatePrompt = nil
        releaseInput()
        if let client = connection {
            stoppingHelper = client.exited
            client.stop()
            connection = nil
        }
        stopClipboardSync()
        stopPerformanceUpdates()
        audioPlayer.stop()
        lifecycle = .disconnected
        hasReceivedFrame = false
        mailbox = ScreenSharingMailbox()
    }
    public func releaseInput() {
        loginInput.cancel()
        cancelPendingPaste()
        commandKeys.removeAll()
        send(["kind": "release"])
    }
    public func setVisible(_ visible: Bool) {
        self.visible = visible
        clipboardSync.setSelected(visible)
        if isRDP { rdpClipboard.setSelected(visible) }
        releaseInput()
        _ = mailbox.takeAudio()
        send(["kind": "audio", "enabled": visible && audioEnabled])
        if !visible { audioPlayer.stop() }
    }
    public func setAudioEnabled(_ enabled: Bool) {
        audioEnabled = enabled
        send(["kind": "audio", "enabled": enabled && visible])
        if !enabled { audioPlayer.stop() }
    }
    public func refresh() { send(["kind": "refresh"]) }
    public func setFrameRate(_ value: Int) {
        let value = RemoteDesktopPreferences.normalizedFrameRate(value)
        guard frameRate != value else { return }
        frameRate = value
        send(["kind": "frameRate", "fps": value])
    }
    public func sendSecureAttention() { send(["kind":"secureAttention"]) }
    public func resizeRDP(width: Int, height: Int) { send(["kind":"resize", "width":width, "height":height]) }
    /// The app reconnects through its normal credential and helper-exit path.
    @discardableResult
    public func selectHighPerformanceResolution(_ value: HighPerformanceResolution) -> Bool {
        guard !isStandardVNC, !isRDP, highPerformanceResolution != value else { return false }
        highPerformanceResolution = value
        return true
    }
    public func sendText(_ text: String) { guard !isEnteringLoginPassword else { return }; send(["kind":"text", "text":text]) }
    public func answerCertificate(_ accepted: Bool) {
        guard let prompt = certificatePrompt else { return }
        certificatePrompt = nil
        send(["kind":"certificateDecision", "id":prompt.id, "accept":accepted])
        if !accepted { disconnect() } else { armConnectionWatchdog(generation: generation) }
    }
    public func cancelTransfer() { send(["kind":"cancelTransfer"]) }
    func recordPresentedFrame() {
        performanceMeter.presentedFrame()
        videoDiagnostics.rendered(now: ProcessInfo.processInfo.systemUptime)
    }
    public func videoDiagnosticsReport(localize: (String) -> String = { $0 }) -> String {
        var snapshot = videoDiagnostics
        (snapshot.receivedFrames, snapshot.lastFrameAt) = mailbox.reception()
        if !decoderName.isEmpty { snapshot.renderer += "\nDecoder: \(decoderName)" }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return snapshot.report(platform: "TermPilot · build \(build) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            mode: isRDP ? "RDP" : isStandardVNC ? "VNC" : "Apple High Performance",
            resolution: "\(Int(desktopSize.width)) × \(Int(desktopSize.height))",
            fps: performance.framesPerSecond, received: performance.receiveBytesPerSecond,
            sent: performance.sendBytesPerSecond, now: ProcessInfo.processInfo.systemUptime, localize: localize)
    }
    private func startPerformanceUpdates() {
        stopPerformanceUpdates()
        performanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.performance = self.performanceMeter.sample(now: ProcessInfo.processInfo.systemUptime)
            }
        }
    }
    private func stopPerformanceUpdates() {
        performanceTask?.cancel(); performanceTask = nil
        performanceMeter = ScreenSharingPerformanceMeter(now: ProcessInfo.processInfo.systemUptime)
        performance = .unavailable
    }
    func beginLocalDrag(_ urls: [URL]) -> Bool {
        guard supportsFileTransfer, hasReceivedFrame, (1...256).contains(urls.count), urls.allSatisfy(\.isFileURL) else { return false }
        recordFileDrag("localDragEntered", count: urls.count)
        return send(["kind": "dragEnter", "paths": urls.map(\.path)])
    }
    func commitLocalDrag() { recordFileDrag("localDragDropped"); send(["kind": "dragDrop"]) }
    func cancelLocalDrag() { send(["kind": "dragCancel"]); releaseInput() }
    func requestRemoteDrag() { if supportsFileTransfer { send(["kind": "dragRequest"]) } }
    func downloadPromisedFile(_ path: String, to url: URL, completion: @escaping ((any Error)?) -> Void) {
        guard supportsFileTransfer, hasReceivedFrame else { completion(CocoaError(.fileWriteUnknown)); return }
        recordFileDrag("filePromiseAccepted", count: 1)
        let id = UUID().uuidString
        fileCompletions[id] = completion
        if !send(["kind": "fileDownload", "requestID": id, "source": path, "destination": url.path]) {
            fileCompletions.removeValue(forKey: id)?(CocoaError(.fileWriteUnknown))
        }
    }
    public func pauseFileTransfer(_ id: String) { send(["kind": isRDP ? "pauseTransfer" : "filePause", "requestID": id]) }
    public func resumeFileTransfer(_ id: String) { send(["kind": isRDP ? "resumeTransfer" : "fileResume", "requestID": id]) }
    public func cancelFileTransfer(_ id: String) { send(["kind": isRDP ? "cancelTransfer" : "fileCancel", "requestID": id]) }
    public func clearFinishedFileTransfers() { fileTransfers.removeAll { $0.isFinished } }
    private func finishFilePromises() {
        remoteDragPaths = []
        let callbacks = fileCompletions.values
        fileCompletions.removeAll()
        callbacks.forEach { $0(CocoaError(.userCancelled)) }
        for index in fileTransfers.indices where !fileTransfers[index].isFinished {
            fileTransfers[index].stage = "failed"
            fileTransfers[index].error = "disconnected"
            onFileTransferChange?(fileTransfers[index])
        }
    }
    public func setClipboardSyncEnabled(_ enabled: Bool) { if isRDP { rdpClipboard.setEnabled(enabled) } else { clipboardSync.setEnabled(enabled) } }
    public func setClipboardFocused(_ focused: Bool) { if isRDP { rdpClipboard.setFocused(focused) } else { clipboardSync.setFocused(focused) } }

    public func sendKey(_ key: UInt32, down: Bool) {
        if isEnteringLoginPassword {
            if key == 0xff1b, down { releaseInput() }
            return
        }
        if isRDP {
            if key == 0xffeb || key == 0xffec { if down { commandKeys.insert(key) } else { commandKeys.remove(key) } }
            let mapped: UInt32 = (key == 0xffeb || key == 0xffec) ? 0xffe3 : key
            if waitingForClipboard { guard deferredKeys.count < 128 else { cancelPendingPaste(); return }; deferredKeys.append(ScreenSharingKeyStroke(key: mapped, down: down)); return }
            if down, !commandKeys.isEmpty, key == 0x76 || key == 0x56 {
                switch rdpClipboard.preparePaste() {
                case .waiting: waitingForClipboard = true; deferredKeys = [ScreenSharingKeyStroke(key: mapped, down: down)]; return
                case .blocked: cancelPendingPaste(); return
                case .ready: break
                }
            }
            send(["kind":"key", "key":mapped, "down":down])
            if down, !commandKeys.isEmpty, key == 0x63 || key == 0x43 { rdpClipboard.remoteCopy() }
            return
        }
        if key == 0xffeb || key == 0xffec {
            if down { commandKeys.insert(key) } else { commandKeys.remove(key) }
        }
        if waitingForClipboard {
            guard deferredKeys.count < 128 else { cancelPendingPaste(); return }
            deferredKeys.append(ScreenSharingKeyStroke(key: key, down: down))
            return
        }
        if down, !commandKeys.isEmpty, key == 0x76 || key == 0x56 {
            switch clipboardSync.preparePaste() {
            case .waiting:
                waitingForClipboard = true
                deferredKeys = [ScreenSharingKeyStroke(key: key, down: down)]
                return
            case .blocked:
                commandKeys.removeAll()
                send(["kind": "release"])
                return
            case .ready: break
            }
        }
        send(["kind": "key", "key": key, "down": down])
        if down, !commandKeys.isEmpty, [0x63, 0x43, 0x78, 0x58].contains(key) { clipboardSync.remoteCopy() }
    }

    private func flushPendingPaste() {
        guard waitingForClipboard else { return }
        waitingForClipboard = false
        let keys = deferredKeys
        deferredKeys.removeAll()
        for event in keys { send(["kind": "key", "key": event.key, "down": event.down]) }
    }

    private func cancelPendingPaste() {
        guard waitingForClipboard else { return }
        waitingForClipboard = false
        deferredKeys.removeAll()
        commandKeys.removeAll()
        send(["kind": "release"])
    }

    private func startClipboardSync() {
        if isRDP { rdpClipboard.setConnected(true) } else { clipboardSync.setConnected(true) }
        clipboardPollTask?.cancel()
        clipboardPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                if self?.isRDP == true { self?.rdpClipboard.tick() } else { self?.clipboardSync.tick() }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func stopClipboardSync() {
        clipboardPollTask?.cancel()
        clipboardPollTask = nil
        clipboardSync.setConnected(false)
        rdpClipboard.setConnected(false)
    }
    public func sendPointer(x: Int, y: Int, buttons: Int) {
        guard !isEnteringLoginPassword else { return }
        if buttons != 0 { cancelPendingPaste() }
        send(["kind": "pointer", "x": x, "y": y, "buttons": buttons])
    }
    public func sendScroll(_ dy: Int) { guard !isEnteringLoginPassword else { return }; send(["kind": "scroll", "dy": dy]) }

    func playAudio() {
        let chunks = mailbox.takeAudio()
        if audioEnabled && visible { chunks.forEach { audioPlayer.play($0) } }
    }
    @discardableResult
    private func send(_ command: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: command), data.count < 1_048_576,
              let connection else { return false }
        connection.write(data + Data([10]))
        return true
    }
    private func updateDesktopSize(_ event: ScreenSharingMessage) {
        guard let width = event.width, let height = event.height,
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 16_777_216 else { return }
        desktopSize = CGSize(width: width, height: height)
    }
    private func receivedFirstFrame(generation id: UUID) {
        guard generation == id else { return }
        firstFrameRetries = 0
        hasReceivedFrame = true; watchdog?.cancel()
    }
    private func invalidStream(generation id: UUID) {
        guard generation == id else { return }
        disconnect(); fail("Invalid screen-sharing data received.")
    }
    private func receive(_ event: ScreenSharingMessage, payload: Data, generation id: UUID) {
        guard generation == id else { return }
        switch event.kind {
        case "credentialKeySent": if let requestID = event.requestID { loginInput.acknowledge(requestID) }
        case "certificate":
            watchdog?.cancel()
            certificatePrompt = RDPCertificatePrompt(id: event.id ?? "", endpoint: event.endpoint ?? "", fingerprint: event.sha256 ?? "", message: event.message ?? "")
        case "clipboardOfferAccepted": rdpClipboard.accepted(event.accepted == true, id: event.offerId)
        case "clipboardPreparing": rdpClipboard.preparing()
        case "clipboardFiles": if isRDP { rdpClipboard.receive(paths: event.paths ?? (try? JSONDecoder().decode([String].self, from: payload)) ?? []) }
        case "audioError": status = event.message ?? "远程音频播放失败"
        case "clipboardError": status = event.message ?? "文件剪贴板错误"; rdpClipboard.failed()
        case "connected":
            updateDesktopSize(event)
            lifecycle = .connected; decoderName = event.decoder ?? ""; status = ""
            startClipboardSync()
            startPerformanceUpdates()
            armFirstFrameWatchdog(generation: id)
        case "desktopSize": updateDesktopSize(event)
        case "clipboardUnsupported": clipboardSync.rejectUnsupportedText()
        case "mediaDiagnostics": videoDiagnostics.media = event.mediaDiagnostics
        case "mediaTransport": mediaBrokerProcessID = event.brokerPID
        case "performance":
            performanceMeter.receiveTraffic(received: event.receiveBytesPerSecond,
                sent: event.sendBytesPerSecond, now: ProcessInfo.processInfo.systemUptime)
        case "status":
            if isRDP { status = event.stage ?? ""; return }
            let titles = ["startup": "Starting Screen Sharing", "resolve": "Resolving Remote Mac",
                          "udpBind": "Preparing Media Ports", "tcp": "Connecting to Remote Mac",
                          "authenticate": "Authenticating Remote Account", "negotiate": "Negotiating Virtual Display",
                          "video": "Waiting for Remote Video", "decode": "Starting Video Decoder"]
            if let stage = event.stage, let title = titles[stage] {
                status = isStandardVNC && stage == "negotiate" ? "Negotiating VNC Desktop" : title
                connectionDiagnostics = "stage=\(stage)"
            }
        case "error":
            if isRDP { disconnect(); fail(event.message ?? event.code ?? "RDP 连接失败"); return }
            if event.code == "mediaBrokerDisconnected", recoverMediaService() { return }
            let safeCode = (event.code ?? "unknown").filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }.prefix(80)
            connectionDiagnostics += "; code=\(safeCode)"
            let message: String
            switch event.code {
            case "busy": message = "Another screen-sharing connection is active. Disconnect it first."
            case "screenSessionAlreadyActive": message = "A high-performance connection to this Mac is already active. Open that session or disconnect it before reconnecting."
            case "legacyScreenSessionActive": message = "An older TermPilot screen-sharing session is active. Disconnect that session and retry."
            case "mediaBrokerDisconnected": message = "The shared screen-sharing service stopped. Reconnect this session."
            case "mediaBrokerUnavailable": message = "The shared screen-sharing service could not start. Reopen TermPilot and retry."
            case "mediaBrokerVersion": message = "The screen-sharing service version does not match. Close all TermPilot screen-sharing sessions and retry."
            case "udpPortsInUse": message = "UDP media ports are in use. Disconnect the system Screen Sharing session or another remote desktop viewer, then retry."
            case "serverProof": message = "The remote Mac's authentication proof could not be verified."
            case "authenticationRejected": message = "The remote Mac rejected authentication. Check the account and password."
            case "networkPermission": message = "Allow TermPilot to access the local network in System Settings, then retry."
            case "connectionRefused": message = "The remote Mac refused the connection. Check the address, port, and sharing service."
            case "addressNotAvailable": message = "The local network address is unavailable. Check the network or VPN connection and reconnect."
            case "connectionTimeout": message = "The remote Mac did not respond before the connection timed out."
            case "runtimeDependency": message = "A Screen Sharing runtime dependency could not load. Reinstall the complete app."
            case "consoleAccount": message = "Log in to the remote Mac using the same account as this connection."
            case "displayMode": message = "The remote Mac did not accept the selected resolution. Choose another resolution and reconnect."
            case "proxyConnectionFailed": message = "Could not reach the proxy. Check its address and port."
            case "proxyAuthentication": message = "Proxy authentication failed. Check the proxy credential."
            case "proxyRejected": message = "The proxy rejected this connection. Check its rules and target port."
            case "vncProxyUnsupported": message = "Standard VNC supports HTTP and SOCKS5 proxies. ProxyCommand is only available for SSH."
            case "vncAuthenticationUnsupported": message = "The VNC server does not offer compatible authentication. Use a Mac account or VNC password."
            case "vncPasswordEncoding": message = "Classic VNC passwords must use Latin-1 characters."
            case "vncProtocolUnsupported", "vncEncodingUnsupported": message = "The server requested an unsupported VNC protocol or encoding."
            case "vncDesktopTooLarge": message = "The VNC desktop exceeds the supported 16-megapixel limit."
            case "vncInvalidData": message = "Invalid VNC screen data received."
            case "vncInputFailed": message = "The VNC connection stopped accepting input."
            default: message = "Screen Sharing could not connect. Check the account, permissions, and network."
            }
            disconnect()
            fail(message)
        case "disconnected":
            if isRDP && !hasReceivedFrame {
                disconnect()
                fail(event.message ?? "RDP connection ended before a desktop was received. Reconnect or update the application.")
                return
            }
            lifecycle = .disconnected; audioPlayer.stop(); stopClipboardSync()
            stopPerformanceUpdates()
            finishFilePromises()
        case "remoteDrag":
            remoteDragPaths = (event.paths ?? []).filter { $0.hasPrefix("/") && !$0.contains("\0") }
            recordFileDrag("remoteDragMetadata", count: remoteDragPaths.count)
            remoteDragChanged?()
        case "fileTransferDiagnostic":
            if let detail = event.message {
                Self.fileLogger.notice("fileIntegrity: \(detail, privacy: .public)")
            }
        case "fileTransfer":
            let id = event.requestID ?? event.id ?? UUID().uuidString
            let previous = fileTransfers.first { $0.id == id }
            let transfer = ScreenSharingFileTransfer(id: id, name: event.name ?? previous?.name ?? "",
                direction: event.direction ?? previous?.direction ?? "", stage: event.stage ?? "failed",
                completedBytes: max(0, event.completedBytes ?? previous?.completedBytes ?? 0),
                totalBytes: max(0, event.totalBytes ?? previous?.totalBytes ?? 0), error: event.error ?? event.code)
            if let index = fileTransfers.firstIndex(where: { $0.id == id }) { fileTransfers[index] = transfer }
            else { fileTransfers.append(transfer) }
            if fileTransfers.count > 256, let index = fileTransfers.firstIndex(where: \.isFinished) { fileTransfers.remove(at: index) }
            onFileTransferChange?(transfer)
            if transfer.isFinished {
                recordFileDrag("fileTransfer.\(transfer.stage).\(transfer.error ?? "ok")")
                fileCompletions.removeValue(forKey: id)?(transfer.stage == "completed" ? nil : CocoaError(.fileWriteUnknown))
            }
        case "clipboardChanged": clipboardSync.remoteChanged()
        case "clipboard":
            if isRDP { rdpClipboard.receive(text: event.text ?? String(data: payload, encoding: .utf8) ?? ""); return }
            let text = event.hasText == true && payload.count <= ScreenSharingClipboardSync.maximumBytes
                ? String(data: payload, encoding: .utf8) : nil
            clipboardSync.receive(id: event.requestID, text: text)
        default: break
        }
    }

    private func recoverMediaService(reason: String = "mediaRecovery") -> Bool {
        guard !isStandardVNC, !isRDP, onMediaServiceInterrupted != nil else { return false }
        let now = Date()
        mediaRecoveryFailures.removeAll { now.timeIntervalSince($0) > 60 }
        guard mediaRecoveryFailures.count < 2 else { return false }
        mediaRecoveryFailures.append(now)
        disconnect()
        let id = generation
        lifecycle = .connecting
        status = reason == "firstFrameRecovery" ? "Retrying Remote Video" : "Recovering Screen Sharing"
        connectionDiagnostics = "stage=\(reason)"
        mediaRecoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.generation == id else { return }
            self.onMediaServiceInterrupted?()
        }
        return true
    }
    func renderingUnavailable() {
        disconnect(); fail("Metal rendering is unavailable on this Mac.")
    }
    private func fail(_ message: String) { lifecycle = .failed(message); status = message }
}

@MainActor
private final class ScreenSharingAudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var prepared = false
    private var scheduledFrames = 0
    private var generation = UUID()
    func play(_ data: Data) {
        let count = data.count / 8
        guard count > 0, data.count % 8 == 0, scheduledFrames + count <= 24_000 else { return }
        if !prepared { engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format); prepared = true }
        if !engine.isRunning {
            do { try engine.start(); player.play() } catch { return }
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                channels[0][i] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt32.self).littleEndian)
                channels[1][i] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: i * 8 + 4, as: UInt32.self).littleEndian)
            }
        }
        scheduledFrames += count
        let id = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                self.scheduledFrames -= count
            }
        }
    }
    func stop() {
        generation = UUID(); scheduledFrames = 0
        player.stop(); engine.stop(); engine.reset()
    }
}
