import Foundation

public enum QuickCredentialProtocol: String, CaseIterable, Sendable {
    case ssh, standardVNC, highPerformance, rdp

    public static func resolve(kind: String, mode: String) -> Self {
        if kind == "rdp" { return .rdp }
        if kind == "screenSharing" || kind == "screen" {
            return mode == "highPerformance" ? .highPerformance : .standardVNC
        }
        return .ssh
    }

    public func supports(kind: String) -> Bool {
        kind == "password" || (self == .ssh && kind == "identityKey")
    }
}

public enum QuickCredentialStrategy: String, CaseIterable, Sendable {
    case manual, recent, fixed
}

/// Device-local preferences contain references only. Secret values remain in the vault.
public struct QuickCredentialPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ protocolKind: QuickCredentialProtocol, _ field: String) -> String {
        "TermPilot.quickCredential.\(protocolKind.rawValue).\(field)"
    }

    public func strategy(_ protocolKind: QuickCredentialProtocol) -> QuickCredentialStrategy {
        QuickCredentialStrategy(rawValue: defaults.string(forKey: key(protocolKind, "strategy")) ?? "") ?? .manual
    }

    public func fixedID(_ protocolKind: QuickCredentialProtocol) -> String {
        defaults.string(forKey: key(protocolKind, "fixed")) ?? ""
    }

    public func selectedID(_ protocolKind: QuickCredentialProtocol) -> String {
        switch strategy(protocolKind) {
        case .manual: return ""
        case .fixed: return fixedID(protocolKind)
        case .recent: return defaults.string(forKey: key(protocolKind, "recent")) ?? ""
        }
    }

    public func configure(_ protocolKind: QuickCredentialProtocol, strategy: QuickCredentialStrategy, credentialID: String) {
        defaults.set(strategy.rawValue, forKey: key(protocolKind, "strategy"))
        defaults.set(credentialID, forKey: key(protocolKind, "fixed"))
    }

    public func connected(_ protocolKind: QuickCredentialProtocol, credentialID: String) {
        guard strategy(protocolKind) == .recent, !credentialID.isEmpty else { return }
        defaults.set(credentialID, forKey: key(protocolKind, "recent"))
    }
}
