import SwiftUI
import UIKit

struct RemoteVideoStats: View {
  @ObservedObject var session: MobileSession
  @State private var showing = false
  var body: some View {
    Button {
      session.dismissKeyboard()
      showing = true
    } label: {
      HStack {
        Text("\(session.renderedFPS, specifier: "%.1f") FPS")
        Text("\(session.performance.number("receiveBytesPerSecond")/1024) KiB/s ↓")
        Spacer()
        Text("\(session.performance.number("sendBytesPerSecond")/1024) KiB/s ↑")
        Image(systemName: "info.circle")
      }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        .padding(.horizontal).padding(.vertical, 8).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel(tr("画面诊断"))
      .accessibilityIdentifier("remote-video-stats")
      .sheet(isPresented: $showing) {
        NavigationStack {
          TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let report = session.videoDiagnosticsReport()
            ScrollView {
              Text(verbatim: report).font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                .accessibilityIdentifier("remote-video-report")
            }.toolbar {
              ToolbarItem(placement: .topBarLeading) {
                Button(tr("复制")) { UIPasteboard.general.string = report }
                  .accessibilityIdentifier("remote-video-copy")
              }
              ToolbarItem(placement: .topBarTrailing) {
                Button(tr("完成")) { showing = false }.accessibilityIdentifier("remote-video-done")
              }
            }
          }.navigationTitle(tr("画面诊断")).navigationBarTitleDisplayMode(.inline)
        }.presentationDetents([.large])
      }
  }
}

extension MobileSession {
  func videoDiagnosticsReport(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String {
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    let mode = protocolKind == "rdp" ? "RDP" : host.text("mode", "standardVNC") == "highPerformance" ? "Apple High Performance" : "VNC"
    return videoDiagnostics.report(
      platform: "TermPilot · build \(build) · \(UIDevice.current.model) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
      mode: mode, resolution: "\(Int(desktopSize.width)) × \(Int(desktopSize.height))",
      fps: connected ? renderedFPS : 0,
      received: (performance["receiveBytesPerSecond"] as? NSNumber)?.doubleValue,
      sent: (performance["sendBytesPerSecond"] as? NSNumber)?.doubleValue,
      now: now, localize: tr)
  }
}
