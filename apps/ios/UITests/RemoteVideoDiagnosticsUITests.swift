import XCTest
final class RemoteVideoDiagnosticsUITests: XCTestCase {
  func testAllModesOpenDiagnosticsBeforeAnyVideoAndReturnToSession() {
    for kind in ["rdp", "standardVNC", "highPerformance"] {
      let app = XCUIApplication()
      app.launchEnvironment["TERMPILOT_KEYBOARD_UI_FIXTURE"] = kind
      app.launchEnvironment["TERMPILOT_VIDEO_UI_FIXTURE"] = "1"
      app.launchArguments = ["-TermPilot.language", "zh-Hans", "-TermPilot.theme", kind == "standardVNC" ? "light" : "dark"]
      app.launch()
      let stats = app.buttons["remote-video-stats"]
      XCTAssertTrue(stats.waitForExistence(timeout: 10))
      stats.tap()
      let report = app.staticTexts["remote-video-report"]
      XCTAssertTrue(report.waitForExistence(timeout: 5))
      XCTAssertTrue(report.label.contains("接收画面: 0"))
      XCTAssertEqual(report.label.contains("Video packets: 1234"), kind == "highPerformance")
      XCTAssertTrue(app.buttons["remote-video-copy"].exists)
      app.buttons["remote-video-copy"].tap()
      let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "video-diagnostics-\(kind)"; shot.lifetime = .keepAlways; add(shot)
      app.buttons["remote-video-done"].tap()
      XCTAssertTrue(stats.waitForExistence(timeout: 5))
      XCTAssertFalse(app.staticTexts["keyboard-fixture-error"].exists)
      app.terminate()
    }
  }
}
