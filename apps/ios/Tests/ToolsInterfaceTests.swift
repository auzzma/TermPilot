import XCTest
import SwiftUI
@testable import TermPilot

final class ToolsInterfaceTests: XCTestCase {
  func testLargeControlPacketAndTruncatedPacket() throws {
    let output=String(repeating:"process 中文\n",count:10000)
    let json=try JSONSerialization.data(withJSONObject:["type":"sftpResponse","stdout":output])
    var count=UInt32(json.count).bigEndian
    var bytes=withUnsafeBytes(of:&count) { Data($0) };bytes.append(json);bytes.append(Data([1,2]))
    XCTAssertEqual(try MobilePacket.decode(bytes).header.text("stdout"),output)
    XCTAssertEqual(try MobilePacket.decode(bytes).data,Data([1,2]))
    XCTAssertThrowsError(try MobilePacket.decode(bytes.prefix(100)))
  }
  func testCounterDeltasResetAndProcessNames() throws {
    var parser=MonitorParser()
    func sample(_ t:Int,_ cpu:String,_ rx:Int,_ tx:Int)->String { "SAMPLE_TIME=\(t)\nMEM_TOTAL_MB=1024\nMEM_USED_MB=256\nCPU_RAW=\(cpu)\nNETIF_BYTES=eth0|\(rx)|\(tx)\nDISK=/|4|20|20\nTOPPROC=7|25|my process" }
    let first=try parser.parse(sample(100,"1000|700|200|100",1000,2000))
    XCTAssertNil(first.metric("cpuUsage"));XCTAssertNil(first.metric("networkRxPerSecond"))
    let next=try parser.parse(sample(103,"1300|880|290|130",4072,3536))
    XCTAssertEqual(try XCTUnwrap(next.metric("cpuUsage")),40,accuracy:0.001)
    XCTAssertEqual(try XCTUnwrap(next.metric("cpuUserUsage")),30,accuracy:0.001)
    XCTAssertEqual(try XCTUnwrap(next.metric("networkRxPerSecond")),1024,accuracy:0.001)
    XCTAssertEqual(try XCTUnwrap(next.metric("networkTxPerSecond")),512,accuracy:0.001)
    XCTAssertEqual(try XCTUnwrap(next.metric("memoryUsed")),268435456,accuracy:0.001)
    let reset=try parser.parse(sample(106,"100|70|20|10",10,20))
    XCTAssertNil(reset.metric("cpuUsage"));XCTAssertNil(reset.metric("networkRxPerSecond"))
    XCTAssertEqual(MonitorParser.processes(" 42 root 1.2 3.4 1024 /path/My App").first?.text("command"),"/path/My App")
    XCTAssertThrowsError(try parser.parse("not a monitor response"))
  }
  @MainActor func testLiveMonitoringToolsAndFullScreenEditor() async throws {
    let fixture=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("mobile-fixture.json")
    guard FileManager.default.fileExists(atPath:fixture.path) else { throw XCTSkip("No authorized fixture") }
    defer { try? FileManager.default.removeItem(at:fixture) }
    let source=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as? JSON)
    var host=try LiveTestFixture.host(source, role: "tools")
    host["connectionKind"]="ssh";host["label"]="工具界面验收"
    let model=AppModel();await model.start();XCTAssertTrue(model.ready)
    let known=model.runtime!.directory.appendingPathComponent("known_hosts");let old=try? Data(contentsOf:known)
    defer { if let old { try? old.write(to:known) } else { try? FileManager.default.removeItem(at:known) };model.runtime?.stop() }
    try Data(source.text("knownHosts").utf8).write(to:known)
    try await model.connect(host);let s=try XCTUnwrap(model.current)
    let until=Date().addingTimeInterval(45)
    while (!s.filesReady || !s.execReady) && Date()<until { try await Task.sleep(for:.milliseconds(30)) }
    XCTAssertTrue(s.filesReady && s.execReady)
    var root=""
    let window=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow })
    let originalController=window.rootViewController
    defer { window.rootViewController=originalController }
    func display<V:View>(_ view:V) async throws {
      window.rootViewController=UIHostingController(rootView:view.environmentObject(model).environment(\.scenePhase,.active))
      window.makeKeyAndVisible();try await Task.sleep(for:.milliseconds(700));window.layoutIfNeeded()
    }
    func shot(_ name:String) {
      let image=UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
      let a=XCTAttachment(image:image);a.name=name;a.lifetime = .keepAlways;add(a)
    }
    do {
      let script=try String(contentsOf:try XCTUnwrap(Bundle.main.url(forResource:"monitor",withExtension:"sh")),encoding:.utf8)
      var parser=MonitorParser();var snapshot:JSON=[:];var history:[Double]=[]
      for _ in 0..<2 {
        let result=try await model.exec(s,command:script);XCTAssertEqual(result.number("code"),0,result.text("stderr"))
        snapshot=try parser.parse(result.text("stdout"));XCTAssertGreaterThan(try XCTUnwrap(snapshot.metric("memoryTotal")),0)
        if let cpu=snapshot.metric("cpuUsage") { history.append(cpu) }
        try await Task.sleep(for:.seconds(1))
      }
      XCTAssertNotNil(snapshot.metric("networkRxPerSecond"))
      s.activePanel="tools"
      for scheme in [ColorScheme.dark,.light] {
        try await display(WorkspaceView(session:s).preferredColorScheme(scheme))
        try await Task.sleep(for:.seconds(6));shot("tools-monitor-\(scheme)")
      }
      s.selectedTool="processes";try await Task.sleep(for:.seconds(3));shot("tools-processes")
      root=try await model.files(s,["action":"realpath","path":"."]).text("path")+"/TermPilot-tools-\(UUID().uuidString)"
      _ = try await model.files(s,["action":"mkdir","path":root])
      let file=root+"/editor-中文.txt"
      _ = try await model.files(s,["action":"writeText","path":file,"content":"original\n","overwrite":false])
      try await model.list(s,path:root);s.selectedTool="files"
      try await Task.sleep(for:.milliseconds(500));shot("tools-files")
      let edit=FileEdit(operation:"writeText",path:file)
      // Exercise the same fullScreenCover presentation as FilesView, including iPad.
      try await display(EditorPresentation(session:s,edit:edit).preferredColorScheme(.dark))
      try await Task.sleep(for:.seconds(2))
      func descendants(_ v:UIView)->[UIView] { [v]+v.subviews.flatMap { descendants($0) } }
      let editor=try XCTUnwrap(descendants(window).compactMap { $0 as? UITextView }.first { $0.text=="original\n" })
      XCTAssertGreaterThan(editor.bounds.height,window.bounds.height * 0.55)
      XCTAssertGreaterThan(editor.bounds.width,window.bounds.width * 0.8)
      shot("editor-fullscreen")
      editor.becomeFirstResponder();try await Task.sleep(for:.milliseconds(600))
      XCTAssertGreaterThan(editor.bounds.height,100)
      shot("editor-keyboard")
      editor.resignFirstResponder()
      _ = try await model.files(s,["action":"delete","path":root]);root=""
      try await model.close(s)
    } catch {
      if !root.isEmpty { _ = try? await model.files(s,["action":"delete","path":root]) }
      try? await model.close(s);throw error
    }
  }
}
private struct EditorPresentation: View {
  @ObservedObject var session: MobileSession
  let edit: FileEdit
  @State private var presented=false
  var body: some View { Color.clear.onAppear { presented=true }.fullScreenCover(isPresented:$presented) { FileEditor(session:session,edit:edit) } }
}
