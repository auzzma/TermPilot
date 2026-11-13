import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// One SwiftUI settings surface for macOS, iPhone and iPad. Network/storage stay in Rust.
public struct DataSyncView: View {
    private let call: @MainActor (Data) async throws -> Data
    private let changed: @MainActor () async -> Void
    @State private var metadata: [String: Any] = [:]
    @State private var status: [String: Any] = [:]
    @State private var provider = "webdav"
    @State private var fields: [String: String] = [:]
    @State private var busy = false
    @State private var error: String?
    @State private var confirmation: Confirmation?
    @State private var recycleSearch = ""
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var repeatPassword = ""
    @State private var currentPassword = ""
    @State private var clientsUpdated = false
    @State private var showPasswordProgress = false
    @State private var passwordRunning = false
    @State private var passwordStarting = false
    @State private var updateCredentials = false
    @State private var chooseVersionFile = false
    @State private var versionFile: URL?
    @State private var versionKey = ""
    @State private var showVersionKey = false
    private var passwordProgress: [String: Any] { status["passwordChange"] as? [String: Any] ?? [:] }
    private var passwordActive: Bool { passwordProgress["active"] as? Bool == true }
    private struct Confirmation: Identifiable { let id = UUID(); let title: String; let request: [String: Any] }
    public init(call: @escaping @MainActor (Data) async throws -> Data, changed: @escaping @MainActor () async -> Void = {}) {
        self.call = call; self.changed = changed
    }
    private var configured: Bool { status["configured"] as? Bool == true }
    private var providers: [[String: Any]] { metadata["providers"] as? [[String: Any]] ?? [] }
    private var selectedProvider: [String: Any] { providers.first { $0["id"] as? String == provider } ?? [:] }
    private var providerObject:[String:Any] {
        var value:[String:Any]=["kind":provider]
        for row in selectedProvider["fields"] as? [[Any]] ?? [] {if let key=row.first as? String{value[key]=fields[key] ?? ""}}
        return value
    }
    @ViewBuilder private var providerFields: some View {
        let definitions = selectedProvider["fields"] as? [[Any]] ?? []
        ForEach(Array(definitions.enumerated()), id: \.offset) { _, field in
            if field.count == 3, let key = field[0] as? String, let label = field[1] as? String {
                let binding = Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 })
                if key == "auth_type" {
                    Picker(label, selection: binding) { Text("Basic").tag(""); Text("Digest").tag("digest"); Text("Bearer Token").tag("token") }
                } else if field[2] as? Bool == true { SecureField(label, text: binding) }
                else { TextField(label, text: binding) }
            }
        }
    }
    private struct ProfileEditor: Identifiable { let id = UUID(); let profile: [String: Any] }
    @State private var profileEditor: ProfileEditor?
    private struct InviteEditor: Identifiable { let id = UUID(); let profileID: String? }
    @State private var inviteEditor: InviteEditor?
    public var body: some View {
        Form {
            Section {
                Label("数据同步", systemImage: "arrow.triangle.2.circlepath.icloud").font(.title2.weight(.semibold))
                Text("各设备使用相同同步库 ID 和 Key。内容在本机加密，离线修改将在下次同步时合并。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("云服务配置") {
                Text("可添加多份同类型服务。一次使用一份配置；切换时保留本机数据，并将期间的增删改与选定同步库合并。").font(.footnote).foregroundStyle(.secondary)
                let profiles = status["profiles"] as? [[String: Any]] ?? []
                if profiles.isEmpty { Text("尚未添加云服务").foregroundStyle(.secondary) }
                ForEach(Array(profiles.enumerated()), id: \.offset) { _, profile in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(profile["title"] as? String ?? "云服务").font(.headline)
                            if profile["active"] as? Bool == true { Label("正在使用", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.tint) }
                        }
                        let cloud = profile["provider"] as? [String: Any] ?? [:]
                        Text("\(providers.first { $0["id"] as? String == cloud["kind"] as? String }?["name"] as? String ?? "云服务") · \(cloud["bucket"] as? String ?? cloud["endpoint"] as? String ?? "")").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text("库 ID：\(profile["library"] as? String ?? "")").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            if profile["active"] as? Bool != true {
                                Button("使用此配置") { confirmation = Confirmation(title: "切换到此云服务？本机数据保留，期间的新增、修改和删除将在此同步库中合并。其它配置暂停同步。", request: ["method":"sync.profile.use", "id":profile["id"] ?? "", "confirmed":true]) }
                            }
                            Button("添加设备") { inviteEditor = InviteEditor(profileID: profile["id"] as? String) }
                            Button("编辑") { profileEditor = ProfileEditor(profile: profile) }
                            Button("删除", role: .destructive) { confirmation = Confirmation(title: "删除此本机配置及其待上传队列？本机主机和云端数据保持不变；删除前会保存本机恢复备份。", request: ["method":"sync.profile.delete", "id":profile["id"] ?? "", "confirmed":true]) }
                        }
                    }.padding(.vertical, 4)
                }
                Button { profileEditor = ProfileEditor(profile: [:]) } label: { Label("添加云服务", systemImage: "plus") }
                Button { inviteEditor = InviteEditor(profileID: nil) } label: { Label("导入云服务", systemImage: "qrcode") }
            }
            if configured {
                Section("当前同步状态") {
                    LabeledContent("库 ID", value: status["library"] as? String ?? "").textSelection(.enabled)
                    LabeledContent("设备", value: status["name"] as? String ?? "")
                    LabeledContent("待上传操作", value: "\(status["pending"] as? Int ?? 0)")
                    Toggle("自动同步", isOn: Binding(get: { status["auto"] as? Bool == true }, set: { enabled in
                        run(["method":"sync.configure", "confirmed":true, "auto":enabled])
                    })).disabled(status["providerUnavailable"] as? Bool == true)
                    SyncLeaseSettings(minutes: status["lockTimeoutMinutes"] as? Int ?? 60) { minutes in
                        run(["method":"sync.configure", "confirmed":true, "lockTimeoutMinutes":minutes])
                    }
                    SyncHistorySettings(count: status["historyVersionCount"] as? Int ?? 10, pending: status["pendingHistoryVersionCount"] as? Int) { count in
                        run(["method":"sync.configure", "confirmed":true, "historyVersionCount":count])
                    }
                    if let last = status["lastCheck"] as? [String: Any], let at = last["at"] as? String {
                        LabeledContent("上次检查", value: at)
                    }
                    HStack {
                        Button("立即同步") { run(["method":"sync.run"]) }.buttonStyle(.borderedProminent).disabled(status["providerUnavailable"] as? Bool == true)
                        Button("恢复旧锁并同步") { inspectLegacyLock() }.disabled(status["providerUnavailable"] as? Bool == true)
                    }
                    Button("检查并修复缺失文件") { run(["method":"sync.repair"]) }.disabled(status["providerUnavailable"] as? Bool == true)
                    if let recovery = status["objectRecovery"] as? [String: Any], let count = recovery["restored"] as? Int {
                        Text("最近检查恢复了 \(count) 个原始文件").font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("生成完整快照") { run(["method":"sync.snapshot"]) }
                    Text("后台同步受手机系统限制。未上传的删除恢复内容会留在本机；回收站默认保留 30 天。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("云端历史") { SyncMaintenanceStatus(status: status["maintenance"] as? [String: Any] ?? [:]) }
                Section("同步 Key") {
                    if status["passwordRequired"] as? Bool == true {
                        Text("云端 Key 已变更。输入当前 Key 后，本机离线修改会继续合并。").foregroundStyle(.orange)
                    }
                    DisclosureGroup("输入当前同步 Key") {
                        SyncKeyField(title: "当前同步 Key", prompt: "请输入当前同步 Key", text: $currentPassword)
                        Button("解锁并同步") {
                            let password = currentPassword; currentPassword = ""
                            busy = true; error = nil
                            Task { do {
                                _ = try await request(["method":"sync.password.unlock", "passphrase":password])
                                _ = try await request(["method":"sync.run"])
                                await load(); await changed()
                            } catch { self.error = error.localizedDescription }; busy = false }
                        }.disabled(currentPassword.isEmpty)
                    }
                    DisclosureGroup("修改同步 Key") {
                        SyncKeyField(title: "原同步 Key", prompt: "请输入原同步 Key", text: $oldPassword)
                        SyncKeyField(title: "新同步 Key", prompt: "至少 12 个字符", text: $newPassword)
                        SyncKeyField(title: "确认新 Key", prompt: "请再次输入新 Key", text: $repeatPassword)
                        Text("先下载全部旧密文，再重新加密并上传，验证后切换。包含增量、历史快照及回收站，也包含已关闭同步范围的云端历史。请预留新旧两份密文和备份的本机空间。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("原云端密文暂时保留用于恢复，旧 Key 仍能解密这些历史副本。其它设备完成升级后才能参与新版同步。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Toggle("所有参与同步的设备均已升级；完成前保持页面打开", isOn: $clientsUpdated)
                        Button("开始修改 Key") { beginPasswordChange() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!clientsUpdated || oldPassword.isEmpty || newPassword.count < 12 || newPassword != repeatPassword || newPassword == oldPassword)
                    }
                }
                Section("回收站") {
                    Picker("保留期限",selection:Binding(get:{status["retentionDays"] as? Int ?? 0},set:{days in
                        confirmation=Confirmation(title:"新期限用于之后的删除；延長会保护当前条目，缩短不会提前清理已保护的条目。",request:["method":"sync.retention","days":days == 0 ? NSNull() : days])
                    })) {Text("7 天").tag(7);Text("30 天").tag(30);Text("90 天").tag(90);Text("长期保留").tag(0)}
                    TextField("搜索已删除记录",text:$recycleSearch)

                    let items = status["recycle"] as? [[String: Any]] ?? []
                    if items.isEmpty { Text("回收站为空").foregroundStyle(.secondary) }
                    ForEach(Array(items.filter { recycleSearch.isEmpty || String(describing:$0["label"] ?? "").localizedCaseInsensitiveContains(recycleSearch) }.enumerated()), id: \.offset) { _, item in
                        VStack(alignment:.leading, spacing:8) {
                            Text(item["label"] as? String ?? "已删除记录")
                            Text(item["deletedAt"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("恢复为新记录") {
                                    confirmation = Confirmation(title:"恢复所选记录为新 ID，已有数据保持不变。本机保留的密码可恢复，其它设备缺少的密码需补填。", request:["method":"sync.restore","ids":[item["id"] as? String ?? ""],"scope":item["scope"] as? String ?? "configuration","actionId":UUID().uuidString,"confirmed":true])
                                }
                                Button("清理", role:.destructive) {
                                    confirmation = Confirmation(title:"清理后无法再从回收站恢复。历史云端密文仍保留，不代表物理擦除。", request:["method":"sync.purge","ids":[item["id"] as? String ?? ""],"scope":item["scope"] as? String ?? "configuration","confirmed":true])
                                }
                            }
                        }
                    }
                }
                Section("冲突") {
                    SyncConflicts(conflicts: status["conflicts"] as? [[String: Any]] ?? [], request: request) { message, command in
                        confirmation = Confirmation(title: message, request: command)
                    }
                }
                Section("快照") {
                    Button("从 TPS 文件恢复") { chooseVersionFile = true }
                    let snapshots = status["snapshots"] as? [[String:Any]] ?? []
                    if snapshots.isEmpty { Text("尚未生成快照").foregroundStyle(.secondary) }
                    ForEach(Array(snapshots.enumerated()),id:\.offset) { _, snapshot in
                        VStack(alignment:.leading,spacing:8) {
                            LabeledContent(snapshot["at"] as? String ?? "快照", value: snapshot["verified"] as? Bool == true ? "已验证" : "等待同步")
                            Button("预览恢复") {previewSnapshot(snapshot["id"] as? String ?? "")}.disabled(snapshot["verified"] as? Bool != true)
                        }
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
        }
        .formStyle(.grouped).disabled(busy)
        .safeAreaInset(edge: .bottom, spacing: 0) { SyncOperationProgress(call: request, busy: busy) }
        .task { await load() }
        .fileImporter(isPresented: $chooseVersionFile, allowedContentTypes: [.data]) { result in
            do { versionFile = try result.get(); versionKey = ""; showVersionKey = true }
            catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $showVersionKey, onDismiss: { versionKey = ""; versionFile = nil }) {
            Form {
                Text("从完整版本恢复").font(.headline)
                Text("输入创建此文件时的同步 Key。无需连接云端；先预览，再恢复已开启同步范围内的数据。")
                SecureField("文件的同步 Key", text: $versionKey)
                HStack {
                    Button("取消") { showVersionKey = false }
                    Button("校验并预览") { importVersionFile() }.disabled(versionKey.isEmpty)
                }
            }.padding().frame(idealWidth: 480, idealHeight: 250)
        }
        .sheet(item: $inviteEditor) { editor in
            SyncInviteView(profileID: editor.profileID, call: call) { await load(); await changed() }
        }
        .sheet(item: $profileEditor) { editor in
            SyncProfileEditor(metadata: metadata, profile: editor.profile, call: request) { await load(); await changed() }
        }
        .sheet(isPresented: $showPasswordProgress) {
            SyncPasswordProgress(progress: passwordProgress, running: passwordRunning || passwordStarting,
                retry: { resumePasswordChange() }, done: { showPasswordProgress = false },
                credentials: { updateCredentials = true })
            .task {
                while !Task.isCancelled && showPasswordProgress {
                    if !passwordStarting, let value = try? await request(["method":"sync.status"]) {
                        status = value
                        if !passwordActive && passwordProgress["phase"] as? String != "completed" { showPasswordProgress = false }
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .sheet(isPresented: $updateCredentials) {
                Form {
                    Text("仅更新原云端位置的认证信息")
                    providerFields
                    if let error { Text(error).foregroundStyle(.red) }
                    HStack {
                        Button("返回") { updateCredentials = false }
                        Button("保存认证信息") {
                            Task { do {
                                _ = try await request(["method":"sync.provider", "provider":providerObject, "confirmed":true])
                                updateCredentials = false; error = nil
                            } catch { self.error = error.localizedDescription } }
                        }
                    }
                }.formStyle(.grouped).frame(idealWidth:500, idealHeight:480)
            }
        }
        .confirmationDialog(confirmation?.title ?? "确认",isPresented:Binding(get:{confirmation != nil},set:{if !$0 {confirmation=nil}}),titleVisibility:.visible) {
            if let confirmation { Button("确认") { run(confirmation.request); self.confirmation=nil } }
            Button("取消",role:.cancel) { confirmation=nil }
        }
    }
    @MainActor private func request(_ value:[String:Any]) async throws -> [String:Any] {
        let data=try await call(JSONSerialization.data(withJSONObject:value))
        return try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
    }
    @MainActor private func load() async {
        do { metadata=try await request(["method":"sync.describe"]);status=try await request(["method":"sync.status"]);if passwordActive { showPasswordProgress = true };if configured{if let cloud=status["provider"] as? [String:Any]{provider=providers.contains { $0["id"] as? String == cloud["kind"] as? String } ? (cloud["kind"] as? String ?? "webdav") : "webdav";fields=[:];for (key,value) in cloud{if let text=value as? String{fields[key]=text}}}} }
        catch { self.error=error.localizedDescription }
    }
    private func inspectLegacyLock() {
        busy = true; error = nil
        Task {
            do {
                let preview = try await request(["method":"sync.lock.inspect"])
                confirmation = Confirmation(title: preview["message"] as? String ?? "确认其他设备已停止同步？", request: ["method":"sync.lock.recover", "expectedHead":preview["expectedHead"] ?? "", "confirmed":true, "otherDevicesStopped":true])
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    private func run(_ command:[String:Any]) {
        busy=true;error=nil
        Task { do { _=try await request(command); if ["sync.profile.use","sync.snapshot"].contains(command["method"] as? String ?? "") { _ = try await request(["method":"sync.run"]) } } catch { self.error=error.localizedDescription }; await load(); await changed(); busy=false }
    }
    private func beginPasswordChange() {
        let command: [String: Any] = ["method":"sync.password.begin", "oldPassphrase":oldPassword, "newPassphrase":newPassword, "confirmPassphrase":repeatPassword, "confirmed":true, "clientsUpdated":clientsUpdated]
        busy = true; error = nil; passwordStarting = true
        status["passwordChange"] = ["active":true, "phase":"preparing", "percent":0]
        showPasswordProgress = true
        Task {
            do {
                status = try await request(command)
                await load() // Restore the actual cloud location before offering credential repair.
                oldPassword = ""; newPassword = ""; repeatPassword = ""
                showPasswordProgress = true
                resumePasswordChange()
            } catch {
                self.error = error.localizedDescription
                if let value = try? await request(["method":"sync.status"]) { status = value }
                showPasswordProgress = passwordActive
            }
            passwordStarting = false; busy = false
        }
    }
    private func resumePasswordChange() {
        guard !passwordRunning else { return }
        passwordRunning = true; error = nil
        Task {
            do { status = try await request(["method":"sync.password.resume"]); await changed() }
            catch { self.error = error.localizedDescription }
            if let value = try? await request(["method":"sync.status"]) { status = value }
            if !passwordActive && passwordProgress["phase"] as? String != "completed" { showPasswordProgress = false }
            passwordRunning = false
        }
    }
    private func previewSnapshot(_ id:String) {
        busy=true;error=nil
        Task {do {
            let result=try await request(["method":"sync.snapshot.preview","id":id])
            let count=result["copies"] as? Int ?? 0
            confirmation=Confirmation(title:"将恢复 \(count) 条记录为新副本，已有记录保持不变。快照中的偏好和 AI 设置（若已开启同步）将作为新的修改应用。",request:["method":"sync.snapshot.restore","id":id,"actionId":UUID().uuidString,"confirmed":true])
        }catch{self.error=error.localizedDescription};busy=false}
    }
    private func importVersionFile() {
        guard let url = versionFile else { return }
        let key = versionKey
        let access = url.startAccessingSecurityScopedResource()
        showVersionKey = false; versionKey = ""; busy = true; error = nil
        Task {
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let imported = try await request(["method":"sync.snapshot.import", "path":url.path, "passphrase":key])
                await load(); busy = false
                previewSnapshot(imported["id"] as? String ?? "")
            } catch { self.error = error.localizedDescription; busy = false }
        }
    }
}
