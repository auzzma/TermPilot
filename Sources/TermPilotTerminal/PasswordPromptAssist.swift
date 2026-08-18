import Foundation

public enum PasswordPromptAssistMode: String, CaseIterable, Sendable {
    case off
    case hint
    case picker
}

public struct PasswordPromptCredential: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var username: String?
    public var password: String
    public var isHostCredential: Bool

    public init(
        id: String,
        label: String,
        username: String?,
        password: String,
        isHostCredential: Bool = false
    ) {
        self.id = id
        self.label = label
        self.username = username
        self.password = password
        self.isHostCredential = isHostCredential
    }
}

public struct PasswordPromptCredentialItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var username: String?

    init(credential: PasswordPromptCredential) {
        id = credential.id
        label = credential.label
        username = credential.username
    }
}

public enum PasswordPromptPresentation: Equatable, Sendable {
    case hint
    case picker
}

public struct PasswordPromptRequest: Equatable, Sendable {
    public var items: [PasswordPromptCredentialItem]
    public var selectedIndex: Int
    public var presentation: PasswordPromptPresentation
}

enum PasswordPromptCommandKind: Equatable {
    case sudo
    case su
}

struct PasswordPromptDetector {
    private static let armDuration: TimeInterval = 10

    private(set) var armedKind: PasswordPromptCommandKind?
    private var armedUntil = Date.distantPast
    private var outputTail = ""
    private var waitsForAuthenticationRetry = false
    private var dismissedWhileArmed = false

    mutating func arm(for command: String, now: Date = Date()) {
        abort()
        guard let kind = Self.commandKind(command) else {
            return
        }
        armedKind = kind
        armedUntil = now.addingTimeInterval(Self.armDuration)
    }

    mutating func observe(
        output: String,
        now: Date = Date()
    ) -> PasswordPromptCommandKind? {
        outputTail = String((outputTail + output).suffix(1_024))
        let rawLine = Self.lastLine(outputTail)
        let plainLine = Self.stripControlSequences(rawLine)
        let isArmed = armedKind != nil && now <= armedUntil

        let match: PasswordPromptCommandKind?
        if Self.isExplicitSudoPrompt(rawLine) {
            match = .sudo
        } else if isArmed,
                  armedKind == .su,
                  Self.isSuPasswordPrompt(rawLine)
        {
            match = .su
        } else if isArmed,
                  armedKind == .sudo,
                  Self.isSudoScopedPasswordPrompt(rawLine)
        {
            match = .sudo
        } else {
            match = nil
        }

        guard let match else {
            if !isArmed {
                armedKind = nil
                waitsForAuthenticationRetry = false
            }
            return nil
        }

        if waitsForAuthenticationRetry {
            let isRetry =
                Self.isExplicitSudoPrompt(rawLine)
                || Self.matchesAuthenticationFailure(outputTail)
            guard isRetry else {
                abort()
                return nil
            }
            waitsForAuthenticationRetry = false
        }

        if dismissedWhileArmed {
            let isNewPromptCycle =
                output.contains(where: { $0 == "\r" || $0 == "\n" })
                || Self.matchesAuthenticationFailure(outputTail)
            guard isNewPromptCycle else {
                return nil
            }
            dismissedWhileArmed = false
        }

        if plainLine.isEmpty {
            return nil
        }
        return match
    }

    mutating func markFilled(now: Date = Date()) {
        waitsForAuthenticationRetry = true
        dismissedWhileArmed = false
        armedUntil = now.addingTimeInterval(Self.armDuration)
        outputTail = ""
    }

    mutating func dismiss(now: Date = Date()) {
        dismissedWhileArmed = armedKind != nil && now <= armedUntil
        if !dismissedWhileArmed {
            abort()
        }
    }

    mutating func reshowDismissedPrompt(
        now: Date = Date()
    ) -> PasswordPromptCommandKind? {
        guard dismissedWhileArmed,
              armedKind != nil,
              now <= armedUntil
        else {
            return nil
        }
        let rawLine = Self.lastLine(outputTail)
        let match: PasswordPromptCommandKind?
        if Self.isExplicitSudoPrompt(rawLine) {
            match = .sudo
        } else if armedKind == .su,
                  Self.isSuPasswordPrompt(rawLine)
        {
            match = .su
        } else if armedKind == .sudo,
                  Self.isSudoScopedPasswordPrompt(rawLine)
        {
            match = .sudo
        } else {
            match = nil
        }
        if match != nil {
            dismissedWhileArmed = false
        }
        return match
    }

    func hasActiveArm(
        for kind: PasswordPromptCommandKind,
        now: Date = Date()
    ) -> Bool {
        armedKind == kind && now <= armedUntil
    }

    mutating func abort() {
        armedKind = nil
        armedUntil = .distantPast
        outputTail = ""
        waitsForAuthenticationRetry = false
        dismissedWhileArmed = false
    }

    static func commandKind(_ command: String) -> PasswordPromptCommandKind? {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = #"^(?:(?:builtin|command)\s+)?(sudo|su)(?:\s|$)"#
        guard let match = firstMatch(prefix, in: value),
              let range = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return value[range] == "sudo" ? .sudo : .su
    }

    static func assistedCommand(in renderedLine: String) -> String? {
        let line = renderedLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else {
            return nil
        }
        if commandKind(line) != nil {
            return line
        }
        let separators = CharacterSet(charactersIn: "$#%>❯➜")
        for scalarIndex in line.unicodeScalars.indices {
            guard separators.contains(line.unicodeScalars[scalarIndex]) else {
                continue
            }
            let nextScalar = line.unicodeScalars.index(after: scalarIndex)
            guard let next = String.Index(nextScalar, within: line) else {
                continue
            }
            let candidate = line[next...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if commandKind(candidate) != nil {
                return candidate
            }
        }
        return nil
    }

    static func isExplicitSudoPrompt(_ value: String) -> Bool {
        guard !containsConcealedText(value) else {
            return false
        }
        let line = stripControlSequences(value)
        return matches(#"(?i)\[sudo[^\]]*\]"#, line)
            && containsPasswordLabel(line)
    }

    static func isSuPasswordPrompt(_ value: String) -> Bool {
        guard !containsConcealedText(value) else {
            return false
        }
        let line = stripControlSequences(value)
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.contains("@"),
              line.count <= 24,
              !matches(#"(?i)(?:enter\s+password|password\s+for\s+user)"#, line)
        else {
            return false
        }
        return matches(
            #"(?i)^(?:password|passwd|密\s*码|口\s*令)\s*[:：]?\s*$"#,
            line
        )
    }

    static func isSudoScopedPasswordPrompt(_ value: String) -> Bool {
        guard !containsConcealedText(value) else {
            return false
        }
        let line = stripControlSequences(value)
        guard containsPasswordLabel(line),
              !matches(#"(?i)(?:enter\s+password|password\s+for\s+user)"#, line)
        else {
            return false
        }
        return matches(
            #"(?i)(?:password\s+for\b|的密码|输入密码|input\s+password)"#,
            line
        )
    }

    private static func containsPasswordLabel(_ value: String) -> Bool {
        matches(#"(?i)(?:\bpassword\b|密\s*码|口\s*令)"#, value)
    }

    private static func matchesAuthenticationFailure(_ value: String) -> Bool {
        matches(
            #"(?i)(?:sorry,\s*try\s*again|incorrect\s+password|authentication\s+failure|auth(?:entication)?\s+fail|密码(?:错误|不正确)|认证失败|鉴权失败|口令错误)"#,
            stripControlSequences(value)
        )
    }

    private static func containsConcealedText(_ value: String) -> Bool {
        matches(#"\x1B\[(?:[0-9]+;)*8(?:;[0-9]+)*m"#, value)
    }

    private static func stripControlSequences(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"\x1B\][^\x07]*(?:\x07|\x1B\\)"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\x1B\[[0-?]*[ -/]*[@-~]"#,
                with: "",
                options: .regularExpression
            )
    }

    private static func lastLine(_ value: String) -> String {
        guard let boundary = value.rangeOfCharacter(
            from: .newlines,
            options: .backwards
        ) else {
            return value
        }
        return String(value[boundary.upperBound...])
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        firstMatch(pattern, in: value) != nil
    }

    private static func firstMatch(
        _ pattern: String,
        in value: String
    ) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        return expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        )
    }
}

struct TerminalCommandInputBuffer {
    private var value = ""

    mutating func replace(with value: String) {
        self.value = value
    }

    mutating func consume(_ bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty else {
            return nil
        }
        if bytes == [0x03] || bytes == [0x04] {
            value = ""
            return nil
        }
        if bytes == [0x7f] || bytes == [0x08] {
            if !value.isEmpty {
                value.removeLast()
            }
            return nil
        }

        let data = String(decoding: bytes, as: UTF8.self)
        if data.hasPrefix("\u{1B}[200~"), data.hasSuffix("\u{1B}[201~") {
            let start = data.index(data.startIndex, offsetBy: 6)
            let end = data.index(data.endIndex, offsetBy: -6)
            value.append(contentsOf: data[start ..< end])
            return nil
        }
        if data.hasPrefix("\u{1B}") {
            return nil
        }

        var submitted: String?
        for character in data {
            if character == "\r" || character == "\n" {
                let command = value.trimmingCharacters(in: .whitespacesAndNewlines)
                value = ""
                if !command.isEmpty {
                    submitted = command
                }
            } else {
                value.append(character)
            }
        }
        return submitted
    }
}
