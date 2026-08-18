import Foundation

enum AppPreferences {
    static let appearance = "appearance"
    static let language = "language"
    static let defaultLanguage = "zh-Hans"
    static let passwordPromptAssistMode = "passwordPromptAssistMode"
    static let defaultPasswordPromptAssistMode = "hint"
    static let autoOpenSystemOverviewOnSSHConnect =
        "autoOpenSystemOverviewOnSSHConnect"
    static let autoAcceptSSHHostKeys = "autoAcceptSSHHostKeys"
    static let overviewRefreshInterval = "overviewRefreshInterval"
    static let processesRefreshInterval = "processesRefreshInterval"
    static let dockerRefreshInterval = "dockerRefreshInterval"
    static let minimumSystemMonitorRefreshInterval = 1
    static let maximumSystemMonitorRefreshInterval = 10
    static let defaultOverviewRefreshInterval = 5
    static let defaultProcessesRefreshInterval = 3
    static let defaultDockerRefreshInterval = 5
    static let defaultAutoOpenSystemOverviewOnSSHConnect = true
    static let defaultAutoAcceptSSHHostKeys = false

    static func normalizedLanguage(_ value: String) -> String {
        switch value {
        case "en":
            "en"
        default:
            defaultLanguage
        }
    }

    static func clampedSystemMonitorRefreshInterval(_ value: Int) -> Int {
        min(
            max(value, minimumSystemMonitorRefreshInterval),
            maximumSystemMonitorRefreshInterval
        )
    }

    static var isAutoOpenSystemOverviewOnSSHConnectEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: autoOpenSystemOverviewOnSSHConnect) != nil else {
            return defaultAutoOpenSystemOverviewOnSSHConnect
        }
        return defaults.bool(forKey: autoOpenSystemOverviewOnSSHConnect)
    }

    static var isAutoAcceptSSHHostKeysEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: autoAcceptSSHHostKeys) != nil else {
            return defaultAutoAcceptSSHHostKeys
        }
        return defaults.bool(forKey: autoAcceptSSHHostKeys)
    }
}
