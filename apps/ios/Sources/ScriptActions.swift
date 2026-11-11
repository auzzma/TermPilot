import SwiftUI

struct ScriptActions: View {
  @EnvironmentObject var model: AppModel
  let record: JSON
  let current: MobileSession
  @State private var target: UInt64 = 0
  @State private var confirmation = false
  private var selected: MobileSession? {
    model.sessions.first {
      $0.id == (target == 0 ? current.id : target) && $0.protocolKind == "ssh" && $0.connected
    }
  }
  var body: some View {
    VStack(alignment: .leading) {
      Picker(tr("目标服务器"), selection: $target) {
        Text(current.label).tag(UInt64(0))
        ForEach(
          model.sessions.filter { $0.id != current.id && $0.protocolKind == "ssh" && $0.connected }
        ) { session in
          Text(session.label).tag(session.id)
        }
      }
      HStack {
        Button(tr("插入终端")) {
          guard let session = selected else { return }
          model.attempt {
            var body = record.text("body")
            while body.hasSuffix("\n") || body.hasSuffix("\r") { body.removeLast() }
            let snapshot = try await model.call([
              "method": "terminal.snapshot", "id": session.terminalID,
            ])
            let bracketed = snapshot["bracketedPaste"] as? Bool == true
            guard bracketed || !body.contains(where: { $0 == "\n" || $0 == "\r" }) else {
              throw MobileError(message: tr("当前终端未启用安全粘贴，多行脚本请使用执行操作"))
            }
            guard !body.contains("\u{1b}") else { throw MobileError(message: tr("快捷命令不能包含终端控制序列")) }
            model.selected = session.id
            session.activePanel = "terminal"
            model.sendText(session, bracketed ? "\u{1b}[200~" + body + "\u{1b}[201~" : body)
          }
        }
        Button(tr("执行…")) { confirmation = true }
      }.disabled(selected == nil)
    }.sheet(isPresented: $confirmation) {
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text(trf("目标：{}", selected?.label ?? tr("已断开"))).font(.headline)
            Text(trf("账号：{}", selected?.host.text("username") ?? ""))
            Text(record.text("shell", "/bin/sh")).font(.caption)
            Text(record.text("body")).font(.system(.body, design: .monospaced)).textSelection(
              .enabled)
          }.padding()
        }.navigationTitle(tr("确认执行脚本")).toolbar {
          ToolbarItem(placement: .cancellationAction) { Button(tr("取消")) { confirmation = false } }
          ToolbarItem(placement: .confirmationAction) {
            Button(tr("执行")) {
              guard let session = selected else {
                confirmation = false
                return
              }
              model.attempt {
                let info = try await model.files(session, ["action": "systemInfo"])
                let plan = try await model.call([
                  "method": "mobile.serverTool", "operation": "script",
                  "value": record.text("body"), "shell": record.text("shell", "/bin/sh"),
                  "platform": info.text("platform"),
                ])
                model.selected = session.id
                session.activePanel = "terminal"
                model.sendText(session, plan.text("command") + "\n")
                confirmation = false
              }
            }.disabled(selected == nil)
          }
        }
      }
    }
  }
}
