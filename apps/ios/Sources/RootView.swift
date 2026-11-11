import SwiftUI

struct RootView: View {
  @AppStorage("TermPilot.language") private var language = "zh-Hans"
  @EnvironmentObject var model: AppModel
  @SceneStorage("TermPilot.windowID") private var windowID = UUID().uuidString
  @SceneStorage("TermPilot.windowSession") private var windowSession = ""
  @State private var search = ""
  @AppStorage("TermPilot.collapsedHostGroups") private var storedCollapsedGroups = "[]"
  private var collapsedGroups: Set<String> { Set((try? JSONDecoder().decode([String].self, from: Data(storedCollapsedGroups.utf8))) ?? []) }
  private func collapseGroups(_ groups: Set<String>) {
    if let data = try? JSONEncoder().encode(groups.sorted()), let value = String(data: data, encoding: .utf8) { storedCollapsedGroups = value }
  }
  @State private var edit: RecordEditorItem?
  @State private var pendingQuickConnection: JSON?
  @State private var homeTab = "hosts"
  var body: some View {
    GeometryReader { geometry in
      if model.controllingWindow != windowID {
        VStack(spacing: 20) {
          Image(systemName: "rectangle.on.rectangle").font(.largeTitle)
          Text(tr("工作区正在另一个窗口中操作"))
          Button(tr("在此窗口继续")) {
            model.claimWindow(windowID, preferredSession: UInt64(windowSession))
          }
          .buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let session = model.current {
        WorkspaceView(session: session).id(session.id)
      } else {
        TabView(selection: $homeTab) {
          Group {
            if geometry.size.width >= MobileDesign.wideBreakpoint {
              NavigationSplitView {
                hosts
              } detail: {
                ContentUnavailableView(
                  "TermPilot", systemImage: "server.rack", description: Text(tr("选择一台主机开始连接")))
              }
            } else {
              NavigationStack { hosts }
            }
          }.tabItem { Label(tr("主机"), systemImage: "server.rack") }.tag("hosts")
          NavigationStack { sessions }
            .tabItem { Label(tr("会话"), systemImage: "rectangle.on.rectangle") }.tag("sessions")
          Group {
            if geometry.size.width >= MobileDesign.wideBreakpoint {
              NavigationSplitView {
                SettingsHome()
              } detail: {
                NavigationStack { GeneralSettings() }
              }
            } else {
              NavigationStack { SettingsHome() }
            }
          }.tabItem { Label(tr("设置"), systemImage: "gearshape") }.tag("settings")
        }.tint(.blue).id(language)
      }
    }
    .task {
      if model.controllingWindow == nil {
        model.claimWindow(windowID, preferredSession: UInt64(windowSession))
      }
    }
    .onChange(of: model.selected) { _, id in
      if model.controllingWindow == windowID {
        windowSession = id.map(String.init) ?? ""
        if UIApplication.shared.applicationState == .active { model.lifecycle(.active) }
      }
    }
    .sheet(item: $edit, onDismiss: {
      guard let host = pendingQuickConnection else { return }
      pendingQuickConnection = nil
      model.attempt { try await model.connect(host) }
    }) { item in
      RecordEditor(item: item, onQuickConnect: { host in
        // Wait for the editor to finish dismissing before a fast connection
        // failure or trust prompt needs the same presentation controller.
        pendingQuickConnection = host
        edit = nil
      }).presentationSizingIfAvailable()
    }
    .sheet(item: $model.interaction) { InteractionView(item: $0).interactiveDismissDisabled() }
    .alert(
      "TermPilot",
      isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    ) {
      Button(tr("好")) { model.error = nil }
    } message: {
      Text(model.error ?? "")
    }
  }
  private var filteredHosts: [JSON] {
    (model.records["hosts"] ?? []).filter {
      search.isEmpty || $0.text("label").localizedCaseInsensitiveContains(search)
        || $0.text("hostname").localizedCaseInsensitiveContains(search)
    }
  }
  private var groupTree: [MobileHostGroupNode] { MobileHostGroups.tree(model.records["groups"] ?? []) }
  private var hostTree: [MobileHostGroupNode] {
    let known = Set((model.records["groups"] ?? []).map { $0.text("id") })
    let ungrouped = (model.records["hosts"] ?? []).contains { !known.contains($0.text("groupID")) }
    return groupTree + (ungrouped ? [MobileHostGroupNode(id: "", name: tr("未分组"), children: [])] : [])
  }
  private var hostRows: [MobileHostTreeRow] {
    let known = Set((model.records["groups"] ?? []).map { $0.text("id") })
    let grouped = Dictionary(grouping: model.records["hosts"] ?? []) { known.contains($0.text("groupID")) ? $0.text("groupID") : "" }
    return MobileHostGroups.rows(hostTree, hosts: grouped, collapsed: collapsedGroups, search: search)
  }
  private var hosts: some View {
    List {
      Section {
        Button {
          edit = RecordEditorItem(collection: "hosts", record: [:], connectOnly: true)
        } label: {
          HStack {
            SettingsLabel(title: "快速连接", icon: "bolt.fill", color: .orange)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
          }
        }.accessibilityIdentifier("home-quick")
        NavigationLink {
          RecordsList(collection: "groups", title: "主机分组")
        } label: {
          SettingsLabel(title: "分组设置", icon: "folder.badge.gearshape")
        }
      }
      if !hostTree.isEmpty {
        Section {
          HStack {
            Spacer()
            Button(tr("全部展开")) { collapseGroups([]) }
            Button(tr("全部收起")) { collapseGroups(hostTree.reduce(into: Set<String>()) { $0.formUnion($1.descendants) }) }
          }.font(.caption).buttonStyle(.borderless)
          ForEach(hostRows) { row in
            if let group = row.group {
              Button {
                var collapsed = collapsedGroups
                if !collapsed.insert(group.id).inserted { collapsed.remove(group.id) }
                withAnimation { collapseGroups(collapsed) }
              } label: {
                HStack(spacing: 10) {
                  Image(systemName: row.expanded ? "chevron.down" : "chevron.right").font(.caption).frame(width: 16)
                  Image(systemName: row.expanded ? "folder.fill" : "folder").foregroundStyle(.blue)
                  Text(group.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                  Spacer()
                  Text(String(row.count)).font(.caption).foregroundStyle(.secondary)
                }.padding(.leading, CGFloat(min(row.depth, 5) * 16)).frame(minHeight: 38).contentShape(Rectangle())
              }.buttonStyle(.plain).accessibilityIdentifier(row.id)
                .accessibilityValue(tr(row.expanded ? "展开" : "收起"))
            } else if let host = row.host {
              hostRow(host).padding(.leading, CGFloat(min(row.depth, 5) * 16)).accessibilityIdentifier(row.id)
            }
          }
        }
      }
      if model.ready && hostRows.isEmpty {
        ContentUnavailableView(
          tr(search.isEmpty ? "添加第一台服务器" : "暂无数据"), systemImage: "server.rack",
          description: Text("SSH · VNC · RDP · Apple")
        )
        .listRowBackground(Color.clear)
      }
    }.listStyle(.insetGrouped).searchable(text: $search, prompt: tr("搜索主机"))
      .navigationTitle(tr("主机")).toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            edit = RecordEditorItem(collection: "hosts", record: [:])
          } label: {
            Image(systemName: "plus").accessibilityLabel(tr("新增主机"))
          }
        }
      }
  }
  private func hostRow(_ host: JSON) -> some View {
    HStack(spacing: 10) {
      Button {
        model.attempt { try await model.connect(host) }
      } label: {
        HStack(spacing: 12) {
          Image(
            systemName: host.text("connectionKind", "ssh") == "ssh" ? "terminal" : "desktopcomputer"
          )
          .font(.system(size: 18)).foregroundStyle(.blue).frame(width: 36, height: 36)
          .background(.blue.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
          VStack(alignment: .leading, spacing: 4) {
            Text(host.text("label")).foregroundStyle(.primary)
            Text(host.text("hostname")).font(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
        }.padding(.vertical, 6).contentShape(Rectangle())
      }.buttonStyle(.plain)
      Button {
        edit = RecordEditorItem(collection: "hosts", record: host)
      } label: {
        Image(systemName: "info.circle").foregroundStyle(.secondary).frame(width: 36, height: 44)
      }
      .buttonStyle(.borderless).accessibilityLabel(tr("编辑") + " " + host.text("label"))
    }.contextMenu {
      Button(tr("编辑")) { edit = RecordEditorItem(collection: "hosts", record: host) }
      Button { model.attempt {
        let draft = try await model.call(["method":"vault.host.duplicateDraft", "id":host.text("id")])
        var copy = draft.object("item")
        copy["label"] = copy.text("label") + " " + tr("副本")
        edit = RecordEditorItem(collection: "hosts", record: copy, isNew: true, initialProfile: draft["screenSharingProfile"] as? JSON)
      } } label: { Label(tr("复制主机"), systemImage: "doc.on.doc") }
      Button(tr("删除"), role: .destructive) {
        model.attempt { try await model.delete("hosts", id: host.text("id")) }
      }
    }
  }
  private var sessions: some View {
    List {
      if model.sessions.isEmpty {
        ContentUnavailableView(tr("暂无会话"), systemImage: "rectangle.on.rectangle").listRowBackground(
          Color.clear)
      } else {
        Section(tr("活动会话")) {
          ForEach(model.sessions) { session in
            Button {
              model.selected = session.id
            } label: {
              HStack(spacing: 12) {
                SettingsLabel(
                  title: session.label,
                  icon: session.protocolKind == "ssh" ? "terminal" : "desktopcomputer", color: .blue
                )
                Spacer()
                Text(tr(session.status)).font(.caption).foregroundStyle(.secondary)
              }
            }.swipeActions {
              Button(tr("断开"), role: .destructive) {
                model.attempt { try await model.close(session) }
              }
            }
          }
        }
      }
    }.listStyle(.insetGrouped).navigationTitle(tr("会话")).toolbar {
      Button {
        edit = RecordEditorItem(collection: "hosts", record: [:], connectOnly: true)
      } label: {
        Image(systemName: "plus").accessibilityLabel(tr("快速连接"))
      }
    }
  }
}

extension View {
  /// A full usable form on phones; the regular-width system sheet stays readable on iPad.
  func presentationSizingIfAvailable() -> some View {
    presentationDetents([.large]).presentationDragIndicator(.visible)
  }
}

extension Dictionary where Key == String, Value == Any {
  var selfID: String { text("id", text("name")) }
}
struct WorkspaceView: View {
  @EnvironmentObject var model: AppModel
  @ObservedObject var session: MobileSession
  private var tab: String { session.activePanel }
  var body: some View {
    if tab == "tools" {
      GeometryReader { geometry in
        if geometry.size.width >= MobileDesign.wideBreakpoint {
          HStack(spacing: 0) {
            VStack(spacing: 0) {
              HStack {
                Text(session.label).font(.headline)
                Spacer()
                Text(tr(session.status)).font(.caption).foregroundStyle(.secondary)
              }.padding()
              Divider()
              surface
              Divider()
              tabs
            }
            Divider()
            ToolsView(session: session).frame(width: min(560, max(360, geometry.size.width * 0.52)))
          }
        } else {
          ToolsView(session: session)
        }
      }
    } else {
      GeometryReader { geometry in
        VStack(spacing: 0) {
          HStack(spacing: 12) {
            Button {
              session.dismissKeyboard()
              model.selected = nil
            } label: {
              Image(systemName: "chevron.left").frame(width: 32, height: 32)
            }.accessibilityLabel(tr("主机")).accessibilityIdentifier("session-back")
            Circle().fill(session.connected ? Color.green : .orange).frame(width: 7, height: 7)
            Text(session.label).font(.headline)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
              Text(tr(session.status)).foregroundStyle(.secondary)
              if session.protocolKind == "ssh", session.connected,
                 let latency = session.latencyMilliseconds {
                Text("\(latency) ms").monospacedDigit().foregroundStyle(SSHLatency.color(latency))
                  .accessibilityIdentifier("ssh-latency")
              }
            }.font(.caption).fixedSize()
            if !session.connected && session.status == "已断开" {
              Button(tr("重新连接")) { model.attempt { try await model.reconnect(session) } }
            }
            Button {
              model.attempt { try await model.close(session) }
            } label: {
              Image(systemName: "xmark")
            }
          }.padding(.horizontal).padding(.vertical, 10)
          Divider()
          if geometry.size.width >= 700 && tab == "ai" {
            HStack(spacing: 0) {
              surface
              Divider()
              VStack(spacing: 0) {
                panel
              }.frame(width: min(440, max(MobileDesign.sidebarWidth, geometry.size.width * 0.46)))
            }
          } else {
            if tab == "terminal" { surface } else { panel }
          }
          if session.protocolKind != "ssh" {
            RemoteVideoStats(session: session)
          }
          if !session.transfers.isEmpty { TransferTray(session: session) }
          Divider()
          tabs
        }.background(Color(uiColor: .systemBackground))
      }
    }
  }
  var tabs: some View {
    HStack {
      tabButton("terminal", tr("终端"), "terminal")
      tabButton("tools", tr("工具"), "wrench.and.screwdriver")
      tabButton("ai", "AI", "sparkles")
    }.padding(6)
  }
  func tabButton(_ key: String, _ label: String, _ icon: String) -> some View {
    Button {
      session.dismissKeyboard()
      if key == "tools" {
        session.toolsReturnPanel = tab
        if session.protocolKind != "ssh" { session.selectedTool = "files" }
      }
      session.activePanel = key
    } label: {
      VStack(spacing: 3) {
        Image(systemName: icon).font(.system(size: 19))
        Text(tr(label)).font(.caption2)
      }.frame(maxWidth: .infinity).padding(7).background(
        tab == key ? Color.accentColor.opacity(0.16) : .clear,
        in: RoundedRectangle(cornerRadius: 10))
    }.accessibilityIdentifier("workspace-" + key)
  }
  @ViewBuilder var surface: some View {
    VStack(spacing: 0) {
      ZStack {
        if session.protocolKind == "ssh" {
          TerminalSurface(session: session)
        } else {
          RemoteSurface(session: session)
        }
        if session.keyboardVisible {
          // Consume this tap before it can reopen SwiftTerm's keyboard or click
          // the remote desktop. Shortcut buttons remain outside this area.
          Button { session.dismissKeyboard() } label: {
            Color.clear.contentShape(Rectangle())
          }.buttonStyle(.plain)
            .accessibilityLabel(tr("收起键盘"))
            .accessibilityIdentifier("session-keyboard-dismiss-area")
        }
      }
      KeyBar(session: session)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
        if session.protocolKind == "ssh", session.terminalView.isFirstResponder {
          session.keyboardVisible = true
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
        if session.protocolKind == "ssh", session.keyboardVisible { session.dismissKeyboard() }
      }
  }
  @ViewBuilder var panel: some View {
    switch tab {
    case "ai": AIView(session: session)
    case "tools": ToolsView(session: session)
    case "files": FilesView(session: session)
    default: ToolsView(session: session)
    }
  }
}
struct InteractionView: View {
  @EnvironmentObject var model: AppModel
  let item: Interaction
  @State private var secret = ""
  @State private var fields: JSON = [:]
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Label(tr("需要确认"), systemImage: "shield.lefthalf.filled").font(.title2)
          if item.event.text("type") == "form" {
            AgentForm(spec: item.event.object("payload"), values: $fields)
          } else {
            Text(
              pretty(
                item.event.object("detail").isEmpty
                  ? item.event.object("payload").isEmpty ? item.event : item.event.object("payload")
                  : item.event.object("detail"))
            ).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
          }
          if item.event.text("type") == "credentialPrompt" {
            SecureField(tr("密码或验证码"), text: $secret).textFieldStyle(.roundedBorder)
          }
          HStack {
            Button(tr("拒绝"), role: .destructive) {
              model.attempt { try await model.answer(item, allow: false) }
            }.buttonStyle(.bordered)
            Spacer()
            Button(tr("允许")) {
              model.attempt {
                try await model.answer(item, allow: true, value: secret, fields: fields)
              }
            }.buttonStyle(.borderedProminent)
          }
        }.padding()
      }.navigationTitle("TermPilot")
    }
  }
}
