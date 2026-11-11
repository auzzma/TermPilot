import XCTest

final class RemoteCursorUITests: XCTestCase {
  func testTouchpadCursorMovesOnStaticDesktopAndSurvivesRotation() {
    defer { XCUIDevice.shared.orientation = .portrait }
    for kind in ["rdp", "standardVNC", "highPerformance"] {
      XCUIDevice.shared.orientation = .portrait
      let app = XCUIApplication()
      app.launchEnvironment["TERMPILOT_KEYBOARD_UI_FIXTURE"] = kind
      app.launchEnvironment["TERMPILOT_CURSOR_UI_FIXTURE"] = "1"
      app.launchArguments = ["-TermPilot.language", "zh-Hans", "-TermPilot.theme", "dark"]
      app.launch()
      let toggle = app.buttons["remote-action-touchpad"]
      XCTAssertTrue(toggle.waitForExistence(timeout: 10))
      let surface = app.descendants(matching: .any).matching(identifier: "remote-desktop-surface").firstMatch
      toggle.tap()
      let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "960, 540"), object: surface)
      XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
      let from = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      let to = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.52))
      from.press(forDuration: 0.05, thenDragTo: to)
      let moved = surface.value as? String
      XCTAssertNotEqual(moved, "960, 540")
      XCTAssertFalse((moved ?? "").isEmpty)
      capture(app, "cursor-\(kind)-portrait")
      XCUIDevice.shared.orientation = .landscapeLeft
      let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
        surface.frame.width > surface.frame.height
      }, object: surface)
      XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
      // The accessibility frame can update before UIKit's rotation animation finishes.
      Thread.sleep(forTimeInterval: 0.6)
      XCTAssertEqual(surface.value as? String, moved, "Rotation must preserve remote pointer position")
      capture(app, "cursor-\(kind)-landscape")
      toggle.tap()
      XCTAssertTrue((surface.value as? String ?? "").isEmpty)
      XCTAssertFalse(app.staticTexts["keyboard-fixture-error"].exists)
      app.terminate()
    }
  }
  private func capture(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name; shot.lifetime = .keepAlways; add(shot)
  }
}
