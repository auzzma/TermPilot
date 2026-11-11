import AppKit
import SwiftUI

struct AIChatBlock: Identifiable {
    let id: String
    let kind: String
    let text: String
    let children: [AIChatBlock]
    let value: [String: Any]
    init(_ value: [String: Any], id: String = "root") {
        self.id = id; self.value = value
        kind = value["kind"] as? String ?? "text"; text = value["text"] as? String ?? ""
        children = (value["children"] as? [[String: Any]] ?? []).enumerated().map { AIChatBlock($0.element, id: id + "." + String($0.offset)) }
    }
    var plain: String { text + children.map(\.plain).joined() }
    static func parse(_ values: [[String: Any]]) -> [AIChatBlock] { values.enumerated().map { AIChatBlock($0.element, id: String($0.offset)) } }
}

struct AIChatMarkdown: View {
    let blocks: [AIChatBlock]
    var body: some View {
        VStack(alignment: .leading, spacing: 11) { ForEach(blocks) { block in AIChatBlockView(block: block) } }
            .font(.system(size: 13)).lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func chatInline(_ node: AIChatBlock, bold: Bool = false, italic: Bool = false, strike: Bool = false, size: CGFloat = 13) -> AttributedString {
    let bold = bold || node.kind == "strong", italic = italic || node.kind == "emphasis", strike = strike || node.kind == "strike"
    var output = AttributedString(node.text)
    if !node.text.isEmpty {
        var font = Font.system(size: size, weight: bold ? .semibold : .regular, design: node.kind == "code" ? .monospaced : .default)
        if italic { font = font.italic() }; output.font = font
        if strike { output.strikethroughStyle = .single }
        if node.kind == "code" { output.backgroundColor = Color.secondary.opacity(0.14) }
    }
    for child in node.children { output += chatInline(child, bold: bold, italic: italic, strike: strike, size: size) }
    if node.kind == "link", let raw = node.value["url"] as? String, !raw.isEmpty, let url = URL(string: raw) { output.link = url }
    return output
}

struct AIChatBlockView: View {
    let block: AIChatBlock
    @State private var expanded = false
    @State private var copied = false
    var body: some View { content }
    private var content: AnyView {
        switch block.kind {
        case "heading":
            return AnyView(Text(chatInline(block, bold: true, size: (block.value["level"] as? Int ?? 3) < 3 ? 17 : 14)).textSelection(.enabled).padding(.top, 5))
        case "list":
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(block.children.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: 9) {
                        Text((block.value["start"] as? Int).map { "\($0 + index)." } ?? "•").foregroundStyle(.secondary).frame(minWidth: 12, alignment: .trailing)
                        AIChatMarkdown(blocks: item.children)
                    }
                }
            }.padding(.leading, 5))
        case "quote":
            return AnyView(HStack(alignment: .top, spacing: 10) { Rectangle().fill(.secondary.opacity(0.3)).frame(width: 3); AIChatMarkdown(blocks: block.children) }.fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary))
        case "table", "codeBlock":
            return AnyView(VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(block.kind == "table" ? "" : block.value["language"] as? String ?? "").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button { AIChatClipboard.copy(exportText); copied = true } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }.help("复制")
                    Button { export() } label: { Image(systemName: "square.and.arrow.down") }.help("导出")
                    Button { expanded = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("放大查看")
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).padding(9)
                blockDetail.padding(.horizontal, 9).padding(.bottom, 10)
            }.background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.18)))
                .sheet(isPresented: $expanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text(block.kind == "table" ? "表格" : "代码").font(.headline); Spacer(); Button("完成") { expanded = false } }
                        ScrollView([.horizontal, .vertical]) { blockDetail.padding(12) }
                    }.padding(20).frame(minWidth: 640, idealWidth: 820, minHeight: 420, idealHeight: 600)
                })
        case "rule": return AnyView(Divider())
        case "image": return AnyView(Label(block.plain.isEmpty ? "图片" : block.plain, systemImage: "photo").font(.caption).foregroundStyle(.secondary))
        case "item", "group": return AnyView(AIChatMarkdown(blocks: block.children))
        default: return AnyView(Text(chatInline(block)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading))
        }
    }
    private var tableRows: [[AIChatBlock]] { block.children.map(\.children) }
    private var exportText: String {
        block.kind == "table" ? tableRows.map { $0.map(\.plain).joined(separator: "\t") }.joined(separator: "\n") : block.plain
    }
    @ViewBuilder private var blockDetail: some View {
        if block.kind == "table" {
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(tableRows.enumerated()), id: \.offset) { row, cells in
                        GridRow {
                            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                                Text(chatInline(cell, bold: row == 0)).textSelection(.enabled)
                                    .frame(width: columnWidth(column), height: rowHeight(cells), alignment: alignment(column)).padding(8)
                                    .background(row == 0 ? Color.secondary.opacity(0.1) : Color.clear)
                                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.16), lineWidth: 0.5))
                            }
                        }
                    }
                }
            }
        } else {
            ScrollView(.horizontal) { Text(block.plain).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
    private func columnWidth(_ column: Int) -> CGFloat {
        let width = tableRows.compactMap { cells -> CGFloat? in
            guard cells.indices.contains(column) else { return nil }
            return (cells[column].plain as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)]).width
        }.max() ?? 44
        return min(140, max(44, ceil(width) + 6))
    }
    private func rowHeight(_ cells: [AIChatBlock]) -> CGFloat {
        cells.enumerated().map { column, cell in
            let measured = (cell.plain as NSString).boundingRect(with: NSSize(width: columnWidth(column), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)])
            return ceil(measured.height) + 5
        }.max() ?? 20
    }
    private func alignment(_ column: Int) -> Alignment {
        let values = block.value["alignments"] as? [String] ?? []
        guard values.indices.contains(column) else { return .leading }
        return values[column] == "right" ? .trailing : values[column] == "center" ? .center : .leading
    }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = block.kind == "table" ? "TermPilot-table.tsv" : "TermPilot-code.txt"
        if panel.runModal() == .OK, let url = panel.url {
            do { try exportText.write(to: url, atomically: true, encoding: .utf8) }
            catch { NSAlert(error: error).runModal() }
        }
    }
}

enum AIChatClipboard {
    static func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}
