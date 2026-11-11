import SwiftUI

struct FileEdit: Identifiable {
  let id = UUID()
  let operation: String
  let path: String
}
struct FileEditor: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) var dismiss
  @ObservedObject var session: MobileSession
  let edit: FileEdit
  @State private var value = ""
  @State private var loaded = false
  @State private var original = ""
  @State private var busy = false
  @State private var error: String?
  @State private var discard = false
  private var title: String {
    ["rename": tr("重命名"), "chmod": tr("文件权限"), "writeText": tr("编辑文本"), "delete": tr("删除文件")][
      edit.operation]
      ?? tr("文件")
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Text(edit.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).padding()
        Divider()
        if busy || (!loaded && error == nil) { ProgressView().padding(8) }
        if let error { Text(error).font(.callout).foregroundStyle(.red).padding() }
        if edit.operation == "writeText" {
          TextEditor(text: $value).font(.system(size: 15, design: .monospaced))
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .disabled(!loaded || busy).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("file-editor-text")
          Divider()
          HStack {
            Text(trf("{} 行 · {} 字符", String(value.filter { $0 == "\n" }.count + 1), String(value.count)))
            Spacer()
            if value != original { Text(tr("未保存")) }
          }.font(.caption).foregroundStyle(.secondary).padding(12)
        } else {
          Form {
            if edit.operation == "delete" { Text(tr("将删除此文件或文件夹及其内容。")) }
            else { TextField(edit.operation == "chmod" ? tr("八进制权限，例如 644") : tr("新名称"), text: $value)
              .textInputAutocapitalization(.never).autocorrectionDisabled() }
          }
        }
      }.navigationTitle(edit.operation == "writeText" ? (edit.path as NSString).lastPathComponent : title).navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("file-editor-page").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button { if busy { return }; if edit.operation == "writeText" && value != original { discard = true } else { dismiss() } } label: { Label(tr("返回"), systemImage: "chevron.left") } }
        ToolbarItem(placement: .confirmationAction) {
          Button(
            edit.operation == "delete" ? tr("删除") : tr("保存"),
            role: edit.operation == "delete" ? .destructive : nil
          ) {
            Task {
              busy = true
              error = nil
              do {
              defer { busy = false }
              var request: JSON = ["action": edit.operation, "path": edit.path]
              switch edit.operation {
              case "rename":
                guard !value.isEmpty, !value.contains("/"), value != ".", value != ".." else {
                  throw MobileError(message: tr("文件名称无效"))
                }
                request["oldPath"] = edit.path
                request["newPath"] = (edit.path as NSString).deletingLastPathComponent + "/" + value
              case "chmod":
                guard let permissions = UInt32(value, radix: 8), permissions <= 0o7777 else {
                  throw MobileError(message: tr("请输入有效的八进制权限"))
                }
                request["permissions"] = permissions
              case "writeText":
                let current = try await model.files(
                  session, ["action": "readText", "path": edit.path]
                ).text("text")
                guard current == original else {
                  throw MobileError(message: tr("远端文件已变化，请重新打开后编辑，避免覆盖其他修改。"))
                }
                request["content"] = value
                request["overwrite"] = true
              default: break
              }
              _ = try await model.files(session, request)
              original = value
              try await model.list(session)
              dismiss()
              } catch { self.error = error.localizedDescription }
            }
          }.disabled(!loaded || busy || (edit.operation == "writeText" && value == original))
        }
      }
    }.interactiveDismissDisabled()
    .confirmationDialog(tr("放弃未保存的修改？"), isPresented: $discard, titleVisibility: .visible) {
      Button(tr("放弃修改"), role: .destructive) { dismiss() }
      Button(tr("继续编辑"), role: .cancel) {}
    }.task {
      do {
        if edit.operation == "writeText" {
          value = try await model.files(session, ["action": "readText", "path": edit.path]).text(
            "text")
          original = value
        } else if edit.operation == "rename" {
          value = (edit.path as NSString).lastPathComponent
        } else if edit.operation == "chmod" {
          value = String(
            try await model.files(session, ["action": "stat", "path": edit.path]).object("entry")
              .number("permissions") & 0o7777, radix: 8)
        }
        loaded = true
      } catch { self.error = error.localizedDescription }
    }
  }
}
