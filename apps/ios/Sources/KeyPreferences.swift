import SwiftUI

struct TerminalKey {
  let name: String, text: String
  let code: Int
  var modifier: Int? = nil
  static let defaultOrder = "Esc,Tab,Ctrl-C,↑,↓,←,→"
  static let all: [TerminalKey] =
    [
      .init(name: "Esc", text: "\u{1b}", code: 0xff1b),
      .init(name: "Tab", text: "\t", code: 0xff09),
      .init(name: "Ctrl-C", text: "\u{3}", code: 99, modifier: 0xffe3),
      .init(name: "↑", text: "\u{1b}[A", code: 0xff52),
      .init(name: "↓", text: "\u{1b}[B", code: 0xff54),
      .init(name: "←", text: "\u{1b}[D", code: 0xff51),
      .init(name: "→", text: "\u{1b}[C", code: 0xff53),
      .init(name: "Home", text: "\u{1b}[H", code: 0xff50),
      .init(name: "End", text: "\u{1b}[F", code: 0xff57),
      .init(name: "PgUp", text: "\u{1b}[5~", code: 0xff55),
      .init(name: "PgDn", text: "\u{1b}[6~", code: 0xff56),
      .init(name: "Delete", text: "\u{1b}[3~", code: 0xffff),
    ]
    + (1...12).map { n in
      let sequence =
        n <= 4
        ? "\u{1b}O" + String(UnicodeScalar(79 + n)!) : "\u{1b}[\([15,17,18,19,20,21,23,24][n-5])~"
      return .init(name: "F\(n)", text: sequence, code: 0xffbd + n)
    }
  static func ordered(_ value: String) -> [TerminalKey] {
    var seen = Set<String>()
    return value.split(separator: ",").compactMap { part in
      let key = String(part)
      return seen.insert(key).inserted ? all.first { $0.name == key } : nil
    }
  }
}

struct KeyPreferencesView: View {
  @AppStorage("TermPilot.keyOrder") private var order = TerminalKey.defaultOrder
  var body: some View {
    List {
      Section(tr("已显示 · 拖动调整顺序")) {
        ForEach(TerminalKey.ordered(order), id: \.name) { key in Text(key.name) }
          .onMove { source, destination in
            var names = TerminalKey.ordered(order).map(\.name)
            names.move(fromOffsets: source, toOffset: destination)
            order = names.joined(separator: ",")
          }
          .onDelete { indices in
            var names = TerminalKey.ordered(order).map(\.name)
            names.remove(atOffsets: indices)
            order = names.joined(separator: ",")
          }
      }
      Section(tr("添加按键")) {
        ForEach(
          TerminalKey.all.filter { key in
            !TerminalKey.ordered(order).contains { $0.name == key.name }
          }, id: \.name
        ) { key in
          Button(key.name) {
            order = (TerminalKey.ordered(order).map(\.name) + [key.name]).joined(separator: ",")
          }
        }
      }
      Button(tr("恢复默认")) { order = TerminalKey.defaultOrder }
    }.navigationTitle(tr("快捷键栏")).toolbar { EditButton() }
  }
}
