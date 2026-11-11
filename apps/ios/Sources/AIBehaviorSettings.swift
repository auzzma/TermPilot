import SwiftUI

struct AIBehaviorSettings: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let session: MobileSession
  var section: String = "safety"
  @State private var timeout = 60
  @State private var iterations = 20
  @State private var blacklist = ""
  @State private var searchEnabled = false
  @State private var searchKind = "tavily"
  @State private var endpoint = ""
  @State private var apiKey = ""
  @State private var maxResults = 5
  var body: some View {
    Form {
      if section != "search" {
        Section(tr("命令执行")) {
          Text(tr("命令执行沿用共享内核的审批模式；命令黑名单始终生效。"))
          Stepper(trf("命令超时（秒） {}", String(timeout)), value: $timeout, in: 1...86400)
          Stepper(trf("最大工具轮次 {}", String(iterations)), value: $iterations, in: 1...100)
          Text(tr("命令黑名单 · 每行一条正则表达式"))
          TextEditor(text: $blacklist).font(.caption.monospaced()).frame(minHeight: 150)
        }
      }
      if section == "search" {
        Section(tr("网络搜索")) {
          Toggle(tr("启用网络搜索"), isOn: $searchEnabled)
          Picker(tr("提供商"), selection: $searchKind) {
            ForEach(["tavily", "exa", "bocha", "zhipu", "searxng"], id: \.self) { Text($0).tag($0) }
          }
          TextField(tr("服务地址（留空使用默认）"), text: $endpoint).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          SecureField("API Key", text: $apiKey)
          Stepper(trf("搜索结果数量 {}", String(maxResults)), value: $maxResults, in: 1...20)
        }
      }
    }.navigationTitle(tr(section == "search" ? "网络搜索" : "行为与安全")).navigationBarTitleDisplayMode(
      .inline
    ).toolbar {
      Button(tr("保存")) {
        model.attempt {
          var settings = model.aiSettings
          settings["commandTimeout"] = timeout
          settings["maxIterations"] = iterations
          settings["commandBlacklist"] = blacklist.split(separator: "\n").map(String.init)
          var search = settings.object("search")
          search.merge([
            "enabled": searchEnabled, "kind": searchKind, "endpoint": endpoint, "apiKey": apiKey,
            "maxResults": maxResults,
          ]) { _, new in new }
          settings["search"] = search
          _ = try await model.aiCall(session, "settings.save", ["settings": settings])
          model.aiSettings = settings
          dismiss()
        }
      }
    }.task {
      timeout = model.aiSettings.number("commandTimeout", 60)
      iterations = model.aiSettings.number("maxIterations", 20)
      blacklist = (model.aiSettings["commandBlacklist"] as? [String] ?? []).joined(separator: "\n")
      let search = model.aiSettings.object("search")
      searchEnabled = search["enabled"] as? Bool ?? false
      searchKind = search.text("kind", "tavily")
      endpoint = search.text("endpoint")
      apiKey = search.text("apiKey")
      maxResults = search.number("maxResults", 5)
    }
  }
}
