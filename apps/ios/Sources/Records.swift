import SwiftUI

struct RecordEditorItem: Identifiable {
  let id = UUID()
  let collection: String
  let record: JSON
  var connectOnly = false
  var isNew = false
  var initialProfile: JSON? = nil
}
enum HostProxySelection {
  static let inline = "__host_inline_proxy__"
  static func value(_ host: JSON) -> String {
    host["proxyConfiguration"] is JSON ? inline : host.text("proxyProfileID")
  }
  static func select(_ value: String, in host: inout JSON) {
    guard value != inline else { return }
    // Imported desktop hosts can contain their own proxy configuration. It has
    // priority in resolveConnection, so selecting Direct/a profile must clear it.
    host["proxyConfiguration"] = NSNull()
    host["proxyProfileID"] = value.isEmpty ? NSNull() : value as Any
  }
}
struct RecordEditor: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) var dismiss
  let item: RecordEditorItem
  var onQuickConnect: ((JSON) -> Void)? = nil
  @State private var fields: JSON = [:]
  @State private var remoteProfile: JSON = [:]
  @State private var saving = false
  var body: some View {
    NavigationStack {
      Form {
        if item.collection == "hosts" {
          if !item.connectOnly {
            Section(tr("基本信息")) {
              field(tr("名称"), "label")
              Picker(tr("分组"), selection: string("groupID")) {
                Text(tr("未分组")).tag("")
                ForEach(MobileHostGroups.options(MobileHostGroups.tree(model.records["groups"] ?? [])), id: \.id) {
                  Text($0.name).tag($0.id)
                }
              }
            }
          }
          Section(tr("连接")) {
            Picker(
              tr("连接类型"),
              selection: Binding(
                get: { fields.text("connectionKind", "ssh") },
                set: { kind in
                  fields["connectionKind"] = kind
                  fields["port"] = kind == "ssh" ? 22 : kind == "rdp" ? 3389 : 5900
                })
            ) {
              Text("SSH").tag("ssh")
              Text(tr("远程管理")).tag("screenSharing")
              Text("RDP").tag("rdp")
            }
            field(tr("IP 地址 / 主机名"), "hostname")
            TextField(tr("端口"), text: number("port", 22)).keyboardType(.numberPad)
          }
          Section(tr("认证")) {
            Picker(tr("凭证"), selection: string("credentialID")) {
              Text(tr("手动输入")).tag("")
              ForEach(model.records["credentials"] ?? [], id: \.selfID) {
                Text($0.text("label")).tag($0.text("id"))
              }
            }
            if fields.text("credentialID").isEmpty {
              field(tr("用户名"), "username")
              SecureField(tr("密码"), text: string("password"))
            }
          }
          Section(tr("网络")) {
            Picker(tr("代理"), selection: Binding(
              get: { HostProxySelection.value(fields) },
              set: { HostProxySelection.select($0, in: &fields) }
            )) {
              Text(tr("直连")).tag("")
              if fields["proxyConfiguration"] is JSON {
                Text(fields.object("proxyConfiguration").text("host") + ":" + String(fields.object("proxyConfiguration").number("port")))
                  .tag(HostProxySelection.inline)
              }
              ForEach(model.records["proxies"] ?? [], id: \.selfID) {
                Text($0.text("label")).tag($0.text("id"))
              }
            }.onChange(of: fields.text("proxyProfileID")) { _, value in
              if !value.isEmpty && fields.text("mode") == "highPerformance" {
                fields["mode"] = "standardVNC"
              }
            }
          }
          if fields.text("connectionKind") == "screenSharing" {
            Section {
              Picker(tr("模式"), selection: string("mode", "standardVNC")) {
                Text(tr("普通 VNC")).tag("standardVNC")
                if fields.text("proxyProfileID").isEmpty {
                  Text(tr("Apple 高性能")).tag("highPerformance")
                }
              }
            } header: {
              Text(tr("显示"))
            } footer: {
              Text(tr("高性能使用局域网直连、1080p SDR 单虚拟屏。实际设备的媒体解码能力仍需验收。"))
            }
          }
        } else if item.collection == "credentials" {
          Section(tr("基本信息")) {
            field(tr("名称"), "label")
            field(tr("用户名"), "username")
          }
          Section(tr("认证")) {
            Picker(tr("类型"), selection: string("kind", "password")) {
              Text(tr("密码")).tag("password")
              Text(tr("私钥")).tag("identityKey")
            }
            if fields.text("kind", "password") == "password" {
              SecureField(tr("密码"), text: string("password"))
            } else {
              TextEditor(text: string("privateKey")).font(.body.monospaced()).frame(minHeight: 180)
                .accessibilityLabel(tr("私钥"))
              SecureField(tr("私钥口令"), text: string("passphrase"))
              Toggle(
                tr("记住口令"),
                isOn: Binding(
                  get: { fields["savesPassphrase"] as? Bool ?? false },
                  set: { fields["savesPassphrase"] = $0 }))
            }
          }
        } else if item.collection == "groups" {
          Section(tr("分组")) {
            field(tr("名称"), "name")
            let tree = MobileHostGroups.tree(model.records["groups"] ?? [])
            let excluded = MobileHostGroups.excluded(fields.text("id"), in: tree)
            Picker(tr("上级分组"), selection: string("parentGroupID")) {
              Text(tr("一级分组")).tag("")
              ForEach(MobileHostGroups.options(tree).filter { !excluded.contains($0.id) }, id: \.id) { option in
                Text(option.name).tag(option.id)
              }
            }
          }
        } else if item.collection == "proxies" {
          Section(tr("代理配置")) {
            field(tr("名称"), "label")
            Picker(tr("类型"), selection: string("type", "socks5")) {
              Text("SOCKS5").tag("socks5")
              Text("HTTP CONNECT").tag("http")
            }
          }
          Section(tr("连接")) {
            field(tr("主机"), "host")
            TextField(tr("端口"), text: number("port", 1080)).keyboardType(.numberPad)
          }
          Section(tr("认证（可选）")) {
            field(tr("用户名"), "username")
            SecureField(tr("密码"), text: string("password"))
          }
        } else if item.collection == "forwards" {
          Section(tr("转发")) {
            field(tr("名称"), "name")
            Picker(tr("类型"), selection: string("kind", "local")) {
              Text(tr("本地")).tag("local")
              Text(tr("远程")).tag("remote")
              Text(tr("动态 SOCKS")).tag("dynamic")
            }
          }
          Section(tr("监听")) {
            field(tr("监听地址"), "localHost", "127.0.0.1")
            TextField(tr("监听端口"), text: number("localPort", 8080)).keyboardType(.numberPad)
          }
          if fields.text("kind", "local") != "dynamic" {
            Section(tr("目标")) {
              field(tr("目标地址"), "remoteHost", "127.0.0.1")
              TextField(tr("目标端口"), text: number("remotePort", 80)).keyboardType(.numberPad)
            }
          }
        } else {
          Section(tr("基本信息")) {
            field(tr("标题"), "title")
            if item.collection == "scripts" { field(tr("解释器"), "shell", "/bin/sh") }
          }
          Section(tr("内容")) {
            TextEditor(text: string("body")).font(.system(.body, design: .monospaced)).frame(
              minHeight: 300)
          }
        }
      }.navigationTitle(
        item.connectOnly
          ? tr("快速连接")
          : item.collection == "hosts"
            ? tr((item.isNew || item.record.isEmpty) ? "添加主机" : "编辑主机") : tr(item.record.isEmpty ? "新增" : "编辑")
      )
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button(tr("取消")) { dismiss() }.disabled(saving) }
        ToolbarItem(placement: .confirmationAction) {
          Button(item.connectOnly ? tr("连接") : tr("保存")) {
            saving = true
            model.attempt {
              defer { saving = false }
              var r = fields
              if item.collection == "hosts" {
                guard !r.text("hostname").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...65535).contains(r.number("port"))
                else { throw MobileError(message: tr("请输入有效的主机地址和端口")) }
                if r.text("label").isEmpty { r["label"] = r.text("hostname") }
              }
              if r.text("id").isEmpty { r["id"] = UUID().uuidString }
              for key in ["credentialID", "proxyProfileID", "groupID", "parentGroupID"] where r.text(key).isEmpty {
                r[key] = NSNull()
              }
              if item.connectOnly {
                if r.text("label").isEmpty { r["label"] = r.text("hostname") }
                if let onQuickConnect { onQuickConnect(r); return }
                try await model.connect(r)
                dismiss()
                return
              }
              if item.collection == "proxies" {
                r["configuration"] = [
                  "type": r.text("type", "socks5"), "host": r.text("host"),
                  "port": r.number("port", 1080), "username": r.text("username"),
                  "password": r.text("password"),
                ]
              }
              if item.collection == "hosts", r.text("connectionKind", "ssh") != "ssh" {
                var profile = remoteProfile
                profile.merge([
                  "hostID": r["id"]!,
                  "mode": r.text("connectionKind") == "rdp"
                    ? "rdp" : r.text("mode", "standardVNC"),
                  "username": r.text("username"), "port": r.number("port", 5900),
                  "password": r.text("password"),
                ]) { _, new in new }
                if profile["audio"] == nil { profile["audio"] = true }
                _ = try await model.call([
                  "method": "vault.save", "collection": "hosts", "item": r,
                  "screenSharingProfile": profile,
                ])
                await model.reload()
              } else {
                try await model.save(item.collection, item: r)
              }
              dismiss()
            }
          }.disabled(saving)
        }
      }
    }.interactiveDismissDisabled(saving).task {
      fields = item.record
      if fields.isEmpty {
        fields = [
          "connectionKind": "ssh", "authentication": "password",
          "port": item.collection == "proxies" ? 1080 : 22,
          "kind": item.collection == "forwards" ? "local" : "password",
          "shell": "/bin/sh",
        ]
      }
      if let profile = item.initialProfile {
        remoteProfile = profile
        fields.merge(profile) { _, b in b }
      }
      if item.collection == "hosts", !item.isNew, !item.record.text("id").isEmpty,
        item.record.text("connectionKind", "ssh") != "ssh"
      {
        if let profile = try? await model.call([
          "method": "vault.get", "collection": "screenSharing", "id": item.record.text("id"),
        ]).object("item") {
          remoteProfile = profile
          fields.merge(profile) { _, b in b }
        }
      }
      if item.collection == "proxies" {
        fields.merge(item.record.object("configuration")) { _, b in b }
      }
    }
  }
  func string(_ key: String, _ fallback: String = "") -> Binding<String> {
    Binding(get: { fields.text(key, fallback) }, set: { fields[key] = $0 })
  }
  func number(_ key: String, _ fallback: Int) -> Binding<String> {
    Binding(get: { String(fields.number(key, fallback)) }, set: { fields[key] = Int($0) ?? 0 })
  }
  func field(_ label: String, _ key: String, _ fallback: String = "") -> some View {
    TextField(tr(label), text: string(key, fallback)).textInputAutocapitalization(.never)
      .autocorrectionDisabled()
  }
}
struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack { SettingsHome().toolbar { Button(tr("完成")) { dismiss() } } }
  }
}
struct RecordsList: View {
  @EnvironmentObject var model: AppModel
  let collection: String, title: String
  @State var edit: RecordEditorItem?
  private var groupOptions: [(id: String, name: String)] { MobileHostGroups.options(MobileHostGroups.tree(model.records["groups"] ?? [])) }
  private var rows: [JSON] {
    let records = model.records[collection] ?? []
    return collection == "groups" ? groupOptions.compactMap { option in records.first { $0.text("id") == option.id } } : records
  }
  var body: some View {
    List {
      if (model.records[collection] ?? []).isEmpty {
        ContentUnavailableView(
          tr("暂无数据"), systemImage: collection == "credentials" ? "key" : "folder",
          description: Text(tr("点击右上角添加"))
        )
        .listRowBackground(Color.clear)
      }
      ForEach(rows, id: \.selfID) { r in
        Button(collection == "groups" ? (groupOptions.first { $0.id == r.text("id") }?.name ?? r.text("name")) : r.text("title", r.text("label", r.text("name")))) {
          edit = RecordEditorItem(collection: collection, record: r)
        }.swipeActions {
          Button(tr("删除"), role: .destructive) {
            model.attempt { try await model.delete(collection, id: r.text("id")) }
          }
        }
      }.onMove { source, destination in
        guard collection == "scripts" else { return }
        var ids = (model.records[collection] ?? []).map { $0.text("id") }
        ids.move(fromOffsets: source, toOffset: destination)
        model.attempt {
          _ = try await model.call([
            "method": "vault.reorder", "collection": collection, "ids": ids,
          ])
          await model.reload()
        }
      }.moveDisabled(collection != "scripts")
    }.listStyle(.insetGrouped).navigationTitle(tr(title)).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if collection == "scripts" { EditButton() }
        Button {
          edit = RecordEditorItem(collection: collection, record: [:])
        } label: {
          Image(systemName: "plus")
        }
      }.sheet(item: $edit) { RecordEditor(item: $0).presentationSizingIfAvailable() }
  }
}
