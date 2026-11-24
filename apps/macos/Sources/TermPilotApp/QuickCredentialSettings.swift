import SwiftUI
import TermPilotDomain

extension QuickCredentialProtocol {
    var title: String {
        switch self {
        case .ssh: return "SSH"
        case .standardVNC: return "Standard VNC"
        case .highPerformance: return "Apple High Performance"
        case .rdp: return "RDP"
        }
    }
}

struct QuickCredentialSettings: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        GroupBox(AppLocalization.string("Quick Connect Credentials")) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(QuickCredentialProtocol.allCases, id: \.self) { kind in
                    QuickCredentialPreferenceRow(kind: kind, credentials: state.credentials)
                }
            }.padding(8)
        }
    }
}

private struct QuickCredentialPreferenceRow: View {
    let kind: QuickCredentialProtocol
    let credentials: [SSHCredential]
    @State private var strategy: QuickCredentialStrategy = .manual
    @State private var fixed = ""
    private var available: [SSHCredential] { credentials.filter { kind.supports(kind: $0.kind.rawValue) } }
    var body: some View {
        HStack {
            Text(AppLocalization.string(kind.title)).frame(width: 145, alignment: .leading)
            Picker(AppLocalization.string("Credential strategy"), selection: $strategy) {
                Text(AppLocalization.string("Choose each time")).tag(QuickCredentialStrategy.manual)
                Text(AppLocalization.string("Remember last successful credential")).tag(QuickCredentialStrategy.recent)
                Text(AppLocalization.string("Fixed credential")).tag(QuickCredentialStrategy.fixed)
            }.labelsHidden()
            if strategy == .fixed {
                Picker(AppLocalization.string("Credential"), selection: $fixed) {
                    Text(AppLocalization.string("Select credential")).tag("")
                    if !fixed.isEmpty && !available.contains(where: { $0.id.uuidString == fixed }) {
                        Text(AppLocalization.string("Credential unavailable. Select again.")).tag(fixed)
                    }
                    ForEach(available) { credential in
                        Text("\(credential.label) · \(credential.username)").tag(credential.id.uuidString)
                    }
                }.labelsHidden()
            }
        }
        .onAppear {
            strategy = QuickCredentialPreferences().strategy(kind)
            fixed = QuickCredentialPreferences().fixedID(kind)
        }
        .onChange(of: strategy) { _, _ in save() }
        .onChange(of: fixed) { _, _ in save() }
    }
    private func save() { QuickCredentialPreferences().configure(kind, strategy: strategy, credentialID: fixed) }
}
