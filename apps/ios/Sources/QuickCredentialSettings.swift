import SwiftUI

extension QuickCredentialProtocol {
  var title: String {
    switch self {
    case .ssh: return "SSH"
    case .standardVNC: return "普通 VNC"
    case .highPerformance: return "Apple 高性能"
    case .rdp: return "RDP"
    }
  }
}

struct MobileQuickCredentialSettings: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    Form {
      ForEach(QuickCredentialProtocol.allCases, id: \.self) { kind in
        MobileQuickCredentialRow(kind: kind, credentials: model.records["credentials"] ?? [])
      }
    }.navigationTitle(tr("快速连接凭证"))
  }
}

private struct MobileQuickCredentialRow: View {
  let kind: QuickCredentialProtocol
  let credentials: [JSON]
  @State private var strategy = QuickCredentialStrategy.manual
  @State private var fixed = ""
  private var available: [JSON] { credentials.filter { kind.supports(kind: $0.text("kind")) } }
  var body: some View {
    Section(tr(kind.title)) {
      Picker(tr("凭证使用方式"), selection: $strategy) {
        Text(tr("每次选择")).tag(QuickCredentialStrategy.manual)
        Text(tr("记住上次成功使用的凭证")).tag(QuickCredentialStrategy.recent)
        Text(tr("固定凭证")).tag(QuickCredentialStrategy.fixed)
      }
      if strategy == .fixed {
        Picker(tr("凭证"), selection: $fixed) {
          Text(tr("请选择凭证")).tag("")
          if !fixed.isEmpty && !available.contains(where: { $0.text("id") == fixed }) {
            Text(tr("凭证不可用，请重新选择。")).tag(fixed)
          }
          ForEach(available, id: \.selfID) { credential in
            Text(credential.text("label") + " · " + credential.text("username")).tag(credential.text("id"))
          }
        }
      }
    }.onAppear {
      strategy = QuickCredentialPreferences().strategy(kind)
      fixed = QuickCredentialPreferences().fixedID(kind)
    }
    .onChange(of: strategy) { _, _ in save() }
    .onChange(of: fixed) { _, _ in save() }
  }
  private func save() { QuickCredentialPreferences().configure(kind, strategy: strategy, credentialID: fixed) }
}
