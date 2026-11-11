import XCTest

final class InterfaceTests: XCTestCase {
  func testHostEditorsAfterFailedQuickConnection() {
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = XCUIApplication()
    app.launchArguments = ["-TermPilot.language", "zh-Hans", "-TermPilot.theme", "dark"]
    app.launch()
    XCTAssertTrue(app.buttons["home-quick"].waitForExistence(timeout: 15))
    app.buttons["home-quick"].tap()
    let address = app.textFields["IP 地址 / 主机名"]
    XCTAssertTrue(address.waitForExistence(timeout: 5))
    address.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
    address.typeText("127.0.0.1\n")
    app.navigationBars["快速连接"].buttons["连接"].tap()
    attach("after-quick-connect", app)
    XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 15))
    app.alerts.buttons["好"].tap()
    app.buttons["session-back"].tap()
    XCTAssertTrue(app.buttons["home-quick"].waitForExistence(timeout: 5))
    app.buttons["home-quick"].tap()
    XCTAssertTrue(app.navigationBars["快速连接"].waitForExistence(timeout: 5))
    app.buttons["取消"].tap()
    app.buttons["新增主机"].tap()
    XCTAssertTrue(app.textFields["名称"].waitForExistence(timeout: 5))
    app.buttons["取消"].tap()
    let edit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "编辑 ")).firstMatch
    if edit.exists {
      edit.tap()
      XCTAssertTrue(app.textFields["名称"].waitForExistence(timeout: 5))
      app.buttons["取消"].tap()
    }
  }
  func testHostEditorsOnIPad() {
    let app = XCUIApplication()
    app.launchArguments = ["-TermPilot.language", "zh-Hans", "-TermPilot.theme", "dark"]
    app.launch()
    XCTAssertTrue(app.buttons["home-quick"].waitForExistence(timeout: 15))
    app.buttons["home-quick"].tap()
    XCTAssertTrue(app.navigationBars["快速连接"].waitForExistence(timeout: 5))
    app.buttons["取消"].tap()
    app.buttons["新增主机"].tap()
    XCTAssertTrue(app.textFields["名称"].waitForExistence(timeout: 5))
    app.buttons["取消"].tap()
    let edit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "编辑 ")).firstMatch
    if edit.exists {
      edit.tap()
      XCTAssertTrue(app.textFields["名称"].waitForExistence(timeout: 5))
      app.buttons["取消"].tap()
    }
    attach("ipad-host-editors", app)
  }
  func testAISettingsPages() {
    let app = launchChineseApp()
    app.buttons["settings-ai"].tap()
    XCTAssertTrue(app.navigationBars["AI 设置"].waitForExistence(timeout: 15))
    attach("ai-settings", app)
    app.buttons["行为与安全"].tap()
    XCTAssertTrue(app.staticTexts["命令黑名单 · 每行一条正则表达式"].exists)
    attach("ai-safety", app)
    app.navigationBars["行为与安全"].buttons.firstMatch.tap()
    app.buttons["网络搜索"].tap()
    XCTAssertTrue(app.switches["启用网络搜索"].exists)
    app.navigationBars["网络搜索"].buttons.firstMatch.tap()
    app.buttons["提供商"].tap()
    app.buttons["新增提供商"].tap()
    XCTAssertTrue(app.textFields["Base URL"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.textFields["默认模型"].exists)
    attach("provider", app)
    app.buttons["取消"].tap()
  }
  func testVideoCodecOptions() {
    let app = launchChineseApp()
    app.buttons["settings-general"].tap()
    app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@", "终端")).firstMatch.tap()
    app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@", "Apple 高性能视频编码")).firstMatch.tap()
    XCTAssertTrue(app.buttons["H.264"].exists)
    app.buttons["H.265"].tap()
    attach("video-codec-h265", app)
    app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@", "Apple 高性能视频编码")).firstMatch.tap()
    app.buttons["H.264"].tap()
  }
  func testGeneralPagesAndTheme() {
    let app = launchChineseApp()
    attach("settings-dark", app)
    app.buttons["settings-general"].tap()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "外观")).firstMatch.tap()
    app.buttons["浅色"].tap()
    attach("appearance-light", app)
    app.buttons["深色"].tap()
    app.navigationBars["外观"].buttons.firstMatch.tap()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "终端")).firstMatch.tap()
    app.buttons["快捷键栏"].tap()
    XCTAssertTrue(app.staticTexts["Esc"].exists)
    attach("shortcuts", app)
  }
  func testQuickConnectProtocolsAndHome() {
    let app = launchChineseApp()
    app.buttons["主机"].firstMatch.tap()
    attach("hosts", app)
    app.buttons["home-quick"].tap()
    XCTAssertTrue(app.navigationBars["快速连接"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["名称"].exists)
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "连接类型")).firstMatch.tap()
    app.buttons["RDP"].tap()
    XCTAssertEqual(app.textFields["端口"].value as? String, "3389")
    attach("quick-connect-rdp", app)
    app.buttons["取消"].tap()
    app.buttons["新增主机"].tap()
    XCTAssertTrue(app.textFields["名称"].waitForExistence(timeout: 5))
    attach("add-host", app)
    app.buttons["取消"].tap()
  }
  func testLanguageSwitchRebuildsSettings() {
    let app = XCUIApplication()
    app.launchArguments = ["-TermPilot.theme", "dark"]
    app.launch()
    let settings = app.buttons["gearshape"].firstMatch
    XCTAssertTrue(settings.waitForExistence(timeout: 15))
    settings.tap()
    app.buttons["settings-general"].tap()
    app.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "语言", "Language")
    ).firstMatch.tap()
    app.buttons["English"].tap()
    XCTAssertTrue(app.buttons["settings-general"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Settings"].firstMatch.exists)
    attach("settings-english", app)
    app.buttons["settings-general"].tap()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Language")).firstMatch.tap()
    app.buttons["简体中文"].tap()
    XCTAssertTrue(app.buttons["settings-general"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["设置"].firstMatch.exists)
  }
  func testDataSyncProviderForm() {
    let app=launchChineseApp()
    let sync=app.buttons.matching(NSPredicate(format:"label CONTAINS %@", "数据同步")).firstMatch
    if !sync.isHittable {app.swipeUp()}
    XCTAssertTrue(sync.waitForExistence(timeout:5));sync.tap()
    XCTAssertTrue(app.staticTexts["同步库"].firstMatch.waitForExistence(timeout:10))
    XCTAssertTrue(app.secureTextFields["同步口令（至少 12 个字符）"].exists)
    app.buttons.matching(NSPredicate(format:"label CONTAINS %@", "WebDAV")).firstMatch.tap()
    app.buttons["Cloudflare R2"].firstMatch.tap()
    XCTAssertTrue(app.textFields["R2 S3 API Endpoint"].waitForExistence(timeout:5))
    XCTAssertFalse(app.textFields["Region"].exists)
    attach("data-sync-r2",app)
    app.buttons.matching(NSPredicate(format:"label CONTAINS %@", "Cloudflare R2")).firstMatch.tap()
    app.buttons["S3 / S3 Compatible"].firstMatch.tap()
    XCTAssertTrue(app.textFields["Region"].waitForExistence(timeout:5))
    attach("data-sync-form",app)
  }
  private func launchChineseApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-TermPilot.language", "zh-Hans", "-TermPilot.theme", "dark"]
    app.launch()
    XCTAssertTrue(app.buttons["设置"].firstMatch.waitForExistence(timeout: 15))
    app.buttons["设置"].firstMatch.tap()
    XCTAssertTrue(app.buttons["settings-general"].waitForExistence(timeout: 5))
    return app
  }
  private func attach(_ name: String, _ app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
