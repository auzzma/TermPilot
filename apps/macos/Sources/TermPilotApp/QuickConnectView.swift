import AppKit
import SwiftUI
import TermPilotDomain

private enum QuickConnectServerToolsMode: String, CaseIterable {
    case disabled
    case sudo
    case su
}

private enum QuickConnectProxySelection: Hashable {
    case direct
    case profile(UUID)
    case custom
}

struct QuickConnectCredentialFields: Equatable {
    var username: String
    var authentication: AuthenticationMethod
    var password: String
    var identityKey: String
    var publicKey: String
    var certificate: String
    var passphrase: String
    var elevationPassword: String
    var elevationMethod: ServerToolsElevationMethod?

    init(credential: SSHCredential) {
        username = credential.username
        authentication = credential.kind == .identityKey
            ? .identityFile
            : .password
        password = credential.kind == .password
            ? credential.password ?? ""
            : ""
        identityKey = credential.kind == .identityKey
            ? credential.privateKey ?? ""
            : ""
        publicKey = credential.kind == .identityKey
            ? credential.publicKey ?? ""
            : ""
        certificate = credential.kind == .identityKey
            ? credential.certificate ?? ""
            : ""
        passphrase = credential.kind == .identityKey
            ? credential.passphrase ?? ""
            : ""
        elevationPassword = credential.elevationPassword ?? ""
        elevationMethod = credential.elevationMethod
    }
}

struct QuickConnectView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let host: TermPilotDomain.Host?
    var onConnected: () -> Void = {}

    @State private var connectionKind: HostConnectionKind
    @State private var hostname = ""
    @State private var username = ""
    @State private var sshPortText = "22"
    @State private var screenSharingPortText = "5900"
    @State private var rdpPortText = "3389"
    @State private var audio = true
    @State private var screenSharingMode: ScreenSharingMode = .highPerformance
    @State private var proxySelection: QuickConnectProxySelection = .direct
    @State private var customProxy = SSHProxyConfiguration()
    @State private var connecting = false
    @State private var credentialID: UUID?
    @State private var credentialDetailsExpanded = false
    @State private var authentication = AuthenticationMethod.agent
    @State private var password = ""
    @State private var identityFile = ""
    @State private var identityKey = ""
    @State private var publicKey = ""
    @State private var certificate = ""
    @State private var passphrase = ""
    @State private var serverToolsMode = QuickConnectServerToolsMode.disabled
    @State private var elevationPassword = ""
    
    @FocusState private var isHostnameFocused: Bool

    init(initialKind: HostConnectionKind = .ssh, host: TermPilotDomain.Host? = nil,
         onConnected: @escaping () -> Void = {}) {
        self.host = host
        self.onConnected = onConnected
        _connectionKind = State(initialValue: initialKind)
        _hostname = State(initialValue: host?.hostname ?? "")
        _username = State(initialValue: host?.username ?? "")
        if let configuration = host?.proxyConfiguration {
            _proxySelection = State(initialValue: .custom)
            _customProxy = State(initialValue: configuration)
        } else if let profileID = host?.proxyProfileID {
            _proxySelection = State(initialValue: .profile(profileID))
        }
    }

    private var isScreenSharing: Bool { connectionKind != .ssh }
    private var effectiveScreenMode: ScreenSharingMode { connectionKind == .rdp ? .rdp : (screenSharingMode == .rdp ? .highPerformance : screenSharingMode) }
    private var portBinding: Binding<String> {
        connectionKind == .rdp ? $rdpPortText : (isScreenSharing ? $screenSharingPortText : $sshPortText)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: localized("Quick Connect"))
                .font(.title2.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    formRow("Connection Type") {
                        Picker("", selection: $connectionKind) {
                            Text("SSH").tag(HostConnectionKind.ssh)
                            Text("RDP · Windows").tag(HostConnectionKind.rdp)
                            Text(verbatim: localized("Remote Management (Screen Sharing)"))
                                .tag(HostConnectionKind.screenSharing)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .accessibilityLabel(localized("Connection Type"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(host != nil)
                    }
                    if connectionKind == .screenSharing {
                        formRow("Display Mode") {
                            Picker("", selection: $screenSharingMode) {
                                Text(verbatim: localized("High Performance")).tag(ScreenSharingMode.highPerformance)
                                Text(verbatim: localized("Standard VNC (TCP)")).tag(ScreenSharingMode.standardVNC)
                            }.labelsHidden().pickerStyle(.menu)
                                .accessibilityLabel(localized("Display Mode"))
                        }
                    }
                    formRow("IP / Host") {
                        TextField("10.0.0.1", text: $hostname)
                            .textFieldStyle(.roundedBorder)
                            .focused($isHostnameFocused)
                            .disabled(host != nil)
                            .onSubmit(connect)
                            .onChange(of: hostname) { _, value in
                                applyPastedTargetIfNeeded(value)
                            }
                    }
                    HStack(spacing: 12) {
                        formRow("Username") {
                            TextField(connectionKind == .rdp ? "用户名或域\\用户名" : (isScreenSharing ? localized("Mac account name") : "root"), text: $username)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(connect)
                        }
                        formRow("Port") {
                            TextField(connectionKind == .rdp ? "3389" : (isScreenSharing ? "5900" : "22"), text: portBinding)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 84)
                                .onSubmit(connect)
                        }
                    }

                    formRow("Credential") {
                        Menu {
                            Button(localized("Custom Credential")) {
                                credentialDetailsExpanded = false
                                credentialID = nil
                            }
                            // Use actual menu actions: macOS Picker ignores disabled Text rows.
                            // The same state.credentials array also drives Settings > Credentials.
                            ForEach(state.credentials) { credential in
                                Button(credentialTitle(credential)) {
                                    guard !isScreenSharing || credential.kind == .password else { return }
                                    credentialDetailsExpanded = false
                                    credentialID = credential.id
                                }
                                .disabled(isScreenSharing && credential.kind != .password)
                            }
                        } label: {
                            Text(selectedCredential.map(credentialTitle) ?? localized("Custom Credential"))
                                .lineLimit(1)
                        }
                        .menuStyle(.borderedButton)
                        .accessibilityLabel(localized("Credential"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if credentialID != nil {
                        DisclosureGroup(isExpanded: $credentialDetailsExpanded) {
                            credentialFields.padding(.top, 10)
                        } label: {
                            Text(verbatim: localized("Credential Details"))
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("quick-connect-credential-details")
                    } else {
                        credentialFields
                    }
                    proxySettings
                    if isScreenSharing { screenSharingSettings }
                }
            }
            .frame(maxHeight: 620)
            .disabled(connecting)

            HStack {
                Spacer()
                Button(localized("Cancel"), role: .cancel) {
                    clearSecrets()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(connecting)
                Button(localized("Connect")) {
                    if canConnect {
                        connect()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(connecting)
        .task {
            await state.refreshCredentials()
            await state.refreshProxyProfiles()
            if let profile = await state.savedScreenSharingProfile(hostID: host?.id) {
                username = profile.username
                if profile.effectiveMode == .rdp { rdpPortText = String(profile.port) } else { screenSharingPortText = String(profile.port) }
                password = profile.password ?? ""
                audio = profile.audio
                screenSharingMode = profile.effectiveMode
            }
            await Task.yield()
            isHostnameFocused = true
        }
        .onChange(of: connectionKind) { _, _ in
            // Key credentials must never become a screen-sharing password.
            if isScreenSharing, selectedCredential?.kind == .identityKey {
                credentialID = nil
                password = ""
            }
        }
        .onDisappear { clearSecrets() }
        .onChange(of: credentialID) { _, _ in
            credentialDetailsExpanded = false
            guard let selectedCredential else { return }
            guard !isScreenSharing || selectedCredential.kind == .password else {
                credentialID = nil
                return
            }
            applyCredential(selectedCredential)
        }
    }

    private var credentialFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            if credentialID != nil {
                Text(
                    verbatim: localized(
                        "Credential values were copied and can be edited."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 92)
            }

            if isScreenSharing {
                Text(verbatim: localized("Choose a password credential from Settings > Credentials, or enter an account and password. SSH private keys cannot be used for screen sharing."))
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 92)
            }

            if !isScreenSharing {
                formRow("Authentication") {
                    Picker("", selection: $authentication) {
                        Text(verbatim: localized("SSH Agent"))
                            .tag(AuthenticationMethod.agent)
                        Text(verbatim: localized("Password"))
                            .tag(AuthenticationMethod.password)
                        Text(verbatim: localized("Private Key"))
                            .tag(AuthenticationMethod.identityFile)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityLabel(localized("Authentication"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if isScreenSharing || authentication == .password {
                formRow("Password") {
                    RevealablePasswordField(
                        localized("Password"),
                        text: $password
                    )
                }
                if !isScreenSharing {
                    Text(verbatim: localized("Used only for this connection and not written to macOS Keychain."))
                        .font(.caption).foregroundStyle(.secondary).padding(.leading, 92)
                }
            }
            if !isScreenSharing && authentication == .identityFile {
                formRow("Private key file") {
                    HStack {
                        TextField(
                            localized("Private key file"),
                            text: $identityFile
                        )
                        .textFieldStyle(.roundedBorder)
                        Button(localized("Choose...")) {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            panel.directoryURL = FileManager.default
                                .homeDirectoryForCurrentUser
                                .appendingPathComponent(
                                    ".ssh",
                                    isDirectory: true
                                )
                            if panel.runModal() == .OK {
                                identityFile = panel.url?.path ?? ""
                            }
                        }
                    }
                }
                formRow("Private key data") {
                    credentialTextEditor(text: $identityKey, height: 72)
                }
                formRow("Passphrase (optional)") {
                    RevealablePasswordField(
                        localized("Passphrase (optional)"),
                        text: $passphrase
                    )
                }
                formRow("Public Key") {
                    credentialTextEditor(text: $publicKey, height: 48)
                }
                formRow("Certificate") {
                    credentialTextEditor(text: $certificate, height: 48)
                }
            }
            if !isScreenSharing { serverToolsSettingsCard }
        }
    }

    private func connect() {
        guard canConnect, let port else { return }
        connecting = true
        Task {
            let opened: Bool
            if isScreenSharing {
                let saved = selectedCredential
                let reusableID = saved?.kind == .password && saved?.username == username && saved?.password == password ? saved?.id : nil
                opened = await state.openScreenSharing(hostname: hostname, port: port,
                    username: username, password: password, audio: audio,
                    host: host, mode: effectiveScreenMode, proxyProfileID: proxyProfileID,
                    proxyConfiguration: proxySelection == .custom ? customProxy : nil, credentialID: reusableID)
            } else {
                // The picker copies values into editable fields; use that draft,
                // not the original vault record, when opening the connection.
                opened = await state.quickConnect(
                    hostname: hostname, username: username, port: port,
                    authentication: authentication, password: password,
                    identityFile: trimmedIdentityFile, identityKey: trimmedIdentityKey,
                    publicKey: trimmedPublicKey, certificate: trimmedCertificate,
                    passphrase: passphrase.isEmpty ? nil : passphrase,
                    elevationPassword: trimmedElevationPassword,
                    serverToolsUseRoot: serverToolsMode != .disabled,
                    serverToolsElevationMethod: serverToolsMode == .su ? .su : .sudo,
                    proxyProfileID: proxyProfileID,
                    proxyConfiguration: proxySelection == .custom ? customProxy : nil)
            }
            connecting = false
            if opened {
                clearSecrets()
                onConnected()
                dismiss()
            }
        }
    }

    private func clearSecrets() {
        password = ""; identityKey = ""; passphrase = ""; elevationPassword = ""
        customProxy.password = nil
    }

    private var selectedCredential: SSHCredential? {
        guard let credentialID else { return nil }
        return state.credentials.first { $0.id == credentialID }
    }

    private var port: Int? {
        let value = portBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(value), (1 ... 65_535).contains(port) else {
            return nil
        }
        return port
    }

    private var trimmedIdentityFile: String? {
        let value = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var trimmedIdentityKey: String? {
        identityKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : identityKey
    }

    private var trimmedPublicKey: String? {
        publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : publicKey
    }

    private var trimmedCertificate: String? {
        certificate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : certificate
    }

    private var trimmedElevationPassword: String? {
        elevationPassword.isEmpty ? nil : elevationPassword
    }

    private var canConnect: Bool {
        guard !connecting, proxyValidationMessage == nil else { return false }
        if isScreenSharing {
            guard selectedCredential?.kind != .identityKey else { return false }
            return (effectiveScreenMode == .standardVNC || !password.isEmpty) && ScreenSharingEndpoint.isValid(
                host: hostname, port: port ?? 0, username: username, mode: effectiveScreenMode)
        }
        let hasHost = !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasUsername = !username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let hasAuthentication = authentication != .password
            || !password.isEmpty
        let hasIdentity = authentication != .identityFile
            || trimmedIdentityFile != nil
            || trimmedIdentityKey != nil
        return hasHost
            && port != nil
            && hasUsername
            && hasAuthentication
            && hasIdentity
    }

    private var screenSharingSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            if connectionKind == .rdp {
                Toggle("播放远端声音", isOn: $audio)
                Text("通过 RDP 连接 Windows；支持双向文本及文件复制粘贴。用户名可填写 域\\用户名。").font(.caption).foregroundStyle(.secondary)
            } else if screenSharingMode == .standardVNC {
                Text(verbatim: localized("Standard VNC shares the existing desktop over TCP. HTTP and SOCKS5 proxies are supported. Username is optional for VNC password authentication."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(verbatim: localized("Standard VNC has no audio or file drag transfer. Basic clipboard sync supports Latin-1 text; other characters are not sent."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
            Text(verbatim: localized("High Performance · SDR · 720p–4K"))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(localized("Play Remote Audio"), isOn: $audio)
            Text(verbatim: localized("Enable Screen Sharing or Remote Management on the Mac and allow this account. The first preview supports one active screen-sharing connection."))
                .font(.caption).foregroundStyle(.secondary)
            Text(verbatim: localized("The virtual display may blank the remote Mac's physical screen."))
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private var proxyProfileID: UUID? {
        if case .profile(let id) = proxySelection { return id }
        return nil
    }

    private var proxyValidationMessage: String? {
        guard proxySelection != .direct else { return nil }
        do {
            let draft = TermPilotDomain.Host(label: "Quick Connect", hostname: hostname, username: username,
                proxyProfileID: proxyProfileID,
                proxyConfiguration: proxySelection == .custom ? customProxy : nil)
            let resolved = try draft.applyingProxySettings(credentials: state.credentials, proxyProfiles: state.proxyProfiles)
            if isScreenSharing {
                try ScreenSharingEndpoint.validateProxy(profileID: proxyProfileID,
                    configuration: resolved.proxyConfiguration, mode: effectiveScreenMode)
            }
            return nil
        } catch {
            return AppLocalization.errorDescription(error)
        }
    }

    private var proxySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            formRow("Proxy") {
                Picker("", selection: $proxySelection) {
                    Text(verbatim: localized("No Application Proxy")).tag(QuickConnectProxySelection.direct)
                    ForEach(state.proxyProfiles) { profile in
                        Text(profile.label).tag(QuickConnectProxySelection.profile(profile.id))
                    }
                    if let id = proxyProfileID, !state.proxyProfiles.contains(where: { $0.id == id }) {
                        Text(verbatim: localized("Unavailable Proxy")).tag(QuickConnectProxySelection.profile(id))
                    }
                    Text(verbatim: localized("Custom Configuration")).tag(QuickConnectProxySelection.custom)
                }
                .labelsHidden().pickerStyle(.menu)
                .accessibilityLabel(localized("Proxy"))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(verbatim: localized("Proxy profiles come from Settings > Proxy. Quick Connect does not save changes."))
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 92)
            if let message = proxyValidationMessage {
                Text(verbatim: message).font(.caption).foregroundStyle(.orange)
                    .padding(.leading, 92)
            }
            if proxySelection == .custom {
                ProxyConfigurationEditor(configuration: $customProxy, credentials: state.credentials)
            }
        }
    }

    private var serverToolsSettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: localized("Server Tools"))
                .font(.headline.weight(.semibold))

            HStack {
                Text(verbatim: localized("Privilege Escalation"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $serverToolsMode) {
                    Text(verbatim: localized("Disabled"))
                        .tag(QuickConnectServerToolsMode.disabled)
                    Text("sudo")
                        .tag(QuickConnectServerToolsMode.sudo)
                    Text("su")
                        .tag(QuickConnectServerToolsMode.su)
                }
                    .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120, alignment: .trailing)
            }

            if serverToolsMode != .disabled {
                RevealablePasswordField(
                    localized("Elevation Password"),
                    text: $elevationPassword
                )

                Text(
                    verbatim: localized(
                        "Leave blank to use the login password when available."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

        }
        .padding(12)
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(
                cornerRadius: 6,
                style: .continuous
            )
        )
    }

    private func formRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: localized(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            content()
        }
    }

    private func credentialTextEditor(
        text: Binding<String>,
        height: CGFloat
    ) -> some View {
        TextEditor(text: text)
            .font(.system(.caption, design: .monospaced))
            .frame(height: height)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3))
            )
    }

    private func localized(_ key: String) -> String {
        AppLocalization.string(key)
    }

    private func credentialTitle(_ credential: SSHCredential) -> String {
        "\(credential.label) [\(credential.kind.appLocalizedTitle)]"
    }

    private func applyCredential(_ credential: SSHCredential) {
        let fields = QuickConnectCredentialFields(credential: credential)
        username = fields.username
        authentication = fields.authentication
        password = fields.password
        identityFile = ""
        identityKey = fields.identityKey
        publicKey = fields.publicKey
        certificate = fields.certificate
        passphrase = fields.passphrase
        elevationPassword = fields.elevationPassword
        serverToolsMode = fields.elevationMethod.map { $0 == .su ? .su : .sudo } ?? .disabled
    }

    private func applyPastedTargetIfNeeded(_ value: String) {
        guard !isScreenSharing else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("ssh://") || trimmed.contains("@"),
              let target = try? QuickConnectParser.parse(trimmed)
        else {
            return
        }
        hostname = target.hostname
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            username = target.username
        }
        sshPortText = String(target.port)
    }
}
