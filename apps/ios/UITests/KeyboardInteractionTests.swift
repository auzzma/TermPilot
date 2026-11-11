import XCTest

final class KeyboardInteractionTests: XCTestCase {
  func testOutsideTapDismissesSSHWithoutReopeningFunctionKeyboard() {
    let app = launch("ssh")
    let toggle = app.buttons["terminal-keyboard-toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10))
    if !app.keyboards.firstMatch.exists { toggle.tap() }
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["session-keyboard-dismiss-area"].waitForExistence(timeout: 5))
    app.buttons["Ctrl"].firstMatch.tap()
    XCTAssertTrue(app.keyboards.firstMatch.exists, "Shortcuts must keep the keyboard open")
    tapOutsideKeyboard(app)
    assertKeyboardHidden(app)
    toggle.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    app.buttons["terminal-keyboard-dismiss"].tap()
    assertKeyboardHidden(app)
    XCTAssertFalse(app.buttons["F1"].exists, "Hide must not display the alternate function keyboard")
    tapOutsideKeyboard(app)
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "A later terminal tap can open the keyboard again")
    tapOutsideKeyboard(app)
    assertKeyboardHidden(app)
  }

  func testOutsideTapDismissesAllRemoteModesWithoutClickingRemote() {
    for kind in ["rdp", "standardVNC", "highPerformance"] {
      let app = launch(kind)
      let toggle = app.buttons["remote-action-keyboard"]
      XCTAssertTrue(toggle.waitForExistence(timeout: 10))
      toggle.tap()
      XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
      XCTAssertFalse(app.buttons["remote-keyboard-dismiss"].exists)
      XCTAssertFalse(app.buttons["terminal-keyboard-dismiss"].exists)
      tapOutsideKeyboard(app)
      assertKeyboardHidden(app)
      XCTAssertFalse(app.staticTexts["keyboard-fixture-error"].exists, "The dismissal tap must not send a remote pointer command")
      toggle.tap()
      XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
      toggle.tap()
      assertKeyboardHidden(app)
    }
  }

  private func launch(_ kind: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["TERMPILOT_KEYBOARD_UI_FIXTURE"] = kind
    app.launchArguments = ["-TermPilot.language", "zh-Hans", "-TermPilot.theme", "dark"]
    app.launch()
    return app
  }
  private func tapOutsideKeyboard(_ app: XCUIApplication) {
    let dismiss = app.buttons["session-keyboard-dismiss-area"]
    if dismiss.exists { dismiss.tap(); return }
    let remote = app.descendants(matching: .any).matching(identifier: "remote-desktop-surface").firstMatch
    let surface = remote.exists ? remote : app.descendants(matching: .any).matching(identifier: "terminal-surface").firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
  }
  private func assertKeyboardHidden(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
    XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, file: file, line: line)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "outside-tap-keyboard-hidden"; shot.lifetime = .keepAlways; add(shot)
  }
}
