import SwiftUI

struct TransferHistoryView: View {
  @EnvironmentObject var model: AppModel
  @State private var export: [URL] = []
  @State private var exporting = false
  var body: some View {
    List {
      if model.transferHistory.isEmpty { Text(tr("暂无传输记录")).foregroundStyle(.secondary) }
      ForEach(model.transferHistory, id: \.selfID) { r in
        VStack(alignment: .leading, spacing: 8) {
          Text(r.text("name")).font(.headline)
          Text(r.text("label") + " · " + state(r.text("status"))).font(.caption).foregroundStyle(
            .secondary)
          if !r.text("error").isEmpty {
            Text(r.text("error")).font(.caption).foregroundStyle(.red).textSelection(.enabled)
          }
          if r.text("status") == "interrupted" && r.text("protocol") == "ssh" {
            Button(r.text("resumeDirectory").isEmpty ? tr("重新传输") : tr("校验并恢复")) {
              model.attempt { try await model.retryTransfer(r) }
            }
          }
          if r.text("status") == "downloaded" {
            Button(tr("导出文件")) {
              export = [URL(fileURLWithPath: r.text("localPath"))]
              exporting = true
            }
          }
        }.padding(.vertical, 5)
      }
    }.navigationTitle(tr("传输记录")).sheet(isPresented: $exporting) { ExportPicker(urls: export) }
  }
  private func state(_ value: String) -> String {
    [
      "active": tr("传输中"), "paused": tr("已暂停"), "interrupted": tr("已中断，等待操作"),
      "completed": tr("已完成"),
      "downloaded": tr("已下载，待导出"), "cancelled": tr("已取消"),
    ][value] ?? value
  }
}
