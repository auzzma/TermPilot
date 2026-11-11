import Foundation
import TermPilotCore

public enum ScreenSharingConfigurationError: Error, LocalizedError, Sendable {
    case savedConnectionChanged
    case invalidProfile
    case proxyUnsupported
    case vncProxyUnsupported

    public var errorDescription: String? {
        switch self {
        case .savedConnectionChanged: "The saved desktop connection changed or was removed. Reopen it from the host list."
        case .invalidProfile:
            "Screen Sharing requires a host, username, and password."
        case .proxyUnsupported:
            "Choose Standard VNC to connect through an HTTP or SOCKS5 proxy. High Performance requires a direct or VPN/TUN connection."
        case .vncProxyUnsupported:
            "Standard VNC supports HTTP and SOCKS5 proxies. ProxyCommand is only available for SSH."
        }
    }
}

public enum ScreenSharingMode: String, Codable, CaseIterable, Sendable {
    case highPerformance
    case standardVNC
    case rdp
}

/// A device's independent screen-sharing settings. Passwords belong only in the
/// encrypted vault, never in SessionDescriptor or workspace snapshots.
public struct ScreenSharingProfile: Codable, Equatable, Sendable {
    public var hostID: UUID
    public var port: Int
    public var username: String
    public var password: String?
    public var audio: Bool
    // Optional on disk for backups and profiles written before build 12.
    public var mode: ScreenSharingMode?
    public var effectiveMode: ScreenSharingMode { mode ?? .highPerformance }

    public init(hostID: UUID, port: Int = 5900, username: String,
                password: String? = nil, audio: Bool = true, mode: ScreenSharingMode? = .highPerformance) {
        self.hostID = hostID
        self.port = port
        self.username = username
        self.password = password
        self.audio = audio
        self.mode = mode
    }
}

public enum ScreenSharingEndpoint {
    /// HP media returns to fixed UDP ports. A TCP proxy alone cannot carry
    /// this session; reject it before any helper or direct socket is opened.
    public static func validateProxy(profileID: UUID?, configuration: SSHProxyConfiguration?, mode: ScreenSharingMode = .highPerformance) throws {
        if mode == .standardVNC || mode == .rdp {
            if configuration?.type == .command { throw ScreenSharingConfigurationError.vncProxyUnsupported }
            return
        }
        guard profileID == nil, configuration == nil else {
            throw ScreenSharingConfigurationError.proxyUnsupported
        }
    }

    public static func isValid(host: String, port: Int, username: String, mode: ScreenSharingMode = .highPerformance) -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return SharedCore.isValidEndpoint(host: host, port: port)
            && (mode == .standardVNC || !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
