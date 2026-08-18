import AppKit
import Darwin
import SwiftUI
import TermPilotDomain

@main
@MainActor
enum TermPilotMain {
    static func main() {
        if AskPassHandler.isRequested {
            exit(AskPassHandler.run())
        }
        TermPilotApplication.main()
    }
}

private struct TermPilotApplication: App {
    private static let terminalWindowID = "terminal"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var windowStates = WindowStateCoordinator()
    @AppStorage(AppPreferences.appearance) private var appearance = "system"
    @AppStorage(AppPreferences.language)
    private var language = AppPreferences.defaultLanguage

    var body: some Scene {
        WindowGroup(id: Self.terminalWindowID) {
            TermPilotWindow(
                coordinator: windowStates,
                appDelegate: appDelegate,
                preferredColorScheme: preferredColorScheme,
                preferredLocale: preferredLocale
            )
        }
        .defaultSize(width: 1280, height: 780)
        .commands {
            TermPilotCommands(
                windowID: Self.terminalWindowID,
                coordinator: windowStates
            )
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light":
            .light
        case "dark":
            .dark
        default:
            nil
        }
    }

    private var preferredLocale: Locale {
        Locale(identifier: AppPreferences.normalizedLanguage(language))
    }
}

private struct TermPilotWindow: View {
    @StateObject private var state = AppState()
    @AppStorage(AppPreferences.passwordPromptAssistMode)
    private var passwordPromptAssistMode =
        AppPreferences.defaultPasswordPromptAssistMode

    let coordinator: WindowStateCoordinator
    let appDelegate: AppDelegate
    let preferredColorScheme: ColorScheme?
    let preferredLocale: Locale

    var body: some View {
        RootView()
            .environmentObject(state)
            .environment(\.locale, preferredLocale)
            .focusedSceneValue(\.termPilotAppState, state)
            .preferredColorScheme(preferredColorScheme)
            .frame(minWidth: 900, minHeight: 560)
            .overlay {
                if let prompt = state.portForwardHostKeyPrompt {
                    PortForwardHostKeyConfirmationOverlay(
                        prompt: prompt.prompt
                    ) {
                        state.respondToPortForwardHostKeyPrompt(accepted: false)
                    } onTrust: {
                        state.respondToPortForwardHostKeyPrompt(accepted: true)
                    }
                    .transition(.opacity)
                }
            }
            .background(
                WindowActivationReader(
                    state: state,
                    coordinator: coordinator
                )
                .frame(width: 0, height: 0)
            )
            .onAppear {
                coordinator.markActive(state)
            }
            .onChange(of: passwordPromptAssistMode) { _, mode in
                state.updatePasswordPromptAssistMode(mode)
            }
            .onOpenURL { url in
                Task {
                    await state.handleURL(url)
                }
            }
            .task {
                appDelegate.coordinator = coordinator
                let bootstrap = coordinator.register(state)
                await state.bootstrap(
                    startsAutoPortForwards: bootstrap.startsAutoPortForwards,
                    initialWorkspaceSnapshot: bootstrap.initialWorkspaceSnapshot
                )
            }
    }
}

private struct PortForwardHostKeyConfirmationOverlay: View {
    let prompt: String
    let onCancel: () -> Void
    let onTrust: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.34)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    Text("Verify SSH Host Key")
                        .font(.title3.weight(.semibold))
                    Spacer()
                }

                ScrollView {
                    Text(prompt)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 260)

                Button("Trust and Connect", action: onTrust)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            .frame(width: 480)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.24), radius: 28, x: 0, y: 16)
        }
    }
}

private struct TermPilotCommands: Commands {
    @FocusedValue(\.termPilotAppState) private var state
    @Environment(\.openWindow) private var openWindow

    let windowID: String
    let coordinator: WindowStateCoordinator

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(AppLocalization.string("New Window")) {
                coordinator.prepareNextWindowClone(from: state)
                openWindow(id: windowID)
            }
            .keyboardShortcut("n", modifiers: .command)

            Divider()

            Button(AppLocalization.string("New Local Shell")) {
                guard let state else {
                    return
                }
                Task {
                    await state.openLocalShell()
                }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(state == nil)

            Button(AppLocalization.string("Quick Connect...")) {
                guard let state else {
                    return
                }
                NotificationCenter.default.post(
                    name: .showQuickConnect,
                    object: state
                )
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(state == nil)
        }

        CommandGroup(replacing: .appSettings) {
            Button(AppLocalization.string("Settings...")) {
                guard let state else {
                    return
                }
                NotificationCenter.default.post(
                    name: .showSettingsSurface,
                    object: state
                )
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(state == nil)
        }

        CommandGroup(replacing: .appInfo) {
            Button(AppLocalization.string("About TermPilot")) {
                guard let state else {
                    return
                }
                NotificationCenter.default.post(
                    name: .showAboutSettingsSurface,
                    object: state
                )
            }
            .disabled(state == nil)
        }

        CommandMenu(AppLocalization.string("Session")) {
            Button(AppLocalization.string("Split Vertically")) {
                guard let state,
                      let sessionID = state.activeWorkspace?.focusedSessionID
                else {
                    return
                }
                Task {
                    await state.openSiblingTerminal(
                        from: sessionID,
                        splitAxis: .vertical
                    )
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(state?.activeWorkspace == nil)

            Button(AppLocalization.string("Split Horizontally")) {
                guard let state,
                      let sessionID = state.activeWorkspace?.focusedSessionID
                else {
                    return
                }
                Task {
                    await state.openSiblingTerminal(
                        from: sessionID,
                        splitAxis: .horizontal
                    )
                }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(state?.activeWorkspace == nil)

            Divider()

            Button(AppLocalization.string("Close Tab")) {
                guard let state,
                      let workspaceID = state.activeWorkspaceID
                else {
                    return
                }
                Task {
                    await state.closeWorkspace(workspaceID)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(state?.activeWorkspaceID == nil)
        }
    }
}

private struct TermPilotAppStateFocusedKey: FocusedValueKey {
    typealias Value = AppState
}

private extension FocusedValues {
    var termPilotAppState: AppState? {
        get { self[TermPilotAppStateFocusedKey.self] }
        set { self[TermPilotAppStateFocusedKey.self] = newValue }
    }
}

@MainActor
struct WindowBootstrapConfiguration {
    let startsAutoPortForwards: Bool
    let initialWorkspaceSnapshot: WorkspaceSnapshot?
}

@MainActor
final class WindowStateCoordinator: ObservableObject {
    private var registrations: [WindowStateRegistration] = []
    private weak var activeState: AppState?
    private var didAssignAutoStartPortForwards = false
    private var pendingCloneSnapshots: [WorkspaceSnapshot] = []

    func markActive(_ state: AppState) {
        activeState = state
    }

    @discardableResult
    func prepareNextWindowClone(from preferredState: AppState?) -> Bool {
        registrations.removeAll { $0.state == nil }

        let states = ([preferredState, activeState] + registrations.reversed().map(\.state))
            .compactMap { $0 }
        var seen = Set<ObjectIdentifier>()
        for state in states {
            guard seen.insert(ObjectIdentifier(state)).inserted,
                  let snapshot = state.currentWorkspaceCloneSnapshot(),
                  !snapshot.sessions.isEmpty,
                  !snapshot.workspaces.isEmpty
            else {
                continue
            }
            pendingCloneSnapshots.append(snapshot)
            return true
        }
        return false
    }

    func register(_ state: AppState) -> WindowBootstrapConfiguration {
        registrations.removeAll { $0.state == nil }
        if registrations.contains(where: { $0.state === state }) {
            return WindowBootstrapConfiguration(
                startsAutoPortForwards: false,
                initialWorkspaceSnapshot: nil
            )
        }

        let startsAutoPortForwards = !didAssignAutoStartPortForwards
        didAssignAutoStartPortForwards = true
        let initialWorkspaceSnapshot = pendingCloneSnapshots.isEmpty
            ? nil
            : pendingCloneSnapshots.removeFirst()
        registrations.append(
            WindowStateRegistration(state: state)
        )
        activeState = state
        return WindowBootstrapConfiguration(
            startsAutoPortForwards: startsAutoPortForwards,
            initialWorkspaceSnapshot: initialWorkspaceSnapshot
        )
    }

    func unregister(_ state: AppState) {
        registrations.removeAll { $0.state == nil }
        registrations.removeAll { $0.state === state }
        if activeState === state {
            activeState = registrations.reversed().compactMap(\.state).first
        }
    }

    func terminateAllSessionsImmediately() {
        registrations.removeAll { $0.state == nil }
        for state in registrations.compactMap(\.state) {
            state.terminateAllSessionsImmediately()
        }
    }
}

@MainActor
private final class WindowStateRegistration {
    weak var state: AppState?

    init(state: AppState) {
        self.state = state
    }
}

private struct WindowActivationReader: NSViewRepresentable {
    weak var state: AppState?
    weak var coordinator: WindowStateCoordinator?

    func makeNSView(context _: Context) -> WindowActivationView {
        let view = WindowActivationView()
        view.state = state
        view.coordinator = coordinator
        return view
    }

    func updateNSView(_ nsView: WindowActivationView, context _: Context) {
        nsView.state = state
        nsView.coordinator = coordinator
        nsView.markActiveIfKeyWindow()
    }
}

private final class WindowActivationView: NSView {
    weak var state: AppState?
    weak var coordinator: WindowStateCoordinator?
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingWindow()
        observedWindow = window
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose),
                name: NSWindow.willCloseNotification,
                object: window
            )
            markActiveIfKeyWindow()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func markActiveIfKeyWindow() {
        guard window?.isKeyWindow == true || window?.isMainWindow == true,
              let state
        else {
            return
        }
        coordinator?.markActive(state)
    }

    @objc private func windowDidBecomeKey() {
        guard let state else {
            return
        }
        coordinator?.markActive(state)
    }

    @objc private func windowWillClose() {
        guard let state else {
            return
        }
        state.terminateAllSessionsImmediately()
        coordinator?.unregister(state)
    }

    private func stopObservingWindow() {
        guard let observedWindow else {
            return
        }
        NotificationCenter.default.removeObserver(
            self,
            name: nil,
            object: observedWindow
        )
        self.observedWindow = nil
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: WindowStateCoordinator?

    func applicationShouldTerminateAfterLastWindowClosed(
        _: NSApplication
    ) -> Bool {
        true
    }

    func applicationShouldTerminate(
        _: NSApplication
    ) -> NSApplication.TerminateReply {
        coordinator?.terminateAllSessionsImmediately()
        return .terminateNow
    }
}

extension Notification.Name {
    static let showQuickConnect = Notification.Name(
        "com.termpilot.showQuickConnect"
    )
    static let showSettingsSurface = Notification.Name(
        "com.termpilot.showSettingsSurface"
    )
    static let showAboutSettingsSurface = Notification.Name(
        "com.termpilot.showAboutSettingsSurface"
    )
    static let termPilotVaultDidChange = Notification.Name(
        "com.termpilot.vaultDidChange"
    )
}

@MainActor
private enum AskPassHandler {
    private struct HostKeyRequest: Encodable {
        var id: String
        var prompt: String
        var createdAt: Date
    }

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["TERMPILOT_ASKPASS_MODE"] == "1"
            && ProcessInfo.processInfo.environment["SSH_ASKPASS_REQUIRE"] == "force"
            && CommandLine.arguments.count > 1
    }

    static func run() -> Int32 {
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
        let normalized = prompt.lowercased()

        if normalized.contains("yes/no")
            || normalized.contains("authenticity of host")
        {
            return confirmHostKey(prompt: prompt)
        }

        if (normalized.contains("password") || normalized.contains("passphrase")),
           let encoded = ProcessInfo.processInfo
               .environment["TERMPILOT_ASKPASS_SECRET_B64"],
           let secret = Data(base64Encoded: encoded)
        {
            write(secret)
            return 0
        }

        return requestSecret(prompt: prompt)
    }

    private static func confirmHostKey(prompt: String) -> Int32 {
        if AppPreferences.isAutoAcceptSSHHostKeysEnabled {
            write(Data("yes\n".utf8))
            return 0
        }

        if let accepted = requestInAppHostKeyConfirmation(prompt: prompt) {
            write(Data((accepted ? "yes\n" : "no\n").utf8))
            return accepted ? 0 : 1
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppLocalization.string("Verify SSH Host Key")
        alert.informativeText = prompt
        alert.addButton(withTitle: AppLocalization.string("Trust and Connect"))
        alert.addButton(withTitle: AppLocalization.string("Cancel"))
        let accepted = alert.runModal() == .alertFirstButtonReturn
        write(Data((accepted ? "yes\n" : "no\n").utf8))
        return accepted ? 0 : 1
    }

    private static func requestInAppHostKeyConfirmation(prompt: String) -> Bool? {
        guard let directoryPath = ProcessInfo.processInfo
            .environment["TERMPILOT_ASKPASS_REQUEST_DIR"],
            !directoryPath.isEmpty
        else {
            return nil
        }

        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let requestID = UUID().uuidString
        let requestURL = directory.appendingPathComponent("request-\(requestID).json")
        let responseURL = directory.appendingPathComponent("response-\(requestID).txt")
        let request = HostKeyRequest(
            id: requestID,
            prompt: prompt,
            createdAt: Date()
        )

        guard let data = try? JSONEncoder().encode(request),
              (try? data.write(to: requestURL, options: .atomic)) != nil
        else {
            return nil
        }

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let response = try? String(contentsOf: responseURL, encoding: .utf8) {
                try? FileManager.default.removeItem(at: requestURL)
                try? FileManager.default.removeItem(at: responseURL)
                let normalized = response
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                return normalized == "yes" || normalized == "y" || normalized == "true"
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        try? FileManager.default.removeItem(at: requestURL)
        return false
    }

    private static func requestSecret(prompt: String) -> Int32 {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

        let field = PasteEnabledSecureTextField(
            frame: NSRect(x: 0, y: 0, width: 360, height: 24)
        )
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = AppLocalization.string("SSH Authentication")
        alert.informativeText = prompt
        alert.accessoryView = field
        alert.addButton(withTitle: AppLocalization.string("Continue"))
        alert.addButton(withTitle: AppLocalization.string("Cancel"))
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            return 1
        }
        write(Data((field.stringValue + "\n").utf8))
        return 0
    }

    private static func write(_ data: Data) {
        FileHandle.standardOutput.write(data)
    }
}

private final class PasteEnabledSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "v":
            if let editor = currentEditor() {
                editor.paste(self)
            } else if let text = NSPasteboard.general.string(forType: .string) {
                stringValue += text
            }
            return true
        case "a":
            currentEditor()?.selectAll(self)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
