import Foundation
import TermPilotDomain

struct TmuxSessionRow: Equatable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var windows: Int
    var attached: Bool
    var created: Date?
    var lastActivity: Date?
}

struct TmuxWindowRow: Equatable, Identifiable, Sendable {
    var id: String { "\(session)\u{1f}\(index)" }
    var session: String
    var index: Int
    var name: String
    var active: Bool
    var panes: Int

    var target: String { "\(session):\(index)" }
}

enum TmuxManagement {
    static let listSessionsCommand =
        "tmux list-sessions -F '#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_created}\t#{session_activity}' 2>/dev/null"

    static let versionCommand = "tmux -V"

    static func newSessionCommand(name: String?) -> String? {
        let trimmed = (name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "tmux new-session -d"
        }
        guard let safe = sanitizeName(trimmed) else {
            return nil
        }
        return "tmux new-session -d -s \(shellQuote(safe))"
    }

    static func killSessionCommand(name: String) -> String? {
        guard let target = sessionTarget(name) else {
            return nil
        }
        return "tmux kill-session -t \(target)"
    }

    static func renameSessionCommand(
        current: String,
        newName: String
    ) -> String? {
        guard let target = sessionTarget(current),
              let safe = sanitizeName(newName)
        else {
            return nil
        }
        return "tmux rename-session -t \(target) \(shellQuote(safe))"
    }

    static func attachCommand(
        name: String,
        detachOthers: Bool = false
    ) -> String? {
        guard let target = sessionTarget(name) else {
            return nil
        }
        let flag = detachOthers ? " -d" : ""
        return "tmux attach-session\(flag) -t \(target)"
    }

    static let killServerCommand = "tmux kill-server"

    static func listWindowsCommand(session: String) -> String? {
        guard let target = sessionTarget(session) else {
            return nil
        }
        return "tmux list-windows -t \(target) -F "
            + "'#{window_index}\t#{window_name}\t#{window_active}\t#{window_panes}' "
            + "2>/dev/null"
    }

    static func sendKeysCommand(target: String, keys: String) -> String? {
        guard let safeTarget = sessionTarget(target) else {
            return nil
        }
        let trimmed = keys.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 2_000,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        // Send the literal text, then a separate Enter key so the remote
        // shell executes it. `-l` prevents tmux from interpreting the
        // payload as key names.
        return "tmux send-keys -t \(safeTarget) -l \(shellQuote(trimmed))"
            + " && tmux send-keys -t \(safeTarget) Enter"
    }

    static func capturePaneCommand(target: String, lines: Int = 200) -> String? {
        guard let safeTarget = sessionTarget(target) else {
            return nil
        }
        let clamped = min(max(lines, 1), 5_000)
        // -p prints to stdout, -S -<n> starts n lines back in the history.
        return "tmux capture-pane -p -t \(safeTarget) -S -\(clamped) 2>/dev/null"
    }

    static func parseSessions(_ output: String) -> [TmuxSessionRow] {
        output.split(separator: "\n").compactMap { line in
            let parts = line
                .split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count >= 3, !parts[0].isEmpty else {
                return nil
            }
            return TmuxSessionRow(
                name: parts[0],
                windows: Int(parts[1]) ?? 0,
                attached: (Int(parts[2]) ?? 0) > 0,
                created: parts.count > 3 ? date(from: parts[3]) : nil,
                lastActivity: parts.count > 4 ? date(from: parts[4]) : nil
            )
        }
    }

    static func parseWindows(_ output: String, session: String) -> [TmuxWindowRow] {
        output.split(separator: "\n").compactMap { line in
            let parts = line
                .split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count >= 4, let index = Int(parts[0]) else {
                return nil
            }
            return TmuxWindowRow(
                session: session,
                index: index,
                name: parts[1],
                active: (Int(parts[2]) ?? 0) > 0,
                panes: Int(parts[3]) ?? 0
            )
        }
    }

    static func indicatesMissingBinary(
        stderr: String,
        code: Int?
    ) -> Bool {
        if code == 127 {
            return true
        }
        let normalized = stderr.lowercased()
        return normalized.contains("command not found")
            || normalized.contains("not found")
            || normalized.contains("no such file")
    }

    /// Extracts the version token from `tmux -V` output, e.g. "tmux 3.4" -> "3.4".
    static func parseVersion(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("tmux ") else {
            return nil
        }
        let token = trimmed
            .dropFirst(5)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init)
        guard let token, !token.isEmpty else {
            return nil
        }
        return token
    }

    /// A shell command hint for installing tmux, tailored to the host distro.
    static func installHint(for distro: HostDistroID?) -> String {
        switch distro {
        case .macos, .freebsd:
            return "brew install tmux"
        case .ubuntu, .debian, .kali:
            return "sudo apt install tmux"
        case .alpine:
            return "sudo apk add tmux"
        case .arch:
            return "sudo pacman -S tmux"
        case .opensuse:
            return "sudo zypper install tmux"
        case .centos, .rocky, .fedora, .redhat, .almalinux, .oracle,
             .amazon, .alinux, .openeuler:
            return "sudo dnf install tmux"
        default:
            return "sudo apt install tmux"
        }
    }

    private static func sanitizeName(_ value: String?) -> String? {
        let trimmed = (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(128)
        let safe = trimmed.filter {
            $0.isASCII
                && ($0.isLetter || $0.isNumber || "_-".contains($0))
        }
        return safe.isEmpty ? nil : String(safe)
    }

    private static func sessionTarget(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 256,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        return shellQuote(trimmed)
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func date(from value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let seconds = TimeInterval(trimmed) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }
}
