import SwiftUI
import TermPilotDomain

struct ProxyConfigurationEditor: View {
    @Binding var configuration: SSHProxyConfiguration
    let credentials: [SSHCredential]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            configurationCard {
                LabeledContent("Type") {
                    Picker("", selection: $configuration.type) {
                        Text("HTTP").tag(SSHProxyType.http)
                        Text("SOCKS5").tag(SSHProxyType.socks5)
                        Text("ProxyCommand").tag(SSHProxyType.command)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                Divider()

                if configuration.type == .command {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use %h for the target host, %p for the target port, and %% for a literal percent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField(
                            "cloudflared access ssh --hostname %h",
                            text: Binding(
                                get: { configuration.command ?? "" },
                                set: { configuration.command = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    }
                } else {
                    LabeledContent("Proxy Host") {
                        TextField("", text: $configuration.host)
                            .multilineTextAlignment(.leading)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                    }

                    Divider()

                    LabeledContent("Port") {
                        TextField("", value: $configuration.port, format: .number)
                            .multilineTextAlignment(.leading)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                    }
                }
            }

            if configuration.type != .command {
                configurationCard {
                    HStack {
                        Label("Credentials", systemImage: "key")
                            .font(.body.weight(.semibold))
                        Spacer()
                        Text("Optional")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    LabeledContent("Saved Credential") {
                        Picker("", selection: proxyCredentialBinding) {
                            Text("Manual Credentials").tag(UUID?.none)
                            ForEach(passwordCredentials) { credential in
                                Text(credential.label).tag(Optional(credential.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }

                    if let selectedCredential {
                        Divider()
                        HStack(spacing: 8) {
                            Image(systemName: "person.badge.key")
                                .foregroundStyle(.secondary)
                            Text(selectedCredential.label)
                            Spacer()
                            Text(selectedCredential.username)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    } else {
                        Divider()
                        LabeledContent("Username") {
                            TextField(
                                "",
                                text: Binding(
                                    get: { configuration.username ?? "" },
                                    set: { configuration.username = $0 }
                                )
                            )
                            .multilineTextAlignment(.leading)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                        }

                        Divider()
                        LabeledContent("Password") {
                            SecureField(
                                "",
                                text: Binding(
                                    get: { configuration.password ?? "" },
                                    set: { configuration.password = $0 }
                                )
                            )
                            .multilineTextAlignment(.leading)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                        }
                    }
                }
            }
        }
    }

    private var passwordCredentials: [SSHCredential] {
        credentials.filter { $0.kind == .password }
    }

    private var selectedCredential: SSHCredential? {
        guard let credentialID = configuration.credentialID else {
            return nil
        }
        return passwordCredentials.first { $0.id == credentialID }
    }

    private var proxyCredentialBinding: Binding<UUID?> {
        Binding(
            get: { configuration.credentialID },
            set: { credentialID in
                configuration.credentialID = credentialID
                if credentialID != nil {
                    configuration.username = nil
                    configuration.password = nil
                }
            }
        )
    }

    private func configurationCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35))
        }
    }
}

struct ProxyProfileEditor: View {
    @State private var profile: SSHProxyProfile
    @State private var isSaving = false
    let credentials: [SSHCredential]
    let onCancel: () -> Void
    let onSave: (SSHProxyProfile) async -> Bool

    init(
        profile: SSHProxyProfile,
        credentials: [SSHCredential],
        onCancel: @escaping () -> Void,
        onSave: @escaping (SSHProxyProfile) async -> Bool
    ) {
        _profile = State(initialValue: profile)
        self.credentials = credentials
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    LocalizedStringKey(
                        profile.label.isEmpty ? "New Proxy" : "Edit Proxy"
                    )
                )
                .font(.title2.weight(.semibold))
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Proxy Name", systemImage: "slider.horizontal.3")
                            .font(.body.weight(.semibold))
                        TextField("", text: $profile.label)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(14)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )

                    ProxyConfigurationEditor(
                        configuration: $profile.configuration,
                        credentials: credentials
                    )
                }
                .padding(20)
            }

            Divider()

            Button("Save") {
                guard !isSaving else {
                    return
                }
                isSaving = true
                Task {
                    let saved = await onSave(profile)
                    isSaving = false
                    if saved {
                        onCancel()
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension SSHProxyType {
    var appLocalizedTitle: String {
        switch self {
        case .http:
            "HTTP"
        case .socks5:
            "SOCKS5"
        case .command:
            "ProxyCommand"
        }
    }
}

extension SSHProxyConfiguration {
    var appEndpointSummary: String {
        type == .command ? "ProxyCommand" : "\(host):\(port)"
    }
}
