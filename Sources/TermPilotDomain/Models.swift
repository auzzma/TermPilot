import Foundation

public enum AuthenticationMethod: String, Codable, CaseIterable, Sendable {
    case agent
    case password
    case identityFile
}

public enum SSHCredentialKind: String, Codable, CaseIterable, Sendable {
    case password
    case identityKey
}

public enum SFTPFileProtocol: String, Codable, CaseIterable, Sendable {
    case auto
    case sftp
    case scp
}

public enum SFTPFilenameEncoding: String, Codable, CaseIterable, Sendable {
    case auto
    case utf8 = "utf-8"
    case gb18030
}

public enum PortForwardKind: String, Codable, CaseIterable, Sendable {
    case local
    case remote
    case dynamic
}

public enum PortForwardStatus: String, Codable, CaseIterable, Sendable {
    case inactive
    case connecting
    case active
    case error
}

public struct PortForwardRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var hostID: UUID?
    public var name: String
    public var order: Int?
    public var kind: PortForwardKind
    public var bindAddress: String
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int?
    public var autoStart: Bool
    public var status: PortForwardStatus
    public var error: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        hostID: UUID? = nil,
        name: String,
        order: Int? = nil,
        kind: PortForwardKind,
        bindAddress: String = "127.0.0.1",
        localPort: Int,
        remoteHost: String = "127.0.0.1",
        remotePort: Int? = nil,
        autoStart: Bool = false,
        status: PortForwardStatus = .inactive,
        error: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.name = name
        self.order = order
        self.kind = kind
        self.bindAddress = bindAddress
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.autoStart = autoStart
        self.status = status
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
    }

    public func validated() throws -> PortForwardRule {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.bindAddress = bindAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.remoteHost = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty else {
            throw PortForwardValidationError.missingName
        }
        guard (1 ... 65_535).contains(copy.localPort) else {
            throw PortForwardValidationError.invalidLocalPort
        }
        if copy.kind != .dynamic {
            guard let remotePort = copy.remotePort,
                  (1 ... 65_535).contains(remotePort)
            else {
                throw PortForwardValidationError.invalidRemotePort
            }
            guard !copy.remoteHost.isEmpty else {
                throw PortForwardValidationError.invalidRemoteHost
            }
        }
        return copy
    }

    public var connectionSignature: String {
        [
            hostID?.uuidString ?? "",
            kind.rawValue,
            bindAddress,
            String(localPort),
            remoteHost,
            remotePort.map(String.init) ?? "",
        ].joined(separator: "\u{1f}")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case hostID
        case name
        case order
        case kind
        case bindAddress
        case localPort
        case remoteHost
        case remotePort
        case autoStart
        case status
        case error
        case createdAt
        case updatedAt
        case lastUsedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        hostID = try container.decodeIfPresent(UUID.self, forKey: .hostID)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        order = try container.decodeIfPresent(Int.self, forKey: .order)
        kind = try container.decodeIfPresent(PortForwardKind.self, forKey: .kind) ?? .local
        bindAddress = try container.decodeIfPresent(String.self, forKey: .bindAddress) ?? "127.0.0.1"
        localPort = try container.decodeIfPresent(Int.self, forKey: .localPort) ?? 0
        remoteHost = try container.decodeIfPresent(String.self, forKey: .remoteHost) ?? "127.0.0.1"
        remotePort = try container.decodeIfPresent(Int.self, forKey: .remotePort)
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        status = try container.decodeIfPresent(PortForwardStatus.self, forKey: .status) ?? .inactive
        error = try container.decodeIfPresent(String.self, forKey: .error)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}

public enum PortForwardValidationError: Error, Equatable, Sendable {
    case missingName
    case invalidLocalPort
    case invalidRemoteHost
    case invalidRemotePort
}

extension PortForwardValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingName:
            "Forward name is required."
        case .invalidLocalPort:
            "Local port must be between 1 and 65535."
        case .invalidRemoteHost:
            "Remote host is required."
        case .invalidRemotePort:
            "Remote port must be between 1 and 65535."
        }
    }
}

public struct AutomationScript: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var shell: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        shell: String = "/bin/zsh",
        body: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.shell = shell
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validated() throws -> AutomationScript {
        var copy = self
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.shell = shell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.title.isEmpty else {
            throw ProductivityValidationError.missingTitle
        }
        guard !copy.shell.isEmpty else {
            throw ProductivityValidationError.missingShell
        }
        return copy
    }
}

public struct HostNote: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var hostID: UUID?
    public var title: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        hostID: UUID? = nil,
        title: String,
        body: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.hostID = hostID
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validated() throws -> HostNote {
        var copy = self
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.title.isEmpty else {
            throw ProductivityValidationError.missingTitle
        }
        return copy
    }
}

public enum ProductivityValidationError: Error, Equatable, Sendable {
    case missingTitle
    case missingShell
}

extension ProductivityValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingTitle:
            "Title is required."
        case .missingShell:
            "Shell is required."
        }
    }
}

public struct SSHCredential: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var username: String
    public var kind: SSHCredentialKind
    public var password: String?
    public var privateKey: String?
    public var publicKey: String?
    public var certificate: String?
    public var passphrase: String?
    public var savesPassphrase: Bool
    public var elevationPassword: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        label: String,
        username: String,
        kind: SSHCredentialKind = .password,
        password: String? = nil,
        privateKey: String? = nil,
        publicKey: String? = nil,
        certificate: String? = nil,
        passphrase: String? = nil,
        savesPassphrase: Bool = false,
        elevationPassword: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.username = username
        self.kind = kind
        self.password = password
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.certificate = certificate
        self.passphrase = passphrase
        self.savesPassphrase = savesPassphrase
        self.elevationPassword = elevationPassword
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validated() throws -> SSHCredential {
        var copy = self
        copy.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.publicKey = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.certificate = certificate?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.label.isEmpty else {
            throw CredentialValidationError.missingLabel
        }
        guard !copy.username.isEmpty else {
            throw CredentialValidationError.missingUsername
        }
        switch copy.kind {
        case .password:
            guard copy.password?.isEmpty == false else {
                throw CredentialValidationError.missingPassword
            }
            copy.privateKey = nil
            copy.publicKey = nil
            copy.certificate = nil
            copy.passphrase = nil
            copy.savesPassphrase = false
            if copy.elevationPassword?.isEmpty == true {
                copy.elevationPassword = nil
            }
        case .identityKey:
            guard copy.privateKey?.isEmpty == false else {
                throw CredentialValidationError.missingPrivateKey
            }
            if !copy.savesPassphrase {
                copy.passphrase = nil
            }
            copy.password = nil
            if copy.elevationPassword?.isEmpty == true {
                copy.elevationPassword = nil
            }
        }
        return copy
    }
}

public enum CredentialValidationError: Error, Equatable, Sendable {
    case missingLabel
    case missingUsername
    case missingPassword
    case missingPrivateKey
}

extension CredentialValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingLabel:
            "Credential label is required."
        case .missingUsername:
            "Credential username is required."
        case .missingPassword:
            "Credential password is required."
        case .missingPrivateKey:
            "Private key content is required."
        }
    }
}

public enum SSHProxyType: String, Codable, CaseIterable, Sendable {
    case http
    case socks5
    case command
}

public struct SSHProxyConfiguration: Codable, Equatable, Sendable {
    public var type: SSHProxyType
    public var host: String
    public var port: Int
    public var command: String?
    public var credentialID: UUID?
    public var username: String?
    public var password: String?

    public init(
        type: SSHProxyType = .http,
        host: String = "",
        port: Int = 8080,
        command: String? = nil,
        credentialID: UUID? = nil,
        username: String? = nil,
        password: String? = nil
    ) {
        self.type = type
        self.host = host
        self.port = port
        self.command = command
        self.credentialID = credentialID
        self.username = username
        self.password = password
    }

    public func validated() throws -> SSHProxyConfiguration {
        var copy = self
        switch copy.type {
        case .command:
            copy.command = command?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard copy.command?.isEmpty == false else {
                throw SSHProxyValidationError.missingCommand
            }
            copy.host = ""
            copy.port = 0
            copy.credentialID = nil
            copy.username = nil
            copy.password = nil
        case .http, .socks5:
            copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !copy.host.isEmpty,
                  !copy.host.hasPrefix("-"),
                  !copy.host.contains(where: \.isWhitespace)
            else {
                throw SSHProxyValidationError.invalidHost
            }
            guard (1 ... 65_535).contains(copy.port) else {
                throw SSHProxyValidationError.invalidPort
            }
            copy.command = nil
            if copy.credentialID != nil {
                copy.username = nil
                copy.password = nil
            } else {
                copy.username = username?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if copy.username?.isEmpty == true {
                    copy.username = nil
                }
                if copy.password?.isEmpty == true {
                    copy.password = nil
                }
            }
        }
        return copy
    }
}

public struct SSHProxyProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var configuration: SSHProxyConfiguration
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        label: String,
        configuration: SSHProxyConfiguration = SSHProxyConfiguration(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.configuration = configuration
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validated() throws -> SSHProxyProfile {
        var copy = self
        copy.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.label.isEmpty else {
            throw SSHProxyValidationError.missingLabel
        }
        copy.configuration = try configuration.validated()
        return copy
    }
}

public enum SSHProxyValidationError: Error, Equatable, Sendable {
    case missingLabel
    case invalidHost
    case invalidPort
    case missingCommand
}

extension SSHProxyValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingLabel:
            "Proxy name is required."
        case .invalidHost:
            "Enter a valid proxy host."
        case .invalidPort:
            "Proxy port must be between 1 and 65535."
        case .missingCommand:
            "ProxyCommand is required."
        }
    }
}

public enum ServerToolsElevationMethod:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case sudo
    case su
}

public struct Host: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var authentication: AuthenticationMethod
    public var identityFile: String?
    public var identityKey: String?
    public var publicKey: String?
    public var certificate: String?
    public var passphrase: String?
    public var password: String?
    public var elevationPassword: String?
    public var credentialID: UUID?
    public var proxyProfileID: UUID?
    public var proxyConfiguration: SSHProxyConfiguration?
    public var groupID: UUID?
    public var sortOrder: Int
    public var distro: HostDistroID?
    public var distroMode: HostDistroMode
    public var manualDistro: HostDistroID?
    public var iconMode: HostIconMode
    public var iconID: HostIconID?
    public var iconColorMode: HostIconColorMode
    public var iconColor: HostIconColorID?
    public var iconColorCustom: String?
    public var sftpFileProtocol: SFTPFileProtocol
    public var sftpFilenameEncoding: SFTPFilenameEncoding
    public var sftpUsesSudo: Bool
    public var sftpFollowsTerminalCWD: Bool?
    public var serverToolsUseRoot: Bool
    public var serverToolsElevationMethod: ServerToolsElevationMethod
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        label: String,
        hostname: String,
        port: Int = 22,
        username: String,
        authentication: AuthenticationMethod = .agent,
        identityFile: String? = nil,
        identityKey: String? = nil,
        publicKey: String? = nil,
        certificate: String? = nil,
        passphrase: String? = nil,
        password: String? = nil,
        elevationPassword: String? = nil,
        credentialID: UUID? = nil,
        proxyProfileID: UUID? = nil,
        proxyConfiguration: SSHProxyConfiguration? = nil,
        groupID: UUID? = nil,
        sortOrder: Int = 0,
        distro: HostDistroID? = nil,
        distroMode: HostDistroMode = .auto,
        manualDistro: HostDistroID? = nil,
        iconMode: HostIconMode = .auto,
        iconID: HostIconID? = nil,
        iconColorMode: HostIconColorMode = .auto,
        iconColor: HostIconColorID? = nil,
        iconColorCustom: String? = nil,
        sftpFileProtocol: SFTPFileProtocol = .auto,
        sftpFilenameEncoding: SFTPFilenameEncoding = .auto,
        sftpUsesSudo: Bool = false,
        sftpFollowsTerminalCWD: Bool? = nil,
        serverToolsUseRoot: Bool = false,
        serverToolsElevationMethod: ServerToolsElevationMethod = .sudo,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authentication = authentication
        self.identityFile = identityFile
        self.identityKey = identityKey
        self.publicKey = publicKey
        self.certificate = certificate
        self.passphrase = passphrase
        self.password = password
        self.elevationPassword = elevationPassword
        self.credentialID = credentialID
        self.proxyProfileID = proxyProfileID
        self.proxyConfiguration = proxyConfiguration
        self.groupID = groupID
        self.sortOrder = sortOrder
        self.distro = distro
        self.distroMode = distroMode
        self.manualDistro = manualDistro
        self.iconMode = iconMode
        self.iconID = iconID
        self.iconColorMode = iconColorMode
        self.iconColor = iconColor
        self.iconColorCustom = iconColorCustom
        self.sftpFileProtocol = sftpFileProtocol
        self.sftpFilenameEncoding = sftpFilenameEncoding
        self.sftpUsesSudo = sftpUsesSudo
        self.sftpFollowsTerminalCWD = sftpFollowsTerminalCWD
        self.serverToolsUseRoot = serverToolsUseRoot
        self.serverToolsElevationMethod = serverToolsElevationMethod
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validated() throws -> Host {
        var copy = self
        copy.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.identityFile = identityFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.publicKey = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.certificate = certificate?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.elevationPassword?.isEmpty == true {
            copy.elevationPassword = nil
        }

        guard !copy.label.isEmpty else {
            throw HostValidationError.missingLabel
        }
        guard !copy.hostname.isEmpty,
              !copy.hostname.hasPrefix("-"),
              !copy.hostname.contains(where: \.isWhitespace)
        else {
            throw HostValidationError.invalidHostname
        }
        guard (1 ... 65_535).contains(copy.port) else {
            throw HostValidationError.invalidPort
        }
        guard !copy.username.isEmpty else {
            throw HostValidationError.missingUsername
        }
        if copy.authentication == .identityFile,
           copy.credentialID == nil,
           copy.identityFile?.isEmpty != false,
           copy.identityKey?.isEmpty != false
        {
            throw HostValidationError.missingIdentityFile
        }
        if let proxyConfiguration = copy.proxyConfiguration {
            copy.proxyConfiguration = try proxyConfiguration.validated()
            copy.proxyProfileID = nil
        }
        if copy.iconMode == .auto {
            copy.iconID = nil
        } else if copy.iconID == nil {
            copy.iconID = .server
        }
        if copy.iconColorMode == .auto {
            copy.iconColor = nil
            copy.iconColorCustom = nil
        } else if !HostAppearance.isValidCustomColor(copy.iconColorCustom) {
            copy.iconColorCustom = nil
            copy.iconColor = copy.iconColor ?? .blue
        }
        if copy.sftpFileProtocol == .scp {
            copy.sftpUsesSudo = false
        }
        return copy
    }
}

public enum HostValidationError: Error, Equatable, Sendable {
    case missingLabel
    case invalidHostname
    case invalidPort
    case missingUsername
    case missingIdentityFile
}

extension HostValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingLabel:
            "Host name is required."
        case .invalidHostname:
            "Enter a valid hostname or IP address."
        case .invalidPort:
            "Port must be between 1 and 65535."
        case .missingUsername:
            "Username is required."
        case .missingIdentityFile:
            "Select a private key file."
        }
    }
}

public struct HostGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var parentGroupID: UUID?
    public var sortOrder: Int

    public init(
        id: UUID = UUID(),
        name: String,
        parentGroupID: UUID? = nil,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.parentGroupID = parentGroupID
        self.sortOrder = sortOrder
    }
}

public enum SessionKind: String, Codable, Sendable {
    case local
    case ssh
}

public enum SessionLifecycle: Codable, Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case exited(Int32?)
    case failed(String)
}

/// Only non-secret fields are allowed in this restorable descriptor.
public struct SessionDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: SessionKind
    public var title: String
    public var hostID: UUID?
    public var hostname: String?
    public var port: Int?
    public var username: String?
    public var authentication: AuthenticationMethod?
    public var credentialID: UUID?
    public var proxyProfileID: UUID?
    public var customProxyConfigured: Bool?
    public var identityFile: String?
    public var sftpFileProtocol: SFTPFileProtocol?
    public var sftpFilenameEncoding: SFTPFilenameEncoding?
    public var sftpUsesSudo: Bool?
    public var sftpFollowsTerminalCWD: Bool?
    public var serverToolsUseRoot: Bool?
    public var serverToolsElevationMethod: ServerToolsElevationMethod?
    public var sshConnectionID: UUID?
    public var shell: String?
    public var workingDirectory: String?
    public var fontSize: Double

    public init(
        id: UUID = UUID(),
        kind: SessionKind,
        title: String,
        hostID: UUID? = nil,
        hostname: String? = nil,
        port: Int? = nil,
        username: String? = nil,
        authentication: AuthenticationMethod? = nil,
        credentialID: UUID? = nil,
        proxyProfileID: UUID? = nil,
        customProxyConfigured: Bool? = nil,
        identityFile: String? = nil,
        sftpFileProtocol: SFTPFileProtocol? = nil,
        sftpFilenameEncoding: SFTPFilenameEncoding? = nil,
        sftpUsesSudo: Bool? = nil,
        sftpFollowsTerminalCWD: Bool? = nil,
        serverToolsUseRoot: Bool? = nil,
        serverToolsElevationMethod: ServerToolsElevationMethod? = nil,
        sshConnectionID: UUID? = nil,
        shell: String? = nil,
        workingDirectory: String? = nil,
        fontSize: Double = 13
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.hostID = hostID
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authentication = authentication
        self.credentialID = credentialID
        self.proxyProfileID = proxyProfileID
        self.customProxyConfigured = customProxyConfigured
        self.identityFile = identityFile
        self.sftpFileProtocol = sftpFileProtocol
        self.sftpFilenameEncoding = sftpFilenameEncoding
        self.sftpUsesSudo = sftpUsesSudo
        self.sftpFollowsTerminalCWD = sftpFollowsTerminalCWD
        self.serverToolsUseRoot = serverToolsUseRoot
        self.serverToolsElevationMethod = serverToolsElevationMethod
        self.sshConnectionID = sshConnectionID
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.fontSize = fontSize
    }

    public static func local(
        shell: String,
        workingDirectory: String? = nil
    ) -> SessionDescriptor {
        SessionDescriptor(
            kind: .local,
            title: URL(fileURLWithPath: shell).lastPathComponent,
            shell: shell,
            workingDirectory: workingDirectory
        )
    }

    public static func ssh(
        host: Host,
        connectionID: UUID = UUID()
    ) -> SessionDescriptor {
        SessionDescriptor(
            kind: .ssh,
            title: host.label,
            hostID: host.id,
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            authentication: host.authentication,
            credentialID: host.credentialID,
            proxyProfileID: host.proxyProfileID,
            customProxyConfigured: host.proxyConfiguration != nil,
            identityFile: host.identityFile,
            sftpFileProtocol: host.sftpFileProtocol,
            sftpFilenameEncoding: host.sftpFilenameEncoding,
            sftpUsesSudo: host.sftpUsesSudo,
            sftpFollowsTerminalCWD: host.sftpFollowsTerminalCWD,
            serverToolsUseRoot: host.serverToolsUseRoot,
            serverToolsElevationMethod: host.serverToolsElevationMethod,
            sshConnectionID: connectionID
        )
    }
}

public struct ConnectionHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var hostID: UUID?
    public var startedAt: Date
    public var endedAt: Date?
    public var succeeded: Bool
    public var errorCategory: String?

    public init(
        id: UUID = UUID(),
        hostID: UUID?,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        succeeded: Bool,
        errorCategory: String? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.succeeded = succeeded
        self.errorCategory = errorCategory
    }
}
