import SwiftUI
import UniformTypeIdentifiers

struct BackupView: View {
  @EnvironmentObject var model: AppModel
  @State private var password = ""
  @State private var importing = false
  @State private var exporting = false
  @State private var files: [URL] = []
  @State private var status = ""
  var body: some View {
    Form {
      Section(tr("跨设备备份")) {
        Text(tr("使用与桌面版相同的加密备份格式。导入前会在本机保存当前数据的加密备份；不会连接云端。"))
        SecureField(tr("备份密码"), text: $password)
        Button(tr("导出加密备份")) {
          model.attempt {
            let path = model.runtime!.directory.appendingPathComponent(
              "TermPilot-\(UUID().uuidString).backup")
            _ = try await model.call([
              "method": "vault.export", "path": path.path, "password": password,
            ])
            files = [path]
            exporting = true
          }
        }.disabled(password.isEmpty)
        Button(tr("导入桌面或移动端备份")) { importing = true }.disabled(password.isEmpty)
        if !status.isEmpty { Text(status) }
      }
    }.navigationTitle(tr("备份与恢复"))
      .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .item]) { result in
        model.attempt {
          let source = try result.get()
          let access = source.startAccessingSecurityScopedResource()
          defer { if access { source.stopAccessingSecurityScopedResource() } }
          let staged = model.runtime!.directory.appendingPathComponent(
            "import-\(UUID().uuidString).backup")
          defer { try? FileManager.default.removeItem(at: staged) }
          try FileManager.default.copyItem(at: source, to: staged)
          let previous = model.runtime!.directory.appendingPathComponent(
            "before-import-\(UUID().uuidString).backup")
          _ = try await model.call([
            "method": "vault.export", "path": previous.path, "password": password,
          ])
          _ = try await model.call([
            "method": "vault.import", "path": staged.path, "password": password,
          ])
          await model.reload()
          status = tr("导入完成；导入前的备份已保存在本机，可导出保留。")
          files = [previous]
          exporting = true
        }
      }.sheet(isPresented: $exporting) { ExportPicker(urls: files) }
  }
}
