import SwiftUI

struct SyncConflicts: View {
    let conflicts: [[String: Any]]
    let request: ([String: Any]) async throws -> [String: Any]
    let confirm: (String, [String: Any]) -> Void
    @State private var search = ""
    var body: some View {
        if conflicts.isEmpty { Text("没有待处理冲突").foregroundStyle(.secondary) }
        else {
            Text("\(conflicts.count) 条记录需要确认。选择需要保留的版本，保存后会同步到其他设备。")
                .font(.footnote).foregroundStyle(.secondary)
            TextField("搜索名称、地址或冲突字段", text: $search)
            ForEach(Array(conflicts.enumerated()), id: \.offset) { _, conflict in
                if matches(conflict) {
                    ConflictRecord(conflict: conflict, request: request, confirm: confirm)
                        .id(conflict["revision"] as? String ?? "")
                }
            }
        }
    }
    private func matches(_ conflict: [String: Any]) -> Bool {
        let details = conflict["details"] as? [[String: Any]] ?? []
        return search.isEmpty || ([conflict["title"], conflict["subtitle"]].compactMap { $0 as? String }
            + details.compactMap { $0["label"] as? String }).joined(separator: " ").localizedCaseInsensitiveContains(search)
    }
}
private struct ConflictRecord: View {
    let conflict: [String: Any]
    let request: ([String: Any]) async throws -> [String: Any]
    let confirm: (String, [String: Any]) -> Void
    @State private var choices: [String: [String: Any]] = [:]
    @State private var expanded = false
    var details: [[String: Any]] { conflict["details"] as? [[String: Any]] ?? [] }
    var deleted: Bool { conflict["deleted"] as? Bool == true }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
            Text(conflict["subtitle"] as? String ?? "").foregroundStyle(.secondary).textSelection(.enabled)
            if deleted {
                Text("删除与编辑冲突：有设备删除了此记录，同时另一个版本仍有修改。原记录目前保持删除；需要恢复时可在回收站恢复为副本。")
                ForEach(Array((conflict["deletions"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, source in
                    Text("删除来源：\(source["name"] as? String ?? "未记录") · \(source["at"] as? String ?? "时间未记录")").font(.caption)
                }
            }
            ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                let key = detail["key"] as? String ?? ""
                VStack(alignment: .leading, spacing: 8) {
                    Text(detail["label"] as? String ?? key).font(.headline)
                    Text(detail["hint"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array((detail["candidates"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { index, candidate in
                        ConflictCandidate(conflict: conflict, field: key, candidate: candidate, number: index + 1,
                            selected: same(choices[key], candidate["dot"] as? [String: Any]), selectable: !deleted,
                            request: request, select: { choices[key] = candidate["dot"] as? [String: Any] })
                    }
                }.padding(.vertical, 8)
                Divider()
            }
            if deleted {
                Button("保留删除") { confirm("确认保留删除？当前编辑内容会保留在同步历史和回收站中。", command(keepDeleted: true)) }
            } else {
                Button("保存冲突选择") {
                    confirm("将所选版本用于“\(conflict["title"] as? String ?? "此记录")”的 \(details.count) 个冲突字段；其他字段保持不变。", command(keepDeleted: false))
                }.buttonStyle(.borderedProminent)
                    .disabled(details.isEmpty || details.contains { choices[$0["key"] as? String ?? ""] == nil })
            }
            Text("记录 ID：\(conflict["id"] as? String ?? "")").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(conflict["title"] as? String ?? "记录冲突").font(.headline)
                Text(deleted ? "删除与编辑冲突" : details.compactMap { $0["label"] as? String }.joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func command(keepDeleted: Bool) -> [String: Any] {
        ["method": "sync.resolve", "scope": conflict["scope"] ?? "", "id": conflict["id"] ?? "",
         "revision": conflict["revision"] ?? "", "choices": choices, "keepDeleted": keepDeleted, "confirmed": true]
    }
    private func same(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
        guard let a, let b else { return false }
        return a["writer"] as? String == b["writer"] as? String && a["seq"] as? Int == b["seq"] as? Int
    }
}
private struct ConflictCandidate: View {
    @Environment(\.scenePhase) private var scenePhase
    let conflict: [String: Any]
    let field: String
    let candidate: [String: Any]
    let number: Int
    let selected: Bool
    let selectable: Bool
    let request: ([String: Any]) async throws -> [String: Any]
    let select: () -> Void
    @State private var revealed: String?
    @State private var error: String?
    @State private var loading = false
    @State private var revealEpoch = 0
    var body: some View {
        let source = candidate["source"] as? [String: Any] ?? [:]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("版本 \(number) · \(source["name"] as? String ?? "来源未记录")").fontWeight(.medium)
                if source["local"] as? Bool == true { Text("本设备").font(.caption).foregroundStyle(.secondary) }
            }
            Text(source["at"] as? String ?? "修改时间未记录").font(.caption).foregroundStyle(.secondary)
            Text(revealed ?? (candidate["display"] as? String ?? "")).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            HStack {
                if candidate["secret"] as? Bool == true {
                    Button(revealed == nil ? "显示敏感内容" : "隐藏内容") {
                        if revealed != nil { revealed = nil; return }
                        loading = true
                        let epoch = revealEpoch
                        Task { do {
                            let value = try await request(["method": "sync.conflict.preview", "scope": conflict["scope"] ?? "",
                                "id": conflict["id"] ?? "", "revision": conflict["revision"] ?? "", "field": field,
                                "dot": candidate["dot"] ?? [:], "reveal": true])
                            if epoch == revealEpoch { revealed = value["display"] as? String }
                        } catch { self.error = error.localizedDescription }; loading = false }
                    }.disabled(loading)
                }
                if selectable {
                    Button(action: select) { Label(selected ? "已选择此版本" : "选择此版本", systemImage: selected ? "checkmark.circle.fill" : "circle") }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .onDisappear { revealed = nil; revealEpoch += 1 }
            .onChange(of: scenePhase) { _, phase in if phase != .active { revealed = nil; revealEpoch += 1 } }
    }
}
struct SyncMaintenanceStatus: View {
    let status: [String: Any]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("云端历史自动清理").font(.headline)
            Text("同步成功后自动检查。按设置的数量保留历史完整版本，不包含当前版本；冲突、删除标记和可恢复的回收站内容完整保留。被淘汰的历史及迁移前的旧文件保护 7 天后分批清理。").font(.footnote).foregroundStyle(.secondary)
            if let time = status["checkedAt"] as? Double {
                Text("上次检查：\(Date(timeIntervalSince1970: time).formatted()) · 清理 \(status["deleted"] as? Int ?? 0) 个文件").font(.caption)
            }
            if let message = status["message"] as? String { Text(message).font(.caption).foregroundStyle(.orange) }
        }
    }
}
