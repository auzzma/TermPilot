import SwiftUI

@MainActor
final class AIProviderModelCatalog: ObservableObject {
    @Published private(set) var models: [String] = []
    @Published private(set) var loading = false
    @Published private(set) var error = ""
    private var generation = 0

    func load(provider: [String: Any], fetch: @MainActor ([String: Any]) async throws -> [String]) async {
        generation += 1
        let current = generation
        loading = true; error = ""; models = []
        defer { if current == generation { loading = false } }
        do {
            let result = try await fetch(provider)
            guard !Task.isCancelled, current == generation else { return }
            models = result
        } catch {
            guard !Task.isCancelled, current == generation else { return }
            self.error = error.localizedDescription
        }
    }

    func filtered(_ query: String) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }
}

struct AIProviderModelPicker: View {
    let provider: [String: Any]
    @Binding var model: String
    let fetch: @MainActor ([String: Any]) async throws -> [String]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog = AIProviderModelCatalog()
    @State private var query = ""
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选择默认模型").font(.headline)
                Spacer()
                Button("刷新") { refresh += 1 }.disabled(catalog.loading)
            }
            TextField("搜索模型", text: $query)
            if catalog.loading {
                HStack { ProgressView().controlSize(.small); Text("正在获取模型列表…").foregroundStyle(.secondary) }
                Spacer()
            } else if !catalog.error.isEmpty {
                Label(catalog.error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).textSelection(.enabled)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(catalog.filtered(query), id: \.self) { id in
                            Button {
                                model = id
                                dismiss()
                            } label: {
                                HStack {
                                    Text(id).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    if model == id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }.padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        if catalog.models.isEmpty { Text("接口未返回模型，可手动填写模型 ID。").foregroundStyle(.secondary) }
                        else if catalog.filtered(query).isEmpty { Text("没有匹配的模型").foregroundStyle(.secondary) }
                    }
                }
            }
            Divider()
            Text("使用当前填写的连接配置获取；选中后点击保存生效。也可关闭列表后手动输入。").font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(width: 400, height: 360)
            .task(id: refresh) { await catalog.load(provider: provider, fetch: fetch) }
    }
}
