import SwiftUI

struct ToolsView: View {
  @EnvironmentObject var model: AppModel
  @ObservedObject var session: MobileSession
  private var selected: String { session.selectedTool }
  @State private var sortMemory = false
  @State private var formOperation = ""
  @State private var query = ""
  @State private var confirm: JSON?
  @State private var pendingConfirm = false
  @State private var value = ""
  @State private var rename = ""
  @State private var text = ""
  @State private var output = ""
  @State private var rows: [JSON] = []
  @State private var tmuxWindows: [JSON] = []
  @State private var tmuxSession = ""
  @State private var busy = false
  @State private var showForm = false
  @State private var showOutput = false
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Group {
      if selected == "files" { FilesView(session: session) }
      else if selected == "monitor" { MonitorView(session: session) }
      else {
        VStack(spacing: 0) {
        HStack {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField(tr("搜索"), text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
          if !query.isEmpty { Button { query="" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
        }.padding(12).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal).padding(.vertical,8)
        List {
          if let error { Text(error).font(.callout).foregroundStyle(.orange) }
          if busy { ProgressView(tr("读取中…")) }
          if ["tmux", "docker", "images"].contains(selected) {
            ForEach(
              Array(
                rows.filter { query.isEmpty || pretty($0).localizedCaseInsensitiveContains(query) }
                  .enumerated()), id: \.offset
            ) { _, row in
              HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 10) {
                Text(row.text("Names", row.text("name", row.text("Repository")))).font(.headline)
                if selected == "docker" { Text(row.text("Image")).font(.caption.monospaced()).foregroundStyle(.secondary) }
                if selected == "images" { Text(row.text("Size")).font(.caption).foregroundStyle(.secondary) }
                Text(row.text("Status", row.text("status", row.text("Tag")))).font(.caption)
                  .foregroundStyle(.secondary)
                if selected == "tmux" { Button(tr("附着")) { run("tmuxAttach", row.text("name"), interactive: true) }.buttonStyle(.bordered) }
                if selected == "docker" { HStack {
                  Button(tr("日志")) { run("dockerLogs", row.text("ID")) }
                  Button("Shell") { run("dockerShell", row.text("ID"), interactive: true) }
                }.buttonStyle(.bordered) }
              }
              Spacer(minLength: 4)
              Menu {
                if selected == "tmux" {
                  Button(tr("附着")) { run("tmuxAttach", row.text("name"), interactive: true) }
                  Button(tr("查看窗口")) { run("tmuxWindows", row.text("name")) }
                  Button(tr("预览")) { run("tmuxPreview", row.text("name")) }
                  Button(tr("发送命令")) {
                    formOperation = "tmuxSend"
                    value = row.text("name")
                    rename = ""
                    showForm = true
                  }
                  Button(tr("重命名")) {
                    formOperation = "tmuxRename"
                    value = row.text("name")
                    showForm = true
                  }
                  Button(tr("结束"), role: .destructive) { run("tmuxKill", row.text("name")) }
                } else if selected == "docker" {
                  ForEach(
                    [
                      ("dockerStart", tr("启动")), ("dockerStop", tr("停止")),
                      ("dockerRestart", tr("重启")),
                      ("dockerPause", tr("暂停")), ("dockerResume", tr("恢复")),
                      ("dockerLogs", tr("日志")),
                      ("dockerInspect", tr("详情")), ("dockerShell", "Shell"),
                      ("dockerLogsFollow", tr("跟随日志")), ("dockerKill", tr("终止")),
                    ], id: \.0
                  ) { op, label in
                    Button(tr(label)) {
                      run(
                        op, row.text("ID"),
                        interactive: op == "dockerShell" || op == "dockerLogsFollow")
                    }
                  }
                  Button(tr("重命名")) {
                    formOperation = "dockerRename"
                    value = row.text("ID")
                    rename = row.text("Names")
                    showForm = true
                  }
                  Button(tr("删除"), role: .destructive) { run("dockerRemove", row.text("ID")) }
                } else {
                  Button(tr("详情")) { run("dockerInspect", row.text("ID")) }
                  Button(tr("标签")) {
                    formOperation = "dockerTag"
                    value = row.text("ID")
                    showForm = true
                  }
                  Button(tr("删除"), role: .destructive) { run("dockerImageRemove", row.text("ID")) }
                }
              } label: { Image(systemName: "ellipsis").padding(12).contentShape(Rectangle()) }
              }.padding(.vertical, 6)
            }
          }
          if ["scripts", "notes", "forwards", "history"].contains(selected) {
            ForEach(
              (model.records[selected] ?? []).filter {
                (query.isEmpty || pretty($0).localizedCaseInsensitiveContains(query))
                  && (!["notes", "history"].contains(selected) || $0.text("hostID").isEmpty
                    || $0.text("hostID") == session.host.text("id"))
              }, id: \.selfID
            ) { r in
              VStack(alignment: .leading, spacing: 8) {
                Text(
                  selected == "history"
                    ? Date(timeIntervalSinceReferenceDate: (r["startedAt"] as? Double) ?? 0)
                      .formatted() + " · "
                      + (r["succeeded"] as? Bool == true ? tr("已连接") : tr("未成功"))
                    : r.text("title", r.text("name", r.text("hostname")))
                ).font(.headline)
                Text(r.text("body")).font(.caption).lineLimit(4)
                if selected == "scripts" {
                  ScriptActions(record: r, current: session)
                }
                if selected == "forwards" {
                  Text("\(r.text("localHost")):\(r.number("localPort")) → \(r.text("remoteHost")):\(r.number("remotePort"))").font(.caption.monospaced()).foregroundStyle(.secondary)
                  HStack {
                    Button(tr("启动")) {
                      model.attempt {
                        _ = try await model.files(session, ["action": "forwardStart", "rule": r])
                      }
                    }
                    Button(tr("停止")) {
                      model.attempt {
                        _ = try await model.files(session, ["action": "forwardStop", "rule": r])
                      }
                    }
                  }
                }
              }
            }
          }
          if selected == "processes" {
            Picker(tr("排序"),selection:$sortMemory) { Text("CPU").tag(false);Text(tr("内存")).tag(true) }.pickerStyle(.segmented)
            ForEach(rows.filter { query.isEmpty || pretty($0).localizedCaseInsensitiveContains(query) }.sorted { ($0.metric(sortMemory ? "memPercent":"cpuPercent") ?? 0) > ($1.metric(sortMemory ? "memPercent":"cpuPercent") ?? 0) },id:\.selfIDForProcess) { row in
              VStack(alignment:.leading,spacing:10) {
                HStack { Text((row.text("command") as NSString).lastPathComponent).font(.headline).lineLimit(2);Spacer();Menu { Button(tr("终止"),role:.destructive) { run("processStop",String(row.number("pid"))) } } label: { Image(systemName:"ellipsis").padding(6) } }
                Text("PID \(row.number("pid")) · " + row.text("user")).font(.caption).foregroundStyle(.secondary)
                HStack { Text("CPU " + monitorPercent(row.metric("cpuPercent"))).foregroundStyle(.cyan);Spacer();Text("MEM " + monitorPercent(row.metric("memPercent"))).foregroundStyle(.purple) }.font(.caption.monospacedDigit())
                Text(row.text("command")).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
              }.padding(.vertical,6)
            }
          }
          if selected == "tmux" {
            ForEach(tmuxWindows, id: \.selfID) { window in
              Button(trf("附着窗口 {} · {}", window.text("index"), window.text("name"))) {
                run(
                  "tmuxWindowAttach", tmuxSession, extra: ["window": Int(window.text("index")) ?? 0]
                )
              }
            }
          }
          if !output.isEmpty && !["docker", "images", "tmux", "processes"].contains(selected) {
            Section(tr("结果")) {
              Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
          }
          if selected == "tmux" {
            Button(tr("新建 tmux 会话")) {
              formOperation = "tmuxCreate"
              value = ""
              showForm = true
            }
          }
          if selected == "images" {
            Button(tr("清理未使用镜像"), role: .destructive) { run("dockerPrune", "") }
          }
          if ["scripts", "notes", "forwards"].contains(selected) {
            NavigationLink(trf("管理已保存的{}", title)) {
              RecordsList(collection: selected, title: title)
            }
          }
        }.listStyle(.insetGrouped)
        }
      }
      }
      .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
      .toolbar(.visible, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement:.topBarLeading) {
          Button { session.activePanel=session.toolsReturnPanel } label: { Label(tr("返回会话"),systemImage:"chevron.left") }
            .accessibilityIdentifier("tools-back")
        }
        ToolbarItem(placement:.principal) { VStack(spacing:2) { Text(title).font(.headline);Text(session.label).font(.caption2).foregroundStyle(.secondary) } }
        ToolbarItem(placement:.topBarTrailing) {
          if selected != "monitor" && selected != "files" { Button { refresh() } label: { Image(systemName:"arrow.clockwise") }.accessibilityLabel(tr("刷新")).disabled(busy) }
        }
      }
      .safeAreaInset(edge:.bottom,spacing:0) {
        VStack(spacing:0) {
          if !session.transfers.isEmpty { TransferTray(session:session) }
          ToolDock(selected:$session.selectedTool,ssh:session.protocolKind == "ssh")
        }
      }
      .task { refresh() }
      .onChange(of:selected) { _,_ in query="";output="";rows=[];refresh() }
      .onChange(of:session.execReady) { _, ready in if ready { refresh() } }
    }.confirmationDialog(tr("确认执行服务器操作"), isPresented: $pendingConfirm) {
      Button(tr("执行"), role: .destructive) {
        if let pending = confirm {
          run(
            pending.text("operation"), pending.text("value"), extra: pending.object("extra"),
            approved: true)
        }
      }
      Button(tr("取消"), role: .cancel) { confirm = nil }
    } message: {
      Text(confirm?.text("operation") ?? "")
    }
    .sheet(isPresented:$showOutput) { NavigationStack { ScrollView { Text(output).font(.system(.callout,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding() }.navigationTitle(tr("结果")).toolbar { Button(tr("完成")) { showOutput=false } } }.presentationDetents([.large]) }
    .alert(formOperation == "tmuxSend" ? tr("发送命令") : tr("名称"), isPresented: $showForm) {
      TextField(tr("名称"), text: $rename)
      Button(tr("取消"), role: .cancel) {}
      Button(tr("保存")) {
        run(
          formOperation,
          value.isEmpty ? rename : value, extra: ["name": rename, "text": rename])
      }
    }
  }
  private var title: String {
    [
      "files": tr("文件"), "monitor": tr("概览"), "processes": tr("进程"), "scripts": tr("脚本"), "tmux": "tmux",
      "docker": "Docker",
      "images": tr("镜像"),
      "commands": tr("命令历史"), "forwards": tr("转发"), "history": tr("历史"), "notes": tr("笔记"),
    ][selected] ?? tr("工具")
  }
  private func perform(_ action: @escaping @MainActor () async throws -> Void) {
    let page=selected
    Task { do { try await action() } catch is CancellationError {} catch { if selected == page { self.error=error.localizedDescription } } }
  }
  private func refresh() {
    error = nil
    output = ""
    rows = []
    tmuxWindows = []
    if !session.connected || selected == "files" || selected == "monitor" { return }
    if selected == "commands" {
      run("commandHistory", "")
      return
    }
    if selected == "processes" {
      perform {
        busy=true
        defer { busy=false }
        let info=try await model.files(session,["action":"systemInfo"])
        let result: [JSON]
        if info.text("platform") == "windows" {
          result=try await model.files(session,["action":"systemMonitor","operation":"processes"]).array("processes")
        } else {
          let response=try await model.exec(session,command:MonitorParser.processCommand)
          guard response.number("code")==0 else { throw MobileError(message:response.text("stderr")) }
          result=MonitorParser.processes(response.text("stdout"))
        }
        if selected == "processes" { rows=result }
      }
    } else if ["tmux", "docker", "images"].contains(selected) {
      run(
        selected == "tmux" ? "tmuxList" : selected == "docker" ? "dockerList" : "dockerImages", "")
    }
  }
  private func run(
    _ operation: String, _ value: String, interactive: Bool = false, extra: JSON = [:],
    approved: Bool = false
  ) {
    if !approved
      && [
        "dockerRemove", "dockerKill", "dockerStop", "dockerPrune", "dockerImageRemove", "tmuxKill",
        "processStop",
      ].contains(operation)
    {
      confirm = ["operation": operation, "value": value, "extra": extra]
      pendingConfirm = true
      return
    }
    let requestedTool = selected
    perform {
      busy = true
      error = nil
      defer { busy = false }
      let info = try await model.files(session, ["action": "systemInfo"])
      let request: JSON = [
        "method": "mobile.serverTool", "operation": operation, "value": value,
        "platform": info.text("platform"),
      ]
      let plan = try await model.call(request.merging(extra) { _, b in b })
      if interactive || plan["interactive"] as? Bool == true {
        session.activePanel = "terminal"
        model.sendText(session, plan.text("command") + "\n")
        return
      }
      let result = try await model.exec(session, command: plan.text("command"))
      guard selected == requestedTool else { return }
      output = result.text("stdout") + result.text("stderr")
      guard result.number("code") == 0 else {
        throw MobileError(message: output.isEmpty ? tr("远端操作失败，请确认工具已安装且账号有权限") : output)
      }
      if ["tmuxPreview", "dockerLogs", "dockerInspect"].contains(operation) { showOutput=true }
      if operation == "tmuxWindows" {
        tmuxSession = value
        tmuxWindows = output.split(separator: "\n").map {
          let c = $0.split(separator: "\t", omittingEmptySubsequences: false)
          return [
            "id": String(c.first ?? ""), "index": String(c.first ?? ""),
            "name": c.count > 1 ? String(c[1]) : "",
          ]
        }
      }
      if operation == "tmuxList" {
        rows = output.split(separator: "\n").map { line in
          let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
          return [
            "name": String(cols.first ?? ""), "status": trf("{} 个窗口 · {} 个连接", cols.count > 1 ? String(cols[1]) : "0", cols.count > 2 ? String(cols[2]) : "0"),
          ]
        }
      }
      if ["tmuxCreate", "tmuxRename", "tmuxKill", "tmuxSend", "dockerStart", "dockerStop", "dockerRestart", "dockerPause", "dockerResume", "dockerRename", "dockerKill", "dockerRemove", "dockerPrune", "dockerTag", "dockerImageRemove", "processStop"].contains(operation) { refresh() }
      if operation == "dockerList" || operation == "dockerImages" {
        rows = output.split(separator: "\n").compactMap {
          try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? JSON
        }
      }
    }
  }
}

extension Dictionary where Key == String, Value == Any { var selfIDForProcess: Int { number("pid") } }
