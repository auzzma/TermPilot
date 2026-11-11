import SwiftUI

struct TerminalSearch: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) var dismiss
  let session: MobileSession
  @State private var text = ""
  @State private var query = ""
  var body: some View {
    NavigationStack {
      ScrollView([.vertical, .horizontal]) {
        Text(
          query.isEmpty
            ? text
            : text.components(separatedBy: "\n").filter {
              $0.localizedCaseInsensitiveContains(query)
            }.joined(separator: "\n")
        )
        .font(.callout.monospaced()).textSelection(.enabled).padding().frame(
          maxWidth: .infinity, alignment: .leading)
      }.searchable(text: $query, prompt: tr("搜索终端历史")).navigationTitle(tr("选择与搜索"))
        .toolbar { Button(tr("完成")) { dismiss() } }
        .task {
          model.attempt {
            var lines: [String] = []
            var start = 0
            while start < 10000 {
              let page = try await model.call([
                "method": "terminal.context", "id": session.terminalID, "range": "lines",
                "startLine": start, "maxLines": 300,
              ])
              lines.append(page.text("text"))
              let next = page.number("nextLine")
              if next <= start || next >= page.number("totalLines") { break }
              start = next
            }
            text = lines.joined(separator: "\n")
          }
        }
    }
  }
}
