import AppKit
import Foundation

/// Owns only the text clipboard of the selected remote pane. Request IDs and
/// pasteboard generations keep late replies from replacing a newer local copy.
@MainActor
final class ScreenSharingClipboardSync {
    static let maximumBytes = 524_288
    var send: ([String: Any]) -> Bool = { _ in false }
    var status: (String) -> Void = { _ in }
    var pasteReady: () -> Void = {}
    var cancelPaste: () -> Void = {}
    private let pasteboard: NSPasteboard
    private let now: () -> Date
    private var enabled = false
    private var connected = false
    private var selected = true
    private var focused = false
    private var baseline = 0
    private var sharedText: String?
    private var outgoingText: String?
    private var outgoingSince = Date.distantPast
    private var remoteCopyUntil = Date.distantPast
    private var copyFetchAfter: Date?
    private var needsFetch = false
    private var applyNextReply = false
    private var remoteBaselineInitialized = false
    private var remoteText: String?
    private var nextPoll = Date.distantFuture
    private var retryAfter = Date.distantPast
    private var timedOut = false
    private var pending: (id: String, revision: Int, deadline: Date, applyRemote: Bool)?

    init(pasteboard: NSPasteboard, now: @escaping () -> Date = Date.init) {
        self.pasteboard = pasteboard
        self.now = now
    }

    func setConnected(_ value: Bool) {
        connected = value
        reset()
        baseline = pasteboard.changeCount
        if value { _ = send(["kind": "clipboardSync", "enabled": enabled]) }
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        reset()
        baseline = pasteboard.changeCount
        if connected { _ = send(["kind": "clipboardSync", "enabled": value]) }
    }

    func setSelected(_ value: Bool) {
        guard selected != value else { return }
        selected = value
        reset()
        // Switching sessions never sends the previous session's clipboard.
        baseline = pasteboard.changeCount
    }

    func setFocused(_ value: Bool) {
        focused = value
        if !value { cancelPaste() }
        else { tick() }
    }

    private var canSend: Bool { connected && enabled && selected && focused && !timedOut }
    private var canReceive: Bool {
        connected && enabled && selected && !timedOut && (focused || now() <= remoteCopyUntil)
    }

    func tick() {
        guard connected && enabled && selected && !timedOut else { return }
        if let pending, now() > pending.deadline {
            timedOut = true
            self.pending = nil
            cancelPaste()
            status("Clipboard sync timed out. Reconnect to retry.")
            return
        }
        if canSend, pasteboard.changeCount != baseline { publishLocalText() }
        if let deadline = copyFetchAfter, now() >= deadline {
            copyFetchAfter = nil
            needsFetch = true
            applyNextReply = true
        }
        // Some Macs do not notify this viewer of every generation change.
        // A bounded poll also covers Copy from a remote application's menus.
        if canSend, now() >= nextPoll { needsFetch = true }
        if canReceive, pending == nil, needsFetch, now() >= retryAfter { fetch() }
    }

    func remoteChanged() {
        guard canReceive else { return }
        needsFetch = true
        applyNextReply = true
        tick()
    }

    func remoteCopy() {
        guard canSend else { return }
        // A following remote Cmd-V must use the new remote copy, rather than
        // uploading the old local clipboard while its reply is in flight.
        pending = nil
        outgoingText = nil
        sharedText = nil
        baseline = pasteboard.changeCount
        remoteCopyUntil = now().addingTimeInterval(1.5)
        copyFetchAfter = now().addingTimeInterval(0.15)
    }

    enum PasteDisposition { case ready, waiting, blocked }
    func preparePaste() -> PasteDisposition {
        guard enabled else { return .ready }
        guard canSend else { return .blocked }
        if now() <= remoteCopyUntil, pasteboard.changeCount == baseline { return .ready }
        guard let text = localText() else {
            status("Automatic clipboard sync supports text only, up to 512 KB.")
            return .blocked
        }
        if text == sharedText, outgoingText == nil { return .ready }
        if text != outgoingText { publishLocalText(force: true) }
        return outgoingText != nil ? .waiting : .blocked
    }

    private func localText() -> String? {
        // Files/images may expose a text representation. Do not send a file
        // URL or replace a remote file clipboard with its path string.
        guard pasteboard.types?.contains(.fileURL) != true,
              let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        guard text.utf8.count <= Self.maximumBytes else {
            status("Clipboard text is too large.")
            return nil
        }
        return text
    }

    private func publishLocalText(force: Bool = false) {
        guard canSend else { return }
        baseline = pasteboard.changeCount
        guard let text = localText() else {
            outgoingText = nil
            sharedText = nil
            cancelPaste()
            return
        }
        guard force || text != sharedText else { return }
        if let outgoingText, outgoingText != text { cancelPaste() }
        guard send(["kind": "clipboardSend", "text": text]) else { return }
        outgoingText = text
        outgoingSince = now()
        remoteCopyUntil = .distantPast
        needsFetch = true
        retryAfter = .distantPast
        if pending == nil { fetch() }
    }

    private func fetch() {
        guard canReceive, pending == nil else { return }
        let id = UUID().uuidString
        pending = (id, pasteboard.changeCount, now().addingTimeInterval(5), applyNextReply)
        needsFetch = false
        applyNextReply = false
        nextPoll = now().addingTimeInterval(1)
        if !send(["kind": "clipboardFetch", "requestID": id]) { pending = nil }
    }

    func receive(id: String?, text: String?) {
        guard let request = pending, id == request.id else { return }
        pending = nil
        guard canReceive, now() <= request.deadline else {
            if outgoingText != nil { needsFetch = true }
            return
        }
        guard pasteboard.changeCount == request.revision else {
            // The local copy happened after the request. Keep that newer copy.
            tick()
            return
        }
        if let outgoingText {
            guard text == outgoingText else {
                if now().timeIntervalSince(outgoingSince) >= 5 {
                    timedOut = true
                    cancelPaste()
                    status("Clipboard sync timed out. Reconnect to retry.")
                } else {
                    needsFetch = true
                    retryAfter = now().addingTimeInterval(0.1)
                }
                return
            }
            self.outgoingText = nil
            remoteBaselineInitialized = true
            remoteText = text
            sharedText = text
            baseline = pasteboard.changeCount
            status("")
            pasteReady()
            return
        }
        let changed = remoteBaselineInitialized && text != remoteText
        remoteBaselineInitialized = true
        remoteText = text
        guard request.applyRemote || changed else { return }
        guard let text, text.utf8.count <= Self.maximumBytes else { return }
        if pasteboard.string(forType: .string) != text {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        baseline = pasteboard.changeCount
        sharedText = text
        status("")
    }

    func rejectUnsupportedText() {
        reset()
        baseline = pasteboard.changeCount
        status("Standard VNC clipboard currently supports Latin-1 text only. The text was not sent.")
    }

    private func reset() {
        pending = nil
        needsFetch = false
        applyNextReply = false
        remoteBaselineInitialized = false
        remoteText = nil
        nextPoll = now().addingTimeInterval(1)
        sharedText = nil
        outgoingText = nil
        copyFetchAfter = nil
        remoteCopyUntil = .distantPast
        retryAfter = .distantPast
        timedOut = false
        cancelPaste()
    }
}
