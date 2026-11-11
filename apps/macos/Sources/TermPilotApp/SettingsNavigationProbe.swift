#if DEBUG
import AppKit
import SwiftUI

/// Runs the real WindowGroup/RootView path without loading a vault or starting engines.
/// Unlike an NSHostingView snapshot, this exercises SwiftUI's window size negotiation.
struct SettingsNavigationProbe: App {
    @StateObject private var state = AppState()
    @StateObject private var ai = AIClient()
    private let defaults = UserDefaults(suiteName: "TermPilot.SettingsNavigationProbe")!

    var body: some Scene {
        WindowGroup {
            RootView(startsAIRuntime: false, aiClient: ai)
                .environmentObject(state)
                .defaultAppStorage(defaults)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    state.preparePerformanceFixtureForTesting(count: 3)
                    try? await Task.sleep(for: .milliseconds(400))
                    NotificationCenter.default.post(name: .showSettingsSurface, object: state)
                    try? await Task.sleep(for: .seconds(2))
                    guard let window = NSApp.windows.first(where: { $0.isVisible }) else { exit(1) }
                    if let path = ProcessInfo.processInfo.environment["TERMPILOT_SETTINGS_PROBE_RESULT"] {
                        do { try saveSnapshot(window, to: path + "-first-open.png") }
                        catch { exit(1) }
                    }
                    var sizes: [[String: Double]] = []
                    for size in [NSSize(width: 900, height: 560), NSSize(width: 1280, height: 780), NSSize(width: 1800, height: 1068)] {
                        window.setContentSize(size)
                        NotificationCenter.default.post(name: .showAboutSettingsSurface, object: state)
                        try? await Task.sleep(for: .milliseconds(300))
                        NotificationCenter.default.post(name: .showSettingsSurface, object: state)
                        try? await Task.sleep(for: .milliseconds(600))
                        sizes.append(["width": window.frame.width, "height": window.frame.height,
                                      "minWidth": window.contentMinSize.width, "minHeight": window.contentMinSize.height])
                    }
                    try? await Task.sleep(for: .seconds(1))
                    NotificationCenter.default.post(name: .showAboutSettingsSurface, object: state)
                    try? await Task.sleep(for: .milliseconds(300))
                    NotificationCenter.default.post(name: .showSettingsSurface, object: state)
                    try? await Task.sleep(for: .seconds(1))
                    if let path = ProcessInfo.processInfo.environment["TERMPILOT_SETTINGS_PROBE_RESULT"] {
                        do {
                            let data = try JSONSerialization.data(withJSONObject: ["passed": true, "windowGroup": true, "fixtureHosts": 24, "sizes": sizes], options: [.prettyPrinted, .sortedKeys])
                            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                            try saveSnapshot(window, to: path + ".png")
                        } catch { exit(1) }
                    }
                    defaults.removePersistentDomain(forName: "TermPilot.SettingsNavigationProbe")
                    NSApp.terminate(nil)
                }
        }.defaultSize(width: 1800, height: 1068)
    }

    private func saveSnapshot(_ window: NSWindow, to path: String) throws {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
