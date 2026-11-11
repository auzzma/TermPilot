import SwiftUI
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SyncInviteView: View {
    let profileID: String?
    let call: @MainActor (Data) async throws -> Data
    let changed: @MainActor () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var code = ""
    @State private var name = "TermPilot"
    @State private var scopes: Set<String> = ["configuration"]
    @State private var preview: [String: Any]?
    @State private var qr: [String: Any]?
    @State private var busy = false
    @State private var scanning = false
    @State private var installed = false
    @State private var error = ""
    @State private var message = ""
    private let scopeRows = [("configuration", "主机、分组、代理、脚本、笔记和 AI 配置"), ("credentials", "密码、私钥和凭证秘密"), ("aiSecrets", "AI API Key 与认证请求头"), ("preferences", "外观、语言和终端偏好"), ("aiHistory", "AI 对话历史")]
    var body: some View {
        NavigationStack {
            Form {
                if !installed {
                    Section {
                        Text(profileID == nil ? "先输入原设备使用的同步 Key，再扫描或粘贴加密配置码。Key 不包含在配置码中。" : "输入此同步库当前的 Key，生成加密配置码。在新设备输入同一个 Key 后扫码或粘贴即可加入。")
                            .font(.callout).foregroundStyle(.secondary)
                        if profileID == nil || code.isEmpty {
                            SyncKeyField(title: "同步 Key", prompt: "请输入当前同步 Key", text: $key)
                                .onChange(of: key) { _, _ in preview = nil; error = "" }
                        }
                    }
                    if profileID != nil { exportSection } else { importSection }
                }
                if !error.isEmpty { Section { Text(error).foregroundStyle(.red) } }
                if !message.isEmpty { Section { Text(message).textSelection(.enabled) } }
            }
            .formStyle(.grouped)
            .disabled(busy)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SyncOperationProgress(call: { command in
                    let data = try await call(JSONSerialization.data(withJSONObject: command))
                    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                }, busy: busy)
            }
            .navigationTitle(profileID == nil ? "导入云服务" : "添加设备")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(installed ? "完成" : "关闭") { dismiss() }.disabled(busy) } }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 740)
        #endif
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: $scanning) {
            NavigationStack {
                SyncCameraView { value in code = value; preview = nil; scanning = false; message = "已识别配置码，点击解析以核对云服务。" }
                    .navigationTitle("扫描配置二维码")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { scanning = false } } }
            }
            #if os(macOS)
            .frame(width: 560, height: 460)
            #endif
        }
    }
    @ViewBuilder private var exportSection: some View {
        Section {
            if code.isEmpty {
                Button("生成配置码") { perform("export") }.disabled(key.count < 12).buttonStyle(.borderedProminent)
            } else {
                if let qr { SyncQRCodeView(qr: qr).frame(maxWidth: 460).aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity) }
                else { Text("配置较长，请复制配置码后在新设备上粘贴。") }
                Button { copyCode(); message = "已复制加密配置码。" } label: { Label("复制配置码", systemImage: "doc.on.doc") }
                Text("配置码包含加密的云服务访问凭证，请仅交给自己的设备。更换 Key 后应重新生成配置码。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private var importSection: some View {
        Section("配置码") {
            HStack {
                Button { scanning = true } label: { Label("扫描二维码", systemImage: "qrcode.viewfinder") }
                Button { pasteCode(); preview = nil } label: { Label("粘贴配置码", systemImage: "doc.on.clipboard") }
            }.disabled(key.count < 12)
            TextEditor(text: $code).font(.system(.caption, design: .monospaced)).frame(minHeight: 90, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
                .disabled(key.count < 12)
                .onChange(of: code) { _, value in preview = nil; if value.utf8.count > 24000 { code = String(value.prefix(24000)) } }
            if preview == nil {
                Button("解析配置码") { perform("preview") }.disabled(key.count < 12 || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        if let preview {
            Section("云服务") {
                Text(preview["title"] as? String ?? "云服务").font(.headline)
                let provider = preview["provider"] as? [String: Any] ?? [:]
                Text(provider["endpoint"] as? String ?? "").font(.caption).textSelection(.enabled)
                if let bucket = provider["bucket"] as? String { LabeledContent("Bucket", value: bucket) }
                LabeledContent("库 ID", value: preview["library"] as? String ?? "").font(.caption)
                TextField("当前设备名称", text: $name).textFieldStyle(.roundedBorder)
            }
            Section("合并并同步的数据") {
                ForEach(scopeRows, id: \.0) { id, title in
                    Toggle(title, isOn: Binding(get: { scopes.contains(id) }, set: { if $0 { scopes.insert(id) } else { scopes.remove(id) } })).disabled(id == "configuration")
                }
                Text("导入后自动启用并同步，当前其它配置暂停。已有相同配置将继续使用，保留原同步范围及未上传修改。脚本和笔记中的手写秘密不会被自动过滤。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("导入并合并同步") { perform("import") }.buttonStyle(.borderedProminent)
            }
        }
    }
    private func copyCode() {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
        #else
        UIPasteboard.general.string = code
        #endif
    }
    private func pasteCode() {
        #if os(macOS)
        code = NSPasteboard.general.string(forType: .string) ?? ""
        #else
        code = UIPasteboard.general.string ?? ""
        #endif
    }
    @MainActor private func perform(_ action: String) {
        busy = true; error = ""; message = ""
        Task {
            do {
                var command: [String: Any] = ["method": "sync.invite.\(action)", "passphrase": key, "code": code, "scopes": Array(scopes), "name": name, "confirmed": true]
                if let profileID { command["id"] = profileID }
                let data = try await call(JSONSerialization.data(withJSONObject: command))
                let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                if action == "export" { code = result["code"] as? String ?? ""; qr = result["qr"] as? [String: Any]; key = "" }
                else if action == "preview" { preview = result }
                else if result["installed"] as? Bool == true {
                    installed = true; key = ""; code = ""; preview = nil
                    message = result["synced"] as? Bool == true ? (result["reused"] as? Bool == true ? "已使用已有配置并完成同步，原同步范围已保留。" : "已添加云服务并完成合并同步。") : "配置已保存，本机数据和待上传修改已保留。请在配置列表使用此配置并重试同步。\n\(result["error"] as? String ?? "")"
                    await changed()
                }
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
struct SyncQRCodeView: View {
    let qr: [String: Any]
    var body: some View {
        Canvas { context, size in
            guard let width = qr["width"] as? Int, width > 0, let modules = qr["modules"] as? String else { return }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let unit = min(size.width, size.height) / CGFloat(width + 8)
            var path = Path()
            for (i, value) in modules.enumerated() where value == "1" {
                path.addRect(CGRect(x: CGFloat(i % width + 4) * unit, y: CGFloat(i / width + 4) * unit, width: unit, height: unit))
            }
            context.fill(path, with: .color(.black))
        }.accessibilityLabel("加密云服务配置二维码")
    }
}
