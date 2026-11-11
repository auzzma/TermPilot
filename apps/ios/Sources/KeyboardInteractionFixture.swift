#if DEBUG
import SwiftUI

/// UI-test-only workspace. No vault or network runtime is opened. Any accidental
/// remote input from a dismissal tap is visible as an error for the test.
struct KeyboardInteractionFixture: View {
  @StateObject private var model = AppModel()
  @StateObject private var session: MobileSession
  init(kind: String) {
    _session = StateObject(wrappedValue: {
      let session = MobileSession(id: 990,
        host: ["label": "Keyboard UI test", "mode": kind],
        kind: ["ssh", "rdp"].contains(kind) ? kind : "screen", terminal: "")
      session.terminalView.getTerminal().setCursorStyle(.steadyBlock)
      session.terminalView.cursorStyleChanged(source: session.terminalView.getTerminal(), newStyle: .steadyBlock)
      session.terminalView.feed(text: "\u{1b}[?25l")
      if ProcessInfo.processInfo.environment["TERMPILOT_VIDEO_UI_FIXTURE"] == "1", kind == "highPerformance" {
        let data = Data(#"{"videoCodec":"H.264","videoPackets":1234,"decodeErrors":40,"audioDecodeErrors":0,"lastVideoDecodeError":-1009,"frames":21,"dropped":3,"decodeMicros":15000,"decodeCalls":3}"#.utf8)
        session.videoDiagnostics.media = try? JSONDecoder().decode(RemoteMediaDiagnostics.self, from: data)
      }
      return session
    }())
  }
  var body: some View {
    VStack(spacing: 0) {
      WorkspaceView(session: session).environmentObject(model)
    }.overlay(alignment: .topTrailing) {
      if let error = model.error { Text(error).accessibilityIdentifier("keyboard-fixture-error") }
    }
    .task {
      try? await Task.sleep(for: .milliseconds(100))
      session.terminalView.getTerminal().setCursorStyle(.steadyBlock)
      session.terminalView.cursorStyleChanged(source: session.terminalView.getTerminal(), newStyle: .steadyBlock)
      session.terminalView.feed(text: "\u{1b}[?25l")
      model.keyboardFixtureCommand = { command in
        if command.text("kind") == "pointer", command.number("buttons") != 0,
           ProcessInfo.processInfo.environment["TERMPILOT_CURSOR_UI_FIXTURE"] != "1" {
          model.error = "Unexpected remote mouse-down"
        }
      }
    }
  }
}
#endif
