import AppKit
import Combine
import Foundation
@preconcurrency import SwiftTerm
import SwiftUI
import TermPilotDomain
import TermPilotRemote

public struct TerminalContextMenuTitles: Equatable, Sendable {
    public var copy: String
    public var paste: String
    public var pasteSelectedText: String

    public init(
        copy: String,
        paste: String,
        pasteSelectedText: String
    ) {
        self.copy = copy
        self.paste = paste
        self.pasteSelectedText = pasteSelectedText
    }

    public static let english = TerminalContextMenuTitles(
        copy: "Copy",
        paste: "Paste",
        pasteSelectedText: "Paste Selected Text"
    )
}

private final class AutoStartingTerminalView:
    LocalProcessTerminalView,
    NSMenuDelegate
{
    private static let cursorBlinkAnimationKey =
        "termpilot.cursor-blink"
    private static let cursorColor = NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 88.0 / 255.0, green: 166.0 / 255.0, blue: 1, alpha: 1)
        }
        return NSColor(srgbRed: 9.0 / 255.0, green: 105.0 / 255.0, blue: 218.0 / 255.0, alpha: 1) // #0969da
    })
    private static let cursorTextColor = NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 13.0 / 255.0, green: 17.0 / 255.0, blue: 23.0 / 255.0, alpha: 1)
        }
        return NSColor(srgbRed: 246.0 / 255.0, green: 248.0 / 255.0, blue: 250.0 / 255.0, alpha: 1) // #f6f8fa
    })
    private static let selectionBackgroundColor = NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 38.0 / 255.0, green: 79.0 / 255.0, blue: 120.0 / 255.0, alpha: 1)
        }
        return NSColor(srgbRed: 178.0 / 255.0, green: 209.0 / 255.0, blue: 255.0 / 255.0, alpha: 1) // #b2d1ff
    })
    private static let selectionForegroundColor = NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 201.0 / 255.0, green: 209.0 / 255.0, blue: 217.0 / 255.0, alpha: 1)
        }
        return NSColor(srgbRed: 36.0 / 255.0, green: 41.0 / 255.0, blue: 47.0 / 255.0, alpha: 1) // #24292f
    })

    weak var runtime: TerminalSessionRuntime?
    var contextMenuTitles = TerminalContextMenuTitles.english
    private var bypassesTermPilotInputProcessing = false
    private var autocompleteOverlay: TerminalAutocompleteOverlayView?
    private weak var cursorObservedWindow: NSWindow?

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func applyTermPilotCursorStyle() {
        caretViewTracksFocus = true
        caretColor = Self.cursorColor
        caretTextColor = Self.cursorTextColor
        selectedTextBackgroundColor = Self.selectionBackgroundColor
        selectedTextForegroundColor = Self.selectionForegroundColor
        getTerminal().setCursorStyle(.steadyBlock)
        applyTermPilotCursorBlinkAnimation()
    }

    override var hasFocus: Bool {
        get {
            super.hasFocus
        }
        set {
            super.hasFocus = newValue
            applyTermPilotCursorBlinkAnimation()
            if newValue {
                DispatchQueue.main.async { [weak self] in
                    guard self?.hasFocus == true else {
                        return
                    }
                    self?.applyTermPilotCursorBlinkAnimation()
                }
            }
        }
    }

    override func cursorStyleChanged(
        source: Terminal,
        newStyle _: CursorStyle
    ) {
        super.cursorStyleChanged(source: source, newStyle: .steadyBlock)
        applyTermPilotCursorBlinkAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeCursorWindowFocusChanges()
        applyTermPilotCursorStyle()
        runtime?.startIfDisplayed()
        runtime?.focusIfRequestedAfterDisplay()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        applyTermPilotCursorBlinkAnimation()
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        applyTermPilotCursorBlinkAnimation()
        let menu = terminalContextMenu()
        let location = convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: location, in: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        terminalContextMenu()
    }

    private func terminalContextMenu() -> NSMenu {
        let hasSelection = selectedTerminalText != nil
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) {
            menu.automaticallyInsertsWritingToolsItems = false
        }
        menu.delegate = self
        menu.addItem(
            contextMenuItem(
                title: contextMenuTitles.copy,
                systemImage: "doc.on.doc",
                action: #selector(copyFromContextMenu(_:)),
                isEnabled: hasSelection
            )
        )
        menu.addItem(
            contextMenuItem(
                title: contextMenuTitles.paste,
                systemImage: "doc.on.clipboard",
                action: #selector(pasteFromContextMenu(_:)),
                isEnabled: true
            )
        )
        menu.addItem(
            contextMenuItem(
                title: contextMenuTitles.pasteSelectedText,
                systemImage: "text.insert",
                action: #selector(pasteSelectedTextFromContextMenu(_:)),
                isEnabled: hasSelection
            )
        )
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeInjectedContextMenuItems(from: menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        removeInjectedContextMenuItems(from: menu)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let displayBytes = runtime?.processOutputForDisplay(slice) ?? Array(slice)
        guard !displayBytes.isEmpty else {
            return
        }
        let preservesSelection = selectionActive
        let previousMouseReporting = allowMouseReporting
        if preservesSelection {
            allowMouseReporting = false
        }
        defer {
            if preservesSelection {
                allowMouseReporting = previousMouseReporting
            }
        }
        super.dataReceived(slice: displayBytes[...])
        autocompleteOverlay?.updateLayout()
    }

    override func send(
        source: TerminalView,
        data: ArraySlice<UInt8>
    ) {
        let bytes = bypassesTermPilotInputProcessing
            ? Array(data)
            : (
                runtime?.processUserInputForProcess(
                    data,
                    renderedLine: currentRenderedLine()
                )
                ?? Array(data)
            )
        guard !bytes.isEmpty else {
            return
        }
        super.send(source: source, data: bytes[...])
    }

    override func layout() {
        super.layout()
        autocompleteOverlay?.updateLayout()
    }

    func currentRenderedLine() -> String? {
        let terminal = getTerminal()
        let row = terminal.getCursorLocation().y
        guard let current = terminal.getLine(row: row)?
            .translateToString(trimRight: true)
        else {
            return nil
        }
        if Self.containsPromptBoundary(current) {
            return current
        }

        var combined = current
        for previousRow in stride(
            from: row - 1,
            through: max(0, row - 4),
            by: -1
        ) {
            guard previousRow >= 0,
                  let previous = terminal.getLine(row: previousRow)?
                    .translateToString(trimRight: true)
            else {
                continue
            }
            combined = previous + combined
            if Self.containsPromptBoundary(previous) {
                return combined
            }
        }
        return current
    }

    func sendPasswordPromptSecret(_ value: String) {
        sendWithoutTermPilotInputProcessing(value)
    }

    func sendAutocompleteText(_ value: String) {
        sendWithoutTermPilotInputProcessing(value)
    }

    func installAutocompleteOverlay(
        onSelectSuggestion: @escaping (Int) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        guard autocompleteOverlay == nil else {
            return
        }
        let overlay = TerminalAutocompleteOverlayView(terminalView: self)
        overlay.onSelectSuggestion = onSelectSuggestion
        overlay.onDismiss = onDismiss
        addSubview(overlay, positioned: .above, relativeTo: nil)
        autocompleteOverlay = overlay
    }

    func updateAutocomplete(
        _ presentation: TerminalAutocompletePresentation
    ) {
        autocompleteOverlay?.update(presentation)
    }

    func stopAutocompleteOverlayMonitoring() {
        autocompleteOverlay?.stopMonitoring()
    }

    private var selectedTerminalText: String? {
        guard selectionActive,
              let selectedText = getSelection(),
              !selectedText.isEmpty
        else {
            return nil
        }
        return selectedText
    }

    func applyTermPilotCursorBlinkAnimation() {
        guard let caretView = subviews.first(where: {
            String(describing: type(of: $0)).contains("CaretView")
        }), let caretLayer = caretView.layer else {
            return
        }
        caretView.needsDisplay = true
        caretLayer.removeAnimation(forKey: #keyPath(CALayer.opacity))
        caretLayer.opacity = 1
        guard hasFocus else {
            caretLayer.removeAnimation(
                forKey: Self.cursorBlinkAnimationKey
            )
            return
        }
        guard caretLayer.animation(
            forKey: Self.cursorBlinkAnimationKey
        ) == nil else {
            return
        }

        let animation = CAKeyframeAnimation(
            keyPath: #keyPath(CALayer.opacity)
        )
        animation.values = [1, 0, 1]
        animation.keyTimes = [0, 0.5, 1]
        animation.duration = 1.2
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete
        animation.delegate = TerminalCursorAnimationDelegate(
            terminalView: self
        )
        caretLayer.add(
            animation,
            forKey: Self.cursorBlinkAnimationKey
        )
    }

    private func observeCursorWindowFocusChanges() {
        let center = NotificationCenter.default
        if let cursorObservedWindow {
            center.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: cursorObservedWindow
            )
            center.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: cursorObservedWindow
            )
        }
        cursorObservedWindow = window
        guard let window else {
            return
        }
        center.addObserver(
            self,
            selector: #selector(cursorWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(cursorWindowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc
    private func cursorWindowDidBecomeKey(_: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.applyTermPilotCursorBlinkAnimation()
        }
    }

    @objc
    private func cursorWindowDidResignKey(_: Notification) {
        applyTermPilotCursorBlinkAnimation()
    }

    private func removeInjectedContextMenuItems(from menu: NSMenu) {
        let actions = [
            #selector(copyFromContextMenu(_:)),
            #selector(pasteFromContextMenu(_:)),
            #selector(pasteSelectedTextFromContextMenu(_:)),
        ]
        for item in menu.items where
            item.target !== self
                || item.action.map({ !actions.contains($0) }) != false
        {
            menu.removeItem(item)
        }
    }

    private func contextMenuItem(
        title: String,
        systemImage: String,
        action: Selector,
        isEnabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = isEnabled
        item.image = NSImage(
            systemSymbolName: systemImage,
            accessibilityDescription: title
        )
        return item
    }

    @objc
    private func copyFromContextMenu(_ sender: NSMenuItem) {
        copy(sender)
    }

    @objc
    private func pasteFromContextMenu(_ sender: NSMenuItem) {
        paste(sender)
    }

    @objc
    private func pasteSelectedTextFromContextMenu(_: NSMenuItem) {
        guard let selectedText = selectedTerminalText else {
            return
        }
        let usesBracketedPaste = getTerminal().bracketedPasteMode
        if usesBracketedPaste {
            send(txt: "\u{1B}[200~")
        }
        send(txt: selectedText)
        if usesBracketedPaste {
            send(txt: "\u{1B}[201~")
        }
    }

    private func sendWithoutTermPilotInputProcessing(_ value: String) {
        bypassesTermPilotInputProcessing = true
        send(txt: value)
        bypassesTermPilotInputProcessing = false
    }

    private static func containsPromptBoundary(_ value: String) -> Bool {
        value.range(
            of: #"[$#%>❯❮→➜➤⟩»›]\s"#,
            options: .regularExpression
        ) != nil
            || value.last.map {
                "$#%>❯❮→➜➤⟩»›".contains($0)
            } == true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        terminalFileDropOperation(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        terminalFileDropOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = terminalDroppedFileURLs(from: sender)
        let input = TerminalDroppedFileFormatter.input(forFileURLs: urls)
        guard !input.isEmpty else {
            return false
        }
        window?.makeFirstResponder(self)
        runtime?.sendText(input)
        return true
    }
}

private final class TerminalCursorAnimationDelegate:
    NSObject,
    CAAnimationDelegate,
    @unchecked Sendable
{
    private weak var terminalView: AutoStartingTerminalView?

    init(terminalView: AutoStartingTerminalView) {
        self.terminalView = terminalView
    }

    nonisolated func animationDidStop(
        _: CAAnimation,
        finished: Bool
    ) {
        guard !finished else {
            return
        }
        Task { @MainActor [weak terminalView] in
            guard terminalView?.hasFocus == true else {
                return
            }
            terminalView?.applyTermPilotCursorBlinkAnimation()
        }
    }
}

public final class TerminalContentInsetView: NSView {
    private let leadingInset: CGFloat
    let terminalView: LocalProcessTerminalView

    init(
        terminalView: LocalProcessTerminalView,
        leadingInset: CGFloat
    ) {
        self.terminalView = terminalView
        self.leadingInset = leadingInset
        super.init(frame: .zero)
        wantsLayer = true
        syncBackgroundWithCurrentAppearance()
        addSubview(terminalView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func layout() {
        super.layout()
        syncBackgroundWithCurrentAppearance()
        terminalView.frame = CGRect(
            x: leadingInset,
            y: 0,
            width: max(0, bounds.width - leadingInset),
            height: bounds.height
        )
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncBackgroundWithCurrentAppearance()
    }

    func syncBackgroundWithCurrentAppearance() {
        layer?.backgroundColor = resolvedTerminalBackgroundColor().cgColor
    }

    private func resolvedTerminalBackgroundColor() -> NSColor {
        let appearance = window?.effectiveAppearance ?? effectiveAppearance
        var color = terminalView.nativeBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            color = terminalView.nativeBackgroundColor.usingColorSpace(.sRGB)
                ?? terminalView.nativeBackgroundColor
        }
        return color
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        guard hitView === self, point.x < leadingInset else {
            return hitView
        }
        return terminalView
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        let interactionWidth = min(
            max(leadingInset, 0),
            bounds.width
        )
        guard interactionWidth > 0, bounds.height > 0 else {
            return
        }
        addCursorRect(
            NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: interactionWidth,
                height: bounds.height
            ),
            cursor: .iBeam
        )
    }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        terminalFileDropOperation(sender)
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        terminalFileDropOperation(sender)
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = terminalDroppedFileURLs(from: sender)
        let input = TerminalDroppedFileFormatter.input(forFileURLs: urls)
        guard !input.isEmpty else {
            return false
        }
        window?.makeFirstResponder(terminalView)
        terminalView.send(txt: input)
        return true
    }
}

enum TerminalDroppedFileFormatter {
    static func input(forFileURLs urls: [URL]) -> String {
        let paths = urls
            .map(displayPath)
            .filter { !$0.isEmpty }
            .map(shellQuotedPath)
        guard !paths.isEmpty else {
            return ""
        }
        return "\(paths.joined(separator: " ")) "
    }

    private static func displayPath(for url: URL) -> String {
        var path = url.path
        guard !path.isEmpty else {
            return path
        }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))
            .flatMap(\.isDirectory)
            ?? url.hasDirectoryPath
        if isDirectory, !path.hasSuffix("/") {
            path += "/"
        }
        return path
    }

    private static func shellQuotedPath(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

@MainActor
private func terminalDroppedFileURLs(from sender: any NSDraggingInfo) -> [URL] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
    ]
    let urls = sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self],
        options: options
    ) as? [URL]
    return urls ?? []
}

@MainActor
private func terminalFileDropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
    terminalDroppedFileURLs(from: sender).isEmpty ? [] : .copy
}

private enum SSH2BridgeControlFraming {
    static let start = "\u{1E}[ssh2:"
    static let end: Character = "\u{1F}"
    static let startBytes = Array(start.utf8)
    static let endByte: UInt8 = 0x1F
}

private struct SSH2BridgeDisplayFilter {
    private var pendingBytes: [UInt8] = []
    private var filteringControlRecord = false

    mutating func reset() {
        pendingBytes.removeAll(keepingCapacity: true)
        filteringControlRecord = false
    }

    mutating func filter(_ slice: ArraySlice<UInt8>) -> [UInt8] {
        var input = pendingBytes + Array(slice)
        pendingBytes.removeAll(keepingCapacity: true)
        var output: [UInt8] = []

        while !input.isEmpty {
            if filteringControlRecord {
                guard let recordEnd = input.firstIndex(
                    of: SSH2BridgeControlFraming.endByte
                ) else {
                    pendingBytes = input
                    return output
                }
                input.removeSubrange(input.startIndex...recordEnd)
                filteringControlRecord = false
                continue
            }

            if let prefixRange = input.firstRange(
                of: SSH2BridgeControlFraming.startBytes
            ) {
                output.append(contentsOf: input[..<prefixRange.lowerBound])
                input.removeSubrange(input.startIndex..<prefixRange.upperBound)
                filteringControlRecord = true
                continue
            }

            let pendingCount = possiblePrefixSuffixLength(in: input)
            output.append(contentsOf: input.dropLast(pendingCount))
            pendingBytes = Array(input.suffix(pendingCount))
            return output
        }

        return output
    }

    private func possiblePrefixSuffixLength(in bytes: [UInt8]) -> Int {
        let prefix = SSH2BridgeControlFraming.startBytes
        let maxLength = min(bytes.count, prefix.count - 1)
        guard maxLength > 0 else {
            return 0
        }

        for length in stride(from: maxLength, through: 1, by: -1) {
            if Array(bytes.suffix(length)) == Array(prefix.prefix(length)) {
                return length
            }
        }
        return 0
    }
}

public struct ConnectionLogEntry: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
    }
}

public struct SSHHostKeyPrompt: Equatable, Sendable {
    public var hostPattern: String
    public var algorithm: String
    public var fingerprint: String
    public var hasExistingHostPattern: Bool

    public init(
        hostPattern: String,
        algorithm: String,
        fingerprint: String,
        hasExistingHostPattern: Bool
    ) {
        self.hostPattern = hostPattern
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.hasExistingHostPattern = hasExistingHostPattern
    }
}

private struct SSH2BridgeHostKeyPromptDetail: Decodable {
    var hostPattern: String
    var algorithm: String
    var fingerprint: String
    var hasHostPattern: Bool?
}

public enum TerminalLatencyQuality: Equatable, Sendable {
    case good
    case elevated
    case poor

    public static func classify(milliseconds: Int) -> Self {
        if milliseconds <= 150 {
            return .good
        }
        if milliseconds <= 400 {
            return .elevated
        }
        return .poor
    }
}

@MainActor
public final class TerminalSessionRuntime: NSObject, ObservableObject {
    public let descriptor: SessionDescriptor

    @Published public private(set) var lifecycle: SessionLifecycle
    @Published public private(set) var title: String
    @Published public private(set) var currentDirectory: String?
    @Published public private(set) var currentUser: String?
    @Published public private(set) var remoteServerVersion: String?
    @Published public private(set) var latencyMilliseconds: Int?
    @Published public private(set) var generation = 0
    @Published public private(set) var launchRequested: Bool
    @Published public private(set) var connectionLog: [ConnectionLogEntry]
    @Published public private(set) var hostKeyPrompt: SSHHostKeyPrompt?
    @Published public private(set) var passwordPromptRequest: PasswordPromptRequest?

    public var surfaceIdentity: String {
        "\(descriptor.id.uuidString)-\(generation)"
    }

    var hasPendingFocusRequest: Bool {
        focusWhenDisplayedRequested
    }

    private let launchConfiguration: ProcessLaunchConfiguration
    private let registry: TerminalSessionRegistry
    private var terminalView: LocalProcessTerminalView?
    private var focusWhenDisplayedRequested = false
    private var contextMenuTitles = TerminalContextMenuTitles.english
    private var started = false
    private var loggedWaitingForDisplay = false
    private var processOutputBuffer = ""
    private var ssh2BridgeDisplayFilter = SSH2BridgeDisplayFilter()
    private var passwordPromptAssistMode = PasswordPromptAssistMode.off
    private var passwordPromptCredentials: [PasswordPromptCredential] = []
    private var passwordPromptDetector = PasswordPromptDetector()
    private var terminalCommandInputBuffer = TerminalCommandInputBuffer()
    private lazy var autocompleteController = TerminalAutocompleteController(
        descriptor: descriptor
    )
    private var isPasswordInputActive = false
    private var passwordPromptSelectedIndex = 0
    private var automaticPasswordPromptSecret: String?
    private var automaticPasswordPromptKind: PasswordPromptCommandKind?
    private var automaticPasswordPromptExpiresAt = Date.distantPast
    private var automaticPasswordPromptGeneration = 0

    public init(
        descriptor: SessionDescriptor,
        launchConfiguration: ProcessLaunchConfiguration,
        registry: TerminalSessionRegistry,
        initialLifecycle: SessionLifecycle = .disconnected,
        startOnDisplay: Bool = true
    ) {
        self.descriptor = descriptor
        self.launchConfiguration = launchConfiguration
        self.registry = registry
        lifecycle = startOnDisplay && initialLifecycle == .disconnected
            ? .connecting
            : initialLifecycle
        title = descriptor.title
        currentDirectory = descriptor.workingDirectory
        currentUser = descriptor.kind == .ssh ? descriptor.username : NSUserName()
        remoteServerVersion = nil
        latencyMilliseconds = nil
        launchRequested = startOnDisplay
        connectionLog = [
            ConnectionLogEntry(
                message: startOnDisplay
                    ? "Session queued; waiting for terminal surface."
                    : "Session restored; reconnect to start a new process."
            ),
        ]
        hostKeyPrompt = nil
        passwordPromptRequest = nil
        super.init()
    }

    public func view() -> LocalProcessTerminalView {
        if let terminalView {
            return terminalView
        }

        appendConnectionLog("Terminal surface created.")
        let view = AutoStartingTerminalView(frame: .zero)
        view.runtime = self
        view.contextMenuTitles = contextMenuTitles
        view.processDelegate = self
        view.autoresizingMask = [.width, .height]
        view.nativeForegroundColor = NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(calibratedRed: 0.83, green: 0.86, blue: 0.90, alpha: 1)
            }
            return NSColor(srgbRed: 36.0 / 255.0, green: 41.0 / 255.0, blue: 47.0 / 255.0, alpha: 1) // #24292f
        })
        view.nativeBackgroundColor = NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(calibratedRed: 0.055, green: 0.067, blue: 0.09, alpha: 1)
            }
            return NSColor(srgbRed: 246.0 / 255.0, green: 248.0 / 255.0, blue: 250.0 / 255.0, alpha: 1) // #f6f8fa
        })
        view.font = TerminalFontPreferences.preferredFont(
            defaultSize: descriptor.fontSize
        )
        view.registerForDraggedTypes([.fileURL])
        view.applyTermPilotCursorStyle()
        view.installAutocompleteOverlay(
            onSelectSuggestion: { [weak self] index in
                self?.autocompleteController.selectSuggestion(at: index)
            },
            onDismiss: { [weak self] in
                self?.autocompleteController.close()
            }
        )
        autocompleteController.onWrite = { [weak view] text in
            view?.sendAutocompleteText(text)
        }
        autocompleteController.onInputLineReplace = { [weak self] value in
            self?.terminalCommandInputBuffer.replace(with: value)
        }
        autocompleteController.onPresentationChange = { [weak view] presentation in
            view?.updateAutocomplete(presentation)
        }
        autocompleteController.currentDirectory = { [weak self] in
            self?.currentDirectory
        }
        view.updateAutocomplete(autocompleteController.presentation)
        view.setAccessibilityLabel("Terminal: \(descriptor.title)")
        terminalView = view
        return view
    }

    public func startIfDisplayed() {
        guard terminalView?.window != nil else {
            logWaitingForDisplay()
            return
        }
        startIfNeeded()
    }

    public func reconnect() {
        terminalView?.terminate()
        terminalView = nil
        autocompleteController.invalidateRemoteDirectoryProvider()
        started = false
        launchRequested = true
        lifecycle = .connecting
        generation += 1
        remoteServerVersion = nil
        latencyMilliseconds = nil
        resetPasswordPromptAssist()
        resetConnectionLog("Reconnect requested; waiting for terminal surface.")
        reportLifecycle(.connecting)
    }

    public func terminate() {
        appendConnectionLog("Terminate requested.")
        terminalView?.terminate()
        autocompleteController.invalidateRemoteDirectoryProvider()
        launchRequested = false
        hostKeyPrompt = nil
        latencyMilliseconds = nil
        resetPasswordPromptAssist()
        lifecycle = .disconnected
        reportLifecycle(.disconnected)
    }

    public func focus() {
        guard let terminalView,
              let window = terminalView.window
        else {
            focusWhenDisplayedRequested = true
            return
        }
        focusWhenDisplayedRequested = false
        window.makeFirstResponder(terminalView)
        (terminalView as? AutoStartingTerminalView)?
            .applyTermPilotCursorBlinkAnimation()
    }

    fileprivate func focusIfRequestedAfterDisplay() {
        guard focusWhenDisplayedRequested else {
            return
        }
        focus()
    }

    public func copySelection() {
        terminalView?.copy(self)
    }

    public func paste() {
        terminalView?.paste(self)
    }

    public func configureContextMenu(
        titles: TerminalContextMenuTitles
    ) {
        contextMenuTitles = titles
        (terminalView as? AutoStartingTerminalView)?
            .contextMenuTitles = titles
    }

    public func sendText(
        _ text: String,
        automaticPassword: String? = nil
    ) {
        if let automaticPassword,
           !automaticPassword.isEmpty,
           let kind = PasswordPromptDetector.commandKind(text)
        {
            automaticPasswordPromptGeneration &+= 1
            let generation = automaticPasswordPromptGeneration
            automaticPasswordPromptSecret = automaticPassword
            automaticPasswordPromptKind = kind
            automaticPasswordPromptExpiresAt = Date()
                .addingTimeInterval(10)
            passwordPromptDetector.arm(for: text)
            Task { @MainActor [weak self] in
                try? await Task.sleep(
                    nanoseconds: 10_000_000_000
                )
                guard let self,
                      self.automaticPasswordPromptGeneration
                        == generation
                else {
                    return
                }
                self.clearAutomaticPasswordPrompt()
            }
        }
        terminalView?.send(txt: text)
    }

    public func configurePasswordPromptAssist(
        mode: PasswordPromptAssistMode,
        credentials: [PasswordPromptCredential]
    ) {
        passwordPromptAssistMode = mode
        var seenPasswords = Set<String>()
        passwordPromptCredentials = credentials.filter {
            !$0.password.isEmpty && seenPasswords.insert($0.password).inserted
        }
        if mode == .off || passwordPromptCredentials.isEmpty {
            resetPasswordPromptAssist()
        } else if passwordPromptRequest != nil {
            passwordPromptRequest = makePasswordPromptRequest(
                for: passwordPromptDetector.armedKind ?? .sudo
            )
        }
    }

    public func configureAutocomplete(
        enabled: Bool,
        showsGhostText: Bool,
        showsPopupMenu: Bool
    ) {
        autocompleteController.configure(
            TerminalAutocompleteSettings(
                enabled: enabled,
                showsGhostText: showsGhostText,
                showsPopupMenu: showsPopupMenu
            )
        )
    }

    public func configureAutocompleteRemoteDirectoryProvider(
        listDirectory:
            @escaping @Sendable (
                _ path: String,
                _ foldersOnly: Bool,
                _ filterPrefix: String,
                _ limit: Int
            ) async -> [TerminalAutocompleteDirectoryEntry],
        close: @escaping @Sendable () async -> Void
    ) {
        autocompleteController.remoteDirectoryProvider = listDirectory
        autocompleteController.closeRemoteDirectoryProvider = close
    }

    public func closeAutocomplete() {
        autocompleteController.close()
        (terminalView as? AutoStartingTerminalView)?
            .stopAutocompleteOverlayMonitoring()
    }

    public func selectPasswordPromptCredential(id: String? = nil) {
        guard let request = passwordPromptRequest else {
            return
        }
        let selectedID = id
            ?? selectedPasswordPromptItem(in: request)?.id
        guard let selectedID,
              let credential = passwordPromptCredentials.first(
                  where: { $0.id == selectedID }
              )
        else {
            dismissPasswordPromptAssist()
            return
        }
        passwordPromptRequest = nil
        isPasswordInputActive = false
        passwordPromptDetector.markFilled()
        (terminalView as? AutoStartingTerminalView)?
            .sendPasswordPromptSecret("\(credential.password)\n")
        focus()
    }

    public func dismissPasswordPromptAssist() {
        passwordPromptRequest = nil
        passwordPromptDetector.dismiss()
    }

    public func respondToHostKeyPrompt(accepted: Bool) {
        guard hostKeyPrompt != nil else {
            return
        }
        appendConnectionLog(
            accepted
                ? "SSH host key accepted by user."
                : "SSH host key rejected by user."
        )
        hostKeyPrompt = nil
        terminalView?.send(txt: accepted ? "yes\n" : "no\n")
    }

    public func findNext(_ term: String) -> Bool {
        terminalView?.findNext(term) ?? false
    }

    public func findPrevious(_ term: String) -> Bool {
        terminalView?.findPrevious(term) ?? false
    }

    public func clearSearch() {
        terminalView?.clearSearch()
    }

    public func changeFontSize(by delta: Double) {
        guard let terminalView else {
            return
        }
        let nextSize = TerminalFontPreferences.clampedFontSize(
            terminalView.font.pointSize + delta
        )
        UserDefaults.standard.set(nextSize, forKey: TerminalFontPreferences.fontSizeKey)
        applyPreferredFont()
    }

    public func applyPreferredFont() {
        setTerminalFontIfNeeded(
            TerminalFontPreferences.preferredFont(
                defaultSize: descriptor.fontSize
            )
        )
    }

    public func applyFont(name: String, size: Double) {
        setTerminalFontIfNeeded(
            TerminalFontPreferences.font(
                named: name,
                size: TerminalFontPreferences.clampedFontSize(size)
            )
        )
    }

    private func setTerminalFontIfNeeded(_ font: NSFont) {
        guard let terminalView else {
            return
        }
        let currentFont = terminalView.font
        if currentFont.fontName == font.fontName,
           abs(currentFont.pointSize - font.pointSize) < 0.01
        {
            return
        }
        terminalView.font = font
    }

    private func startIfNeeded() {
        guard launchRequested, !started, let terminalView else {
            return
        }
        started = true
        loggedWaitingForDisplay = false
        lifecycle = .connecting
        appendConnectionLog("Terminal surface attached to window.")
        appendConnectionLog("Launching \(processLabel): \(commandPreview).")
        reportLifecycle(.connecting)
        terminalView.startProcess(
            executable: launchConfiguration.executable,
            args: launchConfiguration.arguments,
            environment: launchConfiguration.environment,
            currentDirectory: launchConfiguration.currentDirectory
        )
        appendConnectionLog("\(processLabel) process launch requested.")
        guard !isSSH2BridgeLaunch else {
            return
        }
        lifecycle = .connected
        reportLifecycle(.connected)
    }

    private func reportLifecycle(_ lifecycle: SessionLifecycle) {
        let id = descriptor.id
        Task {
            await registry.updateLifecycle(id: id, lifecycle: lifecycle)
        }
    }

    private var processLabel: String {
        switch descriptor.kind {
        case .local:
            "local shell"
        case .ssh:
            if isSSH2BridgeLaunch {
                "ssh2 bridge"
            } else {
                "OpenSSH"
            }
        }
    }

    private var isSSH2BridgeLaunch: Bool {
        launchConfiguration.environment.contains {
            $0.hasPrefix("TERMPILOT_SSH2_BRIDGE_CONFIG_B64=")
        }
    }

    var isSSH2BridgeLaunchForTesting: Bool {
        isSSH2BridgeLaunch
    }

    private var commandPreview: String {
        ([launchConfiguration.executable] + launchConfiguration.arguments)
            .map(sanitizeCommandToken)
            .joined(separator: " ")
    }

    private func sanitizeCommandToken(_ token: String) -> String {
        token
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func logWaitingForDisplay() {
        guard !loggedWaitingForDisplay else {
            return
        }
        loggedWaitingForDisplay = true
        if terminalView == nil {
            appendConnectionLog("Waiting for terminal surface creation.")
        } else {
            appendConnectionLog("Waiting for terminal surface to attach to a window.")
        }
    }

    private func resetConnectionLog(_ message: String) {
        connectionLog.removeAll(keepingCapacity: true)
        processOutputBuffer.removeAll(keepingCapacity: true)
        ssh2BridgeDisplayFilter.reset()
        hostKeyPrompt = nil
        remoteServerVersion = nil
        latencyMilliseconds = nil
        currentUser = descriptor.kind == .ssh ? descriptor.username : NSUserName()
        loggedWaitingForDisplay = false
        appendConnectionLog(message)
    }

    private func appendConnectionLog(_ message: String) {
        connectionLog.append(ConnectionLogEntry(message: message))
        if connectionLog.count > 200 {
            connectionLog.removeFirst(connectionLog.count - 200)
        }
    }

    func processOutputForDisplay(_ slice: ArraySlice<UInt8>) -> [UInt8] {
        let displayBytes: [UInt8]
        if isSSH2BridgeLaunch {
            processSSH2BridgeOutput(String(decoding: slice, as: UTF8.self))
            displayBytes = ssh2BridgeDisplayFilter.filter(slice)
        } else {
            displayBytes = Array(slice)
        }
        observePasswordPromptOutput(
            String(decoding: displayBytes, as: UTF8.self)
        )
        return displayBytes
    }

    func processSSH2BridgeOutputForTesting(_ output: String) {
        processSSH2BridgeOutput(output)
    }

    func processOutputForDisplayForTesting(_ output: String) -> String {
        let bytes = processOutputForDisplay(Array(output.utf8)[...])
        return String(decoding: bytes, as: UTF8.self)
    }

    private func processSSH2BridgeOutput(_ output: String) {
        var input = processOutputBuffer + output
        processOutputBuffer.removeAll(keepingCapacity: true)

        while let start = input.range(of: SSH2BridgeControlFraming.start) {
            let contentStart = start.upperBound
            guard let end = input[contentStart...].firstIndex(
                of: SSH2BridgeControlFraming.end
            ) else {
                processOutputBuffer = String(input[start.lowerBound...])
                return
            }
            processSSH2BridgeLogLine(
                "[ssh2:" + input[contentStart..<end]
            )
            input = String(input[input.index(after: end)...])
        }
        processOutputBuffer = possibleSSH2ControlPrefixSuffix(in: input)
    }

    private func possibleSSH2ControlPrefixSuffix(in value: String) -> String {
        let prefix = SSH2BridgeControlFraming.start
        let maximumLength = min(value.count, prefix.count - 1)
        guard maximumLength > 0 else {
            return ""
        }
        for length in stride(from: maximumLength, through: 1, by: -1) {
            let suffix = String(value.suffix(length))
            if prefix.hasPrefix(suffix) {
                return suffix
            }
        }
        return ""
    }

    func processUserInputForProcess(
        _ data: ArraySlice<UInt8>,
        renderedLine: String? = nil
    ) -> [UInt8] {
        let bytes = Array(data)
        guard !bytes.isEmpty else {
            return []
        }

        if bytes == [0x03] {
            resetPasswordPromptAssist()
            autocompleteController.clearForSensitiveInput()
            _ = terminalCommandInputBuffer.consume(bytes)
            return bytes
        }

        if isPasswordInputActive {
            autocompleteController.clearForSensitiveInput()
            if let request = passwordPromptRequest {
                if Self.isEnter(bytes) {
                    selectPasswordPromptCredential(
                        id: selectedPasswordPromptItem(in: request)?.id
                    )
                    return []
                }
                if bytes == [0x1b] || Self.isBackspace(bytes) {
                    dismissPasswordPromptAssist()
                    return []
                }
                if request.presentation == .picker,
                   let delta = Self.passwordPromptSelectionDelta(bytes)
                {
                    movePasswordPromptSelection(by: delta)
                    return []
                }
                if Self.containsUserPasswordContent(bytes) {
                    dismissPasswordPromptAssist()
                }
            } else if Self.isPasswordPromptReshowKey(bytes),
                      let kind = passwordPromptDetector.reshowDismissedPrompt(),
                      let request = makePasswordPromptRequest(for: kind)
            {
                passwordPromptRequest = request
                if request.presentation == .picker,
                   let delta = Self.passwordPromptSelectionDelta(bytes)
                {
                    movePasswordPromptSelection(by: delta)
                }
                return []
            }

            if Self.isEnter(bytes) {
                isPasswordInputActive = false
                passwordPromptRequest = nil
                passwordPromptDetector.abort()
            }
            return bytes
        }

        if autocompleteController.process(
            bytes: bytes,
            renderedLine: renderedLine
        ) {
            return []
        }

        let recordedCommand = terminalCommandInputBuffer.consume(bytes)
        let recalledCommand = Self.isEnter(bytes)
            ? renderedLine.flatMap(PasswordPromptDetector.assistedCommand)
            : nil
        if let command = recordedCommand ?? recalledCommand {
            passwordPromptSelectedIndex = 0
            passwordPromptDetector.arm(for: command)
        }
        return bytes
    }

    private func observePasswordPromptOutput(_ output: String) {
        guard descriptor.kind == .ssh, !output.isEmpty else {
            return
        }
        let match = passwordPromptDetector.observe(output: output)
        if let match {
            autocompleteController.clearForSensitiveInput()
            if match == automaticPasswordPromptKind,
               Date() <= automaticPasswordPromptExpiresAt,
               let secret = automaticPasswordPromptSecret
            {
                automaticPasswordPromptGeneration &+= 1
                clearAutomaticPasswordPrompt()
                passwordPromptRequest = nil
                isPasswordInputActive = false
                passwordPromptDetector.markFilled()
                (terminalView as? AutoStartingTerminalView)?
                    .sendPasswordPromptSecret("\(secret)\n")
                return
            }
            if Date() > automaticPasswordPromptExpiresAt {
                clearAutomaticPasswordPrompt()
            }
            isPasswordInputActive = true
            if passwordPromptRequest == nil,
               let request = makePasswordPromptRequest(for: match)
            {
                passwordPromptRequest = request
            }
            return
        }

        if isPasswordInputActive,
           output.contains(where: { $0 == "\r" || $0 == "\n" })
        {
            resetPasswordPromptAssist()
        }
    }

    private func makePasswordPromptRequest(
        for kind: PasswordPromptCommandKind
    ) -> PasswordPromptRequest? {
        guard passwordPromptAssistMode != .off else {
            return nil
        }

        let credentials: [PasswordPromptCredential]
        let presentation: PasswordPromptPresentation
        if passwordPromptAssistMode == .picker,
           passwordPromptDetector.hasActiveArm(for: kind)
        {
            credentials = passwordPromptCredentials
            presentation = .picker
        } else {
            credentials = passwordPromptCredentials.filter(\.isHostCredential)
            presentation = .hint
        }
        guard !credentials.isEmpty else {
            return nil
        }
        passwordPromptSelectedIndex = min(
            passwordPromptSelectedIndex,
            credentials.count - 1
        )
        return PasswordPromptRequest(
            items: credentials.map(PasswordPromptCredentialItem.init),
            selectedIndex: passwordPromptSelectedIndex,
            presentation: presentation
        )
    }

    private func movePasswordPromptSelection(by delta: Int) {
        guard var request = passwordPromptRequest,
              !request.items.isEmpty
        else {
            return
        }
        request.selectedIndex =
            (request.selectedIndex + delta + request.items.count)
            % request.items.count
        passwordPromptSelectedIndex = request.selectedIndex
        passwordPromptRequest = request
    }

    private func selectedPasswordPromptItem(
        in request: PasswordPromptRequest
    ) -> PasswordPromptCredentialItem? {
        guard request.items.indices.contains(request.selectedIndex) else {
            return nil
        }
        return request.items[request.selectedIndex]
    }

    private func resetPasswordPromptAssist() {
        automaticPasswordPromptGeneration &+= 1
        clearAutomaticPasswordPrompt()
        passwordPromptRequest = nil
        isPasswordInputActive = false
        passwordPromptSelectedIndex = 0
        passwordPromptDetector.abort()
        terminalCommandInputBuffer = TerminalCommandInputBuffer()
    }

    private func clearAutomaticPasswordPrompt() {
        automaticPasswordPromptSecret = nil
        automaticPasswordPromptKind = nil
        automaticPasswordPromptExpiresAt = .distantPast
    }

    private static func isEnter(_ bytes: [UInt8]) -> Bool {
        bytes == [0x0d] || bytes == [0x0a] || bytes == [0x0d, 0x0a]
    }

    private static func isBackspace(_ bytes: [UInt8]) -> Bool {
        bytes == [0x08] || bytes == [0x7f]
    }

    private static func passwordPromptSelectionDelta(
        _ bytes: [UInt8]
    ) -> Int? {
        switch bytes {
        case [0x1b, 0x5b, 0x41], [0x1b, 0x4f, 0x41]:
            -1
        case [0x1b, 0x5b, 0x42], [0x1b, 0x4f, 0x42]:
            1
        default:
            nil
        }
    }

    private static func isPasswordPromptReshowKey(_ bytes: [UInt8]) -> Bool {
        bytes == [0x1b] || passwordPromptSelectionDelta(bytes) != nil
    }

    private static func containsUserPasswordContent(_ bytes: [UInt8]) -> Bool {
        if bytes.starts(with: [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]) {
            return true
        }
        return bytes.contains { (0x20 ... 0x7e).contains($0) }
    }

    private func processSSH2BridgeLogLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[ssh2:"),
              let close = trimmed.firstIndex(of: "]")
        else {
            return
        }

        let statusStart = trimmed.index(trimmed.startIndex, offsetBy: 6)
        let status = String(trimmed[statusStart..<close])
        let messageStart = trimmed.index(after: close)
        let message = trimmed[messageStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if status == "cwd" {
            updateCurrentDirectory(message.isEmpty ? nil : message)
            return
        }
        if status == "user" {
            currentUser = message.isEmpty ? descriptor.username : message
            return
        }
        if status == "host-key-prompt" {
            hostKeyPrompt = parseHostKeyPrompt(from: message)
            if let hostKeyPrompt {
                appendConnectionLog(
                    "ssh2 host-key: confirm \(hostKeyPrompt.algorithm) fingerprint for \(hostKeyPrompt.hostPattern): \(hostKeyPrompt.fingerprint)"
                )
            } else {
                appendConnectionLog("ssh2 host-key: confirmation required")
            }
            return
        }
        if status == "remote-version" {
            remoteServerVersion = message.isEmpty ? nil : message
            return
        }
        if status == "latency" {
            latencyMilliseconds = Int(message).map { max(0, $0) }
            return
        }
        if status == "latency-unavailable" {
            latencyMilliseconds = nil
            return
        }
        appendConnectionLog("ssh2 \(status): \(message)")

        switch status {
        case "connected":
            hostKeyPrompt = nil
            lifecycle = .connected
            reportLifecycle(.connected)
        case "error":
            hostKeyPrompt = nil
            latencyMilliseconds = nil
            lifecycle = .failed(message.isEmpty ? "ssh2 bridge error" : message)
            reportLifecycle(lifecycle)
        default:
            break
        }
    }

    private func parseHostKeyPrompt(from message: String) -> SSHHostKeyPrompt? {
        guard let jsonStart = message.firstIndex(of: "{"),
              let data = String(message[jsonStart...]).data(using: .utf8),
              let detail = try? JSONDecoder().decode(
                SSH2BridgeHostKeyPromptDetail.self,
                from: data
              )
        else {
            return nil
        }

        return SSHHostKeyPrompt(
            hostPattern: detail.hostPattern,
            algorithm: detail.algorithm,
            fingerprint: detail.fingerprint,
            hasExistingHostPattern: detail.hasHostPattern ?? false
        )
    }
}

extension TerminalSessionRuntime: @preconcurrency LocalProcessTerminalViewDelegate {

    public func bell(source: TerminalView) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .terminalVisualBell,
                object: self.descriptor.id
            )
        }
    }
    public func sizeChanged(
        source _: LocalProcessTerminalView,
        newCols _: Int,
        newRows _: Int
    ) {}

    public func setTerminalTitle(
        source _: LocalProcessTerminalView,
        title: String
    ) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        self.title = trimmed
        let id = descriptor.id
        Task {
            await registry.updateTitle(id: id, title: trimmed)
        }
    }

    public func hostCurrentDirectoryUpdate(
        source _: TerminalView,
        directory: String?
    ) {
        updateCurrentDirectory(directory)
    }

    public func processTerminated(
        source: TerminalView,
        exitCode: Int32?
    ) {
        hostKeyPrompt = nil
        autocompleteController.clearForSensitiveInput()
        if source === terminalView {
            autocompleteController.invalidateRemoteDirectoryProvider()
        }
        resetPasswordPromptAssist()
        if let exitCode {
            appendConnectionLog("\(processLabel) process exited with code \(exitCode).")
        } else {
            appendConnectionLog("\(processLabel) process exited without an exit code.")
        }
        lifecycle = .exited(exitCode)
        reportLifecycle(.exited(exitCode))
    }

    private func updateCurrentDirectory(_ directory: String?) {
        currentDirectory = directory
        let id = descriptor.id
        Task {
            await registry.updateCurrentDirectory(id: id, directory: directory)
        }
    }
}

public struct TerminalSurface: NSViewRepresentable {
    private static let terminalLeadingInset: CGFloat = 10

    @ObservedObject private var runtime: TerminalSessionRuntime
    private let contextMenuTitles: TerminalContextMenuTitles
    @AppStorage(TerminalFontPreferences.fontNameKey)
    private var terminalFontName = TerminalFontPreferences.automaticFontName
    @AppStorage(TerminalFontPreferences.fontSizeKey)
    private var terminalFontSize = TerminalFontPreferences.defaultFontSize
    @AppStorage(TerminalAutocompletePreferences.enabledKey)
    private var autocompleteEnabled =
        TerminalAutocompletePreferences.defaultEnabled
    @AppStorage(TerminalAutocompletePreferences.ghostTextKey)
    private var autocompleteGhostText =
        TerminalAutocompletePreferences.defaultGhostText
    @AppStorage(TerminalAutocompletePreferences.popupMenuKey)
    private var autocompletePopupMenu =
        TerminalAutocompletePreferences.defaultPopupMenu

    public init(
        runtime: TerminalSessionRuntime,
        contextMenuTitles: TerminalContextMenuTitles = .english
    ) {
        self.runtime = runtime
        self.contextMenuTitles = contextMenuTitles
    }

    public func makeNSView(context _: Context) -> TerminalContentInsetView {
        runtime.configureContextMenu(titles: contextMenuTitles)
        let view = runtime.view()
        runtime.applyFont(name: terminalFontName, size: terminalFontSize)
        runtime.configureAutocomplete(
            enabled: autocompleteEnabled,
            showsGhostText: autocompleteGhostText,
            showsPopupMenu: autocompletePopupMenu
        )
        return TerminalContentInsetView(
            terminalView: view,
            leadingInset: Self.terminalLeadingInset
        )
    }

    public func updateNSView(
        _ nsView: TerminalContentInsetView,
        context _: Context
    ) {
        nsView.terminalView.setAccessibilityLabel("Terminal: \(runtime.title)")
        nsView.syncBackgroundWithCurrentAppearance()
        runtime.configureContextMenu(titles: contextMenuTitles)
        runtime.applyFont(name: terminalFontName, size: terminalFontSize)
        runtime.configureAutocomplete(
            enabled: autocompleteEnabled,
            showsGhostText: autocompleteGhostText,
            showsPopupMenu: autocompletePopupMenu
        )
        runtime.startIfDisplayed()
    }

    public static func dismantleNSView(
        nsView: TerminalContentInsetView,
        coordinator _: ()
    ) {
        (nsView.terminalView as? AutoStartingTerminalView)?
            .runtime?
            .closeAutocomplete()
        // The runtime owns the PTY. Hiding a tab must not terminate its process.
    }
}

public enum LocalShellLaunch {
    public static func configuration(
        shell: String? = nil,
        workingDirectory: String? = nil,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProcessLaunchConfiguration {
        let executable = shell
            ?? inheritedEnvironment["SHELL"]
            ?? "/bin/zsh"
        var environment = inheritedEnvironment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "TermPilot"
        return ProcessLaunchConfiguration(
            executable: executable,
            arguments: ["-l"],
            environment: environment
                .map { "\($0.key)=\($0.value)" }
                .sorted(),
            currentDirectory: workingDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser.path
        )
    }
}

extension Notification.Name {
    public static let terminalVisualBell = Notification.Name("com.termpilot.terminalVisualBell")
}
