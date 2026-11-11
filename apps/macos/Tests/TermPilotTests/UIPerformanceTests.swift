import AppKit
import SwiftUI
import TermPilotPersistence
@testable import TermPilotApp
import XCTest

final class UIPerformanceTests: XCTestCase {
    /// Opt-in, identical workload before/after. No network or user's database.
    @MainActor
    func testNavigationBenchmark() throws {
        guard let output = ProcessInfo.processInfo.environment["TERMPILOT_PERFORMANCE_RESULT"],
              ProcessInfo.processInfo.environment["TERMPILOT_TEST_DATA_DIRECTORY"] != nil else {
            throw XCTSkip("Set isolated data directory and performance output to run the benchmark")
        }
        _ = try VaultStore.openDefault()
        var result: [String: Any] = [:]
        for count in [1, 5, 10] {
            let state = AppState()
            state.preparePerformanceFixtureForTesting(count: count)
            let suite = "TermPilot.Performance.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let host = NSHostingView(rootView: RootView(startsAIRuntime: false)
                .environmentObject(state).defaultAppStorage(defaults)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .frame(minWidth: 900, minHeight: 560))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 780),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.contentView = nil; window.close(); defaults.removePersistentDomain(forName: suite) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            func measure(_ action: (Int) -> Void) -> [String: Double] {
                var values: [Double] = []
                for i in 0..<25 {
                    let start = ProcessInfo.processInfo.systemUptime
                    action(i)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.002))
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    if i >= 5 { values.append((ProcessInfo.processInfo.systemUptime - start) * 1_000) }
                }
                values.sort()
                return ["median_ms": values[values.count / 2], "p95_ms": values[Int(Double(values.count - 1) * 0.95)], "max_ms": values.last!]
            }
            result["\(count)_sessions"] = [
                "tab_state_and_layout": measure { i in state.activeWorkspaceID = state.workspaces[i % count].id },
                "settings_section_and_layout": measure { i in NotificationCenter.default.post(
                    name: i % 2 == 0 ? .showSettingsSurface : .showAboutSettingsSurface, object: state) },
                "window_resize_and_layout": measure { i in window.setContentSize(NSSize(width: 1100 + i % 2 * 180, height: 720 + i % 2 * 60)) },
                "session_display_lookup": measure { _ in for descriptor in state.sessions.values { _ = state.sessionHost(for: descriptor) } },
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
    }
}
