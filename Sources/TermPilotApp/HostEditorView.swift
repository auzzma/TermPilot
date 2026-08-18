import AppKit
import SwiftUI
import TermPilotDomain

struct HostEditorView: View {
    static let portFormat = IntegerFormatStyle<Int>.number.grouping(.never)

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var host: TermPilotDomain.Host
    @State private var password = ""
    @State private var isSaving = false
    @State private var saveError: String?
    private let separatorHeight = 1 / (NSScreen.main?.backingScaleFactor ?? 2)

    init(
        host: TermPilotDomain.Host?,
        defaultGroupID: UUID? = nil
    ) {
        if let host {
            _host = State(initialValue: host)
            _password = State(initialValue: host.password ?? "")
        } else {
            var newHost = TermPilotDomain.Host(
                label: "",
                hostname: "",
                username: "root",
                authentication: .password
            )
            newHost.groupID = defaultGroupID
            _host = State(initialValue: newHost)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    verbatim: localized(
                        host.label.isEmpty ? "New Host" : "Edit Host"
                    )
                )
                    .font(.title2.weight(.semibold))
                    .padding(.top, 4)
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(localized("Close"))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hostDetailsCard

                    DisclosureGroup("Advanced Settings") {
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(
                                    localized("Colors & Icons"),
                                    systemImage: "circle.hexagongrid"
                                )
                                .font(.headline.weight(.semibold))
                                HostAppearanceEditor(host: $host)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: localized("SFTP"))
                                    .font(.headline.weight(.semibold))
                                sftpSettingsCard
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: localized("Server Tools"))
                                    .font(.headline.weight(.semibold))
                                serverToolsSettingsCard
                            }

                            proxySettingsSection
                        }
                        .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(editorBackground)

            Divider()

            HStack(spacing: 12) {
                Spacer()
                Button(localized("Cancel"), role: .cancel) {
                    close()
                }
                .controlSize(.large)
                Button(localized("Save")) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
            .padding(20)
        }
        .frame(width: 580)
        .frame(height: 720)
        .overlay {
            if let saveError {
                errorOverlay(saveError)
            }
        }
    }

    
    private var hostDetailsCard: some View {
        VStack(spacing: 0) {
            formRow("Name") {
                TextField("My Server", text: $host.label)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            Divider().padding(.vertical, 8)
            formRow("IP / Host") {
                TextField("10.0.0.1", text: $host.hostname)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            Divider().padding(.vertical, 8)
            formRow("Username") {
                HStack(spacing: 12) {
                    TextField("root", text: $host.username)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    Text(verbatim: localized("Port"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("22", value: $host.port, format: Self.portFormat)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 84)
                        .labelsHidden()
                }
            }
            Divider().padding(.vertical, 8)
            formRow("Credential") {
                Picker("", selection: $host.credentialID) {
                    Text(verbatim: localized("Custom Credential")).tag(UUID?.none)
                    ForEach(state.credentials) { credential in
                        Text(credentialTitle(credential)).tag(UUID?.some(credential.id))
                    }
                }
                .labelsHidden()
                .onChange(of: host.credentialID) { _, newValue in
                    applyCredentialSelection(newValue)
                }
            }
            
            if let selectedCredential {
                Text(verbatim: localized("Leave blank to use the selected credential username."))
                    .font(.caption).foregroundStyle(.secondary)
                    .onAppear { fillCredentialUsernameIfNeeded(selectedCredential.id) }
            } else {
                formRow("Authentication") {
                    Picker("", selection: $host.authentication) {
                        Text(verbatim: localized("SSH Agent")).tag(AuthenticationMethod.agent)
                        Text(verbatim: localized("Password")).tag(AuthenticationMethod.password)
                        Text(verbatim: localized("Private Key")).tag(AuthenticationMethod.identityFile)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                
                if host.authentication == .password {
                    Divider().padding(.vertical, 8)
                    formRow("Password") {
                        SecureField("", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    }
                } else if host.authentication == .identityFile {
                    Divider().padding(.vertical, 8)
                    formRow("Private key") {
                        HStack {
                            TextField("", text: Binding(get: { host.identityFile ?? "" }, set: { host.identityFile = $0.isEmpty ? nil : $0 }))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                            Button(localized("Choose...")) { chooseIdentityFile() }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(rowSeparator, lineWidth: 1))
    }

    private var sftpSettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(localized("Enable SFTP"), isOn: Binding(
                get: { self.host.sftpUsesSudo != true },
                set: { self.host.sftpUsesSudo = $0 ? false : true }
            ))
            Text(verbatim: localized("SFTP must be enabled on the server."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(rowSeparator, lineWidth: 1))
    }

    private var serverToolsSettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(localized("Use root privileges for server tools"), isOn: Binding(
                get: { self.host.serverToolsUseRoot },
                set: { self.host.serverToolsUseRoot = $0 ? true : false }
            ))
            if host.serverToolsUseRoot == true {
                Picker(localized("Elevation Method"), selection: Binding(
                    get: { self.host.serverToolsElevationMethod },
                    set: { self.host.serverToolsElevationMethod = $0 }
                )) {
                    Text("sudo").tag(ServerToolsElevationMethod.sudo)
                    Text("su").tag(ServerToolsElevationMethod.su)
                }
                SecureField(localized("Elevation Password"), text: Binding(
                    get: { self.host.elevationPassword ?? "" },
                    set: { self.host.elevationPassword = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
        }
        .padding(16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(rowSeparator, lineWidth: 1))
    }

    private var proxySettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: localized("Proxy Bridge")).font(.headline.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                Toggle(localized("Connect through proxy"), isOn: proxyEnabledBinding)
                if proxyIsEnabled {
                    Picker(localized("Proxy Profile"), selection: proxyProfileBinding) {
                        Text(verbatim: localized("Custom Configuration")).tag(UUID?.none)
                        ForEach(state.proxyProfiles) { profile in
                            Text(profile.label).tag(UUID?.some(profile.id))
                        }
                    }
                    if host.proxyProfileID == nil {
                        Picker(localized("Protocol"), selection: customProxyValueBinding(\SSHProxyConfiguration.type)) {
                            Text("HTTP").tag(SSHProxyType.http)
                            Text("SOCKS5").tag(SSHProxyType.socks5)
                        }
                        formRow("Host") {
                            TextField("127.0.0.1", text: customProxyValueBinding(\SSHProxyConfiguration.host))
                                .textFieldStyle(.roundedBorder)
                        }
                        formRow("Port") {
                            TextField("1080", value: customProxyValueBinding(\SSHProxyConfiguration.port), format: Self.portFormat)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            .padding(16)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(rowSeparator, lineWidth: 1))
        }
    }

    private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 16) {
            Text(verbatim: localized(title))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func credentialTitle(_ credential: SSHCredential) -> String {
        "\(credential.label) [\(credential.kind.appLocalizedTitle)]"
    }

    private func errorOverlay(_ message: String) -> some View {
        Text(message)
            .padding()
            .background(Color.red.opacity(0.8))
            .foregroundStyle(.white)
            .cornerRadius(8)
            .padding()
    }

    private var editorBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private var cardBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    private var rowSeparator: Color {
        Color(nsColor: .separatorColor).opacity(0.45)
    }

    private var selectedCredential: SSHCredential? {
        guard let credentialID = host.credentialID else {
            return nil
        }
        return state.credentials.first { $0.id == credentialID }
    }

    private var proxyIsEnabled: Bool {
        host.proxyProfileID != nil || host.proxyConfiguration != nil
    }

    private var proxyEnabledBinding: Binding<Bool> {
        Binding(
            get: { proxyIsEnabled },
            set: { enabled in
                if enabled {
                    if !proxyIsEnabled {
                        host.proxyConfiguration = SSHProxyConfiguration()
                    }
                } else {
                    host.proxyProfileID = nil
                    host.proxyConfiguration = nil
                }
            }
        )
    }

    private var proxyProfileBinding: Binding<UUID?> {
        Binding(
            get: { host.proxyProfileID },
            set: { profileID in
                host.proxyProfileID = profileID
                if profileID == nil {
                    host.proxyConfiguration = host.proxyConfiguration
                        ?? SSHProxyConfiguration()
                } else {
                    host.proxyConfiguration = nil
                }
            }
        )
    }

    private var customProxyType: SSHProxyType {
        host.proxyConfiguration?.type ?? .http
    }

    private var proxyPasswordCredentials: [SSHCredential] {
        state.credentials.filter { $0.kind == .password }
    }

    private var selectedProxyCredential: SSHCredential? {
        guard let credentialID = host.proxyConfiguration?.credentialID else {
            return nil
        }
        return proxyPasswordCredentials.first { $0.id == credentialID }
    }

    private var customProxyCredentialBinding: Binding<UUID?> {
        Binding(
            get: { host.proxyConfiguration?.credentialID },
            set: { credentialID in
                var configuration = host.proxyConfiguration
                    ?? SSHProxyConfiguration()
                configuration.credentialID = credentialID
                if credentialID != nil {
                    configuration.username = nil
                    configuration.password = nil
                }
                host.proxyProfileID = nil
                host.proxyConfiguration = configuration
            }
        )
    }

    private func customProxyValueBinding<Value>(
        _ keyPath: WritableKeyPath<SSHProxyConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                (host.proxyConfiguration ?? SSHProxyConfiguration())[
                    keyPath: keyPath
                ]
            },
            set: { value in
                var configuration = host.proxyConfiguration
                    ?? SSHProxyConfiguration()
                configuration[keyPath: keyPath] = value
                host.proxyProfileID = nil
                host.proxyConfiguration = configuration
            }
        )
    }

    private func customProxyOptionalStringBinding(
        _ keyPath: WritableKeyPath<SSHProxyConfiguration, String?>
    ) -> Binding<String> {
        Binding(
            get: {
                (host.proxyConfiguration ?? SSHProxyConfiguration())[
                    keyPath: keyPath
                ] ?? ""
            },
            set: { value in
                var configuration = host.proxyConfiguration
                    ?? SSHProxyConfiguration()
                configuration[keyPath: keyPath] = value
                host.proxyProfileID = nil
                host.proxyConfiguration = configuration
            }
        )
    }

    private var selectedProxyProfile: SSHProxyProfile? {
        guard let proxyProfileID = host.proxyProfileID else {
            return nil
        }
        return state.proxyProfiles.first { $0.id == proxyProfileID }
    }

    private var missingProxyProfileID: UUID? {
        guard let proxyProfileID = host.proxyProfileID,
              selectedProxyProfile == nil
        else {
            return nil
        }
        return proxyProfileID
    }

    private func applyCredentialSelection(_ credentialID: UUID?) {
        guard let credentialID,
              let credential = state.credentials.first(where: { $0.id == credentialID })
        else {
            return
        }
        host.username = credential.username
        switch credential.kind {
        case .password:
            host.authentication = .password
        case .identityKey:
            host.authentication = .identityFile
        }
        password = ""
    }

    private func fillCredentialUsernameIfNeeded(_ credentialID: UUID?) {
        guard host.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let credentialID,
              let credential = state.credentials.first(where: { $0.id == credentialID })
        else {
            return
        }
        host.username = credential.username
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.title = AppLocalization.string("Choose SSH Private Key")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        if panel.runModal() == .OK {
            host.identityFile = panel.url?.path
        }
    }

    private func close() {
        dismiss()
    }

    private func save() {
        guard !isSaving else {
            return
        }
        isSaving = true
        saveError = nil
        Task {
            let saved = await state.saveHost(
                host,
                password: password.isEmpty ? nil : password
            )
            isSaving = false
            if saved {
                close()
            } else {
                saveError = state.presentedError
                    ?? AppLocalization.string("The host could not be saved.")
                state.presentedError = nil
            }
        }
    }
    private func localized(_ key: String) -> String {
        AppLocalization.string(key)
    }

}

private struct HostEditorOutsideClickMonitor: NSViewRepresentable {
    var onOutsideClick: () -> Void

    func makeNSView(context _: Context) -> HostEditorOutsideClickView {
        let view = HostEditorOutsideClickView()
        view.onOutsideClick = onOutsideClick
        return view
    }

    func updateNSView(
        _ nsView: HostEditorOutsideClickView,
        context _: Context
    ) {
        nsView.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(
        _ nsView: HostEditorOutsideClickView,
        coordinator _: ()
    ) {
        nsView.stopMonitoring()
    }
}

private final class HostEditorOutsideClickView: NSView {
    var onOutsideClick: (() -> Void)?
    private var eventMonitor: Any?
    private var isClosing = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else {
            return
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stopMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent {
        guard let window,
              event.window !== window,
              !isClosing
        else {
            return event
        }

        isClosing = true
        DispatchQueue.main.async { [weak self] in
            self?.onOutsideClick?()
        }
        return event
    }

    deinit {
        MainActor.assumeIsolated {
            stopMonitoring()
        }
    }
}
