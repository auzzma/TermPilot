import AppKit
import SwiftUI

enum AISettingsTab: String, CaseIterable, Identifiable {
    case providers = "提供商", agents = "Agent", tools = "工具接入", search = "网络搜索", security = "安全"
    var id: String { rawValue }
}

/// Both the main Settings surface and the chat shortcut show this same editor.
struct AISettingsView: View {
    @ObservedObject var client: AIClient
    var embedded = false
    var initialTab: AISettingsTab = .providers
    @Environment(\.dismiss) private var dismiss
    @State private var tab: AISettingsTab = .providers
    @State private var value: [String: Any] = [:]
    @State private var providerDraft: [String: Any]?
    @State private var agentDrafts: [[String: Any]] = []
    @State private var discovered: [[String: Any]] = []
    @State private var integration: [String: Any] = [:]
    @State private var skills: [[String: Any]] = []
    @State private var grants: [[String: Any]] = []
    @State private var message = ""
    @State private var busy = false
    @State private var integrationClient = "codex"
    private var providers: [[String: Any]] { client.settings["providers"] as? [[String: Any]] ?? [] }
    private var quick: [[String: Any]] { value["quickMessages"] as? [[String: Any]] ?? [] }
    private var access: [String: Any] { value["toolAccess"] as? [String: Any] ?? [:] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI").font(.title2.bold())
            Picker("AI 设置分类", selection: $tab) { ForEach(AISettingsTab.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .providers: providerPage
                    case .agents: agentPage
                    case .tools: toolsPage
                    case .search: searchPage
                    case .security: securityPage
                    }
                }.padding(2).frame(maxWidth: 850, alignment: .leading)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if !embedded { Button("关闭") { dismiss() } }
                if tab != .providers && tab != .agents { Button("保存设置") { perform { try await saveCommon(); message = "已保存" } }.disabled(busy) }
            }
        }.padding(20).frame(minWidth: 580, minHeight: 520)
        .frame(width: embedded ? nil : 760, height: embedded ? nil : 700)
        .onAppear { tab = initialTab; reload() }
        .onChange(of: client.ready) { if client.ready { reload() } }
        .task { await refreshSupportingData() }
    }

    private var providerPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("提供商").font(.headline); Spacer(); Menu("添加提供商") {
                ForEach(client.presets, id: \.kindID) { preset in Button(preset["name"] as? String ?? "Custom") {
                    var p = preset; p["id"] = UUID().uuidString; p["enabled"] = true; p["verifyTls"] = true; p["contextWindow"] = 0; providerDraft = p
                } }
            } }
            if providers.isEmpty && providerDraft == nil { Text("添加提供商并配置 API Key、接口地址和默认模型，即可使用内置 Agent。").foregroundStyle(.secondary) }
            ForEach(providers, id: \.aiID) { provider in
                if providerDraft?.aiID != provider.aiID { providerCard(provider) }
            }
            if let draft = providerDraft {
                AIProviderEditor(provider: draft, fetchModels: { try await client.fetchModels(for: $0) }, save: { p in
                    var settings = client.settings
                    var list = providers.filter { $0.aiID != p.aiID }; list.append(p)
                    settings["providers"] = list
                    try await client.saveSettings(settings)
                    providerDraft = nil; value = client.settings; message = "提供商已保存"
                }, cancel: { providerDraft = nil }).id(draft.aiID)
            }
        }
    }
    private func providerCard(_ provider: [String: Any]) -> some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "cpu").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider["name"] as? String ?? "提供商").font(.headline)
                    Text((provider["apiKey"] as? String ?? "").isEmpty && provider["kind"] as? String != "ollama" ? "未设置 API Key" : provider["model"] as? String ?? "未设置默认模型").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { providerDraft = provider } label: { Image(systemName: "pencil") }.help("编辑提供商")
                Button(role: .destructive) { perform { var s = client.settings; s["providers"] = providers.filter { $0.aiID != provider.aiID }; try await client.saveSettings(s); value = client.settings } } label: { Image(systemName: "trash") }.help("删除提供商")
                Toggle("启用", isOn: Binding(get: { provider["enabled"] as? Bool ?? true }, set: { enabled in perform {
                    var s = client.settings; s["providers"] = providers.map { p in var p = p; if p.aiID == provider.aiID { p["enabled"] = enabled }; return p }; try await client.saveSettings(s); value = client.settings
                } })).toggleStyle(.switch).labelsHidden().help("启用提供商")
            }.padding(10)
        }
    }

    private var agentPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("外部 Agent").font(.headline); Spacer(); Button("重新检测") { perform { discovered = try await client.request("agent.discover") as? [[String: Any]] ?? [] } } }
            Text("使用本机已安装的 Agent 及其账号。路径留空时自动查找；TermPilot 不下载或启动 Node.js / Python。").font(.callout).foregroundStyle(.secondary)
            ForEach(agentDrafts.indices, id: \.self) { index in
                AIAgentEditor(agent: agentDrafts[index], status: discovered.first { $0["kind"] as? String == agentDrafts[index]["kind"] as? String } ?? [:], client: client) { agent in
                    var settings = client.settings
                    var list = settings["agents"] as? [[String: Any]] ?? []
                    list.removeAll { $0.aiID == agent.aiID || $0["kind"] as? String == agent["kind"] as? String }
                    list.append(agent); settings["agents"] = list
                    try await client.saveSettings(settings); agentDrafts[index] = agent; value = client.settings
                }
            }
        }
    }

    private var toolsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("聊天快捷入口") { Toggle("选中终端内容时显示“添加到对话”", isOn: bool("selectionShortcut", fallback: true)).padding(8) }
            GroupBox("工具接入") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("选择外部 Agent 访问 TermPilot 会话的方式。").foregroundStyle(.secondary)
                    Picker("接入方式", selection: nestedText("toolAccess", "mode", fallback: "mcp")) { Text("MCP").tag("mcp"); Text("Skills + CLI").tag("skills-cli") }
                    if access["mode"] as? String == "skills-cli" { Text("外部客户端可通过下方 CLI 调用同一套工具，仍需开启对外接入。").font(.caption) }
                }.padding(8)
            }
            GroupBox("对外 MCP") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("向外部客户端提供终端、SFTP、主机和端口转发工具。连接期间请保持 TermPilot 运行。").font(.callout).foregroundStyle(.secondary)
                    HStack { Text((integration["status"] as? [String: Any])?["enabled"] as? Bool == true ? "已开启" : "已关闭"); Spacer(); Button((integration["status"] as? [String: Any])?["enabled"] as? Bool == true ? "关闭对外接入" : "开启对外接入") { perform {
                        try await saveCommon()
                        let enabled = (integration["status"] as? [String: Any])?["enabled"] as? Bool == true
                        _ = try await client.request(enabled ? "mcp.disable" : "mcp.enable", enabled ? [:] : ["configured": true])
                        try await client.loadSettings(); value = client.settings; try await refreshIntegration()
                    } } }
                    Text("写操作权限模式：\(modeLabel)").font(.caption)
                    Picker("可用模式", selection: nestedText("toolAccess", "availability", fallback: "temporary")) { Text("临时").tag("temporary"); Text("常开").tag("persistent") }
                    if access["availability"] as? String != "persistent" { HStack { Text("空闲超时"); TextField("分钟", text: nestedNumber("toolAccess", "idleMinutes", fallback: 10)).frame(width: 80); Text("分钟").foregroundStyle(.secondary) } }
                    Text("临时模式空闲后自动关闭；常开模式会在下次启动时恢复。").font(.caption).foregroundStyle(.secondary)
                    Toggle("host_open 时激活窗口", isOn: nestedBool("toolAccess", "activateOnHostOpen", fallback: true))
                    Divider()
                    HStack { Text("客户端配置").font(.headline); Spacer(); Button("刷新") { perform { try await refreshIntegration() } } }
                    Picker("客户端", selection: $integrationClient) { Text("Codex").tag("codex"); Text("Claude Code").tag("claude"); Text("Grok").tag("grok"); Text("Cursor").tag("cursor") }.pickerStyle(.segmented)
                    copyRow("Launcher", integration["launcher"] as? String ?? "")
                    copyRow("Discovery", integration["discovery"] as? String ?? "")
                    copyRow("配置片段", (integration["clients"] as? [String: String])?[integrationClient] ?? "")
                    if access["mode"] as? String == "skills-cli" { copyRow("CLI 用法", "\"\(integration["launcher"] as? String ?? "termpilot-engine")\" ai-tool get_environment '{}'\n设置环境变量 TERMPILOT_MCP_DISCOVERY 为上述 Discovery 路径。") }
                }.padding(8)
            }
            GroupBox("用户 Skills") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("在技能目录中添加 SKILL.md；在对话中选择需要附加的技能。").font(.caption).foregroundStyle(.secondary)
                    Text(integration["skillsDirectory"] as? String ?? "").font(.caption).textSelection(.enabled)
                    HStack { Button("重新加载 Skills") { perform { skills = try await client.request("skills.list") as? [[String: Any]] ?? [] } }; Button("打开 Skills 文件夹") { if let path = integration["skillsDirectory"] as? String { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } } }
                    Text("已就绪 \(skills.count) 个")
                    ForEach(skills, id: \.aiID) { Text($0["name"] as? String ?? $0.aiID).font(.caption) }
                }.padding(8)
            }
            GroupBox("快捷消息") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("在聊天框输入 / 或点击快捷按钮，将常用提示词插入草稿。").font(.caption).foregroundStyle(.secondary)
                    ForEach(quick.indices, id: \.self) { i in
                        VStack { TextField("名称", text: quickText(i, "name")); TextField("命令（不含 /）", text: quickText(i, "slug")); TextField("说明", text: quickText(i, "description")); TextEditor(text: quickText(i, "content")).frame(height: 80); Button("删除快捷消息", role: .destructive) { var list = quick; list.remove(at: i); value["quickMessages"] = list } }.padding(8)
                        Divider()
                    }
                    Button("添加快捷消息") { value["quickMessages"] = quick + [["id": UUID().uuidString, "name": "", "slug": "", "content": ""]] }
                }.padding(8)
            }
        }
    }

    private var searchPage: some View {
        GroupBox("网络搜索") {
            Form {
                Toggle("启用网络搜索", isOn: nestedBool("search", "enabled", fallback: false))
                Text("允许 AI 搜索互联网获取最新信息。").font(.caption).foregroundStyle(.secondary)
                Picker("搜索供应商", selection: nestedText("search", "kind", fallback: "tavily")) { ForEach(["tavily", "exa", "bocha", "zhipu", "searxng"], id: \.self) { Text($0 == "searxng" ? "SearXNG" : $0.capitalized).tag($0) } }
                SecureField("API 密钥", text: nestedText("search", "apiKey"))
                TextField("API 地址（留空使用默认值）", text: nestedText("search", "endpoint"))
                TextField("最大结果数（1–20）", text: nestedNumber("search", "maxResults", fallback: 5))
            }.padding(12)
        }
    }
    private var securityPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("安全") { Form {
                Picker("权限模式", selection: text("mode", fallback: "confirm")) { Text("观察者 — 仅允许读取").tag("observe"); Text("确认 — 操作前询问").tag("confirm"); Text("自动 — 按已配置规则执行").tag("auto") }
                TextField("命令超时（秒）", text: number("commandTimeout", fallback: 60))
                TextField("最大迭代次数", text: number("maxIterations", fallback: 20))
                Text("这些设置约束经由 TermPilot 的操作；外部 Agent 的本机工具使用它自身的权限规则。").font(.caption).foregroundStyle(.secondary)
            }.padding(12) }
            GroupBox("命令黑名单") { VStack(alignment: .leading, spacing: 10) {
                Text("每行一条正则表达式。匹配的终端命令会被拦截，自动模式也不例外。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { (value["commandBlacklist"] as? [String] ?? []).joined(separator: "\n") }, set: { value["commandBlacklist"] = $0.components(separatedBy: "\n").filter { !$0.isEmpty } })).font(.system(.caption, design: .monospaced)).frame(height: 170)
                Button("恢复默认") { value["commandBlacklist"] = client.configuration["commandBlacklist"] ?? [] }
            }.padding(8) }
            GroupBox("许可记忆表") { VStack(alignment: .leading, spacing: 10) {
                Text("显示审批时记住的操作授权；可随时撤销。").font(.caption).foregroundStyle(.secondary)
                Button("刷新") { perform { grants = try await client.request("grants.list") as? [[String: Any]] ?? [] } }
                if grants.isEmpty { Text("尚无规则").foregroundStyle(.secondary) }
                ForEach(grants, id: \.aiID) { grant in HStack { Text(grant["name"] as? String ?? grant.aiID); Spacer(); Button("撤销") { perform { _ = try await client.request("grants.delete", ["id": grant.aiID]); grants.removeAll { $0.aiID == grant.aiID } } } } }
            }.padding(8) }
        }
    }

    private var modeLabel: String { ["observe": "观察者", "confirm": "确认 — 操作前询问", "auto": "自动"][value["mode"] as? String ?? "confirm"] ?? "确认" }
    private func copyRow(_ title: String, _ content: String) -> some View { VStack(alignment: .leading) { HStack { Text(title).font(.caption.bold()); Spacer(); Button("复制") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(content, forType: .string) }.disabled(content.isEmpty) }; Text(content).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
    private func reload() { value = client.settings; let saved = value["agents"] as? [[String: Any]] ?? []; agentDrafts = client.agentCatalog.filter { !["grok", "mimo"].contains($0["kind"] as? String ?? "") }.map { row in saved.first { $0["kind"] as? String == row["kind"] as? String } ?? ["id": UUID().uuidString, "kind": row["kind"] ?? "", "name": row["name"] ?? ""] }; agentDrafts += saved.filter { a in !agentDrafts.contains { $0.aiID == a.aiID || $0["kind"] as? String == a["kind"] as? String } } }
    private func refreshSupportingData() async { guard client.ready else { return }; do { discovered = try await client.request("agent.discover") as? [[String: Any]] ?? []; try await refreshIntegration(); skills = try await client.request("skills.list") as? [[String: Any]] ?? []; grants = try await client.request("grants.list") as? [[String: Any]] ?? [] } catch { message = error.localizedDescription } }
    private func refreshIntegration() async throws { integration = try await client.request("integration.info") as? [String: Any] ?? [:] }
    private func saveCommon() async throws { var updated = client.settings; for key in ["mode", "search", "quickMessages", "commandTimeout", "commandBlacklist", "maxIterations", "selectionShortcut", "toolAccess"] { if let entry = value[key] { updated[key] = entry } }; try await client.saveSettings(updated); value = client.settings }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) { Task { busy = true; defer { busy = false }; do { try await action() } catch { message = error.localizedDescription } } }
    private func text(_ key: String, fallback: String = "") -> Binding<String> { Binding(get: { value[key] as? String ?? fallback }, set: { value[key] = $0 }) }
    private func number(_ key: String, fallback: Int) -> Binding<String> { Binding(get: { String(value[key] as? Int ?? fallback) }, set: { value[key] = Int($0) ?? 0 }) }
    private func bool(_ key: String, fallback: Bool) -> Binding<Bool> { Binding(get: { value[key] as? Bool ?? fallback }, set: { value[key] = $0 }) }
    private func nestedText(_ key: String, _ field: String, fallback: String = "") -> Binding<String> { Binding(get: { (value[key] as? [String: Any])?[field] as? String ?? fallback }, set: { var v = value[key] as? [String: Any] ?? [:]; v[field] = $0; value[key] = v }) }
    private func nestedNumber(_ key: String, _ field: String, fallback: Int) -> Binding<String> { Binding(get: { String((value[key] as? [String: Any])?[field] as? Int ?? fallback) }, set: { var v = value[key] as? [String: Any] ?? [:]; v[field] = Int($0) ?? 0; value[key] = v }) }
    private func nestedBool(_ key: String, _ field: String, fallback: Bool) -> Binding<Bool> { Binding(get: { (value[key] as? [String: Any])?[field] as? Bool ?? fallback }, set: { var v = value[key] as? [String: Any] ?? [:]; v[field] = $0; value[key] = v }) }
    private func quickText(_ i: Int, _ key: String) -> Binding<String> { Binding(get: { quick.indices.contains(i) ? quick[i][key] as? String ?? "" : "" }, set: { var list = quick; guard list.indices.contains(i) else { return }; list[i][key] = $0; value["quickMessages"] = list }) }
}

struct AIProviderEditor: View {
    let provider: [String: Any]
    let fetchModels: @MainActor ([String: Any]) async throws -> [String]
    let save: @MainActor ([String: Any]) async throws -> Void
    let cancel: () -> Void
    @State private var value: [String: Any] = [:]
    @State private var parameters: [String: String] = [:]
    @State private var error = ""
    @State private var saving = false
    @State private var choosingModel = false
    var body: some View {
        GroupBox(value["name"] as? String ?? "提供商") {
            VStack(alignment: .leading, spacing: 12) {
                Form {
                    TextField("显示名称", text: field("name"))
                    Picker("协议风格", selection: field("protocol")) { Text("Anthropic 兼容").tag("anthropic"); Text("OpenAI 兼容").tag("chat"); Text("Google 兼容").tag("google"); Text("OpenAI Responses").tag("responses") }
                    SecureField("API Key", text: field("apiKey"))
                    TextField("Base URL", text: field("baseUrl"))
                    LabeledContent("默认模型") {
                        HStack {
                            TextField("输入模型 ID，或从列表选择", text: field("model")).labelsHidden()
                            Button("选择模型") { choosingModel = true }
                                .popover(isPresented: $choosingModel) {
                                    AIProviderModelPicker(provider: value, model: field("model"), fetch: fetchModels)
                                }
                        }
                    }
                    TextField("上下文窗口（可留空）", text: Binding(get: { (value["contextWindow"] as? Int).flatMap { $0 == 0 ? nil : String($0) } ?? "" }, set: { value["contextWindow"] = Int($0) ?? 0 }))
                    Toggle("跳过 TLS 证书验证（用于自签名证书）", isOn: Binding(get: { value["verifyTls"] as? Bool == false }, set: { value["verifyTls"] = !$0 }))
                    DisclosureGroup("高级参数") {
                        Text("留空使用提供商默认值。").font(.caption).foregroundStyle(.secondary)
                        ForEach(["max_tokens", "temperature", "top_p", "frequency_penalty", "presence_penalty"], id: \.self) { name in TextField(name, text: Binding(get: { parameters[name] ?? "" }, set: { parameters[name] = $0 })) }
                        TextField("代理地址（可选）", text: field("proxy"))
                    }
                }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                HStack { Spacer(); Button("取消", action: cancel); Button("保存") { Task { saving = true; defer { saving = false }; do {
                    var p = value; var params = p["parameters"] as? [String: Any] ?? [:]
                    for (key, raw) in parameters { if raw.isEmpty { params.removeValue(forKey: key) } else { guard let n = Double(raw), n.isFinite else { throw AIError.message("\(key) 请输入有效数字") }; params[key] = n } }
                    p["parameters"] = params; try await save(p)
                } catch { self.error = error.localizedDescription } } }.disabled(saving) }
            }.padding(12)
        }.onAppear { value = provider; for (k, v) in provider["parameters"] as? [String: Any] ?? [:] { parameters[k] = String(describing: v) } }
    }
    private func field(_ key: String) -> Binding<String> { Binding(get: { value[key] as? String ?? "" }, set: { value[key] = $0 }) }
}

private struct AIAgentEditor: View {
    let agent: [String: Any]
    let status: [String: Any]
    @ObservedObject var client: AIClient
    let save: @MainActor ([String: Any]) async throws -> Void
    @State private var value: [String: Any] = [:]
    @State private var env = ""
    @State private var message = ""
    private var unavailable: Bool { status["available"] as? Bool == false || client.agentCatalog.first { $0["kind"] as? String == agent["kind"] as? String }?["available"] as? Bool == false }
    var body: some View {
        GroupBox(agent["name"] as? String ?? "Agent") {
            VStack(alignment: .leading, spacing: 10) {
                Text(message.isEmpty ? (unavailable ? "此适配器尚未实现，不能运行任务。" : status["message"] as? String ?? (status["detected"] as? Bool == true ? "已检测到 · 认证未验证" : "未找到")) : message).font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("可执行文件路径（留空自动检测）", text: field("executable"))
                    Button("浏览…") { let p = NSOpenPanel(); if p.runModal() == .OK { value["executable"] = p.url?.path ?? "" } }
                    Button("检查") { Task { do { let result = try await client.request("agent.probe", value) as? [String: Any] ?? [:]; value["executable"] = result["executable"]; message = "已检测到：\(result["version"] as? String ?? "") · 认证未验证" } catch { message = error.localizedDescription } } }
                    Button("重置") { value["executable"] = ""; message = "已清除自定义路径，保存后生效" }
                }
                DisclosureGroup("认证与配置（可选）") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("工作目录", text: field("cwd")); TextField("模型（留空使用 Agent 默认）", text: field("model"))
                        if agent["kind"] as? String == "claude" {
                            TextField("配置目录（留空使用 ~/.claude）", text: field("configDirectory"))
                            TextField("Settings 文件（路径或内联 JSON）", text: field("settingsFile"))
                            Text("使用已完成 Claude Code 登录的配置目录。").font(.caption).foregroundStyle(.secondary)
                        }
                        if agent["kind"] as? String == "codex" {
                            Picker("认证方式", selection: Binding(get: { value["authMode"] as? String == "apiKey" ? "apiKey" : "cli" }, set: { value["authMode"] = $0 })) { Text("使用 Codex 已登录账号").tag("cli"); Text("API Key").tag("apiKey") }
                            if value["authMode"] as? String == "apiKey" { SecureField("API Key", text: field("apiKey")); TextField("Base URL（留空使用 OpenAI）", text: field("baseUrl")) }
                        }
                        Text("环境变量（每行 KEY=VALUE）").font(.caption)
                        TextEditor(text: $env).font(.system(.caption, design: .monospaced)).frame(height: 90)
                        Text("配置加密保存在 TermPilot 中，传给选中的 Agent 进程。").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 6)
                }
                HStack { Spacer(); Button("保存") { Task { do { var data = value; var vars: [String: String] = [:]; for line in env.split(separator: "\n") { guard let equals = line.firstIndex(of: "=") else { throw AIError.message("环境变量格式应为 KEY=VALUE") }; let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces); guard !key.isEmpty else { throw AIError.message("环境变量名不能为空") }; vars[key] = String(line[line.index(after: equals)...]) }; data["env"] = vars; try await save(data); message = "已保存" } catch { message = error.localizedDescription } } }.disabled(unavailable) }
            }.padding(10)
        }.onAppear { value = agent; env = (agent["env"] as? [String: String] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") }
    }
    private func field(_ key: String) -> Binding<String> { Binding(get: { value[key] as? String ?? "" }, set: { value[key] = $0 }) }
}
private extension Dictionary where Key == String, Value == Any { var kindID: String { self["kind"] as? String ?? "" } }
