import Foundation

public enum HostDistroMode: String, Codable, CaseIterable, Sendable {
    case auto
    case manual
}

public enum HostIconMode: String, Codable, CaseIterable, Sendable {
    case auto
    case custom
}

public enum HostIconColorMode: String, Codable, CaseIterable, Sendable {
    case auto
    case manual
}

public enum HostDistroID: String, Codable, CaseIterable, Sendable {
    case linux
    case ubuntu
    case debian
    case centos
    case rocky
    case fedora
    case arch
    case alpine
    case amazon
    case opensuse
    case redhat
    case almalinux
    case oracle
    case kali
    case alinux
    case openeuler
    case macos
    case freebsd
    case cisco
    case juniper
    case huawei
    case h3c
    case hpe
    case mikrotik
    case fortinet
    case paloalto
    case zyxel
    case ruijie

    public static func detect(from output: String) -> HostDistroID? {
        let lines = output.split(whereSeparator: \.isNewline)
        if let idLine = lines.first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("ID=")
        }) {
            let value = idLine
                .dropFirst(idLine.firstIndex(of: "=").map {
                    idLine.distance(from: idLine.startIndex, to: $0) + 1
                } ?? 0)
                .trimmingCharacters(in: CharacterSet(
                    charactersIn: "\"' "
                ))
            if let normalized = normalize(value) {
                return normalized
            }
        }
        return normalize(output)
    }

    public static func normalize(_ value: String?) -> HostDistroID? {
        let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !value.isEmpty else {
            return nil
        }
        if value == "darwin"
            || value == "macos"
            || value == "mac os"
            || value == "mac os x"
            || value.contains("darwin kernel")
            || value.contains("macos")
            || value.contains("mac os")
        {
            return .macos
        }
        if value.contains("freebsd") { return .freebsd }
        if value.contains("ubuntu") { return .ubuntu }
        if value.contains("debian") { return .debian }
        if value.contains("centos") { return .centos }
        if value.contains("rocky") { return .rocky }
        if value.contains("fedora") { return .fedora }
        if value.contains("arch") || value.contains("manjaro") { return .arch }
        if value.contains("alpine") { return .alpine }
        if value.contains("amzn")
            || value.contains("amazon")
            || value.contains("aws")
        {
            return .amazon
        }
        if value.contains("opensuse")
            || value.contains("suse")
            || value.contains("sles")
        {
            return .opensuse
        }
        if value.contains("red hat")
            || value.contains("redhat")
            || value.contains("rhel")
        {
            return .redhat
        }
        if value.contains("almalinux") { return .almalinux }
        if value.contains("oracle") { return .oracle }
        if value.contains("kali") { return .kali }
        if value.contains("openeuler") || value.contains("open euler") {
            return .openeuler
        }
        if value.contains("alinux")
            || value.contains("aliyun")
            || value.contains("alibaba cloud")
        {
            return .alinux
        }
        if let vendor = HostDistroID(rawValue: value),
           vendor.isNetworkVendor {
            return vendor
        }
        if value == "linux" || value.contains("linux") { return .linux }
        return nil
    }

    public static func detectVendor(
        fromSSHVersion softwareVersion: String?
    ) -> HostDistroID? {
        var value = softwareVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        value = value.replacingOccurrences(
            of: #"^SSH-(?:2\.0|1\.99)-"#,
            with: "",
            options: .regularExpression
        )
        guard !value.isEmpty else {
            return nil
        }
        if value.range(of: #"^Cisco[-_]"#, options: .regularExpression) != nil
            || value.range(of: #"^CiscoIOS_"#, options: .regularExpression) != nil
            || value.hasPrefix("CISCO_WLC")
        {
            return .cisco
        }
        if value.hasPrefix("NetScreen") { return .juniper }
        if value == "-"
            || value.range(
                of: #"^(HUAWEI[-_]|VRP-)"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        {
            return .huawei
        }
        if value.range(
            of: #"^(H3C[-_\s]|Comware-|3Com\s*OS)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return .h3c
        }
        if value.range(of: #"^mpSSH_"#, options: .regularExpression) != nil {
            return .hpe
        }
        if value.hasPrefix("ROSSSH") { return .mikrotik }
        if value.range(
            of: #"^FortiSSH_"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return .fortinet
        }
        if value.range(
            of: #"^PaloAltoNetworks[_-]"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return .paloalto
        }
        if value.range(
            of: #"^Zyxel\s*SSH"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return .zyxel
        }
        if value.range(
            of: #"^RGOS_SSH\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return .ruijie
        }
        return nil
    }

    public var isNetworkVendor: Bool {
        switch self {
        case .cisco, .juniper, .huawei, .h3c, .hpe, .mikrotik,
             .fortinet, .paloalto, .zyxel, .ruijie:
            true
        default:
            false
        }
    }

    public var defaultColorHex: String {
        switch self {
        case .ubuntu: "#E95420"
        case .debian: "#A81D33"
        case .centos: "#9C27B0"
        case .rocky: "#0B9B69"
        case .fedora: "#3C6EB4"
        case .arch: "#1793D1"
        case .alpine: "#0D597F"
        case .amazon: "#FF9900"
        case .opensuse: "#73BA25"
        case .redhat: "#EE0000"
        case .oracle: "#C74634"
        case .kali: "#0F6DB3"
        case .almalinux: "#173B66"
        case .alinux: "#FF6A00"
        case .openeuler: "#002FA7"
        case .macos, .linux: "#333333"
        case .freebsd: "#AB2B28"
        case .cisco: "#1BA0D7"
        case .juniper: "#0A6EB4"
        case .huawei: "#CF0A2C"
        case .h3c: "#FFFFFF"
        case .hpe: "#01A982"
        case .mikrotik: "#293239"
        case .fortinet: "#EE3124"
        case .paloalto: "#FA582D"
        case .zyxel: "#00497A"
        case .ruijie: "#E60012"
        }
    }
}

public enum HostIconID: String, Codable, CaseIterable, Sendable {
    case server
    case terminal
    case database
    case cloud
    case router
    case shield
    case code
    case box
    case globe
    case cpu
    case hardDrive = "hard-drive"
    case network
    case wifi
    case lock
    case key
    case monitor
    case container
    case activity
    case zap
    case serverCog = "server-cog"

    public var defaultColorID: HostIconColorID {
        switch self {
        case .server: .blue
        case .terminal, .serverCog: .slate
        case .database: .cyan
        case .cloud, .monitor: .sky
        case .router, .zap: .orange
        case .shield: .green
        case .code: .violet
        case .box, .key: .amber
        case .globe, .container: .teal
        case .cpu: .indigo
        case .hardDrive: .zinc
        case .network: .lime
        case .wifi: .purple
        case .lock: .rose
        case .activity: .red
        }
    }
}

public enum HostIconColorID: String, Codable, CaseIterable, Sendable {
    case blue
    case green
    case red
    case amber
    case purple
    case cyan
    case orange
    case slate
    case violet
    case pink
    case rose
    case lime
    case teal
    case sky
    case indigo
    case zinc

    public var hex: String {
        switch self {
        case .blue: "#2563EB"
        case .green: "#16A34A"
        case .red: "#DC2626"
        case .amber: "#B45309"
        case .purple: "#9333EA"
        case .cyan: "#0891B2"
        case .orange: "#EA580C"
        case .slate: "#475569"
        case .violet: "#7C3AED"
        case .pink: "#DB2777"
        case .rose: "#E11D48"
        case .lime: "#65A30D"
        case .teal: "#0D9488"
        case .sky: "#0284C7"
        case .indigo: "#4F46E5"
        case .zinc: "#52525B"
        }
    }
}

public enum HostAppearance {
    public static func isValidCustomColor(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        return value.range(
            of: #"^#[0-9a-fA-F]{6}$"#,
            options: .regularExpression
        ) != nil
    }
}

public extension Host {
    var effectiveDistro: HostDistroID? {
        distroMode == .manual ? (manualDistro ?? distro) : distro
    }

    var effectiveIconColorHex: String {
        if iconColorMode == .manual {
            if HostAppearance.isValidCustomColor(iconColorCustom) {
                return iconColorCustom!
            }
            return (iconColor ?? .blue).hex
        }
        if iconMode == .custom {
            return (iconID ?? .server).defaultColorID.hex
        }
        return effectiveDistro?.defaultColorHex ?? HostIconColorID.blue.hex
    }
}
