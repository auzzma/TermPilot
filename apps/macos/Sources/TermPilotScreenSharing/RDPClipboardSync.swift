import AppKit
import Foundation

/// File bytes travel over CLIPRDR. AppKit receives only completed local file URLs.
@MainActor
final class RDPClipboardSync {
    var send: ([String: Any]) -> Bool = { _ in false }
    var status: (String) -> Void = { _ in }
    var ready: () -> Void = {}
    var rejected: () -> Void = {}
    private let board: NSPasteboard
    private var offered: Int?
    private var baseline: Int
    private var incomingBaseline: Int?
    private var connected = false
    private var enabled = true
    private var selected = true
    private var focused = false
    private var awaitingOffer = false
    private var blocked = false
    private var offerID: String?
    private var sentAt = Date.distantPast
    private var publication = UUID()
    init(pasteboard: NSPasteboard) { board = pasteboard; baseline = pasteboard.changeCount }
    func setConnected(_ value: Bool) {
        publication = UUID(); connected = value; offered = nil; baseline = board.changeCount; incomingBaseline = nil; awaitingOffer = false
        if value { _ = send(["kind":"clipboardSync", "enabled":enabled]); _ = send(["kind":"clipboardActive", "active":selected]) }
    }
    func setEnabled(_ value: Bool) { publication = UUID(); enabled = value; offered = nil; _ = send(["kind":"clipboardSync", "enabled":value]); if !value { incomingBaseline = nil; rejected() } }
    func setSelected(_ value: Bool) {
        guard selected != value else { return }
        publication = UUID(); selected = value; offered = nil; baseline = board.changeCount; incomingBaseline = nil; awaitingOffer = false
        _ = send(["kind":"clipboardActive", "active":value]); if !value { rejected() }
    }
    func setFocused(_ value: Bool) { focused = value; if value { tick() } }
    func tick() {
        guard connected && enabled && selected else { return }
        if awaitingOffer, Date().timeIntervalSince(sentAt) > 15 { awaitingOffer = false; blocked = true; status("文件剪贴板准备超时，请重试复制"); rejected() }
        if focused && board.changeCount != baseline { publish() }
    }
    func preparePaste() -> ScreenSharingClipboardSync.PasteDisposition {
        guard enabled else { return .ready }
        guard connected && selected else { return .blocked }
        if board.changeCount != baseline || offered != baseline { publish() }
        return blocked ? .blocked : (awaitingOffer ? .waiting : .ready)
    }
    private func publish() {
        publication = UUID(); baseline = board.changeCount; offered = baseline; incomingBaseline = nil; blocked = false
        let id = UUID().uuidString; offerID = id
        var command: [String: Any] = ["kind":"clipboardOffer", "offerId":id]
        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly:true]) as? [URL], !files.isEmpty {
            command["paths"] = files.map(\.path)
        } else if let text = board.string(forType: .string) {
            command["text"] = text
        } else { blocked = true; status("剪贴板中没有可复制的文本或文件"); return }
        guard let data = try? JSONSerialization.data(withJSONObject: command), data.count < 1_048_576 else {
            blocked = true; status("剪贴板内容过大，请减少一次复制的项目或文本"); return
        }
        awaitingOffer = send(command); blocked = !awaitingOffer; sentAt = Date()
        if blocked { status("剪贴板发送失败，请重新复制后重试") }
    }
    func remoteCopy() { publication = UUID(); baseline = board.changeCount; offered = baseline; incomingBaseline = baseline; awaitingOffer = false; offerID = nil; blocked = false }
    func preparing() { guard selected && enabled else { return }; remoteCopy(); status("正在准备剪贴板…") }
    func receive(text: String) {
        guard selected && enabled, incomingBaseline == board.changeCount else { return }
        publication = UUID(); board.clearContents(); board.setString(text, forType: .string); baseline = board.changeCount; offered = baseline; incomingBaseline = nil
    }
    func receive(paths: [String]) {
        guard selected && enabled, incomingBaseline == board.changeCount else { return }
        let token = UUID(); publication = token
        let expected = board.changeCount
        Task { [weak self] in
            let valid = await Task.detached(priority: .utility) {
                !paths.isEmpty && paths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
            }.value
            guard let self, valid, self.publication == token,
                  self.connected, self.selected, self.enabled,
                  self.incomingBaseline == expected, self.board.changeCount == expected else { return }
            let urls = paths.map { URL(fileURLWithPath: $0) }
            self.board.clearContents(); self.board.writeObjects(urls as [NSURL])
            self.baseline = self.board.changeCount; self.offered = self.baseline; self.incomingBaseline = nil
            self.status("文件已接收，可以在 Finder 中粘贴")
        }
    }

    func failed() { publication = UUID(); awaitingOffer = false; offerID = nil; blocked = true; rejected() }
    func accepted(_ success: Bool, id: String? = nil) {
        guard id == nil || id == offerID else { return }
        guard awaitingOffer else { return }; awaitingOffer = false
        if success { blocked = false; ready() } else { blocked = true; status("远端未接受文件剪贴板，请重试复制"); rejected() }
    }
}

public struct RDPCertificatePrompt: Identifiable, Sendable {
    public let id: String
    public let endpoint: String
    public let fingerprint: String
    public let message: String
}
