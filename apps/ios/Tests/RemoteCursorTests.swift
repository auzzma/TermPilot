import SwiftUI
import XCTest
@testable import TermPilot

final class RemoteCursorTests: XCTestCase {
  @MainActor func testWorkspaceModeToggleUpdatesMountedCanvas() async throws {
    let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows).first { $0.isKeyWindow })
    let old = window.rootViewController
    defer { window.rootViewController = old }
    let model = AppModel(); model.keyboardFixtureCommand = { _ in }
    let session = MobileSession(id: 993, host: [:], kind: "rdp", terminal: "")
    let controller = UIHostingController(rootView: WorkspaceView(session: session).environmentObject(model))
    window.rootViewController = controller; window.makeKeyAndVisible()
    func find(_ view: UIView) -> RemoteCanvas? {
      if let canvas = view as? RemoteCanvas { return canvas }
      return view.subviews.compactMap { find($0) }.first
    }
    try await Task.sleep(for: .milliseconds(200))
    let canvas = try XCTUnwrap(find(controller.view))
    XCTAssertTrue(canvas.session === session)
    session.touchpad = true
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertFalse(canvas.cursorView.isHidden)
    XCTAssertEqual(canvas.accessibilityValue, "960, 540")
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
    let shot = XCTAttachment(image: image); shot.name = "mounted-cursor"; shot.lifetime = .keepAlways; add(shot)
    let next = MobileSession(id: 994, host: [:], kind: "screen", terminal: "")
    next.touchpad = true; next.remoteCursorPoint = CGPoint(x: 400, y: 200)
    controller.rootView = WorkspaceView(session: next).environmentObject(model)
    try await Task.sleep(for: .milliseconds(200))
    let replaced = try XCTUnwrap(find(controller.view))
    XCTAssertTrue(replaced.session === next, "A reused SwiftUI view must not retain the previous session's input state")
    XCTAssertEqual(replaced.accessibilityValue, "400, 200")
    XCTAssertNil(canvas.superview)
    XCTAssertTrue(canvas.isPaused)
  }
  @MainActor private func tip(_ canvas: RemoteCanvas) -> CGPoint {
    CGPoint(x: canvas.cursorView.frame.minX + RemoteCursorView.hotspot.x,
            y: canvas.cursorView.frame.minY + RemoteCursorView.hotspot.y)
  }

  @MainActor func testAllModesShowPointerWithoutVideoAndPreserveSessionPosition() async throws {
    for mode in ["rdp", "standardVNC", "highPerformance"] {
      let model = AppModel()
      var commands: [JSON] = []
      model.keyboardFixtureCommand = { commands.append($0) }
      let session = MobileSession(id: 991, host: ["mode": mode], kind: mode == "rdp" ? "rdp" : "screen", terminal: "")
      session.desktopSize = CGSize(width: 1280, height: 720)
      let canvas = RemoteCanvas(session: session, model: model)
      canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
      canvas.layoutIfNeeded()
      XCTAssertTrue(canvas.cursorView.isHidden)
      session.touchpad = true; canvas.updateCursor()
      XCTAssertFalse(canvas.cursorView.isHidden)
      XCTAssertEqual(tip(canvas), CGPoint(x: 200, y: 300))
      XCTAssertFalse(canvas.cursorView.isUserInteractionEnabled)
      XCTAssertTrue(canvas.hitTest(tip(canvas), with: nil) === canvas)
      canvas.sendCursor(CGPoint(x: 960.9, y: 360.4), 1)
      try await Task.sleep(for: .milliseconds(30))
      XCTAssertEqual(commands.last?.number("x"), 960)
      XCTAssertEqual(commands.last?.number("y"), 360)
      XCTAssertEqual(commands.last?.number("buttons"), 1)
      XCTAssertEqual(tip(canvas), CGPoint(x: 300, y: 300), "Arrow tip matches transmitted integer pixel")
      let recreated = RemoteCanvas(session: session, model: model)
      recreated.frame = canvas.frame; recreated.layoutIfNeeded()
      XCTAssertEqual(tip(recreated), tip(canvas))
      XCTAssertEqual(session.videoDiagnostics.receivedFrames, 0)
      XCTAssertEqual(session.videoDiagnostics.renderedFrames, 0, "Local pointer movement is not a received video frame")
      session.touchpad = false; canvas.updateCursor()
      XCTAssertTrue(canvas.cursorView.isHidden)
      session.touchpad = true; session.isClosing = true; canvas.updateCursor()
      XCTAssertTrue(canvas.cursorView.isHidden)
      XCTAssertNil(model.error)
    }
  }

  @MainActor func testHotspotTracksZoomPanRotationClampingAndDirectInput() async throws {
    let model = AppModel()
    var commands: [JSON] = []
    model.keyboardFixtureCommand = { commands.append($0) }
    let session = MobileSession(id: 992, host: [:], kind: "rdp", terminal: "")
    session.desktopSize = CGSize(width: 1280, height: 720); session.touchpad = true
    let canvas = RemoteCanvas(session: session, model: model)
    canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
    canvas.sendCursor(CGPoint(x: 800, y: 400), 0)
    canvas.setViewport(zoom: 2, offset: CGPoint(x: -20, y: 30))
    XCTAssertEqual(tip(canvas), CGPoint(x: 280, y: 355))
    canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 400)
    canvas.layoutIfNeeded()
    XCTAssertEqual(tip(canvas).x, 557.7777778, accuracy: 0.001)
    XCTAssertEqual(tip(canvas).y, 274.4444444, accuracy: 0.001)
    canvas.setViewport(zoom: 1, offset: .zero)
    canvas.sendCursor(CGPoint(x: -100, y: 900), 0)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(commands.last?.number("x"), 0)
    XCTAssertEqual(commands.last?.number("y"), 719)
    XCTAssertEqual(tip(canvas).x, 44.4444444, accuracy: 0.001)
    XCTAssertEqual(tip(canvas).y, 399.4444444, accuracy: 0.001)
    session.touchpad = false
    canvas.move(CGPoint(x: 400, y: 200), 0)
    session.touchpad = true; canvas.updateCursor()
    XCTAssertEqual(tip(canvas), CGPoint(x: 400, y: 200))
    session.desktopSize = CGSize(width: 320, height: 200)
    canvas.updateCursor()
    XCTAssertEqual(session.remoteCursorPoint, CGPoint(x: 319, y: 199))
    XCTAssertEqual(session.videoDiagnostics.renderedFrames, 0)
  }
}
