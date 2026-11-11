import SwiftUI
import XCTest

@testable import TermPilot

/// Visual regression fixtures contain no live servers or credentials.
final class MobileStyleTests: XCTestCase {
  @MainActor func testTabletToolsKeepTerminalVisible() async throws {
    let model = AppModel()
    let session = MobileSession(
      id: 0, host: ["label": "UI Preview", "hostname": "preview.invalid", "username": "demo"],
      kind: "ssh", terminal: "")
    session.activePanel = "tools"
    let window = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        .first { $0.isKeyWindow })
    guard window.bounds.width >= 760 else { throw XCTSkip("Tablet layout test") }
    let original = window.rootViewController
    defer { window.rootViewController = original }
    window.rootViewController = UIHostingController(
      rootView: WorkspaceView(session: session).environmentObject(model).preferredColorScheme(.dark)
    )
    window.makeKeyAndVisible()
    try await Task.sleep(for: .milliseconds(700))
    window.layoutIfNeeded()
    XCTAssertNotNil(session.terminalView.superview)
    XCTAssertGreaterThan(session.terminalView.bounds.width, 200)
    XCTAssertLessThan(session.terminalView.bounds.width, window.bounds.width * 0.65)
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = "tablet-tools-split"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  @MainActor func testChatAndOverviewInBothThemes() async throws {
    let model = AppModel()
    await model.start()
    defer { model.runtime?.stop() }
    let session = MobileSession(
      id: 0,
      host: [
        "id": "ui-fixture", "hostname": "preview.invalid", "label": "UI Preview",
        "username": "demo",
      ], kind: "settings", terminal: "")
    model.settingsSession = session
    session.conversation = [
      "messages": [
        ["role": "user", "content": "服务器还剩多少磁盘空间？"],
        [
          "role": "assistant", "content": "以下为界面测试示例。",
          "calls": [["name": "terminal_execute", "arguments": ["command": "df -h"]]],
        ],
        ["role": "tool", "content": "Filesystem  Size  Used  Avail\n/dev/vda1   20G   6.8G  13G"],
        [
          "role": "assistant",
          "content":
            "## 磁盘空间\n\n| 分区 | 总容量 | 剩余 |\n| --- | --- | --- |\n| `/` | 20 GB | 13 GB |\n\n可用空间充足。",
        ],
      ]
    ]
    let window = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        .first { $0.isKeyWindow })
    let original = window.rootViewController
    defer { window.rootViewController = original }
    let snapshot: JSON = [
      "cpuUsage": 4.0, "cpuUserUsage": 1.4, "cpuSystemUsage": 2.6, "memoryUsed": 300_000_000.0,
      "memoryTotal": 1_000_000_000.0, "networkRxPerSecond": 7500.0, "networkTxPerSecond": 1700.0,
      "uptime": "12d 11h", "os": "Debian 12",
      "disks": [
        ["mount": "/", "used": 6_800_000_000.0, "total": 20_000_000_000.0, "percent": 34.0]
      ],
    ]
    for scheme in [ColorScheme.dark, .light] {
      for (name, view) in [
        ("chat", AnyView(AIView(session: session))),
        (
          "overview-preserved",
          AnyView(
            ScrollView {
              MonitorDashboard(
                snapshot: snapshot, host: session.host, history: [4, 6, 3, 5, 4, 7, 4]
              ).padding(16)
            }.background(Color(uiColor: .systemGroupedBackground)))
        ),
      ] {
        window.rootViewController = UIHostingController(
          rootView: view.environmentObject(model).preferredColorScheme(scheme))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(1000))
        window.layoutIfNeeded()
        XCTAssertGreaterThan(window.rootViewController!.view.bounds.height, 600)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
          window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(name)-\(scheme)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
    }
    XCTAssertNil(model.error)
  }
}
