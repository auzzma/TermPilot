import SwiftUI
import UIKit

/// Native Markdown blocks. Text is rendered as text, never executable HTML.
struct MarkdownView: View {
  let text: String
  struct Block: Identifiable {
    let id: Int
    let kind: String
    let text: String
    var rows: [[String]] = []
  }
  private var blocks: [Block] {
    let lines = text.components(separatedBy: "\n")
    var result: [Block] = []
    var index = 0
    while index < lines.count {
      let line = lines[index]
      index += 1
      if line.hasPrefix("```") {
        var content: [String] = []
        while index < lines.count && !lines[index].hasPrefix("```") {
          content.append(lines[index])
          index += 1
        }
        if index < lines.count { index += 1 }
        result.append(Block(id: result.count, kind: "code", text: content.joined(separator: "\n")))
      } else if line.contains("|"), index < lines.count, lines[index].contains("---"),
        lines[index].allSatisfy({ "| :-\t".contains($0) })
      {
        func cells(_ s: String) -> [String] {
          s.trimmingCharacters(in: CharacterSet(charactersIn: " |\t")).components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        var rows = [cells(line)]
        index += 1
        while index < lines.count && lines[index].contains("|") {
          rows.append(cells(lines[index]))
          index += 1
        }
        result.append(Block(id: result.count, kind: "table", text: "", rows: rows))
      } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
        result.append(
          Block(id: result.count, kind: line.hasPrefix("#") ? "heading" : "text", text: line))
      }
    }
    return result
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(blocks) { block in
        switch block.kind {
        case "code":
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(tr("代码")).font(.caption).foregroundStyle(.secondary)
              Spacer()
              Button {
                UIPasteboard.general.string = block.text
              } label: {
                Image(systemName: "doc.on.doc")
              }.accessibilityLabel(tr("复制代码"))
            }
            ScrollView(.horizontal) {
              Text(block.text).font(.callout.monospaced()).textSelection(.enabled).fixedSize(
                horizontal: true, vertical: false)
            }
          }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        case "table":
          ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
              ForEach(Array(block.rows.enumerated()), id: \.offset) { row, cells in
                GridRow {
                  ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    Text(.init(cell)).fontWeight(row == 0 ? .semibold : .regular).frame(
                      minWidth: 90, maxWidth: 200, alignment: .leading
                    ).padding(10)
                      .background(row == 0 ? Color.secondary.opacity(0.12) : .clear)
                      .overlay(Rectangle().stroke(Color.secondary.opacity(0.18), lineWidth: 0.5))
                  }
                }
              }
            }.textSelection(.enabled)
          }
        case "heading":
          Text(block.text.drop(while: { $0 == "#" || $0 == " " })).font(.headline).padding(.top, 5)
            .textSelection(.enabled)
        default:
          let line = block.text.trimmingCharacters(in: .whitespaces)
          Text(
            .init(line.hasPrefix("- ") || line.hasPrefix("* ") ? "• " + line.dropFirst(2) : line)
          ).textSelection(.enabled)
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
