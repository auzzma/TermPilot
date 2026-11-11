import SwiftUI
import TermPilotDomain
import TermPilotRemote
import TermPilotTerminal

enum CommandHistorySource: String, Sendable {
    case bash
    case zsh
    case fish
}

enum CommandHistoryDataSource: Equatable, Sendable {
    case remote
    case local(shell: String?)
}

struct CommandHistoryEntry: Identifiable, Equatable, Sendable {
    var id = UUID()
    var command: String
    var source: CommandHistorySource
    var timestamp: Date?
}

enum RemoteCommandHistoryParser {
    private static let shellMarker = "__TP_HISTORY_SHELL__"
    private static let bashMarker = "__TP_HISTORY_BASH__"
    private static let zshMarker = "__TP_HISTORY_ZSH__"
    private static let fishMarker = "__TP_HISTORY_FISH__"

    static func parse(_ output: String, limit: Int = 1_000) -> [CommandHistoryEntry] {
        let shell = detectedShell(in: output)
        let lists: [[CommandHistoryEntry]]
        switch shell {
        case "bash":
            lists = [parseBash(section(bashMarker, in: output))]
        case "zsh":
            lists = [parseZsh(section(zshMarker, in: output))]
        case "fish":
            lists = [parseFish(section(fishMarker, in: output))]
        default:
            lists = [
                parseBash(section(bashMarker, in: output)),
                parseZsh(section(zshMarker, in: output)),
                parseFish(section(fishMarker, in: output)),
            ]
        }
        return merge(lists, limit: limit)
    }

    static func parseBash(_ text: String) -> [CommandHistoryEntry] {
        guard !text.isEmpty else {
            return []
        }
        let lines = normalizedLines(text)
        var entries: [CommandHistoryEntry] = []
        var pendingTimestamp: Date?
        var pendingLines: [String] = []
        var isTimestampedHistory = false

        func flushPendingCommand() {
            let command = pendingLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty {
                entries.append(
                    CommandHistoryEntry(
                        command: command,
                        source: .bash,
                        timestamp: pendingTimestamp
                    )
                )
            }
            pendingLines = []
            pendingTimestamp = nil
        }

        for line in lines {
            if line.hasPrefix("#"),
               line.count >= 10,
               let seconds = TimeInterval(line.dropFirst())
            {
                flushPendingCommand()
                pendingTimestamp = Date(timeIntervalSince1970: seconds)
                isTimestampedHistory = true
                continue
            }
            if isTimestampedHistory {
                pendingLines.append(line)
            } else {
                let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !command.isEmpty {
                    entries.append(
                        CommandHistoryEntry(
                            command: command,
                            source: .bash
                        )
                    )
                }
            }
        }
        flushPendingCommand()
        return entries
    }

    static func parseZsh(_ text: String) -> [CommandHistoryEntry] {
        guard !text.isEmpty else {
            return []
        }
        return joinContinuations(normalizedLines(text)).compactMap { record in
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            guard trimmed.hasPrefix(": "),
                  let semicolon = trimmed.firstIndex(of: ";")
            else {
                return CommandHistoryEntry(command: trimmed, source: .zsh)
            }

            let metadata = trimmed[..<semicolon]
            let command = trimmed[trimmed.index(after: semicolon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty,
                  let durationSeparator = metadata.lastIndex(of: ":"),
                  let seconds = TimeInterval(
                      metadata[metadata.index(metadata.startIndex, offsetBy: 2)
                          ..< durationSeparator]
                  )
            else {
                return command.isEmpty
                    ? nil
                    : CommandHistoryEntry(command: command, source: .zsh)
            }
            return CommandHistoryEntry(
                command: command,
                source: .zsh,
                timestamp: Date(timeIntervalSince1970: seconds)
            )
        }
    }

    static func parseFish(_ text: String) -> [CommandHistoryEntry] {
        guard !text.isEmpty else {
            return []
        }
        var entries: [CommandHistoryEntry] = []
        var currentCommand: String?
        var currentTimestamp: Date?

        func flushCurrent() {
            guard let command = currentCommand, !command.isEmpty else {
                currentCommand = nil
                currentTimestamp = nil
                return
            }
            entries.append(
                CommandHistoryEntry(
                    command: command,
                    source: .fish,
                    timestamp: currentTimestamp
                )
            )
            currentCommand = nil
            currentTimestamp = nil
        }

        for line in normalizedLines(text) {
            if line.hasPrefix("- cmd:") {
                flushCurrent()
                let value = String(line.dropFirst("- cmd:".count))
                    .trimmingCharacters(in: .whitespaces)
                let command = unescapeFish(value)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentCommand = command.isEmpty ? nil : command
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if currentCommand != nil,
               trimmed.hasPrefix("when:"),
               let seconds = TimeInterval(
                   trimmed.dropFirst("when:".count)
                       .trimmingCharacters(in: .whitespaces)
               )
            {
                currentTimestamp = Date(timeIntervalSince1970: seconds)
            }
        }
        flushCurrent()
        return entries
    }

    static func merge(
        _ lists: [[CommandHistoryEntry]],
        limit: Int = 1_000
    ) -> [CommandHistoryEntry] {
        guard limit > 0 else {
            return []
        }
        let indexed = lists
            .flatMap { $0 }
            .enumerated()
            .map { (entry: $0.element, index: $0.offset) }
            .sorted { lhs, rhs in
                let left = lhs.entry.timestamp?.timeIntervalSince1970 ?? 0
                let right = rhs.entry.timestamp?.timeIntervalSince1970 ?? 0
                if left != right {
                    return left > right
                }
                return lhs.index > rhs.index
            }

        var seen = Set<String>()
        var merged: [CommandHistoryEntry] = []
        for item in indexed {
            let command = item.entry.command
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty,
                  !isManagedCommand(command),
                  seen.insert(command).inserted
            else {
                continue
            }
            var entry = item.entry
            entry.command = command
            merged.append(entry)
            if merged.count >= limit {
                break
            }
        }
        return merged
    }

    private static func detectedShell(in output: String) -> String {
        normalizedLines(output)
            .first { $0.hasPrefix(shellMarker) }
            .map { String($0.dropFirst(shellMarker.count)).lowercased() }
            ?? "unknown"
    }

    private static func section(_ marker: String, in output: String) -> String {
        guard let markerRange = output.range(of: marker) else {
            return ""
        }
        let start = markerRange.upperBound
        let end = [bashMarker, zshMarker, fishMarker]
            .compactMap {
                output.range(of: $0, range: start ..< output.endIndex)?.lowerBound
            }
            .min()
            ?? output.endIndex
        return String(output[start ..< end])
            .trimmingCharacters(in: .newlines)
    }

    private static func normalizedLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    private static func joinContinuations(_ lines: [String]) -> [String] {
        var records: [String] = []
        var buffer: String?
        for line in lines {
            let backslashCount = line.reversed().prefix { $0 == "\\" }.count
            let continues = backslashCount % 2 == 1
            let body = continues ? String(line.dropLast()) : line
            buffer = buffer.map { "\($0)\n\(body)" } ?? body
            if !continues, let completed = buffer {
                records.append(completed)
                buffer = nil
            }
        }
        if let buffer {
            records.append(buffer)
        }
        return records
    }

    private static func unescapeFish(_ value: String) -> String {
        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            let next = value.index(after: index)
            if character == "\\", next < value.endIndex {
                switch value[next] {
                case "n":
                    output.append("\n")
                    index = value.index(after: next)
                    continue
                case "\\":
                    output.append("\\")
                    index = value.index(after: next)
                    continue
                default:
                    break
                }
            }
            output.append(character)
            index = next
        }
        return output
    }

    private static func isManagedCommand(_ command: String) -> Bool {
        if command.contains("__NCMCP_") {
            return true
        }
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let clearsTerminal = normalized.contains("\\033[H\\033[2J\\033[3J")
        let launchesManagedProcess =
            normalized.contains("docker inspect")
            || normalized.contains("docker exec")
            || normalized.contains("docker logs")
            || normalized.contains("tmux attach")
        return clearsTerminal && launchesManagedProcess
    }
}

@MainActor
final class CommandHistoryModel: ObservableObject {
    @Published private(set) var entries: [CommandHistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var loadedUsername: String?

    let host: TermPilotDomain.Host
    let workspaceID: UUID
    let sourceConnectionID: UUID?
    let sourceSessionID: UUID?
    let dataSource: CommandHistoryDataSource

    init(
        host: TermPilotDomain.Host,
        workspaceID: UUID,
        sourceConnectionID: UUID?,
        sourceSessionID: UUID?,
        dataSource: CommandHistoryDataSource = .remote
    ) {
        self.host = host
        self.workspaceID = workspaceID
        self.sourceConnectionID = sourceConnectionID
        self.sourceSessionID = sourceSessionID
        self.dataSource = dataSource
    }

    func loadIfNeeded(
        terminalUsername: String? = nil,
        using state: AppState
    ) async {
        let username = historyUsername(for: terminalUsername)
        guard fetchedAt == nil
                || loadedUsername != username
                || errorMessage != nil
        else {
            return
        }
        await refresh(terminalUsername: terminalUsername, using: state)
    }

    func refresh(
        terminalUsername: String? = nil,
        using state: AppState
    ) async {
        guard !isLoading else {
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let stdout: String
            let stderr: String
            let code: Int?
            var username = historyUsername(for: terminalUsername)
            switch dataSource {
            case .remote:
                let requestsRoot =
                    username == "root"
                    && host.username != "root"
                let response: RemoteExecResponse
                if requestsRoot {
                    do {
                        response = try await fetchRemoteHistory(
                            using: state,
                            elevated: true
                        )
                    } catch {
                        username = host.username
                        response = try await fetchRemoteHistory(
                            using: state,
                            elevated: false
                        )
                    }
                } else {
                    response = try await fetchRemoteHistory(
                        using: state,
                        elevated: false
                    )
                }
                stdout = response.stdout
                stderr = response.stderr
                code = response.code
            case .local(let shell):
                let response = try await LocalCommandExecutor.run(
                    command: Self.fetchCommand,
                    shell: shell
                        ?? ProcessInfo.processInfo.environment["SHELL"]
                        ?? "/bin/zsh",
                    workingDirectory: FileManager.default
                        .homeDirectoryForCurrentUser.path,
                    timeoutMS: 12_000
                )
                stdout = response.stdout
                stderr = response.stderr
                code = Int(response.code)
            }
            if let code, code != 0 {
                let message = stderr
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw SSH2SFTPBridgeError.remote(
                    message.isEmpty
                        ? AppLocalization.string("Failed to read remote history.")
                        : message
                )
            }
            entries = RemoteCommandHistoryParser.parse(stdout)
            loadedUsername = username
            fetchedAt = Date()
        } catch is CancellationError {
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
        isLoading = false
    }

    private func historyUsername(for terminalUsername: String?) -> String {
        Self.historyUsername(
            terminalUsername: terminalUsername,
            loginUsername: host.username
        )
    }

    nonisolated static func historyUsername(
        terminalUsername: String?,
        loginUsername: String
    ) -> String {
        let username = terminalUsername?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if username == "root" || username == loginUsername {
            return username ?? loginUsername
        }
        return loginUsername
    }

    private func fetchRemoteHistory(
        using state: AppState,
        elevated: Bool
    ) async throws -> RemoteExecResponse {
        let response = try await state.execServerTool(
            in: workspaceID,
            host: host,
            sourceConnectionID: sourceConnectionID,
            sourceSessionID: sourceSessionID,
            command: Self.fetchCommand,
            timeoutMS: 12_000,
            elevated: elevated
        )
        guard response.code == nil || response.code == 0 else {
            throw SSH2SFTPBridgeError.remote(
                response.stderr.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        }
        return response
    }

    private static let fetchCommand = #"""
    exec sh -c '
    SH="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)"; [ -n "$SH" ] || SH="$SHELL"
    FISH="${XDG_DATA_HOME:-$HOME/.local/share}/fish/fish_history"; [ -f "$FISH" ] || FISH="$HOME/.config/fish/fish_history"
    case "$SH" in
      *zsh) printf "%s\n" "__TP_HISTORY_SHELL__zsh"; printf "%s\n" "__TP_HISTORY_ZSH__"; tail -n 1000 "${HISTFILE:-$HOME/.zsh_history}" 2>/dev/null || true ;;
      *bash) printf "%s\n" "__TP_HISTORY_SHELL__bash"; printf "%s\n" "__TP_HISTORY_BASH__"; tail -n 1000 "${HISTFILE:-$HOME/.bash_history}" 2>/dev/null || true ;;
      *fish) printf "%s\n" "__TP_HISTORY_SHELL__fish"; printf "%s\n" "__TP_HISTORY_FISH__"; tail -n 3000 "$FISH" 2>/dev/null || true ;;
      *) printf "%s\n" "__TP_HISTORY_SHELL__unknown"; printf "%s\n" "__TP_HISTORY_BASH__"; tail -n 1000 "$HOME/.bash_history" 2>/dev/null || true; printf "%s\n" "__TP_HISTORY_ZSH__"; tail -n 1000 "$HOME/.zsh_history" 2>/dev/null || true; printf "%s\n" "__TP_HISTORY_FISH__"; tail -n 3000 "$FISH" 2>/dev/null || true ;;
    esac
    '
    """#
}

struct SessionCommandHistoryPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: CommandHistoryModel
    @ObservedObject var runtime: TerminalSessionRuntime

    @State private var query = ""
    @State private var expandedEntryID: UUID?

    private var filteredEntries: [CommandHistoryEntry] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return model.entries
        }
        return model.entries.filter {
            $0.command.localizedCaseInsensitiveContains(value)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            metadataBar
            Divider()
            content
        }
        .task(id: runtime.currentUser) {
            await model.loadIfNeeded(
                terminalUsername: runtime.currentUser,
                using: state
            )
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search command history...", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

            Button {
                Task {
                    await model.refresh(
                        terminalUsername: runtime.currentUser,
                        using: state
                    )
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(model.isLoading ? .degrees(360) : .zero)
            }
            .buttonStyle(.borderless)
            .disabled(model.isLoading)
            .help("Refresh command history")
        }
        .padding(8)
    }

    private var metadataBar: some View {
        HStack(spacing: 6) {
            HostIconView(host: model.host, size: 20)
            Text(model.host.label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if let username = model.loadedUsername {
                Text(username)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !model.entries.isEmpty {
                Text(
                    String(
                        format: AppLocalization.string("%@ commands"),
                        String(model.entries.count)
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading, model.entries.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading remote history...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = model.errorMessage, model.entries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Retry") {
                    Task {
                        await model.refresh(
                            terminalUsername: runtime.currentUser,
                            using: state
                        )
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty {
            ContentUnavailableView(
                "No command history found on this host.",
                systemImage: "clock.arrow.circlepath"
            )
        } else if filteredEntries.isEmpty {
            ContentUnavailableView(
                "No matching commands.",
                systemImage: "magnifyingglass"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredEntries) { entry in
                        historyRow(entry)
                        Divider()
                            .padding(.leading, 10)
                    }
                }
            }
        }
    }

    private func historyRow(_ entry: CommandHistoryEntry) -> some View {
        let isExpanded = expandedEntryID == entry.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    expandedEntryID = isExpanded ? nil : entry.id
                } label: {
                    Text(entry.command.replacingOccurrences(of: "\n", with: " "))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                commandActionButton(
                    "Paste to terminal",
                    systemImage: "doc.on.clipboard"
                ) {
                    paste(entry.command)
                }
                commandActionButton(
                    "Run in terminal",
                    systemImage: "play.fill"
                ) {
                    run(entry.command)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 38)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let timestamp = entry.timestamp {
                        Text(timestamp.formatted(date: .abbreviated, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("Paste to terminal") {
                            paste(entry.command)
                        }
                        Button("Run in terminal") {
                            run(entry.command)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .padding(.top, 4)
                .background(Color.secondary.opacity(0.05))
            }
        }
        .background(isExpanded ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private func commandActionButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(Text(title))
    }

    private func paste(_ command: String) {
        runtime.sendText(command)
        runtime.focus()
    }

    private func run(_ command: String) {
        runtime.sendText(command.hasSuffix("\n") ? command : "\(command)\n")
        runtime.focus()
    }
}
