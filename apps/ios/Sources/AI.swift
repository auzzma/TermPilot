import SwiftUI

extension AppModel {
  func openAISettings() async throws -> MobileSession {
    if settingsSession == nil {
      settingsSession = MobileSession(
        id: 0, host: ["id": "settings", "label": tr("AI 设置")], kind: "settings", terminal: "")
    }
    let session = settingsSession!
    try await openAI(session)
    return session
  }

  func aiCall(_ session: MobileSession, _ method: String, _ params: JSON = [:]) async throws -> JSON
  {
    guard let ai = session.ai else { throw MobileError(message: tr("AI 尚未启动")) }
    let id = UUID().uuidString
    return try await request(ai, ["id": id, "method": method, "params": params], id: id)
  }
  func openAI(_ session: MobileSession) async throws {
    if session.ai == nil {
      let context: JSON = [
        "sessions": [
          [
            "sessionId": String(session.id), "hostId": session.host.text("id"),
            "label": session.label, "hostname": session.host.text("hostname"),
            "username": session.host.text("username"),
            "connected": session.connected && session.protocolKind == "ssh",
            "scope": session.aiScope,
          ]
        ]
      ]
      let r = try await call([
        "method": "session.open", "protocol": "ai",
        "command": [
          "id": "init", "method": "initialize",
          "params": [
            "context": context,
            "tools": [
              "terminal_write", "terminal_read_context", "terminal_execute", "terminal_start",
              "terminal_poll", "terminal_stop",
            ],
          ],
        ],
      ])
      session.ai = UInt64(r.number("session"))
    }
    aiSettings = try await aiCall(session, "settings.get").object("settings")
    if session.protocolKind == "settings" { return }
    if session.conversation.isEmpty {
      session.conversation = try await aiCall(
        session, "conversation.create",
        ["scope": session.aiScope, "agent": aiSettings.text("selected")])
    }
  }
  func aiTool(_ session: MobileSession, event: JSON) async throws {
    let payload = event.object("payload")
    let args = payload.object("arguments")
    var answer: JSON
    do {
      guard session.protocolKind == "ssh", args.text("sessionId") == String(session.id),
        session.connected
      else {
        throw MobileError(message: tr("AI 目标会话已失效"))
      }
      switch payload.text("name") {
      case "terminal_write":
        try await send(
          session.id, ["type": "data", "data": Data(args.text("text").utf8).base64EncodedString()])
        answer = ["ok": true, "result": [:]]
      case "terminal_read_context":
        var r = args
        r["method"] = "terminal.context"
        r["id"] = session.terminalID
        answer = ["ok": true, "result": try await call(r)]
      case "session_close":
        try await close(session)
        answer = ["ok": true, "result": [:]]
      default: throw MobileError(message: tr("当前移动客户端不支持此工具"))
      }
    } catch { answer = ["ok": false, "error": error.localizedDescription] }
    if let ai = session.ai {
      try await send(
        ai,
        [
          "id": UUID().uuidString, "method": "interaction.reply",
          "params": ["requestId": event.text("requestId"), "value": answer],
        ])
    }
  }
}
struct AIView: View {
  @EnvironmentObject var model: AppModel
  @ObservedObject var session: MobileSession
  @State private var input = ""
  @State private var settings = false
  @State private var history = false
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "sparkles")
        Menu {
          ForEach(model.aiSettings.array("providers"), id: \.selfID) { provider in
            Button(provider.text("name")) {
              model.attempt {
                session.conversation = try await model.aiCall(
                  session, "conversation.draft",
                  ["conversationId": session.conversation.text("id"), "agent": provider.text("id")])
              }
            }
          }
        } label: {
          Text(
            model.aiSettings.array("providers").first {
              $0.text("id") == session.conversation.text("agent")
            }?.text("name") ?? "TermPilot Agent"
          ).font(.headline)
        }
        Spacer()
        Button {
          history = true
        } label: {
          Image(systemName: "clock.arrow.circlepath")
        }.accessibilityLabel(tr("对话历史"))
        Button {
          model.attempt {
            session.conversation = try await model.aiCall(
              session, "conversation.create",
              ["scope": session.aiScope, "agent": model.aiSettings.text("selected")])
          }
        } label: {
          Image(systemName: "square.and.pencil")
        }.accessibilityLabel(tr("新对话"))
        Button {
          settings = true
        } label: {
          Image(systemName: "gearshape")
        }.accessibilityLabel(tr("AI 设置"))
      }.padding()
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          if session.conversation.array("messages").isEmpty {
            ContentUnavailableView(
              trf("与 {} 对话", session.label), systemImage: "sparkles",
              description: Text(tr("询问服务器状态、分析终端输出或获取配置帮助")))
            if model.aiSettings.array("providers").isEmpty {
              Button(tr("配置 AI")) { settings = true }.buttonStyle(.bordered).frame(
                maxWidth: .infinity)
            }
          }
          ForEach(Array(session.conversation.array("messages").enumerated()), id: \.offset) {
            _, message in
            AIMessageRow(message: message)
          }
          if !session.partial.isEmpty { MarkdownView(text: session.partial) }
        }.padding()
      }
      Divider()
      HStack(alignment: .bottom) {
        TextField(trf("发送到 {}", session.label), text: $input, axis: .vertical).lineLimit(1...6)
          .textFieldStyle(.plain).padding(.vertical, 8)
        if session.conversation.text("status") == "running" {
          Button {
            model.attempt {
              _ = try await model.aiCall(
                session, "turn.stop", ["conversationId": session.conversation.text("id")])
            }
          } label: {
            Image(systemName: "stop.fill")
          }
        } else {
          Button {
            let text = input
            input = ""
            model.attempt {
              _ = try await model.aiCall(
                session, "turn.start",
                ["conversationId": session.conversation.text("id"), "text": text])
            }
          } label: {
            Image(systemName: "arrow.up.circle.fill").font(.title2)
          }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }.padding(12).background(
        Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: MobileDesign.composerRadius)
      ).padding(12)
    }.background(Color(uiColor: .systemGroupedBackground)).task {
      model.attempt { try await model.openAI(session) }
    }.sheet(isPresented: $settings) {
      NavigationStack {
        AISettingsHome(session: session).toolbar { Button(tr("完成")) { settings = false } }
      }.presentationSizingIfAvailable()
    }.sheet(isPresented: $history) {
      NavigationStack {
        List {
          ForEach(session.conversations, id: \.selfID) { conversation in
            Button(conversation.text("title", tr("对话"))) {
              model.attempt {
                session.conversation = try await model.aiCall(
                  session, "conversation.get", ["conversationId": conversation.text("id")])
                history = false
              }
            }.swipeActions {
              Button(tr("删除"), role: .destructive) {
                model.attempt {
                  _ = try await model.aiCall(
                    session, "conversation.delete", ["conversationId": conversation.text("id")])
                  session.conversations.removeAll { $0.text("id") == conversation.text("id") }
                }
              }
            }
          }
        }.navigationTitle("\(session.label) 的对话").toolbar { Button(tr("完成")) { history = false } }
      }.task {
        model.attempt {
          session.conversations = try await model.aiCall(
            session, "conversation.list", ["scope": session.aiScope]
          ).array("items")
        }
      }
    }
  }
}
func pretty(_ value: Any) -> String {
  guard JSONSerialization.isValidJSONObject(value),
    let d = try? JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
  else { return String(describing: value) }
  return String(decoding: d, as: UTF8.self)
}
struct ProviderEditor: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) var dismiss
  let session: MobileSession
  var initialProviderID: String = ""
  @State private var loadingModels = false
  @State private var modelError = ""
  @State private var name = "OpenAI"
  @State private var url = "https://api.openai.com/v1"
  @State private var key = ""
  @State private var selection = ""
  @State private var protocolName = "chat"
  @State private var models: [String] = []
  @State private var providerID = UUID().uuidString
  @State private var contextWindow = "32768"
  @State private var proxy = ""
  @State private var headers = "{}"
  @State private var parameters = "{}"
  @State private var verifyTLS = true
  @State private var enabled = true
  @State private var deleteConfirmation = false
  var body: some View {
    NavigationStack {
      Form {
        Section(tr("基本信息")) {
          TextField(tr("名称"), text: $name)
          Picker(tr("协议"), selection: $protocolName) {
            Text(tr("OpenAI 兼容")).tag("chat")
            Text("Responses").tag("responses")
            Text("Anthropic").tag("anthropic")
            Text("Google").tag("google")
          }
        }
        Section(tr("服务连接")) {
          TextField("Base URL", text: $url).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          SecureField("API Key", text: $key)
        }
        Section(tr("模型")) {
          TextField(tr("默认模型"), text: $selection).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Button {
            loadingModels = true
            modelError = ""
            Task { @MainActor in
              defer { loadingModels = false }
              do {
                let result = try await model.aiCall(
                  session, "provider.models", ["provider": try checkedProvider()])
                models =
                  (result["models"] as? [String]) ?? result.array("models").map { $0.text("id") }
                if models.isEmpty { modelError = tr("未返回模型，请手动输入模型 ID") }
              } catch { modelError = error.localizedDescription }
            }
          } label: {
            HStack {
              Text(tr(loadingModels ? "正在获取模型…" : "获取模型"))
              Spacer()
              if loadingModels { ProgressView() }
            }
          }.disabled(loadingModels)
          if !modelError.isEmpty { Text(modelError).font(.caption).foregroundStyle(.red) }
          if !models.isEmpty {
            Picker(tr("选择模型"), selection: $selection) {
              if !models.contains(selection) {
                Text(selection.isEmpty ? tr("请选择模型") : selection).tag(selection)
              }
              ForEach(models, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.navigationLink)
          }
        }
        DisclosureGroup(tr("高级参数")) {
          Toggle(tr("启用提供商"), isOn: $enabled)
          Toggle(tr("验证 TLS 证书"), isOn: $verifyTLS)
          TextField(tr("上下文窗口"), text: $contextWindow).keyboardType(.numberPad)
          TextField(tr("代理 URL"), text: $proxy).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Text(tr("自定义请求头（JSON）"))
          TextEditor(text: $headers).font(.caption.monospaced()).frame(minHeight: 90)
          Text(tr("模型参数（JSON）"))
          TextEditor(text: $parameters).font(.caption.monospaced()).frame(minHeight: 90)
        }
        if model.aiSettings.array("providers").contains(where: { $0.text("id") == providerID }) {
          Button(tr("删除提供商"), role: .destructive) { deleteConfirmation = true }
        }
      }.navigationTitle(tr(initialProviderID == "new" ? "新增提供商" : "AI 提供商"))
        .navigationBarTitleDisplayMode(.inline).toolbar {
          ToolbarItem(placement: .cancellationAction) { Button(tr("取消")) { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button(tr("保存")) {
              model.attempt {
                var settings = model.aiSettings
                settings["providers"] =
                  settings.array("providers").filter { $0.text("id") != providerID } + [
                    try checkedProvider()
                  ]
                settings["selected"] = providerID
                _ = try await model.aiCall(session, "settings.save", ["settings": settings])
                model.aiSettings = settings
                if !session.conversation.text("id").isEmpty {
                  session.conversation = try await model.aiCall(
                    session, "conversation.draft",
                    ["conversationId": session.conversation.text("id"), "agent": providerID])
                }
                dismiss()
              }
            }
          }
        }
    }.confirmationDialog(tr("删除提供商"), isPresented: $deleteConfirmation) {
      Button(tr("删除"), role: .destructive) {
        model.attempt {
          var settings = model.aiSettings
          let providers = settings.array("providers").filter { $0.text("id") != providerID }
          settings["providers"] = providers
          if settings.text("selected") == providerID {
            settings["selected"] = providers.first?.text("id") ?? ""
          }
          _ = try await model.aiCall(session, "settings.save", ["settings": settings])
          model.aiSettings = settings
          dismiss()
        }
      }
    }.onAppear {
      if let p = model.aiSettings.array("providers").first(where: {
        $0.text("id")
          == (initialProviderID.isEmpty ? model.aiSettings.text("selected") : initialProviderID)
      }) {
        load(p)
      }
    }
  }
  private func load(_ p: JSON) {
    providerID = p.text("id")
    name = p.text("name")
    url = p.text("baseUrl")
    key = p.text("apiKey")
    selection = p.text("model")
    protocolName = p.text("protocol", "chat")
    contextWindow = String(p.number("contextWindow", 32768))
    proxy = p.text("proxy")
    headers = pretty(p.object("headers"))
    parameters = pretty(p.object("parameters"))
    verifyTLS = p["verifyTls"] as? Bool ?? true
    enabled = p["enabled"] as? Bool ?? true
    models = []
  }
  private func checkedProvider() throws -> JSON {
    guard let window = Int(contextWindow), window > 0,
      let headerValues = try JSONSerialization.jsonObject(with: Data(headers.utf8))
        as? [String: String],
      let parameterValues = try JSONSerialization.jsonObject(with: Data(parameters.utf8)) as? JSON
    else {
      throw MobileError(message: tr("请检查上下文窗口及 JSON 参数格式"))
    }
    var p = model.aiSettings.array("providers").first { $0.text("id") == providerID } ?? [:]
    p.merge([
      "id": providerID, "name": name, "kind": "custom", "protocol": protocolName,
      "baseUrl": url, "apiKey": key, "model": selection, "enabled": enabled, "verifyTls": verifyTLS,
      "contextWindow": window, "proxy": proxy, "headers": headerValues,
      "parameters": parameterValues,
    ]) { _, b in b }
    return p
  }
}

struct GlobalAISettings: View {
  @EnvironmentObject var model: AppModel
  @State private var session: MobileSession?
  var body: some View {
    Group {
      if let session { AISettingsHome(session: session) } else { ProgressView(tr("加载 AI 配置…")) }
    }
    .task { model.attempt { session = try await model.openAISettings() } }
  }
}

private struct AIMessageRow: View {
  let message: JSON
  private var user: Bool { message.text("role") == "user" }
  var body: some View {
    if !message.text("content").isEmpty || !message.array("calls").isEmpty {
      HStack(alignment: .top) {
        if user { Spacer(minLength: 32) }
        VStack(alignment: .leading, spacing: 10) {
          if message.text("role") == "tool" {
            AIToolDisclosure(title: tr("执行结果"), content: message.text("content"))
          } else if user {
            Text(message.text("content")).textSelection(.enabled)
          } else if !message.text("content").isEmpty {
            MarkdownView(text: message.text("content"))
          }
          ForEach(Array(message.array("calls").enumerated()), id: \.offset) { _, call in
            let command = call.object("arguments").text("command")
            AIToolDisclosure(
              title: command.isEmpty ? call.text("name") : "$ " + command,
              content: pretty(call["arguments"] ?? [:]))
          }
        }.padding(user ? 14 : 0).background(
          user ? Color(uiColor: .secondarySystemGroupedBackground) : .clear,
          in: RoundedRectangle(cornerRadius: MobileDesign.chatRadius))
        if !user { Spacer(minLength: 0) }
      }
    }
  }
}
private struct AIToolDisclosure: View {
  let title: String, content: String
  @State private var expanded = false
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation { expanded.toggle() }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption)
          Text(title).font(.caption.monospaced()).lineLimit(1)
          Spacer(minLength: 0)
        }.foregroundStyle(.secondary).padding(12).contentShape(Rectangle())
      }.buttonStyle(.plain)
      if expanded {
        Divider()
        Text(content).font(.caption.monospaced()).textSelection(.enabled).padding(12)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .background(
        Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: MobileDesign.toolRadius)
      )
      .overlay(RoundedRectangle(cornerRadius: MobileDesign.toolRadius).strokeBorder(.secondary.opacity(0.15)))
  }
}
