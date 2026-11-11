import SwiftUI

struct AIChatToolGroup: View {
    @ObservedObject var client: AIClient
    let tools: [[String: Any]]
    @State private var expanded = false
    private var active: Bool { tools.contains { ["approval", "running"].contains($0["state"] as? String ?? "") } }
    var body: some View {
        if tools.count == 1, let tool = tools.first { AIChatToolCard(client: client, tool: tool) }
        else {
            VStack(spacing: 0) {
                Button { expanded.toggle() } label: {
                    HStack { Image(systemName: expanded ? "chevron.down" : "chevron.right"); Text(active ? "正在使用 \(tools.count) 个工具" : "已使用 \(tools.count) 个工具"); Spacer() }
                        .font(.caption).foregroundStyle(.secondary).padding(10).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if expanded { Divider(); VStack(spacing: 6) { ForEach(tools, id: \.aiID) { tool in AIChatToolCard(client: client, tool: tool) } }.padding(6) }
            }.background(Color.secondary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.18)))
                .onAppear { expanded = active }.onChange(of: active) { expanded = active }
        }
    }
}

struct AIChatToolCard: View {
    @ObservedObject var client: AIClient
    let tool: [String: Any]
    @State private var expanded = false
    @State private var replying = false
    @FocusState private var reviewFocused: Bool
    private var state: String { tool["state"] as? String ?? "interrupted" }
    private var approval: [String: Any]? { tool["approval"] as? [String: Any] }
    private var pending: Bool { approval != nil }
    private var caption: String { ["approval":"等待批准", "running":"执行中", "completed":"已完成", "error":"失败", "interrupted":"已中断", "background":"后台运行"][state] ?? state }
    private var color: Color { state == "error" ? .red : state == "approval" ? .orange : state == "completed" ? .green : .secondary }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded || pending ? "chevron.down" : "chevron.right").font(.system(size: 9))
                    Text(tool["summary"] as? String ?? "工具").font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    if state == "running" { ProgressView().controlSize(.mini) }
                    else { Image(systemName: ["approval":"exclamationmark.shield", "completed":"checkmark.circle", "error":"xmark.circle", "background":"clock", "interrupted":"slash.circle"][state] ?? "circle").foregroundStyle(color).help(caption) }
                }.foregroundStyle(.secondary).padding(10).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(caption)：\(tool["summary"] as? String ?? "工具")")
            if expanded || pending {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if pending { Label("\(client.targetLabel) · 操作需要批准", systemImage: "server.rack").font(.caption).foregroundStyle(.secondary) }
                    details("参数", text: tool["arguments"] as? String ?? "")
                    if let output = tool["output"] as? String, !output.isEmpty { details("结果 · " + caption, text: output) }
                    if pending {
                        HStack {
                            Button("拒绝", role: .destructive) { respond(false) }
                            Spacer(minLength: 4)
                            if (approval?["payload"] as? [String: Any])?["external"] as? Bool != true {
                                Button("记住 1 小时") { respond(true, remember: true) }.help("仅记住相同目标与操作；可在 AI 安全设置撤销")
                            }
                            Button("允许") { respond(true) }.tint(.green)
                        }.controlSize(.small).disabled(replying)
                        Text("聚焦卡片：Enter 允许 · Esc 拒绝").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }.padding(10)
            }
        }.background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke((pending ? Color.orange : Color.secondary).opacity(0.22)))
            .focusable(pending).focused($reviewFocused)
            .onKeyPress(.return) { guard reviewFocused, pending, !replying else { return .ignored }; respond(true); return .handled }
            .onKeyPress(.escape) { guard reviewFocused, pending, !replying else { return .ignored }; respond(false); return .handled }
            .onChange(of: pending) { if !pending { expanded = false; replying = false } }
    }
    @ViewBuilder private func details(_ title: String, text: String) -> some View {
        if !text.isEmpty {
            HStack { Text(title).font(.caption2).foregroundStyle(.secondary); Spacer(); Button { AIChatClipboard.copy(text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("复制完整内容") }
            ScrollView([.horizontal, .vertical]) { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: pending ? 170 : 240)
        }
    }
    private func respond(_ allow: Bool, remember: Bool = false) {
        guard let approval, !replying else { return }; replying = true
        Task { await client.respond(approval, value: ["allow": allow, "remember": remember]); replying = false }
    }
}
