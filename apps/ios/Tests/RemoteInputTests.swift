import SwiftUI
import XCTest
@testable import TermPilot

final class RemoteInputTests: XCTestCase {
  @MainActor private func window() throws -> UIWindow {
    try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows).first { $0.isKeyWindow })
  }
  @MainActor private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { descendants($0) }
  }
  @MainActor private func waitForUI(
    _ message: String, file: StaticString = #filePath, line: UInt = #line,
    until condition: @MainActor () -> Bool
  ) async throws {
    // SwiftUI updates and UIKit focus changes span separate main-run-loop turns.
    // Observe completion instead of assuming a loaded simulator finishes in 150 ms.
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    _ = try XCTUnwrap(condition() ? true : nil, message, file: file, line: line)
  }
  @MainActor func testCommittedIMETextReturnAndBackspaceGoDirectlyToRemote() async throws {
    let window = try window(), original = window.rootViewController
    defer { window.rootViewController = original }
    let controller = UIViewController()
    window.rootViewController = controller
    let input = RemoteKeyboard.InputView()
    controller.view.addSubview(input)
    input.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    var text: [String] = [], keys: [Int] = []
    input.sendText = { text.append($0) }; input.sendKey = { keys.append($0) }
    input.setRequested(true)
    window.makeKeyAndVisible()
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertTrue(input.isFirstResponder)
    input.insertText("abc123")
    XCTAssertEqual(text, ["abc123"])
    XCTAssertTrue(input.text.isEmpty)
    input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
    input.textViewDidChange(input)
    XCTAssertEqual(text, ["abc123"], "Do not transmit unfinished pinyin")
    input.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0))
    input.unmarkText()
    XCTAssertEqual(text, ["abc123", "你"])
    input.insertText("\n"); input.insertText("\t"); input.deleteBackward()
    XCTAssertEqual(keys, [0xff0d, 0xff09, 0xff08])
    input.setMarkedText("unfinished", selectedRange: NSRange(location: 10, length: 0))
    input.hideKeyboard()
    XCTAssertEqual(text, ["abc123", "你"], "Hiding the keyboard must not submit a composition")
    XCTAssertFalse(input.isFirstResponder)
  }

  @MainActor func testRemoteKeyboardOutsideTapAndSystemDismissWithoutAccessoryOrModal() async throws {
    let window = try window(), original = window.rootViewController
    defer { window.rootViewController = original }
    for (kind, mode) in [("rdp", ""), ("screen", "standardVNC"), ("screen", "highPerformance")] {
      let model = AppModel()
      let session = MobileSession(id: 900, host: ["label": "Remote UI fixture", "mode": mode], kind: kind, terminal: "")
      defer { session.dismissKeyboard() }
      let context = "\(kind)/\(mode)"
      let root = UIHostingController(rootView: WorkspaceView(session: session).environmentObject(model).environment(\.locale, Locale(identifier: "zh-Hans")).preferredColorScheme(.dark))
      window.rootViewController = root; window.makeKeyAndVisible()
      try await waitForUI("\(context): remote input and canvas must be mounted") {
        let views = self.descendants(root.view)
        return views.contains { $0 is RemoteKeyboard.InputView && $0.window === window }
          && views.contains { $0 is RemoteCanvas && $0.window === window && !$0.bounds.isEmpty }
      }
      let input = try XCTUnwrap(descendants(root.view).compactMap { $0 as? RemoteKeyboard.InputView }.first)
      let canvas = try XCTUnwrap(descendants(root.view).compactMap { $0 as? RemoteCanvas }.first)
      XCTAssertTrue(canvas.isUserInteractionEnabled, "The Metal desktop must receive touch and keyboard-dismiss gestures")
      XCTAssertNotNil(canvas.hitTest(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), with: nil))
      XCTAssertFalse(input.isFirstResponder)
      XCTAssertFalse(session.keyboardVisible)
      session.keyboardVisible = true
      try await waitForUI("\(context): keyboard must open") { input.isFirstResponder }
      XCTAssertTrue(input.isFirstResponder)
      XCTAssertNil(root.presentedViewController, "Keyboard must not present an input sheet")
      XCTAssertLessThanOrEqual(input.bounds.height, 1)
      if kind == "rdp" {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let shot = XCTAttachment(image: image); shot.name = "rdp-inline-keyboard"; shot.lifetime = .keepAlways; add(shot)
      }
      XCTAssertNil(input.inputAccessoryView, "Remote modes must not show a redundant dismiss button")
      var sent: [String] = []
      input.sendText = { sent.append($0) }
      input.setMarkedText("unfinished", selectedRange: NSRange(location: 10, length: 0))
      session.dismissKeyboard()
      XCTAssertTrue(sent.isEmpty, "Tapping outside must not commit unfinished composition")
      XCTAssertFalse(session.keyboardVisible); XCTAssertFalse(input.isFirstResponder)
      try await Task.sleep(for: .milliseconds(200))
      XCTAssertFalse(input.isFirstResponder, "Dismissal must not reopen keyboard on the next SwiftUI update")
      session.keyboardVisible = true
      try await waitForUI("\(context): keyboard must reopen after outside dismissal") { input.isFirstResponder }
      XCTAssertTrue(input.isFirstResponder, "Keyboard must reopen after dismissing")
      input.resignFirstResponder()
      XCTAssertFalse(session.keyboardVisible, "System dismissal must update the toggle")
      session.keyboardVisible = true
      try await waitForUI("\(context): keyboard must reopen after system dismissal") { input.isFirstResponder }
      XCTAssertTrue(input.isFirstResponder, "Verify focus before testing the next dismissal")
      session.keyboardVisible = false
      try await waitForUI("\(context): clearing the toggle must close the keyboard") { !input.isFirstResponder }
      XCTAssertFalse(input.isFirstResponder, "Second tap on keyboard must close it")
      XCTAssertNil(model.error)
    }
  }

  @MainActor func testSSHHideAndOutsideTapDismissInsteadOfOpeningFunctionKeyboard() async throws {
    let window = try window(), original = window.rootViewController
    defer { window.rootViewController = original }
    let session = MobileSession(id: 901, host: [:], kind: "ssh", terminal: "")
    let root = UIHostingController(rootView: WorkspaceView(session: session).environmentObject(AppModel()))
    window.rootViewController = root; window.makeKeyAndVisible()
    try await Task.sleep(for: .milliseconds(200))
    let terminal = session.terminalView
    XCTAssertTrue(terminal.window === window, "Toolbar actions must address the terminal mounted in this workspace")
    let accessory = try XCTUnwrap(terminal.inputAccessoryView as? TerminalKeyboardAccessory)
    let hide = try XCTUnwrap(accessory.items?.last)
    session.toggleKeyboard()
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertTrue(terminal.isFirstResponder)
    XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(hide.action), to: hide.target, from: hide, for: nil))
    XCTAssertFalse(terminal.isFirstResponder)
    XCTAssertNil(terminal.inputView, "Hide must not switch to SwiftTerm's function-key panel")
    session.toggleKeyboard()
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertTrue(terminal.isFirstResponder)
    XCTAssertTrue(session.keyboardVisible)
    // Also clear a restored legacy alternate input view on dismissal.
    terminal.inputView = UIInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), inputViewStyle: .keyboard)
    terminal.reloadInputViews()
    session.controlKey = true; session.altKey = true
    session.dismissKeyboard()
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertFalse(terminal.isFirstResponder)
    XCTAssertNil(terminal.inputView)
    XCTAssertFalse(session.controlKey); XCTAssertFalse(session.altKey)
    XCTAssertFalse(session.keyboardVisible)
    session.toggleKeyboard()
    XCTAssertTrue(terminal.isFirstResponder)
    XCTAssertNil(terminal.inputView, "Reopening must use the normal software keyboard")
    session.dismissKeyboard()
  }

  @MainActor func testCloseCancelsPendingWorkAndLateInputButKeepsRealErrors() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let runtime = try MobileRuntime(directory: root, testKey: Data(repeating: 92, count: 32))
    defer { runtime.stop(); try? FileManager.default.removeItem(at: root) }
    let model = AppModel(); model.runtime = runtime
    // An idle local AI worker supplies a real channel without opening a network connection.
    let opened = try await runtime.call(["method": "session.open", "protocol": "ai",
      "command": ["id": "init", "method": "initialize", "params": [:]]])
    let id = UInt64(opened.number("session"))
    let s = MobileSession(id: id, host: ["sessionID": UUID().uuidString, "label": "Close fixture"], kind: "rdp", terminal: "")
    model.sessions = [s]; model.selected = id; s.keyboardVisible = true
    let pending = Task { try await model.request(id, ["id": "pending", "method": "settings.get", "params": [:]], id: "pending") }
    await Task.yield()
    try await model.close(s)
    do { _ = try await pending.value; XCTFail("Pending requests must be cancelled") }
    catch is CancellationError { }
    XCTAssertTrue(s.isClosing); XCTAssertFalse(s.keyboardVisible)
    XCTAssertTrue(model.sessions.isEmpty); XCTAssertNil(model.selected)
    try await model.close(s) // Repeated close is harmless.
    do { try await model.send(id, ["kind": "release"]); XCTFail("Late input must be cancelled") }
    catch is CancellationError { }
    let completed = expectation(description: "late view callback")
    model.attempt { defer { completed.fulfill() }; try await model.send(id, ["kind": "release"]) }
    await fulfillment(of: [completed], timeout: 2)
    model.receive(MobilePacket(header: ["session": id, "kind": "error", "message": "Session is closed"], data: Data()))
    XCTAssertNil(model.error)
    let other = MobileSession(id: id + 1000, host: [:], kind: "rdp", terminal: "")
    model.sessions = [other]
    model.receive(MobilePacket(header: ["session": other.id, "kind": "error", "message": "Real connection error"], data: Data()))
    XCTAssertEqual(model.error, "Real connection error")
  }

  @MainActor func testFailedSessionRetainsCauseAndCancelsLateInputAndPrompts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let runtime = try MobileRuntime(directory: root, testKey: Data(repeating: 93, count: 32))
    defer { runtime.stop(); try? FileManager.default.removeItem(at: root) }
    let model = AppModel(); model.runtime = runtime
    let session = MobileSession(id: 90001, host: ["sessionID": UUID().uuidString], kind: "ssh", terminal: "")
    session.connected = true; session.filesReady = true; session.execReady = true
    session.latencyMilliseconds = 42
    model.sessions = [session]; model.selected = session.id
    model.receive(MobilePacket(header: ["session": session.id, "type": "hostKeyPrompt"], data: Data()))
    XCTAssertNotNil(model.interaction)
    model.receive(MobilePacket(header: ["session": session.id, "type": "error", "message": "Connection refused"], data: Data()))
    model.receive(MobilePacket(header: ["session": session.id, "type": "sessionEnded"], data: Data()))
    XCTAssertNil(model.interaction)
    XCTAssertFalse(session.connected); XCTAssertFalse(session.filesReady); XCTAssertFalse(session.execReady)
    XCTAssertNil(session.latencyMilliseconds)
    do { try await model.send(session.id, ["type": "resize", "cols": 100, "rows": 30]); XCTFail("Ended worker must not receive resize") }
    catch is CancellationError { }
    XCTAssertEqual(model.error, "Connection refused")
    // Allow asynchronous history persistence to finish before deleting this test vault.
    try await Task.sleep(for: .milliseconds(200))
  }
}
