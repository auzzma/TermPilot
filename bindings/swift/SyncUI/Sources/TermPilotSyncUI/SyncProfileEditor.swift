import Foundation
import SwiftUI

/// A single editor owns the destination, library identity and synchronization policy.
struct SyncProfileEditor: View {
    let metadata: [String: Any]
    let profile: [String: Any]
    let call: @MainActor ([String: Any]) async throws -> [String: Any]
    let saved: @MainActor () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var kind = "webdav"
    @State private var fields: [String: String] = [:]
    @State private var library = ""
    @State private var device = "TermPilot"
    @State private var password = ""
    @State private var scopes: Set<String> = ["configuration"]
    @State private var automatic = false
    @State private var confirmed = false
    @State private var busy = false
    @State private var error: String?
    private var editing: Bool { profile["id"] is String }
    private var providers: [[String: Any]] { metadata["providers"] as? [[String: Any]] ?? [] }
    private var provider: [String: Any] { providers.first { $0["id"] as? String == kind } ?? [:] }
    private var definitions: [[Any]] { provider["fields"] as? [[Any]] ?? [] }
    var body: some View {
        NavigationStack {
            Form {
                Section("云服务配置") {
                    TextField("配置名称", text: $title)
                    Picker("服务类型", selection: Binding(get: { kind }, set: { kind = $0; fields = [:] })) {
                        ForEach(providers.compactMap { $0["id"] as? String }, id: \.self) { id in
                            Text(providers.first { $0["id"] as? String == id }?["name"] as? String ?? id).tag(id)
                        }
                    }
                    if let help = provider["help"] as? String { Text(help).font(.footnote).foregroundStyle(.secondary) }
                    ForEach(Array(definitions.enumerated()), id: \.offset) { _, field in
                        if field.count == 3, let key = field[0] as? String, let label = field[1] as? String {
                            let binding = Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 })
                            if key == "auth_type" {
                                Picker(label, selection: binding) { Text("Basic").tag(""); Text("Digest").tag("digest"); Text("Bearer Token").tag("token") }
                            } else if field[2] as? Bool == true { SecureField(label, text: binding) }
                            else { TextField(label, text: binding) }
                        }
                    }
                    if editing { Text("同一地址和账号下，凭证留空会保留原值。更换地址或账号时请重新填写凭证；原云端数据保留。").font(.footnote).foregroundStyle(.secondary) }
                    TextField("同步库 ID（新建库时留空）", text: $library).disabled(editing)
                    if editing { Text("库 ID 标识现有同步历史。连接其它同步库时，请新增一份配置。").font(.footnote).foregroundStyle(.secondary) }
                    TextField("当前设备名称", text: $device)
                    SyncKeyField(title: "同步 Key", prompt: editing ? "重新启用同步范围时填写当前 Key" : "至少 12 个字符", text: $password)
                    Text("同步 Key 用于数据加密，与云服务访问密钥不同。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("此配置的同步范围") {
                    ForEach((metadata["scopes"] as? [[String]] ?? []).filter { $0.count == 2 }, id: \.first) { row in
                        Toggle(row[1], isOn: Binding(get: { scopes.contains(row[0]) }, set: { if $0 { scopes.insert(row[0]) } else { scopes.remove(row[0]) } })).disabled(row[0] == "configuration")
                    }
                    Toggle("使用此配置时自动同步", isOn: $automatic)
                    Text("脚本和笔记中的手写秘密不会被自动过滤。其它配置的自动同步在未选用时暂停。").font(.footnote).foregroundStyle(.secondary)
                    Toggle("确认保存配置及所选数据合并范围", isOn: $confirmed)
                }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            }
            .formStyle(.grouped).disabled(busy)
            .navigationTitle(editing ? "编辑云服务" : "添加云服务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(busy || !confirmed || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!editing && password.count < 12)) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { SyncOperationProgress(call: call, busy: busy) }
        }
        .frame(idealWidth: 620, idealHeight: 720)
        .interactiveDismissDisabled(busy)
        .task {
            title = profile["title"] as? String ?? ""
            library = profile["library"] as? String ?? ""
            device = profile["name"] as? String ?? "TermPilot"
            scopes = Set(profile["scopes"] as? [String] ?? ["configuration"])
            automatic = profile["auto"] as? Bool == true
            if let cloud = profile["provider"] as? [String: String] { fields = cloud; kind = cloud["kind"] ?? "webdav" }
        }
    }
    private func save() {
        var provider: [String: Any] = ["kind": kind]
        for field in definitions { if let key = field.first as? String { provider[key] = fields[key] ?? "" } }
        let command: [String: Any] = ["method": editing ? "sync.profile.update" : "sync.profile.add", "id": profile["id"] ?? "", "title": title, "provider": provider, "library": library, "name": device, "passphrase": password, "scopes": Array(scopes).sorted(), "auto": automatic, "confirmed": confirmed]
        busy = true; error = nil
        Task {
            do { _ = try await call(command); password = ""; await saved(); dismiss() }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
