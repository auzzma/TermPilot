import Foundation

public struct QuickConnectTarget: Equatable, Sendable {
    public var hostname: String
    public var username: String
    public var port: Int

    public init(hostname: String, username: String, port: Int = 22) {
        self.hostname = hostname
        self.username = username
        self.port = port
    }
}

public enum QuickConnectError: Error, Equatable, Sendable {
    case empty
    case invalidFormat
    case missingUsername
    case invalidPort
}

extension QuickConnectError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .empty:
            "Enter a host to connect."
        case .invalidFormat:
            "Use user@host, user@host:port, or ssh://user@host:port."
        case .missingUsername:
            "Include the SSH username."
        case .invalidPort:
            "Port must be between 1 and 65535."
        }
    }
}

public enum QuickConnectParser {
    public static func parse(_ rawValue: String) throws -> QuickConnectTarget {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw QuickConnectError.empty
        }

        if value.lowercased().hasPrefix("ssh://") {
            return try parseURL(value)
        }
        return try parseDirect(value)
    }

    private static func parseURL(_ value: String) throws -> QuickConnectTarget {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "ssh",
              let host = components.host,
              !host.isEmpty
        else {
            throw QuickConnectError.invalidFormat
        }
        guard let username = components.user, !username.isEmpty else {
            throw QuickConnectError.missingUsername
        }
        let port = components.port ?? 22
        guard (1 ... 65_535).contains(port) else {
            throw QuickConnectError.invalidPort
        }
        return QuickConnectTarget(
            hostname: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
            username: username,
            port: port
        )
    }

    private static func parseDirect(_ value: String) throws -> QuickConnectTarget {
        guard let separator = value.firstIndex(of: "@") else {
            throw QuickConnectError.missingUsername
        }

        let username = String(value[..<separator])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var hostAndPort = String(value[value.index(after: separator)...])
        guard !username.isEmpty else {
            throw QuickConnectError.missingUsername
        }
        guard !hostAndPort.isEmpty else {
            throw QuickConnectError.invalidFormat
        }

        var port = 22
        let hostname: String
        if hostAndPort.hasPrefix("[") {
            guard let closingBracket = hostAndPort.firstIndex(of: "]") else {
                throw QuickConnectError.invalidFormat
            }
            hostname = String(hostAndPort[hostAndPort.index(after: hostAndPort.startIndex) ..< closingBracket])
            hostAndPort.removeSubrange(...closingBracket)
            if !hostAndPort.isEmpty {
                guard hostAndPort.first == ":",
                      let parsedPort = Int(hostAndPort.dropFirst())
                else {
                    throw QuickConnectError.invalidPort
                }
                port = parsedPort
            }
        } else if hostAndPort.filter({ $0 == ":" }).count == 1,
                  let separator = hostAndPort.lastIndex(of: ":")
        {
            hostname = String(hostAndPort[..<separator])
            guard let parsedPort = Int(hostAndPort[hostAndPort.index(after: separator)...]) else {
                throw QuickConnectError.invalidPort
            }
            port = parsedPort
        } else {
            hostname = hostAndPort
        }

        guard !hostname.isEmpty, !hostname.contains(where: \.isWhitespace) else {
            throw QuickConnectError.invalidFormat
        }
        guard (1 ... 65_535).contains(port) else {
            throw QuickConnectError.invalidPort
        }
        return QuickConnectTarget(hostname: hostname, username: username, port: port)
    }
}
