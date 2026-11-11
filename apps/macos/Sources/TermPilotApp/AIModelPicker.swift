import SwiftUI

struct AIModelPicker: View {
    @ObservedObject var client: AIClient
    @Binding var providerID: String
    @Binding var model: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var items: [String: [String]] = [:]
    @State private var message = ""
    @State private var loading: Set<String> = []
    private var providers: [[String: Any]] { (client.settings["providers"] as? [[String: Any]] ?? []).filter { $0["enabled"] as? Bool != false } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择提供商和模型").font(.headline)
            TextField("搜索模型", text: $query)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(providers, id: \.aiID) { provider in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(provider["name"] as? String ?? "提供商").font(.headline); Spacer(); if loading.contains(provider.aiID) { ProgressView().controlSize(.small) }; Button("刷新模型") { discover(provider) }.disabled(loading.contains(provider.aiID)) }
                            ForEach(models(provider), id: \.self) { name in
                                HStack {
                                    Button { providerID = provider.aiID; model = name; dismiss() } label: { Text(name).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                                    Button { pin(provider.aiID, name) } label: { Image(systemName: pinned(provider.aiID, name) ? "star.fill" : "star") }.buttonStyle(.plain).help("固定模型")
                                }
                            }
                            if models(provider).isEmpty { Text("未配置默认模型，可刷新列表或在提供商设置中填写。").font(.caption).foregroundStyle(.secondary) }
                            Divider()
                        }
                    }
                    if providers.isEmpty { Text("请在设置 → AI → 提供商中添加并启用提供商。").foregroundStyle(.secondary) }
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.padding(16)
    }
    private func models(_ provider: [String: Any]) -> [String] {
        let defaultModel = provider["model"] as? String ?? ""
        let models = Set((items[provider.aiID] ?? []) + (defaultModel.isEmpty ? [] : [defaultModel]))
        return models.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.sorted { a, b in
            if pinned(provider.aiID, a) != pinned(provider.aiID, b) { return pinned(provider.aiID, a) }; return a < b
        }
    }
    private func pinned(_ provider: String, _ model: String) -> Bool { (client.settings["pinnedModels"] as? [String] ?? []).contains(provider + ":" + model) }
    private func pin(_ provider: String, _ model: String) { Task { do { var s = client.settings; var pins = s["pinnedModels"] as? [String] ?? []; let key = provider + ":" + model; if pins.contains(key) { pins.removeAll { $0 == key } } else { pins.append(key) }; s["pinnedModels"] = pins; try await client.saveSettings(s) } catch { message = error.localizedDescription } } }
    private func discover(_ provider: [String: Any]) { Task { loading.insert(provider.aiID); defer { loading.remove(provider.aiID) }; do {
        items[provider.aiID] = try await client.fetchModels(for: provider)
        message = "已获取 \(items[provider.aiID]?.count ?? 0) 个模型"
    } catch { message = error.localizedDescription } } }
}
