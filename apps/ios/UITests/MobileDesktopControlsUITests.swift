import XCTest
final class MobileDesktopControlsUITests: XCTestCase {
  func testCapabilitiesAndHighPerformanceMenu() {
    for mode in ["unsupported","supported","highPerformance"] {
      let app = XCUIApplication()
      app.launchEnvironment["TERMPILOT_KEYBOARD_UI_FIXTURE"] = mode == "highPerformance" ? mode : "standardVNC"
      app.launchEnvironment["TERMPILOT_DESKTOP_UI_FIXTURE"] = mode
      app.launchArguments = ["-TermPilot.language","zh-Hans","-TermPilot.theme",mode == "supported" ? "light" : "dark"]
      app.launch()
      let bar = app.scrollViews["remote-action-bar"]
      XCTAssertTrue(bar.waitForExistence(timeout:10))
      XCTAssertTrue(app.buttons["remote-action-copy"].exists)
      let login = app.buttons["remote-login-password"], resolution = app.buttons["remote-resolution"]
      for _ in 0..<12 {
        let frame = resolution.frame
        if !frame.isEmpty && bar.frame.contains(frame) { break }
        bar.swipeLeft()
      }
      XCTAssertTrue(login.isHittable); XCTAssertTrue(login.isEnabled); XCTAssertTrue(resolution.isHittable)
      XCTAssertLessThanOrEqual(bar.frame.height,60)
      XCTAssertEqual(login.frame.midY,resolution.frame.midY,accuracy:1)
      XCTAssertEqual(app.buttons["remote-action-audio"].frame.midY,login.frame.midY,accuracy:1)
      XCTAssertLessThan(app.buttons["remote-action-audio"].frame.minX,login.frame.minX)
      XCTAssertLessThan(login.frame.minX,resolution.frame.minX)
      XCTAssertFalse(app.staticTexts["remote-login-status"].exists)
      XCTAssertFalse(app.staticTexts["remote-resolution-status"].exists)
      let row = XCTAttachment(screenshot:app.screenshot()); row.name = "inline-toolbar-\(mode)"; row.lifetime = .keepAlways; add(row)
      resolution.tap()
      let small = app.buttons["1280 × 720"]
      XCTAssertTrue(small.waitForExistence(timeout:5)); XCTAssertEqual(small.isEnabled,mode != "unsupported")
      XCTAssertFalse(app.staticTexts["修改分辨率会重新连接当前会话。"].exists)
      let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = "desktop-controls-\(mode)"; shot.lifetime = .keepAlways; add(shot)
      if mode == "supported" {
        small.tap()
        let updated = XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","1280 × 720"),object:resolution)
        wait(for:[updated],timeout:5)
      }
      app.terminate()
    }
  }
}
