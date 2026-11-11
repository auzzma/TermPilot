import SwiftUI

struct MonitorView: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.scenePhase) var phase
  @ObservedObject var session: MobileSession
  @State private var snapshot: JSON = [:]
  @State private var parser = MonitorParser()
  @State private var history: [Double] = []
  @State private var error: String?
  @State private var refreshing = false
  @State private var revision = 0
  @State private var updated: Date?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Label(tr("实时监控"), systemImage: "waveform.path.ecg").font(.headline)
          Spacer()
          if refreshing { ProgressView().controlSize(.small) }
          Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel(tr("刷新"))
        }
        if let error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
        MonitorDashboard(snapshot: snapshot, host: session.host, history: history)
        if let updated { Text(tr("更新于") + " " + updated.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary) }
      }.padding(16).frame(maxWidth: 1000).frame(maxWidth: .infinity)
    }.background(Color(uiColor: .systemGroupedBackground))
    .task(id: "\(phase)-\(revision)-\(session.connected)-\(session.execReady)-\(session.filesReady)") {
      guard phase == .active else { return }
      while !Task.isCancelled {
        guard session.connected else { error = tr("请先连接服务器"); return }
        refreshing = true
        do {
          let info = try await model.files(session, ["action":"systemInfo"])
          let value: JSON
          if info.text("platform") == "windows" {
            value = try await model.files(session, ["action":"systemMonitor","operation":"overview"])
          } else {
            guard let url=Bundle.main.url(forResource:"monitor",withExtension:"sh") else { throw MobileError(message:tr("无法获取监控数据")) }
            let response=try await model.exec(session,command:String(contentsOf:url,encoding:.utf8))
            guard response.number("code")==0 else { throw MobileError(message:response.text("stderr")) }
            value=try parser.parse(response.text("stdout"))
          }
          try Task.checkCancellation()
          snapshot=value;error=nil;updated=Date()
          if let cpu=value.metric("cpuUsage"), value["cpuReady"] as? Bool != false { history.append(cpu);history=Array(history.suffix(60)) }
        } catch is CancellationError { refreshing=false;return }
        catch { self.error=error.localizedDescription }
        refreshing=false
        do { try await Task.sleep(for:.seconds(error == nil ? 3 : 10)) } catch { return }
      }
    }
  }
}

struct MonitorDashboard: View {
  let snapshot: JSON
  let host: JSON
  let history: [Double]
  private var cpu: Double? { snapshot["cpuReady"] as? Bool == false ? nil : snapshot.metric("cpuUsage") }
  private var memory: Double? { guard let t=snapshot.metric("memoryTotal"), t>0,let u=snapshot.metric("memoryUsed") else { return nil };return u*100/t }
  private var disk: JSON { snapshot.array("disks").first ?? [:] }
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      card {
        HStack(alignment:.top) {
          Image(systemName: "server.rack").font(.largeTitle).foregroundStyle(.cyan).padding(6)
          VStack(alignment:.leading,spacing:8) {
            Text(host.text("hostname")).font(.headline).foregroundStyle(.cyan)
            Text(host.text("username") + " · " + snapshot.text("os","--")).font(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength:4)
          VStack(alignment:.trailing,spacing:6) { Text(tr("运行时间")).font(.caption).foregroundStyle(.secondary);Text(snapshot.text("uptime","--")).font(.caption.bold()).foregroundStyle(.green) }
        }
      }
      LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:12) {
        metric("CPU",icon:"cpu",color:.cyan,value:monitorPercent(cpu),percent:cpu,detail:tr("用户")+" "+monitorPercent(snapshot.metric("cpuUserUsage"))+" · "+tr("系统")+" "+monitorPercent(snapshot.metric("cpuSystemUsage")))
        metric(tr("内存"),icon:"memorychip",color:.purple,value:monitorPercent(memory),percent:memory,detail:monitorBytes(snapshot.metric("memoryUsed"))+" / "+monitorBytes(snapshot.metric("memoryTotal")))
        metric(tr("磁盘"),icon:"externaldrive",color:.orange,value:monitorPercent(disk.metric("percent")),percent:disk.metric("percent"),detail:monitorBytes(disk.metric("used"))+" / "+monitorBytes(disk.metric("total")))
        metric(tr("网络"),icon:"wifi",color:.green,value:monitorBytes(snapshot.metric("networkRxPerSecond"))+"/s",percent:nil,detail:"↑ "+monitorBytes(snapshot.metric("networkTxPerSecond"))+"/s")
      }
      card {
        VStack(alignment:.leading,spacing:12) {
          Label(tr("CPU 负载趋势"),systemImage:"waveform.path.ecg").font(.subheadline.bold())
          Canvas { context,size in
            for i in 0...4 { var line=Path();let y=size.height*CGFloat(i)/4;line.move(to:CGPoint(x:0,y:y));line.addLine(to:CGPoint(x:size.width,y:y));context.stroke(line,with:.color(.secondary.opacity(0.2)),lineWidth:1) }
            if history.count>1 { var line=Path();for (i,v) in history.enumerated(){let p=CGPoint(x:size.width*CGFloat(i)/CGFloat(max(1,history.count-1)),y:size.height*(1-CGFloat(min(100,max(0,v)))/100));if i==0{line.move(to:p)}else{line.addLine(to:p)}};context.stroke(line,with:.color(.cyan),style:StrokeStyle(lineWidth:2.5,lineJoin:.round)) }
          }.frame(height:130).accessibilityLabel(tr("CPU 负载趋势"))
          HStack { Text("0–100%");Spacer();Text(history.isEmpty ? tr("等待采样") : tr("每 3 秒更新")) }.font(.caption2).foregroundStyle(.secondary)
        }
      }
      section(tr("磁盘分区"),icon:"externaldrive",color:.orange)
      if snapshot.array("disks").isEmpty { empty }
      ForEach(Array(snapshot.array("disks").enumerated()),id:\.offset) { _,r in card {
        VStack(spacing:10){HStack{Text(r.text("mount")).font(.subheadline);Spacer();Text(monitorBytes(r.metric("used"))+" / "+monitorBytes(r.metric("total"))).font(.caption).foregroundStyle(.secondary)};ProgressView(value:min(100,max(0,r.metric("percent") ?? 0)),total:100).tint(.orange)}
      }}
      section(tr("网络接口"),icon:"network",color:.green)
      if snapshot.array("networkInterfaces").isEmpty { empty }
      ForEach(Array(snapshot.array("networkInterfaces").enumerated()),id:\.offset) { _,r in card {
        HStack{Text(r.text("name")).font(.subheadline);Spacer();VStack(alignment:.trailing,spacing:5){Text("↓ "+monitorBytes(r.metric("rxPerSecond"))+"/s").foregroundStyle(.green);Text("↑ "+monitorBytes(r.metric("txPerSecond"))+"/s").foregroundStyle(.blue)}.font(.caption.monospacedDigit())}
      }}
      LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:12) {
        ForEach([("loadAverage","负载"),("os","系统"),("kernel","内核"),("swap","交换分区")],id:\.0) { key,title in card { VStack(alignment:.leading,spacing:8){Text(tr(title)).font(.caption).foregroundStyle(.secondary);Text(snapshot.text(key,"--")).font(.caption).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)} } }
      }
      section(tr("内存占用最高进程"),icon:"memorychip",color:.pink)
      ForEach(Array(snapshot.array("topMemoryProcesses").enumerated()),id:\.offset) { _,r in card { VStack(alignment:.leading,spacing:10){HStack{Text(r.text("command")).font(.subheadline).lineLimit(2);Spacer();Text("PID \(r.number("pid"))").font(.caption).foregroundStyle(.secondary)};HStack{Text("MEM").font(.caption2);ProgressView(value:min(100,max(0,r.metric("memoryPercent") ?? 0)),total:100).tint(.purple);Text(monitorPercent(r.metric("memoryPercent"))).font(.caption.monospacedDigit())}} } }
    }.accessibilityIdentifier("monitor-dashboard")
  }
  private var empty: some View { Text(tr("暂无数据")).font(.caption).foregroundStyle(.secondary).padding(.vertical,8) }
  private func section(_ title:String,icon:String,color:Color)->some View { Label(title,systemImage:icon).font(.subheadline.bold()).foregroundStyle(color).padding(.top,4) }
  private func card<Content:View>(@ViewBuilder _ content:()->Content)->some View { content().padding(16).frame(maxWidth:.infinity,alignment:.leading).background(Color(uiColor:.secondarySystemGroupedBackground),in:RoundedRectangle(cornerRadius:18)).overlay(RoundedRectangle(cornerRadius:18).strokeBorder(.secondary.opacity(0.15))) }
  private func metric(_ title:String,icon:String,color:Color,value:String,percent:Double?,detail:String)->some View { card { VStack(alignment:.leading,spacing:12){HStack{Label(title,systemImage:icon).font(.subheadline.bold());Spacer(minLength:2)}.foregroundStyle(color);Text(value).font(.title3.bold()).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1);if let percent { ProgressView(value:min(100,max(0,percent)),total:100).tint(color) };Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2).frame(minHeight:28,alignment:.topLeading)} } }
}
