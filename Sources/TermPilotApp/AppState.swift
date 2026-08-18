import AppKit
import Foundation
import SwiftUI
import TermPilotDomain
import TermPilotPersistence
import TermPilotRemote
import TermPilotTerminal

private final class ManagedPortForwardProcess: @unchecked Sendable {
    let ruleID: UUID
    private let process = Process()
    private let outputLock = NSLock()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutData = Data()
    private var stderrData = Data()
    private let onExit: @MainActor (UUID, Int32?, Bool, String) -> Void
    private var stoppedByUser = false

    init(
        ruleID: UUID,
        launchConfiguration: ProcessLaunchConfiguration,
        onExit: @escaping @MainActor (UUID, Int32?, Bool, String) -> Void
    ) {
        self.ruleID = ruleID
        self.onExit = onExit
        process.executableURL = URL(fileURLWithPath: launchConfiguration.executable)
        process.arguments = launchConfiguration.arguments
        process.environment = Dictionary(
            uniqueKeysWithValues: launchConfiguration.environment.compactMap { item in
                guard let separator = item.firstIndex(of: "=") else {
                    return nil
                }
                let key = String(item[..<separator])
                let value = String(item[item.index(after: separator)...])
                return (key, value)
            }
        )
        if let currentDirectory = launchConfiguration.currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    var isRunning: Bool {
        process.isRunning
    }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.appendOutput(handle.availableData, isError: false)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.appendOutput(handle.availableData, isError: true)
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let stoppedByUser = self.stoppedByUser
            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self.appendOutput(
                self.stdoutPipe.fileHandleForReading.availableData,
                isError: false
            )
            self.appendOutput(
                self.stderrPipe.fileHandleForReading.availableData,
                isError: true
            )
            let errorOutput = self.sanitizedErrorOutput()
            Task { @MainActor in
                self.onExit(
                    self.ruleID,
                    process.terminationStatus,
                    stoppedByUser,
                    errorOutput
                )
            }
        }
        try process.run()
    }

    func stop() {
        stoppedByUser = true
        guard process.isRunning else {
            return
        }
        process.terminate()
    }

    private func appendOutput(_ data: Data, isError: Bool) {
        guard !data.isEmpty else {
            return
        }
        outputLock.lock()
        if isError {
            stderrData.append(data)
        } else {
            stdoutData.append(data)
        }
        outputLock.unlock()
    }

    private func sanitizedErrorOutput() -> String {
        outputLock.lock()
        let errorData = stderrData
        let outputData = stdoutData
        outputLock.unlock()

        let raw = String(data: errorData.isEmpty ? outputData : errorData, encoding: .utf8)
            ?? ""
        let cleaned = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return String(cleaned.prefix(2_000))
    }
}

enum TerminalSidePanelTab: String, CaseIterable, Identifiable {
    case sftp
    case system
    case scripts
    case history
    case notes
    case forwarding

    var id: String { rawValue }

    static func available(for kind: SessionKind) -> [TerminalSidePanelTab] {
        switch kind {
        case .local:
            [.sftp, .system, .scripts, .history, .notes]
        case .ssh:
            allCases
        }
    }
}

struct PortForwardHostKeyPrompt: Identifiable, Equatable {
    var id: String
    var prompt: String
    var responseURL: URL
}

private struct AskPassHostKeyRequest: Codable {
    var id: String
    var prompt: String
    var createdAt: Date
}

enum OpenSSHCredentialText {
    static func normalizedFileContent(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2,
           let first = text.first,
           let last = text.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'")
        {
            text.removeFirst()
            text.removeLast()
        }
        text = text
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasSuffix("\n") {
            text.append("\n")
        }
        return text
    }
}

private struct WorkspaceServerToolsExecClient {
    var token: UUID
    var hostID: UUID
    var connectionID: UUID?
    var hostUpdatedAt: Date
    var elevationMethod: ServerToolsElevationMethod
    var client: SSH2SFTPBridgeClient
}

private actor TerminalAutocompleteRemoteDirectoryProvider {
    private struct CacheKey: Hashable {
        var path: String
        var foldersOnly: Bool
        var filterPrefix: String
        var limit: Int
    }

    private struct CacheEntry {
        var entries: [TerminalAutocompleteDirectoryEntry]
        var createdAt: Date
    }

    private let makeClient:
        @MainActor @Sendable () throws -> SSH2SFTPBridgeClient
    private var client: SSH2SFTPBridgeClient?
    private var cache: [CacheKey: CacheEntry] = [:]

    init(
        makeClient:
            @escaping @MainActor @Sendable () throws
                -> SSH2SFTPBridgeClient
    ) {
        self.makeClient = makeClient
    }

    func entries(
        path: String,
        foldersOnly: Bool,
        filterPrefix: String,
        limit: Int
    ) async -> [TerminalAutocompleteDirectoryEntry] {
        let clampedLimit = max(1, min(limit, 200))
        let key = CacheKey(
            path: path,
            foldersOnly: foldersOnly,
            filterPrefix: filterPrefix.lowercased(),
            limit: clampedLimit
        )
        if let cached = cache[key],
           Date().timeIntervalSince(cached.createdAt) < 5
        {
            return cached.entries
        }

        do {
            let client: SSH2SFTPBridgeClient
            if let existing = self.client {
                client = existing
            } else {
                client = try await makeClient()
                self.client = client
            }
            let response = try await client.exec(
                command: Self.listCommand(
                    path: path,
                    foldersOnly: foldersOnly,
                    filterPrefix: filterPrefix,
                    limit: clampedLimit
                ),
                timeoutMS: 3_000
            )
            let entries = Self.parseEntries(
                response.stdout,
                limit: clampedLimit
            )
            cache[key] = CacheEntry(
                entries: entries,
                createdAt: Date()
            )
            if cache.count > 60 {
                cache = Dictionary(
                    uniqueKeysWithValues: cache
                        .sorted { $0.value.createdAt > $1.value.createdAt }
                        .prefix(30)
                        .map { ($0.key, $0.value) }
                )
            }
            return entries
        } catch {
            if let client {
                await client.close()
                self.client = nil
            }
            return []
        }
    }

    func close() async {
        if let client {
            await client.close()
            self.client = nil
        }
        cache.removeAll()
    }

    private static func listCommand(
        path: String,
        foldersOnly: Bool,
        filterPrefix: String,
        limit: Int
    ) -> String {
        let pathExpression: String
        if path == "~" {
            pathExpression = #""$HOME""#
        } else if path.hasPrefix("~/") {
            let suffix = path.dropFirst(2)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "`", with: "\\`")
            pathExpression = #""$HOME/\#(suffix)""#
        } else {
            pathExpression = shellQuote(path)
        }
        let prefix = shellQuote(filterPrefix.lowercased())
        return """
        find \(pathExpression) -mindepth 1 -maxdepth 1 -exec sh -c '
          prefix="$1"
          folders_only="$2"
          limit="$3"
          shift 3
          count=0
          for path do
            name=${path##*/}
            lower_name=$(printf "%s" "$name" | tr "[:upper:]" "[:lower:]")
            if [ -n "$prefix" ]; then
              case "$lower_name" in
                "$prefix"*) ;;
                *) continue ;;
              esac
            fi
            if [ "$folders_only" -eq 1 ] && [ ! -d "$path" ]; then
              continue
            fi
            if [ -L "$path" ]; then
              type="symlink"
            elif [ -d "$path" ]; then
              type="directory"
            else
              type="file"
            fi
            printf "%s\\0%s\\0" "$name" "$type"
            count=$((count + 1))
            if [ "$count" -ge "$limit" ]; then
              break
            fi
          done
        ' sh \(prefix) \(foldersOnly ? 1 : 0) \(limit) {} + 2>/dev/null
        """
    }

    private static func parseEntries(
        _ output: String,
        limit: Int
    ) -> [TerminalAutocompleteDirectoryEntry] {
        let fields = output.split(
            separator: "\0",
            omittingEmptySubsequences: false
        )
        var entries: [TerminalAutocompleteDirectoryEntry] = []
        var index = 0
        while index + 1 < fields.count, entries.count < limit {
            let name = String(fields[index])
            let kind = TerminalAutocompleteDirectoryEntry.Kind(
                rawValue: String(fields[index + 1])
            )
            if !name.isEmpty, let kind {
                entries.append(
                    TerminalAutocompleteDirectoryEntry(
                        name: name,
                        kind: kind
                    )
                )
            }
            index += 2
        }
        return entries
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

@MainActor
final class AppState: ObservableObject {
    private static let localHostID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
    )!

    @Published private(set) var hosts: [TermPilotDomain.Host] = []
    @Published private(set) var groups: [HostGroup] = []
    @Published private(set) var credentials: [SSHCredential] = []
    @Published private(set) var recentHosts: [TermPilotDomain.Host] = []
    @Published private(set) var proxyProfiles: [SSHProxyProfile] = []
    @Published private(set) var workspaces: [WorkspaceDocument] = []
    @Published private(set) var sessions: [UUID: SessionDescriptor] = [:]
    @Published private(set) var runtimes: [UUID: TerminalSessionRuntime] = [:]
    @Published private(set) var knownHosts: [KnownHostRecord] = []
    @Published private(set) var fileTransfers: [FileTransferRecord] = []
    @Published private(set) var terminalSidePanelWorkspaceIDs = Set<UUID>()
    @Published private(set) var workspaceSFTPModels: [UUID: SFTPBrowserModel] = [:]
    @Published private(set) var workspaceCommandHistoryModels: [UUID: CommandHistoryModel] = [:]
    @Published private(set) var workspaceSidePanelSessionIDs: [UUID: UUID] = [:]
    @Published private(set) var workspaceSidePanelTabs: [UUID: TerminalSidePanelTab] = [:]
    @Published private(set) var workspaceSystemMonitorTabs: [UUID: String] = [:]
    @Published private(set) var portForwardRules: [PortForwardRule] = []
    @Published private(set) var automationScripts: [AutomationScript] = []
    @Published private(set) var hostNotes: [HostNote] = []
    @Published private(set) var portForwardHostKeyPrompt: PortForwardHostKeyPrompt?
    @Published var activeWorkspaceID: UUID?
    @Published var hostSearch = ""
    @Published var presentedError: String?
    @Published private(set) var isReady = false

    let registry = TerminalSessionRegistry()

    private var vaultStore: VaultStore?
    private var knownHostsStore: KnownHostsStore?
    private var recordedHistorySessionIDs = Set<UUID>()
    private var knownHostRefreshSessionIDs = Set<UUID>()
    private var hostDistroDetectionHostIDs = Set<UUID>()
    private var registryTask: Task<Void, Never>?
    private var vaultChangeTask: Task<Void, Never>?
    private var askPassRequestTask: Task<Void, Never>?
    private var askPassRequestDirectory: URL?
    private var handledAskPassRequestIDs = Set<String>()
    private var portForwardProcesses: [UUID: ManagedPortForwardProcess] = [:]
    private var sessionHosts: [UUID: TermPilotDomain.Host] = [:]
    private var automaticSystemOverviewSuppressedSessionIDs = Set<UUID>()
    private var workspaceServerToolsExecClients:
        [UUID: WorkspaceServerToolsExecClient] = [:]

    var filteredHosts: [TermPilotDomain.Host] {
        let query = hostSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return hosts
        }
        return hosts.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.hostname.localizedCaseInsensitiveContains(query)
                || $0.username.localizedCaseInsensitiveContains(query)
        }
    }

    var activeWorkspace: WorkspaceDocument? {
        workspaces.first { $0.id == activeWorkspaceID }
    }

    func isTerminalSidePanelVisible(in workspaceID: UUID) -> Bool {
        terminalSidePanelWorkspaceIDs.contains(workspaceID)
    }

    func terminalSidePanelSourceSessionID(in workspaceID: UUID) -> UUID? {
        workspaceSidePanelSessionIDs[workspaceID]
    }

    func terminalSidePanelUpdateID(in workspaceID: UUID) -> String {
        guard let sourceSessionID = workspaceSidePanelSessionIDs[workspaceID],
              let descriptor = sessions[sourceSessionID]
        else {
            return workspaceID.uuidString
        }
        let connectionID: String
        switch descriptor.kind {
        case .local:
            connectionID = "local"
        case .ssh:
            connectionID = descriptor.sshConnectionID?.uuidString
                ?? sourceSessionID.uuidString
        }
        return "\(workspaceID.uuidString)-\(connectionID)"
    }

    func terminalSidePanelSessionID(in workspaceID: UUID) -> UUID? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              let sourceSessionID = workspaceSidePanelSessionIDs[workspaceID],
              workspace.root.sessionIDs.contains(sourceSessionID),
              let sourceDescriptor = sessions[sourceSessionID]
        else {
            return nil
        }
        let focusedSessionID = workspace.focusedSessionID
        guard let focusedDescriptor = sessions[focusedSessionID],
              Self.terminalSidePanelDescriptorsShareConnection(
                  sourceDescriptor,
                  focusedDescriptor
              )
        else {
            return sourceSessionID
        }
        return focusedSessionID
    }

    nonisolated static func terminalSidePanelDescriptorsShareConnection(
        _ lhs: SessionDescriptor,
        _ rhs: SessionDescriptor
    ) -> Bool {
        if lhs.id == rhs.id {
            return true
        }
        guard lhs.kind == rhs.kind else {
            return false
        }
        switch lhs.kind {
        case .local:
            return true
        case .ssh:
            guard let lhsConnectionID = lhs.sshConnectionID,
                  let rhsConnectionID = rhs.sshConnectionID
            else {
                return false
            }
            return lhsConnectionID == rhsConnectionID
        }
    }

    func terminalSidePanelTab(in workspaceID: UUID) -> TerminalSidePanelTab {
        workspaceSidePanelTabs[workspaceID] ?? .sftp
    }

    func terminalSystemMonitorTab(in workspaceID: UUID) -> String {
        workspaceSystemMonitorTabs[workspaceID] ?? "overview"
    }

    func selectTerminalSystemMonitorTab(
        _ tab: String,
        in workspaceID: UUID
    ) {
        workspaceSystemMonitorTabs[workspaceID] = tab
    }

    func sftpSidePanelModel(in workspaceID: UUID) -> SFTPBrowserModel? {
        workspaceSFTPModels[workspaceID]
    }

    func commandHistoryModel(in workspaceID: UUID) -> CommandHistoryModel? {
        workspaceCommandHistoryModels[workspaceID]
    }

    func sessionHost(for descriptor: SessionDescriptor) -> TermPilotDomain.Host? {
        switch descriptor.kind {
        case .local:
            return TermPilotDomain.Host(
                id: Self.localHostID,
                label: AppLocalization.string("Local Terminal"),
                hostname: ProcessInfo.processInfo.hostName,
                username: NSUserName(),
                distro: .macos
            )
        case .ssh:
            return try? sshHost(for: descriptor)
        }
    }

    func toggleSFTPSidePanel(
        in workspaceID: UUID,
        for sessionID: UUID
    ) {
        if terminalSidePanelWorkspaceIDs.contains(workspaceID) {
            let usesRequestedConnection =
                workspaceSidePanelSessionIDs[workspaceID]
                    .flatMap { sessions[$0] }
                    .flatMap { sourceDescriptor in
                        sessions[sessionID].map {
                            Self.terminalSidePanelDescriptorsShareConnection(
                                sourceDescriptor,
                                $0
                            )
                        }
                    } ?? false
            if usesRequestedConnection,
               (workspaceSidePanelTabs[workspaceID] == .sftp
                || workspaceSidePanelTabs[workspaceID] == nil)
            {
                closeTerminalSidePanel(in: workspaceID)
            } else {
                openTerminalSidePanel(
                    in: workspaceID,
                    for: sessionID,
                    tab: .sftp
                )
            }
        } else {
            openTerminalSidePanel(
                in: workspaceID,
                for: sessionID,
                tab: .sftp
            )
        }
    }

    func openTerminalSidePanel(
        in workspaceID: UUID,
        for sessionID: UUID,
        tab: TerminalSidePanelTab
    ) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              workspace.root.sessionIDs.contains(sessionID),
              let descriptor = sessions[sessionID],
              let host = sessionHost(for: descriptor)
        else {
            return
        }
        let isLocal = descriptor.kind == .local
        let sourceDescriptor = workspaceSidePanelSessionIDs[workspaceID]
            .flatMap { sessions[$0] }
        let keepsExistingConnection = sourceDescriptor.map {
            Self.terminalSidePanelDescriptorsShareConnection($0, descriptor)
        } ?? false
        let hasExistingModels =
            workspaceSFTPModels[workspaceID] != nil
            || workspaceCommandHistoryModels[workspaceID] != nil
        if (!keepsExistingConnection
                && workspaceSidePanelSessionIDs[workspaceID] != nil)
            || (sourceDescriptor == nil && hasExistingModels)
        {
            closeTerminalSidePanel(in: workspaceID)
        }
        if workspaceSidePanelSessionIDs[workspaceID] == nil {
            workspaceSidePanelSessionIDs[workspaceID] = sessionID
        }
        if workspaceSFTPModels[workspaceID] == nil {
            workspaceSFTPModels[workspaceID] = SFTPBrowserModel(
                host: host,
                sourceConnectionID: descriptor.sshConnectionID,
                sourceSessionID: sessionID,
                dataSource: isLocal ? .local : .remote,
                initialLocalDirectory: isLocal
                    ? runtimes[sessionID]?.currentDirectory
                        ?? descriptor.workingDirectory
                    : nil
            )
        }
        if workspaceCommandHistoryModels[workspaceID] == nil {
            workspaceCommandHistoryModels[workspaceID] = CommandHistoryModel(
                host: host,
                workspaceID: workspaceID,
                sourceConnectionID: descriptor.sshConnectionID,
                sourceSessionID: sessionID,
                dataSource: isLocal
                    ? .local(shell: descriptor.shell)
                    : .remote
            )
        }
        workspaceSidePanelTabs[workspaceID] = tab
        terminalSidePanelWorkspaceIDs.insert(workspaceID)
    }

    func selectTerminalSidePanelTab(
        _ tab: TerminalSidePanelTab,
        in workspaceID: UUID
    ) {
        guard terminalSidePanelWorkspaceIDs.contains(workspaceID) else {
            return
        }
        workspaceSidePanelTabs[workspaceID] = tab
    }

    func closeTerminalSidePanel(in workspaceID: UUID) {
        terminalSidePanelWorkspaceIDs.remove(workspaceID)
        workspaceSidePanelTabs.removeValue(forKey: workspaceID)
        workspaceSystemMonitorTabs.removeValue(forKey: workspaceID)
        workspaceSidePanelSessionIDs.removeValue(forKey: workspaceID)
        releaseServerToolsExecClient(in: workspaceID)
        let model = workspaceSFTPModels.removeValue(forKey: workspaceID)
        model?.close()
        workspaceCommandHistoryModels.removeValue(forKey: workspaceID)
    }

    private func releaseServerToolsExecClient(in workspaceID: UUID) {
        guard let entry = workspaceServerToolsExecClients.removeValue(
            forKey: workspaceID
        ) else {
            return
        }
        Task {
            await entry.client.close()
        }
    }

    private func releaseAllServerToolsExecClients() {
        let clients = workspaceServerToolsExecClients.values.map(\.client)
        workspaceServerToolsExecClients.removeAll()
        Task {
            for client in clients {
                await client.close()
            }
        }
    }

    func bootstrap(
        startsAutoPortForwards: Bool = true,
        initialWorkspaceSnapshot: WorkspaceSnapshot? = nil
    ) async {
        guard !isReady else {
            return
        }
        do {
            let vault = try await Task.detached {
                try VaultStore.openDefault()
            }.value
            let knownHostsStore = try await Task.detached {
                try KnownHostsStore()
            }.value

            vaultStore = vault
            self.knownHostsStore = knownHostsStore
            hosts = try await vault.fetchHosts()
            groups = try await vault.fetchGroups()
            credentials = try await vault.fetchCredentials()
            proxyProfiles = try await vault.fetchProxyProfiles()
            knownHosts = try await knownHostsStore.records()
            try await refreshLocalWorkflows()
            try? await vault.eraseWorkspaceSnapshot()

            if let initialWorkspaceSnapshot {
                try await restore(
                    initialWorkspaceSnapshot,
                    startsSessionsOnDisplay: true
                )
            }
            observeRegistry()
            observeVaultChanges()
            startAskPassRequestObserver()
            isReady = true
            if startsAutoPortForwards {
                await startAutoStartPortForwards()
            }
        } catch {
            presentedError = AppLocalization.errorDescription(error)
            isReady = true
        }
    }

    func respondToPortForwardHostKeyPrompt(accepted: Bool) {
        guard let prompt = portForwardHostKeyPrompt else {
            return
        }
        let response = accepted ? "yes\n" : "no\n"
        do {
            try response.write(to: prompt.responseURL, atomically: true, encoding: .utf8)
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
        portForwardHostKeyPrompt = nil
    }

    func currentWorkspaceSnapshot() -> WorkspaceSnapshot? {
        let liveSessionIDs = Set(runtimes.keys)
        let liveSessions = sessions.values.filter {
            liveSessionIDs.contains($0.id)
        }
        return WorkspaceSnapshot(
            activeWorkspaceID: activeWorkspaceID,
            sessions: Array(liveSessions),
            workspaces: workspaces
        ).sanitized()
    }

    func currentWorkspaceCloneSnapshot() -> WorkspaceSnapshot? {
        guard let snapshot = currentWorkspaceSnapshot() else {
            return nil
        }

        var sessionIDReplacements: [UUID: UUID] = [:]
        var connectionIDReplacements: [UUID: UUID] = [:]
        let clonedSessions = snapshot.sessions.map { session -> SessionDescriptor in
            var copy = session
            let newID = UUID()
            sessionIDReplacements[session.id] = newID
            copy.id = newID
            if copy.kind == .ssh {
                copy.sshConnectionID = replacedConnectionID(
                    for: session.sshConnectionID,
                    replacements: &connectionIDReplacements
                )
            }
            return copy
        }

        var workspaceIDReplacements: [UUID: UUID] = [:]
        let clonedWorkspaces = snapshot.workspaces.map { workspace -> WorkspaceDocument in
            let newID = UUID()
            workspaceIDReplacements[workspace.id] = newID
            return WorkspaceDocument(
                id: newID,
                title: workspace.title,
                root: workspace.root.replacingSessionIDs(sessionIDReplacements),
                focusedSessionID: sessionIDReplacements[workspace.focusedSessionID]
                    ?? workspace.focusedSessionID,
                pinned: workspace.pinned
            )
        }

        return WorkspaceSnapshot(
            activeWorkspaceID: activeWorkspaceID.flatMap {
                workspaceIDReplacements[$0]
            },
            sessions: clonedSessions,
            workspaces: clonedWorkspaces
        ).sanitized()
    }

    func refreshHosts() async {
        guard let vaultStore else {
            return
        }
        do {
            hosts = try await vaultStore.fetchHosts()
            groups = try await vaultStore.fetchGroups()
            credentials = try await vaultStore.fetchCredentials()
            proxyProfiles = try await vaultStore.fetchProxyProfiles()
            refreshSessionHostAppearances()
            refreshActivePasswordPromptAssistConfigurations()
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    private func refreshSessionHostAppearances() {
        let hostsByID = Dictionary(uniqueKeysWithValues: hosts.map {
            ($0.id, $0)
        })
        for sessionID in Array(sessionHosts.keys) {
            guard var sessionHost = sessionHosts[sessionID] else {
                continue
            }
            guard let savedHost = hostsByID[sessionHost.id] else {
                continue
            }
            sessionHost.distro = savedHost.distro
            sessionHost.distroMode = savedHost.distroMode
            sessionHost.manualDistro = savedHost.manualDistro
            sessionHost.iconMode = savedHost.iconMode
            sessionHost.iconID = savedHost.iconID
            sessionHost.iconColorMode = savedHost.iconColorMode
            sessionHost.iconColor = savedHost.iconColor
            sessionHost.iconColorCustom = savedHost.iconColorCustom
            sessionHosts[sessionID] = sessionHost
        }
    }

    func refreshRecentHosts() async {
        guard let vaultStore else { return }
        do {
            let history = try await vaultStore.fetchHistory(limit: 50)
            var uniqueHostIDs = [UUID]()
            var seen = Set<UUID>()
            for entry in history {
                guard let hostID = entry.hostID, !seen.contains(hostID) else { continue }
                seen.insert(hostID)
                uniqueHostIDs.append(hostID)
            }
            let mapped = uniqueHostIDs.compactMap { id in self.hosts.first(where: { $0.id == id }) }
            await MainActor.run { self.recentHosts = Array(mapped.prefix(5)) }
        } catch {
            // ignore
        }
    }

    func refreshCredentials() async {
        guard let vaultStore else {
            return
        }
        do {
            credentials = try await vaultStore.fetchCredentials()
            releaseAllServerToolsExecClients()
            refreshActivePasswordPromptAssistConfigurations()
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func refreshProxyProfiles() async {
        guard let vaultStore else {
            return
        }
        do {
            proxyProfiles = try await vaultStore.fetchProxyProfiles()
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func exportEncryptedBackup(
        to url: URL,
        password: String
    ) async throws {
        guard let vaultStore else {
            throw AppStateError.notReady
        }
        let snapshot = try await vaultStore.makeBackupSnapshot()
        let data = try await Task.detached(priority: .userInitiated) {
            try EncryptedBackupCodec.encrypt(
                snapshot,
                password: password
            )
        }.value
        try data.write(to: url, options: [.atomic])
    }

    func importEncryptedBackup(
        from url: URL,
        password: String
    ) async throws -> BackupImportSummary {
        guard let vaultStore else {
            throw AppStateError.notReady
        }
        let data = try Data(
            contentsOf: url,
            options: [.mappedIfSafe]
        )
        let snapshot = try await Task.detached(
            priority: .userInitiated
        ) {
            try EncryptedBackupCodec.decrypt(
                data,
                password: password
            )
        }.value
        let summary = try await vaultStore.importBackupSnapshot(
            snapshot
        )
        hosts = try await vaultStore.fetchHosts()
        groups = try await vaultStore.fetchGroups()
        credentials = try await vaultStore.fetchCredentials()
        proxyProfiles = try await vaultStore.fetchProxyProfiles()
        try await refreshLocalWorkflows()
        releaseAllServerToolsExecClients()
        refreshSessionHostAppearances()
        refreshActivePasswordPromptAssistConfigurations()
        notifyVaultChanged()
        return summary
    }

    func saveCredential(_ credential: SSHCredential) async {
        guard let vaultStore else {
            presentedError = AppLocalization.errorDescription(AppStateError.notReady)
            return
        }
        do {
            try await vaultStore.saveCredential(credential)
            await refreshCredentials()
            await refreshHosts()
            notifyVaultChanged()
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func createGeneratedCredential(
        label: String,
        username: String,
        request: SSHKeyGenerationRequest
    ) async throws -> SSHCredential {
        guard let vaultStore else {
            throw AppStateError.notReady
        }
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            throw CredentialValidationError.missingLabel
        }
        guard !username.isEmpty else {
            throw CredentialValidationError.missingUsername
        }
        let script = AppResourceLocator.url(
            forResource: "termpilot-keygen",
            withExtension: "cjs",
            subdirectory: "keygen"
        ) ?? AppResourceLocator.url(
            forResource: "termpilot-keygen",
            withExtension: "cjs"
        )
        guard let script else {
            throw AppStateError.missingCredentialKeyGenerator
        }
        guard let resourceDirectory = Bundle.main.resourceURL,
              let runtime = SSH2BridgeRuntimeLocator.bundledRuntime(
                  in: resourceDirectory
              )
        else {
            throw AppStateError.missingSSH2BridgeRuntime
        }
        var request = request
        request.comment = label
        let pair = try await SSHCredentialKeyGenerator.generate(
            request: request,
            script: script,
            runtime: runtime
        )
        let credential = SSHCredential(
            label: label,
            username: username,
            kind: .identityKey,
            privateKey: pair.privateKey,
            publicKey: pair.publicKey,
            passphrase: request.passphrase,
            savesPassphrase: request.passphrase?.isEmpty == false
        )
        try await vaultStore.saveCredential(credential)
        await refreshCredentials()
        notifyVaultChanged()
        return credential
    }

    func exportCredential(
        _ credential: SSHCredential,
        to host: TermPilotDomain.Host
    ) async throws {
        guard let vaultStore else {
            throw AppStateError.notReady
        }
        guard credential.kind == .identityKey,
              credential.privateKey?.isEmpty == false,
              let publicKey = credential.publicKey,
              !publicKey.isEmpty
        else {
            throw SSHCredentialKeyError.invalidPublicKey
        }
        let command = try SSHAuthorizedKeyCommand.make(publicKey: publicKey)
        let client = try makeSFTPClient(
            for: host,
            opensFileChannel: false
        )
        let response: RemoteExecResponse
        do {
            response = try await client.exec(
                command: command,
                timeoutMS: 30_000
            )
            await client.close()
        } catch {
            await client.close()
            throw error
        }
        if let code = response.code, code != 0 {
            let message = response.stderr.isEmpty
                ? "Remote key installation failed."
                : response.stderr
            throw SSHCredentialKeyError.remoteInstallFailed(message)
        }

        var verificationHost = host
        verificationHost.authentication = .identityFile
        verificationHost.credentialID = nil
        verificationHost.password = nil
        verificationHost.identityFile = nil
        verificationHost.identityKey = credential.privateKey
        verificationHost.publicKey = credential.publicKey
        verificationHost.certificate = credential.certificate
        verificationHost.passphrase = credential.passphrase
        let verificationClient = try makeSFTPClient(
            for: verificationHost,
            opensFileChannel: false
        )
        do {
            let verification = try await verificationClient.exec(
                command: "true",
                timeoutMS: 20_000
            )
            await verificationClient.close()
            if let code = verification.code, code != 0 {
                throw SSHCredentialKeyError.keyAuthenticationRejected
            }
        } catch {
            await verificationClient.close()
            throw SSHCredentialKeyError.keyAuthenticationRejected
        }

        var linkedHost = host
        linkedHost.authentication = .identityFile
        linkedHost.credentialID = credential.id
        linkedHost.password = nil
        linkedHost.identityFile = nil
        linkedHost.identityKey = nil
        linkedHost.publicKey = nil
        linkedHost.certificate = nil
        linkedHost.passphrase = nil
        try await vaultStore.saveHost(linkedHost)
        await refreshHosts()
        notifyVaultChanged()
    }

    func deleteCredential(_ credential: SSHCredential) async -> Bool {
        guard let vaultStore else {
            return false
        }
        do {
            try await vaultStore.deleteCredential(id: credential.id)
            await refreshCredentials()
            await refreshHosts()
            notifyVaultChanged()
            return true
        } catch {
            presentedError = AppLocalization.errorDescription(error)
            return false
        }
    }

    func saveProxyProfile(_ profile: SSHProxyProfile) async -> Bool {
        guard let vaultStore else {
            presentedError = AppLocalization.errorDescription(AppStateError.notReady)
            return false
        }
        do {
            let profile = try profile.validated()
            try validateProxyCredentialReference(profile.configuration)
            try await vaultStore.saveProxyProfile(profile)
            await refreshProxyProfiles()
            await refreshHosts()
            notifyVaultChanged()
            return true
        } catch {
            presentedError = AppLocalization.errorDescription(error)
            return false
        }
    }

    func deleteProxyProfile(_ profile: SSHProxyProfile) async {
        guard let vaultStore else {
            return
        }
        do {
            try await vaultStore.deleteProxyProfile(id: profile.id)
            await refreshProxyProfiles()
            await refreshHosts()
            notifyVaultChanged()
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func moveProxyProfile(
        id: UUID,
        over targetID: UUID
    ) {
        guard id != targetID,
              let sourceIndex = proxyProfiles.firstIndex(where: {
                  $0.id == id
              }),
              let targetIndex = proxyProfiles.firstIndex(where: {
                  $0.id == targetID
              })
        else {
            return
        }
        let profile = proxyProfiles.remove(at: sourceIndex)
        proxyProfiles.insert(
            profile,
            at: min(targetIndex, proxyProfiles.count)
        )
    }

    func persistProxyProfileOrder() async {
        guard let vaultStore else {
            return
        }
        do {
            try await vaultStore.reorderProxyProfiles(
                ids: proxyProfiles.map(\.id)
            )
            notifyVaultChanged()
        } catch {
            await refreshProxyProfiles()
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    private func validateProxyCredentialReference(
        _ configuration: SSHProxyConfiguration?
    ) throws {
        guard let credentialID = configuration?.credentialID else {
            return
        }
        guard let credential = credentials.first(where: {
            $0.id == credentialID
        }),
        credential.kind == .password,
        !credential.username.isEmpty,
        credential.password?.isEmpty == false
        else {
            throw AppStateError.invalidProxyCredential
        }
    }

    func saveHost(
        _ host: TermPilotDomain.Host,
        password: String?
    ) async -> Bool {
        guard let vaultStore else {
            presentedError = AppLocalization.errorDescription(AppStateError.notReady)
            return false
        }

        var host = host
        if let credentialID = host.credentialID {
            guard let credential = credentials.first(where: { $0.id == credentialID }) else {
                presentedError = AppLocalization.errorDescription(AppStateError.invalidCredential)
                return false
            }
            if host.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                host.username = credential.username
            }
            host.authentication = credential.kind.authenticationMethod
            host.password = nil
            host.identityFile = nil
            host.identityKey = nil
            host.passphrase = nil
        } else if host.authentication == .password {
            if let password, !password.isEmpty {
                host.password = password
            }
        } else {
            host.password = nil
        }
        if let proxyConfiguration = host.proxyConfiguration {
            do {
                host.proxyConfiguration = try proxyConfiguration.validated()
                host.proxyProfileID = nil
                try validateProxyCredentialReference(host.proxyConfiguration)
            } catch {
                presentedError = AppLocalization.errorDescription(error)
                return false
            }
        } else if let proxyProfileID = host.proxyProfileID {
            guard let proxyProfile = proxyProfiles.first(where: {
                $0.id == proxyProfileID
            }) else {
                presentedError = AppLocalization.errorDescription(
                    AppStateError.invalidProxyProfile
                )
                return false
            }
            do {
                try validateProxyCredentialReference(
                    proxyProfile.configuration
                )
            } catch {
                presentedError = AppLocalization.errorDescription(error)
                return false
            }
        }
        do {
            try await vaultStore.saveHost(host)
            await refreshHosts()
            notifyVaultChanged()
            return true
        } catch {
            presentedError = AppLocalization.errorDescription(error)
            return false
        }
    }

    func deleteHost(_ host: TermPilotDomain.Host) async {
        guard let vaultStore else {
            return
        }
        do {
            try await vaultStore.deleteHost(id: host.id)
            await refreshHosts()
            notifyVaultChanged()
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func moveHosts(
        ids: Set<UUID>,
        toGroup groupID: UUID?
    ) async -> Bool {
        guard let vaultStore else {
            presentedError = AppLocalization.errorDescription(AppStateError.notReady)
            return false
        }
        guard !ids.isEmpty else {
            return true
        }
        if let groupID,
           !groups.contains(where: { $0.id == groupID })
        {
            presentedError = AppLocalization.errorDescription(AppStateError.invalidGroup)
            return false
        }
        do {
            try await vaultStore.moveHosts(ids: ids, toGroup: groupID)
            await refreshHosts()
            notifyVaultChanged()
            return true
        } catch {
            presentedError = AppLocalization.errorDescription(error)
            return false
        }
    }

    func reorderHosts(
        ids: Set<UUID>,
        toGroup groupID: UUID?,
        beforeHostID: UUID?
    ) async -> Bool {
        guard let vaultStore else {
            presentedError = AppLocalization.errorDescription(AppStateError.notReady)
            return false
        }
        guard !ids.isEmpty else {
            return true
        }
        if let groupID,
           !groups.contains(where: { $0.id == groupID })
        {
            presentedError = AppLocalization.errorDescription(AppStateError.invalidGroup)
            return false
        }
        do {
            try await vaultStore.moveHosts(
                ids: ids,
                toGroup: groupID,
                beforeHostID: beforeHostID
            )
            await refreshHosts()
            notifyVaultChanged()
            return true
        } catch {
            presentedError = AppLocalization.errorDescription(error)
            return false
        }
    }

    func assignProxyProfile(
        toHosts ids: Set<UUID>,
        proxyProfileID: UUID
    ) async -> Bool {
        guard let vaultStore else {
            presentedError = AppLocalization.errorDescription(AppStateError.notReady)
            return false
        }
        guard !ids.isEmpty else {
            return true
        }
        guard let proxyProfile = proxyProfiles.first(where: {
            $0.id == proxyProfileID
        }) else {
            presentedError = AppLocalization.errorDescription(
                AppStateError.invalidProxyProfile
            )
            return false
        }
        do {
            try validateProxyCredentialReference(proxyProfile.configuration)
            try await vaultStore.assignProxyProfile(
                toHosts: ids,
                proxyProfileID: proxyProfileID
            )
            await refreshHosts()
            notifyVaultChanged()
            return true
        } catch {
            presentedError = AppLocalization.errorDescription(error)
            return false
        }
    }

    func disableProxy(
        forHosts ids: Set<UUID>
    ) async -> Bool {
        guard let vaultStore else {
            presentedError = AppLocalization.errorDescription(AppStateError.notReady)
            return false
        }
        guard !ids.isEmpty else {
            return true
        }
        do {
            try await vaultStore.disableProxy(forHosts: ids)
            await refreshHosts()
            notifyVaultChanged()
            return true
        } catch {
            presentedError = AppLocalization.errorDescription(error)
            return false
        }
    }

    func duplicateHost(_ host: TermPilotDomain.Host) async -> TermPilotDomain.Host? {
        guard let vaultStore else {
            presentedError = AppLocalization.errorDescription(AppStateError.notReady)
            return nil
        }
        var copy = host
        copy.id = UUID()
        copy.label = "\(host.label) \(AppLocalization.string("Copy"))"
        copy.createdAt = Date()
        copy.updatedAt = Date()

        do {
            try await vaultStore.saveHost(copy)
            await refreshHosts()
            notifyVaultChanged()
            return copy
        } catch {
            presentedError = AppLocalization.errorDescription(error)
            return nil
        }
    }

    func saveGroup(_ group: HostGroup) async -> Bool {
        guard let vaultStore else {
            return false
        }
        do {
            try await vaultStore.saveGroup(group)
            await refreshHosts()
            notifyVaultChanged()
            return true
        } catch {
            presentedError = AppLocalization.errorDescription(error)
            return false
        }
    }

    func moveGroup(
        id: UUID,
        toParent parentGroupID: UUID?,
        beforeGroupID: UUID?
    ) async -> Bool {
        guard let vaultStore else {
            presentedError = AppLocalization.errorDescription(AppStateError.notReady)
            return false
        }
        guard groups.contains(where: { $0.id == id }) else {
            presentedError = AppLocalization.errorDescription(AppStateError.invalidGroup)
            return false
        }
        if let parentGroupID,
           !groups.contains(where: { $0.id == parentGroupID })
        {
            presentedError = AppLocalization.errorDescription(AppStateError.invalidGroup)
            return false
        }
        do {
            try await vaultStore.moveGroup(
                id: id,
                toParent: parentGroupID,
                beforeGroupID: beforeGroupID
            )
            await refreshHosts()
            notifyVaultChanged()
            return true
        } catch {
            presentedError = AppLocalization.errorDescription(error)
            return false
        }
    }

    func deleteGroup(_ group: HostGroup) async {
        guard let vaultStore else {
            return
        }
        do {
            try await vaultStore.deleteGroup(id: group.id)
            await refreshHosts()
            notifyVaultChanged()
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func refreshKnownHosts() async {
        guard let knownHostsStore else {
            return
        }
        do {
            knownHosts = try await knownHostsStore.records()
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func deleteKnownHost(_ record: KnownHostRecord) async {
        guard let knownHostsStore else {
            return
        }
        do {
            try await knownHostsStore.remove(lineNumber: record.lineNumber)
            knownHosts = try await knownHostsStore.records()
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func deleteKnownHosts(_ records: [KnownHostRecord]) async {
        guard let knownHostsStore else {
            return
        }
        let lineNumbers = Set(records.map(\.lineNumber))
        guard !lineNumbers.isEmpty else {
            return
        }
        do {
            try await knownHostsStore.remove(lineNumbers: lineNumbers)
            knownHosts = try await knownHostsStore.records()
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func refreshLocalWorkflows() async throws {
        guard let vaultStore else {
            return
        }
        portForwardRules = try await vaultStore.fetchPortForwardRules()
            .map { rule in
                guard let process = portForwardProcesses[rule.id] else {
                    var copy = rule
                    if copy.status == .active || copy.status == .connecting {
                        copy.status = .inactive
                        copy.error = nil
                    }
                    return copy
                }
                var copy = rule
                copy.status = process.isRunning ? copy.status : .inactive
                return copy
            }
        automationScripts = mergedAutomationScripts(
            scripts: try await vaultStore.fetchAutomationScripts(),
            legacyScripts: try await vaultStore.fetchLegacyAutomationScriptsFromSnippets()
        )
        hostNotes = try await vaultStore.fetchHostNotes()
    }

    private func mergedAutomationScripts(
        scripts: [AutomationScript],
        legacyScripts: [AutomationScript]
    ) -> [AutomationScript] {
        let scriptIDs = Set(scripts.map(\.id))
        return scripts + legacyScripts.filter { !scriptIDs.contains($0.id) }
    }

    func savePortForwardRule(_ rule: PortForwardRule) async {
        guard let vaultStore else { return }
        do {
            if let existing = portForwardRules.first(where: { $0.id == rule.id }),
               existing.connectionSignature != rule.connectionSignature
            {
                await stopPortForward(existing)
            }
            try await vaultStore.savePortForwardRule(rule)
            try await refreshLocalWorkflows()
            notifyVaultChanged()
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func deletePortForwardRule(_ rule: PortForwardRule) async {
        guard let vaultStore else { return }
        do {
            await stopPortForward(rule)
            try await vaultStore.deletePortForwardRule(id: rule.id)
            try await refreshLocalWorkflows()
            notifyVaultChanged()
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func saveAutomationScript(_ script: AutomationScript) async {
        guard let vaultStore else { return }
        do {
            try await vaultStore.saveAutomationScript(script)
            try? await vaultStore.deleteLegacySnippet(id: script.id)
            try await refreshLocalWorkflows()
            notifyVaultChanged()
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func deleteAutomationScript(_ script: AutomationScript) async {
        guard let vaultStore else { return }
        do {
            try await vaultStore.deleteAutomationScript(id: script.id)
            try? await vaultStore.deleteLegacySnippet(id: script.id)
            try await refreshLocalWorkflows()
            notifyVaultChanged()
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func moveAutomationScript(
        id: UUID,
        over targetID: UUID
    ) {
        guard id != targetID,
              let sourceIndex = automationScripts.firstIndex(where: {
                  $0.id == id
              }),
              let targetIndex = automationScripts.firstIndex(where: {
                  $0.id == targetID
              })
        else {
            return
        }
        let script = automationScripts.remove(at: sourceIndex)
        automationScripts.insert(
            script,
            at: min(targetIndex, automationScripts.count)
        )
    }

    func persistAutomationScriptOrder() async {
        guard let vaultStore else {
            return
        }
        do {
            for script in automationScripts {
                try await vaultStore.saveAutomationScript(script)
                try? await vaultStore.deleteLegacySnippet(id: script.id)
            }
            try await vaultStore.reorderAutomationScripts(
                ids: automationScripts.map(\.id)
            )
            notifyVaultChanged()
        } catch {
            try? await refreshLocalWorkflows()
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func saveHostNote(_ note: HostNote) async {
        guard let vaultStore else { return }
        do {
            try await vaultStore.saveHostNote(note)
            try await refreshLocalWorkflows()
            notifyVaultChanged()
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func deleteHostNote(_ note: HostNote) async {
        guard let vaultStore else { return }
        do {
            try await vaultStore.deleteHostNote(id: note.id)
            try await refreshLocalWorkflows()
            notifyVaultChanged()
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func makeSFTPClient(
        for host: TermPilotDomain.Host,
        sourceConnectionID: UUID? = nil,
        sourceSessionID: UUID? = nil,
        opensFileChannel: Bool = true,
        elevatesOperations: Bool = false,
        persistentElevation: Bool = false
    ) throws -> SSH2SFTPBridgeClient {
        let resolvedHost = try host.applyingConnectionSettings(
            credentials: credentials,
            proxyProfiles: proxyProfiles
        )
        let elevationPassword = elevatesOperations
            ? PasswordPromptQuickFillResolver.password(
                for: resolvedHost,
                credentials: credentials
            )
            : nil
        let resourceName = sourceConnectionID == nil
            ? "termpilot-sftp-bridge"
            : "termpilot-ssh2-bridge"
        let subdirectory = sourceConnectionID == nil
            ? "sftp-bridge"
            : "ssh2-bridge"
        let bridgeScript = AppResourceLocator.url(
            forResource: resourceName,
            withExtension: "cjs",
            subdirectory: subdirectory
        ) ?? AppResourceLocator.url(
            forResource: resourceName,
            withExtension: "cjs"
        )
        guard let bridgeScript else {
            if sourceConnectionID == nil {
                throw AppStateError.missingSFTPBridge
            }
            throw AppStateError.missingSSH2Bridge
        }
        let sftpBridgeScript: URL?
        if sourceConnectionID == nil {
            sftpBridgeScript = nil
        } else {
            sftpBridgeScript = AppResourceLocator.url(
                forResource: "termpilot-sftp-bridge",
                withExtension: "cjs",
                subdirectory: "sftp-bridge"
            ) ?? AppResourceLocator.url(
                forResource: "termpilot-sftp-bridge",
                withExtension: "cjs"
            )
            guard sftpBridgeScript != nil else {
                throw AppStateError.missingSFTPBridge
            }
        }
        guard let resourceDirectory = Bundle.main.resourceURL,
              let runtime = SSH2BridgeRuntimeLocator.bundledRuntime(
                in: resourceDirectory
              )
        else {
            throw AppStateError.missingSSH2BridgeRuntime
        }
        return try SSH2SFTPBridgeClient(
            host: resolvedHost,
            sourceConnectionID: sourceConnectionID,
            sourceSessionID: sourceSessionID,
            bridgeScript: bridgeScript,
            sftpBridgeScript: sftpBridgeScript,
            runtime: runtime,
            opensFileChannel: opensFileChannel,
            elevatesOperations: elevatesOperations,
            persistentElevation: persistentElevation,
            elevationMethod: resolvedHost.serverToolsElevationMethod,
            elevationPassword: elevationPassword
        )
    }

    func execServerTool(
        in workspaceID: UUID,
        host: TermPilotDomain.Host,
        sourceConnectionID: UUID?,
        sourceSessionID: UUID?,
        command: String,
        timeoutMS: Int,
        elevated: Bool
    ) async throws -> RemoteExecResponse {
        try await execServerTool(
            in: workspaceID,
            host: host,
            sourceConnectionID: sourceConnectionID,
            sourceSessionID: sourceSessionID,
            command: command,
            timeoutMS: timeoutMS,
            elevated: elevated,
            allowsTransportRetry: true
        )
    }

    private func execServerTool(
        in workspaceID: UUID,
        host: TermPilotDomain.Host,
        sourceConnectionID: UUID?,
        sourceSessionID: UUID?,
        command: String,
        timeoutMS: Int,
        elevated: Bool,
        allowsTransportRetry: Bool
    ) async throws -> RemoteExecResponse {
        guard elevated else {
            let client = try makeSFTPClient(
                for: host,
                sourceConnectionID: sourceConnectionID,
                sourceSessionID: sourceSessionID,
                opensFileChannel: false
            )
            do {
                let response = try await client.exec(
                    command: command,
                    timeoutMS: timeoutMS
                )
                await client.close()
                return response
            } catch {
                await client.close()
                try Task.checkCancellation()
                if allowsTransportRetry,
                   Self.isRecoverableServerToolsTransportError(error)
                {
                    return try await execServerTool(
                        in: workspaceID,
                        host: host,
                        sourceConnectionID: sourceConnectionID,
                        sourceSessionID: sourceSessionID,
                        command: command,
                        timeoutMS: timeoutMS,
                        elevated: elevated,
                        allowsTransportRetry: false
                    )
                }
                throw error
            }
        }

        let entry: WorkspaceServerToolsExecClient
        if let existing = workspaceServerToolsExecClients[workspaceID],
           existing.hostID == host.id,
           existing.connectionID == sourceConnectionID,
           existing.hostUpdatedAt == host.updatedAt,
           existing.elevationMethod == host.serverToolsElevationMethod
        {
            entry = existing
        } else {
            releaseServerToolsExecClient(in: workspaceID)
            let client = try makeSFTPClient(
                for: host,
                sourceConnectionID: sourceConnectionID,
                sourceSessionID: sourceSessionID,
                opensFileChannel: false,
                elevatesOperations: true,
                persistentElevation: true
            )
            entry = WorkspaceServerToolsExecClient(
                token: UUID(),
                hostID: host.id,
                connectionID: sourceConnectionID,
                hostUpdatedAt: host.updatedAt,
                elevationMethod: host.serverToolsElevationMethod,
                client: client
            )
            workspaceServerToolsExecClients[workspaceID] = entry
        }

        do {
            return try await entry.client.exec(
                command: command,
                timeoutMS: timeoutMS,
                elevated: true
            )
        } catch {
            if workspaceServerToolsExecClients[workspaceID]?.token
                == entry.token
            {
                workspaceServerToolsExecClients.removeValue(
                    forKey: workspaceID
                )
            }
            await entry.client.close()
            try Task.checkCancellation()
            if allowsTransportRetry,
               Self.isRecoverableServerToolsTransportError(error)
            {
                return try await execServerTool(
                    in: workspaceID,
                    host: host,
                    sourceConnectionID: sourceConnectionID,
                    sourceSessionID: sourceSessionID,
                    command: command,
                    timeoutMS: timeoutMS,
                    elevated: elevated,
                    allowsTransportRetry: false
                )
            }
            throw error
        }
    }

    nonisolated static func isRecoverableServerToolsTransportError(
        _ error: any Error
    ) -> Bool {
        if error is CancellationError {
            return false
        }
        if let bridgeError = error as? SSH2SFTPBridgeError {
            switch bridgeError {
            case .closed:
                return true
            case .remote:
                break
            }
        }

        let nsError = error as NSError
        let recoverablePOSIXCodes = Set([
            Int(POSIXErrorCode.EBADF.rawValue),
            Int(POSIXErrorCode.EPIPE.rawValue),
            Int(POSIXErrorCode.ECONNRESET.rawValue),
            Int(POSIXErrorCode.ENOTCONN.rawValue),
        ])
        if nsError.domain == NSPOSIXErrorDomain,
           recoverablePOSIXCodes.contains(nsError.code)
        {
            return true
        }
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey]
            as? any Error,
           isRecoverableServerToolsTransportError(underlyingError)
        {
            return true
        }

        let message = [
            error.localizedDescription,
            String(describing: error),
        ]
        .joined(separator: " ")
        .lowercased()
        return [
            "bad file descriptor",
            "错误的文件描述符",
            "broken pipe",
            "bridge is closed",
            "broker connection closed",
            "broker is not available",
            "socket is not connected",
            "connection reset",
            "persistent root session closed",
        ].contains { message.contains($0) }
    }

    func recordFileTransfer(_ transfer: FileTransferRecord) {
        fileTransfers.insert(transfer, at: 0)
        if fileTransfers.count > 100 {
            fileTransfers.removeLast(fileTransfers.count - 100)
        }
    }

    func updateFileTransfer(
        id: UUID,
        bytesTransferred: UInt64,
        totalBytes: UInt64?,
        at now: Date = Date()
    ) {
        guard let index = fileTransfers.firstIndex(where: { $0.id == id }) else {
            return
        }
        let elapsed = now.timeIntervalSince(fileTransfers[index].sampledAt)
        if elapsed >= 0.05,
           bytesTransferred >= fileTransfers[index].sampledBytes
        {
            let delta = bytesTransferred - fileTransfers[index].sampledBytes
            let instantaneousRate = Double(delta) / elapsed
            let previousRate = fileTransfers[index].bytesPerSecond
            fileTransfers[index].bytesPerSecond = previousRate > 0
                ? previousRate * 0.25 + instantaneousRate * 0.75
                : instantaneousRate
            fileTransfers[index].sampledBytes = bytesTransferred
            fileTransfers[index].sampledAt = now
        }
        fileTransfers[index].bytesTransferred = bytesTransferred
        fileTransfers[index].totalBytes = totalBytes ?? fileTransfers[index].totalBytes
    }

    func finishFileTransfer(
        id: UUID,
        status: FileTransferStatus,
        bytesTransferred: UInt64? = nil
    ) {
        guard let index = fileTransfers.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let bytesTransferred {
            fileTransfers[index].bytesTransferred = bytesTransferred
        }
        fileTransfers[index].bytesPerSecond = 0
        fileTransfers[index].status = status
        fileTransfers[index].finishedAt = Date()
    }

    func setFileTransferStatus(
        id: UUID,
        status: FileTransferStatus,
        bytesTransferred: UInt64? = nil,
        totalBytes: UInt64? = nil
    ) {
        guard let index = fileTransfers.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let bytesTransferred {
            fileTransfers[index].bytesTransferred = bytesTransferred
        }
        if let totalBytes {
            fileTransfers[index].totalBytes = totalBytes
        }
        fileTransfers[index].status = status
        switch status {
        case .succeeded, .failed, .cancelled, .paused:
            fileTransfers[index].bytesPerSecond = 0
        case .running:
            fileTransfers[index].bytesPerSecond = 0
            fileTransfers[index].sampledBytes =
                bytesTransferred ?? fileTransfers[index].bytesTransferred
            fileTransfers[index].sampledAt = Date()
        case .queued, .attention:
            break
        }
        switch status {
        case .succeeded, .failed, .cancelled:
            fileTransfers[index].finishedAt = Date()
        case .queued, .running, .paused, .attention:
            fileTransfers[index].finishedAt = nil
        }
    }

    func restartFileTransfer(
        id: UUID,
        destinationPath: String,
        name: String? = nil
    ) {
        guard let index = fileTransfers.firstIndex(where: { $0.id == id }) else {
            return
        }
        let now = Date()
        fileTransfers[index].destinationPath = destinationPath
        if let name {
            fileTransfers[index].name = name
        }
        fileTransfers[index].bytesTransferred = 0
        fileTransfers[index].totalBytes = nil
        fileTransfers[index].bytesPerSecond = 0
        fileTransfers[index].status = .running
        fileTransfers[index].finishedAt = nil
        fileTransfers[index].sampledBytes = 0
        fileTransfers[index].sampledAt = now
    }

    func clearFinishedFileTransfers() {
        fileTransfers.removeAll {
            switch $0.status {
            case .queued, .running, .paused, .attention:
                false
            case .succeeded, .failed, .cancelled:
                true
            }
        }
    }

    func connect(
        host: TermPilotDomain.Host,
        splitAxis: SplitAxis? = nil
    ) async {
        do {
            let resolvedHost = try host.applyingConnectionSettings(
                credentials: credentials,
                proxyProfiles: proxyProfiles
            )
            try await openSSHSession(host: resolvedHost, splitAxis: splitAxis)
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func quickConnect(
        _ value: String,
        authentication: AuthenticationMethod = .agent,
        password: String? = nil,
        identityFile: String? = nil,
        identityKey: String? = nil,
        publicKey: String? = nil,
        certificate: String? = nil,
        passphrase: String? = nil,
        elevationPassword: String? = nil,
        serverToolsUseRoot: Bool = false,
        serverToolsElevationMethod:
            ServerToolsElevationMethod = .sudo
    ) async -> Bool {
        do {
            let target = try QuickConnectParser.parse(value)
            return await quickConnect(
                hostname: target.hostname,
                username: target.username,
                port: target.port,
                authentication: authentication,
                password: password,
                identityFile: identityFile,
                identityKey: identityKey,
                publicKey: publicKey,
                certificate: certificate,
                passphrase: passphrase,
                elevationPassword: elevationPassword,
                serverToolsUseRoot: serverToolsUseRoot,
                serverToolsElevationMethod:
                    serverToolsElevationMethod
            )
        } catch {
            presentedError = AppLocalization.errorDescription(error)
            return false
        }
    }

    func quickConnect(
        hostname rawHostname: String,
        username rawUsername: String,
        port: Int,
        credentialID: UUID? = nil,
        authentication: AuthenticationMethod = .agent,
        password: String? = nil,
        identityFile: String? = nil,
        identityKey: String? = nil,
        publicKey: String? = nil,
        certificate: String? = nil,
        passphrase: String? = nil,
        elevationPassword: String? = nil,
        serverToolsUseRoot: Bool = false,
        serverToolsElevationMethod:
            ServerToolsElevationMethod = .sudo
    ) async -> Bool {
        do {
            var hostname = rawHostname.trimmingCharacters(in: .whitespacesAndNewlines)
            var username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            var effectivePort = port
            if hostname.lowercased().hasPrefix("ssh://") || hostname.contains("@") {
                let target = try QuickConnectParser.parse(hostname)
                hostname = target.hostname
                effectivePort = target.port
                if username.isEmpty {
                    username = target.username
                }
            }

            var resolvedAuthentication = authentication
            if let credentialID {
                guard let credential = credentials.first(where: { $0.id == credentialID }) else {
                    throw AppStateError.invalidCredential
                }
                if username.isEmpty {
                    username = credential.username
                }
                resolvedAuthentication = credential.kind.authenticationMethod
            }

            let host = Self.makeQuickConnectHost(
                hostname: hostname,
                port: effectivePort,
                username: username,
                authentication: resolvedAuthentication,
                identityFile: resolvedAuthentication == .identityFile ? identityFile : nil,
                identityKey: resolvedAuthentication == .identityFile ? identityKey : nil,
                publicKey: resolvedAuthentication == .identityFile ? publicKey : nil,
                certificate: resolvedAuthentication == .identityFile ? certificate : nil,
                passphrase: resolvedAuthentication == .identityFile ? passphrase : nil,
                password: credentialID == nil
                    && resolvedAuthentication == .password
                        ? password
                        : nil,
                elevationPassword: elevationPassword,
                credentialID: credentialID,
                serverToolsUseRoot: serverToolsUseRoot,
                serverToolsElevationMethod:
                    serverToolsElevationMethod
            )
            if credentialID == nil, resolvedAuthentication == .password {
                guard let password, !password.isEmpty else {
                    throw QuickConnectFormError.missingPassword
                }
            }
            let resolvedHost = try host.applyingConnectionSettings(
                credentials: credentials,
                proxyProfiles: proxyProfiles
            )
            try await openSSHSession(host: resolvedHost)
            return true
        } catch {
            presentedError = AppLocalization.errorDescription(error)
            return false
        }
    }

    nonisolated static func makeQuickConnectHost(
        hostname: String,
        port: Int,
        username: String,
        authentication: AuthenticationMethod,
        identityFile: String?,
        identityKey: String?,
        publicKey: String?,
        certificate: String?,
        passphrase: String?,
        password: String?,
        elevationPassword: String?,
        credentialID: UUID?,
        serverToolsUseRoot: Bool,
        serverToolsElevationMethod: ServerToolsElevationMethod
    ) -> TermPilotDomain.Host {
        TermPilotDomain.Host(
            id: QuickConnectHostIdentity.id(
                hostname: hostname,
                port: port,
                username: username
            ),
            label: hostname,
            hostname: hostname,
            port: port,
            username: username,
            authentication: authentication,
            identityFile: authentication == .identityFile
                ? identityFile
                : nil,
            identityKey: authentication == .identityFile
                ? identityKey
                : nil,
            publicKey: authentication == .identityFile
                ? publicKey
                : nil,
            certificate: authentication == .identityFile
                ? certificate
                : nil,
            passphrase: authentication == .identityFile
                ? passphrase
                : nil,
            password: authentication == .password
                ? password
                : nil,
            elevationPassword: elevationPassword,
            credentialID: credentialID,
            serverToolsUseRoot: serverToolsUseRoot,
            serverToolsElevationMethod: serverToolsElevationMethod
        )
    }

    func openLocalShell(splitAxis: SplitAxis? = nil) async {
        await prepareForSplitIfNeeded(splitAxis: splitAxis)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let descriptor = SessionDescriptor.local(
            shell: shell,
            workingDirectory: workingDirectory
        )
        let runtime = TerminalSessionRuntime(
            descriptor: descriptor,
            launchConfiguration: LocalShellLaunch.configuration(
                shell: shell,
                workingDirectory: workingDirectory
            ),
            registry: registry
        )
        await addSession(descriptor, runtime: runtime, splitAxis: splitAxis)
    }

    func runAutomationScript(_ script: AutomationScript) async {
        guard let sessionID = activeWorkspace?.focusedSessionID,
              runtimes[sessionID] != nil
        else {
            presentedError = AppLocalization.string("No focused terminal is available.")
            return
        }
        await runAutomationScript(script, in: sessionID)
    }

    func runAutomationScript(_ script: AutomationScript, in sessionID: UUID) async {
        guard let runtime = runtimes[sessionID] else {
            presentedError = AppLocalization.string("No focused terminal is available.")
            return
        }
        do {
            let script = try script.validated()
            sendShellScript(script.body, to: runtime)
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func runAutomationScript(
        _ script: AutomationScript,
        on host: TermPilotDomain.Host
    ) async {
        do {
            let sessionID = try await openSSHSession(host: host)
            try await waitForConnectedRuntime(sessionID: sessionID)
            guard let runtime = runtimes[sessionID] else {
                throw AppStateError.invalidSession
            }
            let script = try script.validated()
            sendShellScript(script.body, to: runtime)
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    private func sendShellScript(
        _ script: String,
        to runtime: TerminalSessionRuntime,
        automaticPassword: String? = nil
    ) {
        runtime.sendText(
            script.hasSuffix("\n") ? script : "\(script)\n",
            automaticPassword: automaticPassword
        )
    }

    private func waitForConnectedRuntime(sessionID: UUID) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard let runtime = runtimes[sessionID] else {
                throw AppStateError.invalidSession
            }
            switch runtime.lifecycle {
            case .connected:
                return
            case let .failed(message):
                throw AppStateError.workflowRunFailed(message)
            case let .exited(code):
                let message = code.map {
                    String(
                        format: AppLocalization.string("Session exited before script ran with code %@."),
                        String($0)
                    )
                } ?? AppLocalization.string("Session exited before script ran.")
                throw AppStateError.workflowRunFailed(message)
            case .connecting, .disconnected:
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw AppStateError.workflowRunFailed(
            AppLocalization.string("Timed out waiting for SSH connection.")
        )
    }


    func startPortForward(
        _ rule: PortForwardRule,
        host overrideHost: TermPilotDomain.Host? = nil
    ) async {
        do {
            var rule = try rule.validated()
            let host = try overrideHost?.applyingConnectionSettings(
                credentials: credentials,
                proxyProfiles: proxyProfiles
            )
                ?? hostForWorkflow(hostID: rule.hostID)
            if let process = portForwardProcesses[rule.id], process.isRunning {
                await updatePortForwardStatus(id: rule.id, status: .active)
                return
            }
            let launch = try await portForwardLaunchConfiguration(rule: rule, host: host)
            rule.status = .connecting
            rule.error = nil
            await savePortForwardRule(rule)
            let process = ManagedPortForwardProcess(
                ruleID: rule.id,
                launchConfiguration: launch
            ) { [weak self] ruleID, exitCode, stoppedByUser, errorOutput in
                Task {
                    await self?.handlePortForwardExit(
                        ruleID: ruleID,
                        exitCode: exitCode,
                        stoppedByUser: stoppedByUser,
                        errorOutput: errorOutput
                    )
                }
            }
            portForwardProcesses[rule.id] = process
            try process.start()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.markPortForwardActiveIfStillRunning(rule.id)
            }
        } catch {
            await updatePortForwardStatus(
                id: rule.id,
                status: .error,
                error: AppLocalization.errorDescription(error)
            )
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func stopPortForward(_ rule: PortForwardRule) async {
        if let process = portForwardProcesses.removeValue(forKey: rule.id) {
            process.stop()
        }
        await updatePortForwardStatus(id: rule.id, status: .inactive)
    }

    private func updatePortForwardStatus(
        id: UUID,
        status: PortForwardStatus,
        error: String? = nil
    ) async {
        guard let index = portForwardRules.firstIndex(where: { $0.id == id }) else {
            return
        }
        portForwardRules[index].status = status
        portForwardRules[index].error = error
        if status == .active {
            portForwardRules[index].lastUsedAt = Date()
        }
        guard let vaultStore else {
            return
        }
        do {
            try await vaultStore.savePortForwardRule(portForwardRules[index])
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    private func markPortForwardActiveIfStillRunning(_ id: UUID) async {
        guard let process = portForwardProcesses[id], process.isRunning else {
            return
        }
        await updatePortForwardStatus(id: id, status: .active)
    }

    private func handlePortForwardExit(
        ruleID: UUID,
        exitCode: Int32?,
        stoppedByUser: Bool,
        errorOutput: String
    ) async {
        portForwardProcesses.removeValue(forKey: ruleID)
        if stoppedByUser || exitCode == 0 {
            await updatePortForwardStatus(id: ruleID, status: .inactive)
        } else {
            let fallback = "Port forward exited with code \(exitCode.map(String.init) ?? "unknown")."
            await updatePortForwardStatus(
                id: ruleID,
                status: .error,
                error: errorOutput.isEmpty ? fallback : errorOutput
            )
        }
    }

    private func startAutoStartPortForwards() async {
        let rules = portForwardRules.filter(\.autoStart)
        for rule in rules {
            await startPortForward(rule)
        }
    }

    func openSiblingTerminal(
        from sessionID: UUID,
        splitAxis: SplitAxis
    ) async {
        await prepareForSplitIfNeeded(
            splitAxis: splitAxis,
            targetSessionID: sessionID
        )
        guard let descriptor = sessions[sessionID] else {
            await openLocalShell(splitAxis: splitAxis)
            return
        }

        switch descriptor.kind {
        case .local:
            await openLocalShell(splitAxis: splitAxis)
        case .ssh:
            do {
                let host = try sshHost(for: descriptor)
                try await openSSHSession(
                    host: host,
                    splitAxis: splitAxis,
                    connectionID: descriptor.sshConnectionID ?? UUID()
                )
            } catch {
                presentedError = AppLocalization.errorDescription(error)
            }
        }
    }

    @discardableResult
    func openTerminalTab(
        from sessionID: UUID,
        in workspaceID: UUID,
        title: String? = nil
    ) async -> UUID? {
        guard let descriptor = sessions[sessionID],
              let workspace = workspaces.first(where: { $0.id == workspaceID }),
              workspace.root.sessionIDs.contains(sessionID)
        else {
            return nil
        }

        switch descriptor.kind {
        case .local:
            let shell = descriptor.shell
                ?? ProcessInfo.processInfo.environment["SHELL"]
                ?? "/bin/zsh"
            var tabDescriptor = SessionDescriptor.local(
                shell: shell,
                workingDirectory: descriptor.workingDirectory
            )
            if let title, !title.isEmpty {
                tabDescriptor.title = title
            }
            let runtime = TerminalSessionRuntime(
                descriptor: tabDescriptor,
                launchConfiguration: LocalShellLaunch.configuration(
                    shell: shell,
                    workingDirectory: descriptor.workingDirectory
                ),
                registry: registry
            )
            automaticSystemOverviewSuppressedSessionIDs.insert(
                tabDescriptor.id
            )
            await addSessionAsTab(
                tabDescriptor,
                runtime: runtime,
                targetSessionID: sessionID,
                workspaceID: workspaceID
            )
            return tabDescriptor.id
        case .ssh:
            do {
                let host = try sshHost(for: descriptor)
                var tabDescriptor = SessionDescriptor.ssh(
                    host: host,
                    connectionID: descriptor.sshConnectionID ?? UUID()
                )
                if let title, !title.isEmpty {
                    tabDescriptor.title = title
                }
                let runtime = try await makeRuntime(
                    descriptor: tabDescriptor,
                    host: host,
                    startOnDisplay: true
                )
                sessionHosts[tabDescriptor.id] = host
                automaticSystemOverviewSuppressedSessionIDs.insert(
                    tabDescriptor.id
                )
                await addSessionAsTab(
                    tabDescriptor,
                    runtime: runtime,
                    targetSessionID: sessionID,
                    workspaceID: workspaceID
                )
                return tabDescriptor.id
            } catch {
                presentedError = AppLocalization.errorDescription(error)
                return nil
            }
        }
    }

    @discardableResult
    func openTerminalTabAndRun(
        from sessionID: UUID,
        in workspaceID: UUID,
        title: String,
        command: String,
        automaticElevationPassword: Bool = false
    ) async -> UUID? {
        let command = command.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !command.isEmpty,
              let terminalSessionID = await openTerminalTab(
                  from: sessionID,
                  in: workspaceID,
                  title: title
              )
        else {
            return nil
        }
        do {
            try await waitForConnectedRuntime(
                sessionID: terminalSessionID
            )
            guard let runtime = runtimes[terminalSessionID] else {
                throw AppStateError.invalidSession
            }
            let automaticPassword: String?
            if automaticElevationPassword,
               let sourceDescriptor = sessions[sessionID],
               let host = try? sshHost(for: sourceDescriptor)
            {
                automaticPassword =
                    PasswordPromptQuickFillResolver.password(
                        for: host,
                        credentials: credentials
                    )
            } else {
                automaticPassword = nil
            }
            sendShellScript(
                command,
                to: runtime,
                automaticPassword: automaticPassword
            )
            return terminalSessionID
        } catch {
            presentedError = AppLocalization.errorDescription(error)
            return nil
        }
    }

    func reconnect(sessionID: UUID) {
        guard let runtime = runtimes[sessionID] else {
            return
        }
        invalidateSFTPConnections(sharing: runtime.descriptor)
        runtime.reconnect()
    }

    private func invalidateSFTPConnections(
        sharing descriptor: SessionDescriptor
    ) {
        for (workspaceID, sourceSessionID) in workspaceSidePanelSessionIDs {
            guard let sourceDescriptor = sessions[sourceSessionID],
                  sourceSessionID == descriptor.id
                    || Self.terminalSidePanelDescriptorsShareConnection(
                        sourceDescriptor,
                        descriptor
                    )
            else {
                continue
            }
            workspaceSFTPModels[workspaceID]?.invalidateRemoteConnection()
        }
    }

    private func reconnectVisibleSFTPConnections(
        sharing descriptor: SessionDescriptor
    ) {
        for (workspaceID, sourceSessionID) in workspaceSidePanelSessionIDs {
            guard activeWorkspaceID == workspaceID,
                  terminalSidePanelWorkspaceIDs.contains(workspaceID),
                  terminalSidePanelTab(in: workspaceID) == .sftp,
                  let sourceDescriptor = sessions[sourceSessionID],
                  sourceSessionID == descriptor.id
                    || Self.terminalSidePanelDescriptorsShareConnection(
                        sourceDescriptor,
                        descriptor
                    ),
                  let model = workspaceSFTPModels[workspaceID]
            else {
                continue
            }
            Task {
                await model.connect(using: self)
            }
        }
    }

    func close(sessionID: UUID, in workspaceID: UUID) async {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return
        }
        let workspace = workspaces[index]
        if workspace.root.sessionIDs.count == 1 {
            await closeWorkspace(workspaceID)
            return
        }
        guard let root = workspace.root.removing(sessionID: sessionID) else {
            return
        }

        var updatedWorkspace = workspace
        updatedWorkspace.root = root
        if updatedWorkspace.focusedSessionID == sessionID,
           let fallback = root.sessionIDs.first
        {
            updatedWorkspace.focusedSessionID = fallback
        }

        if workspaceSidePanelSessionIDs[workspaceID] == sessionID {
            let replacementSessionID = sessions[sessionID].flatMap {
                sourceDescriptor in
                root.sessionIDs.first { candidateSessionID in
                    guard let candidateDescriptor = sessions[candidateSessionID]
                    else {
                        return false
                    }
                    return Self.terminalSidePanelDescriptorsShareConnection(
                        sourceDescriptor,
                        candidateDescriptor
                    )
                }
            }
            if let replacementSessionID {
                workspaceSidePanelSessionIDs[workspaceID] =
                    replacementSessionID
            } else {
                closeTerminalSidePanel(in: workspaceID)
            }
        }

        workspaces[index] = updatedWorkspace
        runtimes[sessionID]?.terminate()
        if let descriptor = sessions[sessionID] {
            await recordHistoryIfNeeded(descriptor: descriptor, exitCode: 143)
        }
        runtimes.removeValue(forKey: sessionID)
        sessions.removeValue(forKey: sessionID)
        sessionHosts.removeValue(forKey: sessionID)
        automaticSystemOverviewSuppressedSessionIDs.remove(sessionID)
        await registry.remove(id: sessionID)
    }

    func closeWorkspace(_ workspaceID: UUID) async {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return
        }
        let sessionIDs = workspaces[index].root.sessionIDs
        let nextActiveWorkspaceID = workspaces.indices.contains(index + 1)
            ? workspaces[index + 1].id
            : workspaces.indices.contains(index - 1)
                ? workspaces[index - 1].id
                : nil
        if activeWorkspaceID == workspaceID {
            activeWorkspaceID = nextActiveWorkspaceID
        }
        workspaces.remove(at: index)
        closeTerminalSidePanel(in: workspaceID)
        for sessionID in sessionIDs {
            runtimes[sessionID]?.terminate()
            if let descriptor = sessions[sessionID] {
                await recordHistoryIfNeeded(descriptor: descriptor, exitCode: 143)
            }
            runtimes.removeValue(forKey: sessionID)
            sessions.removeValue(forKey: sessionID)
            sessionHosts.removeValue(forKey: sessionID)
            automaticSystemOverviewSuppressedSessionIDs.remove(sessionID)
            await registry.remove(id: sessionID)
        }
    }

    func closeOtherWorkspaces(keeping workspaceID: UUID) async {
        let ids = workspaces.map(\.id).filter { $0 != workspaceID }
        for id in ids {
            await closeWorkspace(id)
        }
        activeWorkspaceID = workspaceID
    }

    func closeAllWorkspaces() async {
        let ids = workspaces.map(\.id)
        for id in ids {
            await closeWorkspace(id)
        }
    }

    func terminateAllSessionsImmediately() {
        let sessionIDs = Array(sessions.keys)
        let serverToolsExecClients =
            workspaceServerToolsExecClients.values.map(\.client)
        for runtime in runtimes.values {
            runtime.terminate()
        }
        for model in workspaceSFTPModels.values {
            model.close()
        }
        for process in portForwardProcesses.values {
            process.stop()
        }

        runtimes.removeAll()
        sessions.removeAll()
        sessionHosts.removeAll()
        automaticSystemOverviewSuppressedSessionIDs.removeAll()
        workspaceSFTPModels.removeAll()
        workspaceCommandHistoryModels.removeAll()
        terminalSidePanelWorkspaceIDs.removeAll()
        workspaceSidePanelSessionIDs.removeAll()
        workspaceSidePanelTabs.removeAll()
        workspaceSystemMonitorTabs.removeAll()
        workspaceServerToolsExecClients.removeAll()
        portForwardProcesses.removeAll()
        workspaces.removeAll()
        activeWorkspaceID = nil

        let registry = registry
        Task {
            for client in serverToolsExecClients {
                await client.close()
            }
            for sessionID in sessionIDs {
                await registry.remove(id: sessionID)
            }
        }
    }

    @discardableResult
    func detachSession(
        sessionID: UUID,
        from workspaceID: UUID,
        toIndex rawDestination: Int? = nil
    ) -> Bool {
        guard let sourceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let descriptor = sessions[sessionID],
              workspaces[sourceIndex].root.sessionIDs.count > 1,
              let root = workspaces[sourceIndex].root.removing(sessionID: sessionID)
        else {
            return false
        }
        workspaces[sourceIndex].root = root
        if workspaces[sourceIndex].focusedSessionID == sessionID,
           let fallback = root.sessionIDs.first
        {
            workspaces[sourceIndex].focusedSessionID = fallback
        }
        let detached = WorkspaceDocument.single(session: descriptor)
        let defaultDestination = min(sourceIndex + 1, workspaces.count)
        let destination = min(
            max(rawDestination ?? defaultDestination, 0),
            workspaces.count
        )
        workspaces.insert(detached, at: destination)
        activeWorkspaceID = detached.id
        return true
    }

    @discardableResult
    func detachPane(
        containing sessionID: UUID,
        from workspaceID: UUID,
        toIndex rawDestination: Int? = nil
    ) -> Bool {
        guard let sourceIndex = workspaces.firstIndex(where: {
                  $0.id == workspaceID
              }),
              let descriptor = sessions[sessionID],
              workspaces[sourceIndex].root.paneCount > 1
        else {
            return false
        }

        let extraction = workspaces[sourceIndex].root.extractingPane(
            containing: sessionID
        )
        guard let root = extraction.remaining,
              let detachedRoot = extraction.detached
        else {
            return false
        }

        workspaces[sourceIndex].root = root
        if !root.sessionIDs.contains(workspaces[sourceIndex].focusedSessionID),
           let fallback = root.sessionIDs.first
        {
            workspaces[sourceIndex].focusedSessionID = fallback
        }

        let detached = WorkspaceDocument(
            title: descriptor.title,
            root: detachedRoot,
            focusedSessionID: sessionID
        )
        let defaultDestination = min(sourceIndex + 1, workspaces.count)
        let destination = min(
            max(rawDestination ?? defaultDestination, 0),
            workspaces.count
        )
        workspaces.insert(detached, at: destination)
        activeWorkspaceID = detached.id
        return true
    }

    @discardableResult
    func mergeWorkspace(
        sourceWorkspaceID: UUID,
        into targetWorkspaceID: UUID,
        nextTo targetSessionID: UUID,
        axis: SplitAxis,
        placement: SplitPlacement
    ) async -> Bool {
        guard sourceWorkspaceID != targetWorkspaceID,
              let source = workspaces.first(where: { $0.id == sourceWorkspaceID }),
              let target = workspaces.first(where: { $0.id == targetWorkspaceID }),
              source.root.paneCount == 1,
              target.root.sessionIDs.contains(targetSessionID)
        else {
            return false
        }

        let hadVisibleSidePanel =
            isTerminalSidePanelVisible(in: sourceWorkspaceID)
            || isTerminalSidePanelVisible(in: targetWorkspaceID)
        closeTerminalSidePanel(in: sourceWorkspaceID)
        closeTerminalSidePanel(in: targetWorkspaceID)
        if hadVisibleSidePanel {
            await Task.yield()
        }

        guard let source = workspaces.first(where: { $0.id == sourceWorkspaceID }),
              source.root.paneCount == 1,
              let targetIndex = workspaces.firstIndex(where: {
                  $0.id == targetWorkspaceID
              }),
              workspaces[targetIndex].root.sessionIDs.contains(targetSessionID)
        else {
            return false
        }

        workspaces[targetIndex].root = workspaces[targetIndex].root.insertingPane(
            source.root,
            nextTo: targetSessionID,
            axis: axis,
            placement: placement
        )
        workspaces.removeAll { $0.id == sourceWorkspaceID }
        activeWorkspaceID = targetWorkspaceID
        return true
    }

    func focus(sessionID: UUID, workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              workspaces[index].root.sessionIDs.contains(sessionID)
        else {
            return
        }
        workspaces[index].focusedSessionID = sessionID
        workspaces[index].root = workspaces[index].root.selectingTab(
            sessionID: sessionID
        )
        runtimes[sessionID]?.focus()
    }

    func selectTerminalTab(
        sessionID: UUID,
        workspaceID: UUID
    ) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              workspaces[index].root.sessionIDs.contains(sessionID)
        else {
            return
        }
        workspaces[index].focusedSessionID = sessionID
        workspaces[index].root = workspaces[index].root.selectingTab(
            sessionID: sessionID
        )
        runtimes[sessionID]?.focus()
    }

    func moveTerminalTab(
        sessionID: UUID,
        workspaceID: UUID,
        toIndex: Int
    ) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              workspaces[index].root.sessionIDs.contains(sessionID)
        else {
            return
        }
        workspaces[index].root = workspaces[index].root.movingTab(
            sessionID: sessionID,
            toIndex: toIndex
        )
    }

    @discardableResult
    func splitTerminalTab(
        sessionID: UUID,
        workspaceID: UUID,
        nextTo targetSessionID: UUID,
        axis: SplitAxis,
        placement: SplitPlacement
    ) async -> Bool {
        guard let index = workspaces.firstIndex(where: {
                  $0.id == workspaceID
              })
        else {
            return false
        }
        let original = workspaces[index].root
        let candidate = original.splittingTab(
            sessionID: sessionID,
            nextTo: targetSessionID,
            axis: axis,
            placement: placement
        )
        guard candidate != original else {
            return false
        }

        let hadVisibleSidePanel = isTerminalSidePanelVisible(in: workspaceID)
        closeTerminalSidePanel(in: workspaceID)
        if hadVisibleSidePanel {
            await Task.yield()
        }

        guard let currentIndex = workspaces.firstIndex(where: {
                  $0.id == workspaceID
              })
        else {
            return false
        }
        let currentRoot = workspaces[currentIndex].root
        let updatedRoot = currentRoot.splittingTab(
            sessionID: sessionID,
            nextTo: targetSessionID,
            axis: axis,
            placement: placement
        )
        guard updatedRoot != currentRoot else {
            return false
        }

        workspaces[currentIndex].root = updatedRoot
        workspaces[currentIndex].focusedSessionID = sessionID
        activeWorkspaceID = workspaceID
        return true
    }

    func renameWorkspace(id: UUID, title: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            return
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return
        }
        workspaces[index].title = title
    }

    func duplicateWorkspace(id: UUID) async {
        guard let workspace = workspaces.first(where: { $0.id == id }) else {
            return
        }
        do {
            var replacements: [UUID: UUID] = [:]
            var connectionIDReplacements: [UUID: UUID] = [:]
            var newSessions: [SessionDescriptor] = []
            var newRuntimes: [UUID: TerminalSessionRuntime] = [:]

            for oldID in workspace.root.sessionIDs {
                guard var descriptor = sessions[oldID] else {
                    continue
                }
                let newID = UUID()
                replacements[oldID] = newID
                descriptor.id = newID
                if descriptor.kind == .ssh {
                    descriptor.sshConnectionID = replacedConnectionID(
                        for: descriptor.sshConnectionID,
                        replacements: &connectionIDReplacements
                    )
                }
                let runtime = try await restoredRuntime(
                    descriptor: descriptor,
                    startOnDisplay: true
                )
                newSessions.append(descriptor)
                newRuntimes[newID] = runtime
            }
            guard replacements.count == workspace.root.sessionIDs.count,
                  let newFocus = replacements[workspace.focusedSessionID]
            else {
                return
            }

            for descriptor in newSessions {
                sessions[descriptor.id] = descriptor
                runtimes[descriptor.id] = newRuntimes[descriptor.id]
                await registry.insert(
                    descriptor: descriptor,
                    lifecycle: newRuntimes[descriptor.id]?.lifecycle
                        ?? .connecting
                )
            }
            let duplicate = WorkspaceDocument(
                title: "\(workspace.title) \(AppLocalization.string("Copy"))",
                root: workspace.root.replacingSessionIDs(replacements),
                focusedSessionID: newFocus
            )
            let insertionIndex = (workspaces.firstIndex { $0.id == id } ?? 0) + 1
            workspaces.insert(duplicate, at: min(insertionIndex, workspaces.count))
            activeWorkspaceID = duplicate.id
        } catch {
            presentedError = AppLocalization.errorDescription(error)
        }
    }

    func togglePinned(id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            return
        }
        workspaces[index].pinned.toggle()
        workspaces.sort {
            if $0.pinned != $1.pinned {
                return $0.pinned
            }
            return false
        }
    }

    func moveWorkspace(id: UUID, offset: Int) {
        guard let source = workspaces.firstIndex(where: { $0.id == id }) else {
            return
        }
        let destination = min(max(source + offset, 0), workspaces.count - 1)
        guard source != destination else {
            return
        }
        let item = workspaces.remove(at: source)
        workspaces.insert(item, at: destination)
    }

    func moveWorkspace(id: UUID, toIndex rawDestination: Int) {
        guard let source = workspaces.firstIndex(where: { $0.id == id }) else {
            return
        }
        var destination = min(max(rawDestination, 0), workspaces.count)
        if source < destination {
            destination -= 1
        }
        guard source != destination else {
            return
        }
        let item = workspaces.remove(at: source)
        workspaces.insert(item, at: destination)
    }

    func updateSplitSizes(
        workspaceID: UUID,
        splitID: UUID,
        sizes: [Double]
    ) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return
        }
        workspaces[index].root = workspaces[index].root.updatingSplitSizes(
            splitID: splitID,
            sizes: sizes
        )
    }

    func handleURL(_ url: URL) async {
        guard url.scheme?.lowercased() == "ssh" else {
            return
        }
        _ = await quickConnect(url.absoluteString)
    }

    private func addSession(
        _ descriptor: SessionDescriptor,
        runtime: TerminalSessionRuntime,
        splitAxis: SplitAxis?
    ) async {
        await registerSession(descriptor, runtime: runtime)

        if let splitAxis,
           let activeWorkspaceID,
           let index = workspaces.firstIndex(where: { $0.id == activeWorkspaceID })
        {
            let target = workspaces[index].focusedSessionID
            workspaces[index].root = workspaces[index].root.inserting(
                sessionID: descriptor.id,
                nextTo: target,
                axis: splitAxis
            )
            workspaces[index].focusedSessionID = descriptor.id
        } else {
            let workspace = WorkspaceDocument.single(session: descriptor)
            workspaces.append(workspace)
            activeWorkspaceID = workspace.id
        }
    }

    private func addSessionAsTab(
        _ descriptor: SessionDescriptor,
        runtime: TerminalSessionRuntime,
        targetSessionID: UUID,
        workspaceID: UUID
    ) async {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              workspaces[index].root.sessionIDs.contains(targetSessionID)
        else {
            await addSession(descriptor, runtime: runtime, splitAxis: nil)
            return
        }

        await registerSession(descriptor, runtime: runtime)
        workspaces[index].root = workspaces[index].root.addingTab(
            sessionID: descriptor.id,
            nextTo: targetSessionID
        )
        workspaces[index].focusedSessionID = descriptor.id
        activeWorkspaceID = workspaceID
    }

    private func registerSession(
        _ descriptor: SessionDescriptor,
        runtime: TerminalSessionRuntime
    ) async {
        sessions[descriptor.id] = descriptor
        runtimes[descriptor.id] = runtime
        await registry.insert(
            descriptor: descriptor,
            lifecycle: runtime.lifecycle
        )
    }

    private func hostForWorkflow(hostID: UUID?) throws -> TermPilotDomain.Host {
        if let hostID,
           let host = hosts.first(where: { $0.id == hostID })
        {
            return try host.applyingConnectionSettings(
                credentials: credentials,
                proxyProfiles: proxyProfiles
            )
        }
        if let hostID,
           let host = sessionHosts.values.first(where: { $0.id == hostID })
        {
            return try host.applyingConnectionSettings(
                credentials: credentials,
                proxyProfiles: proxyProfiles
            )
        }
        if let host = hosts.first {
            return try host.applyingConnectionSettings(
                credentials: credentials,
                proxyProfiles: proxyProfiles
            )
        }
        throw AppStateError.invalidHost
    }

    private func materializedOpenSSHHost(
        _ host: TermPilotDomain.Host
    ) throws -> TermPilotDomain.Host {
        guard host.authentication == .identityFile else {
            return host
        }

        let hasInlineKey = host.identityFile?.isEmpty != false
            && host.identityKey?.isEmpty == false
        let hasCertificate = host.certificate?.isEmpty == false
        guard hasInlineKey || hasCertificate else {
            return host
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TermPilot-ssh-keys", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var copy = host
        if hasInlineKey, let identityKey = host.identityKey {
            let keyURL = directory.appendingPathComponent("\(host.id.uuidString).key")
            try OpenSSHCredentialText.normalizedFileContent(identityKey)
                .write(to: keyURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: keyURL.path
            )
            copy.identityFile = keyURL.path
        }
        if hasCertificate, let certificate = host.certificate {
            let certificateURL = directory
                .appendingPathComponent("\(host.id.uuidString)-cert.pub")
            try OpenSSHCredentialText.normalizedFileContent(certificate).write(
                to: certificateURL,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: certificateURL.path
            )
            copy.certificate = certificateURL.path
        }
        copy.password = host.passphrase
        return copy
    }

    private func portForwardLaunchConfiguration(
        rule: PortForwardRule,
        host: TermPilotDomain.Host
    ) async throws -> ProcessLaunchConfiguration {
        guard let knownHostsStore else {
            throw AppStateError.notReady
        }
        let knownHostsFile = await knownHostsStore.fileURL
        let askPassExecutable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let askPassRequestDirectory = try ensureAskPassRequestDirectory()
        let sshHost = try materializedOpenSSHHost(host)
        var launch = try OpenSSHTransport.launchConfiguration(
            host: sshHost,
            knownHostsFile: knownHostsFile,
            askPassExecutable: askPassExecutable,
            askPassRequestDirectory: askPassRequestDirectory
        )
        launch.arguments.removeAll { $0 == "-tt" }

        if let proxyConfiguration = sshHost.proxyConfiguration {
            guard let resourceDirectory = Bundle.main.resourceURL,
                  let runtime = SSH2BridgeRuntimeLocator.bundledRuntime(
                      in: resourceDirectory
                  )
            else {
                throw AppStateError.missingSSH2BridgeRuntime
            }
            let proxyCommandScript = AppResourceLocator.url(
                forResource: "termpilot-proxy-command",
                withExtension: "cjs",
                subdirectory: "proxy-bridge"
            ) ?? AppResourceLocator.url(
                forResource: "termpilot-proxy-command",
                withExtension: "cjs"
            )
            guard let proxyCommandScript else {
                throw AppStateError.missingProxyBridge
            }
            let encodedProxy = try JSONEncoder()
                .encode(proxyConfiguration)
                .base64EncodedString()
            launch.environment.removeAll {
                $0.hasPrefix("TERMPILOT_PROXY_COMMAND_CONFIG_B64=")
            }
            launch.environment.append(
                "TERMPILOT_PROXY_COMMAND_CONFIG_B64=\(encodedProxy)"
            )
            let command = [
                shellQuote(runtime.nodeExecutable.path),
                shellQuote(proxyCommandScript.path),
                "%h",
                "%p",
            ].joined(separator: " ")
            let proxyArguments = ["-o", "ProxyCommand=\(command)"]
            if let separator = launch.arguments.firstIndex(of: "--") {
                launch.arguments.insert(contentsOf: proxyArguments, at: separator)
            } else {
                launch.arguments.append(contentsOf: proxyArguments)
            }
        }

        let forwardingArguments = PortForwardOpenSSHArguments
            .forwardingArguments(for: rule)
        if let separator = launch.arguments.firstIndex(of: "--") {
            launch.arguments.insert(contentsOf: forwardingArguments, at: separator)
        } else {
            launch.arguments.append(contentsOf: forwardingArguments)
        }
        return launch
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    @discardableResult
    private func openSSHSession(
        host: TermPilotDomain.Host,
        splitAxis: SplitAxis? = nil,
        connectionID: UUID = UUID()
    ) async throws -> UUID {
        await prepareForSplitIfNeeded(splitAxis: splitAxis)
        let host = try host.applyingConnectionSettings(
            credentials: credentials,
            proxyProfiles: proxyProfiles
        )
        let descriptor = SessionDescriptor.ssh(
            host: host,
            connectionID: connectionID
        )
        let runtime = try await makeRuntime(
            descriptor: descriptor,
            host: host,
            startOnDisplay: true
        )
        sessionHosts[descriptor.id] = host
        await addSession(
            descriptor,
            runtime: runtime,
            splitAxis: splitAxis
        )
        return descriptor.id
    }

    private func prepareForSplitIfNeeded(
        splitAxis: SplitAxis?,
        targetSessionID: UUID? = nil
    ) async {
        guard splitAxis != nil,
              let sessionID = targetSessionID
                ?? activeWorkspace?.focusedSessionID,
              let workspaceID = workspaces.first(where: {
                  $0.root.sessionIDs.contains(sessionID)
              })?.id,
              isTerminalSidePanelVisible(in: workspaceID)
        else {
            return
        }
        closeTerminalSidePanel(in: workspaceID)
        await Task.yield()
    }

    private func makeRuntime(
        descriptor: SessionDescriptor,
        host: TermPilotDomain.Host,
        startOnDisplay: Bool
    ) async throws -> TerminalSessionRuntime {
        let bridgeScript = AppResourceLocator.url(
            forResource: "termpilot-ssh2-bridge",
            withExtension: "cjs",
            subdirectory: "ssh2-bridge"
        ) ?? AppResourceLocator.url(
            forResource: "termpilot-ssh2-bridge",
            withExtension: "cjs"
        )
        guard let bridgeScript else {
            throw AppStateError.missingSSH2Bridge
        }
        guard let resourceDirectory = Bundle.main.resourceURL,
              let runtime = SSH2BridgeRuntimeLocator.bundledRuntime(
                in: resourceDirectory
              )
        else {
            throw AppStateError.missingSSH2BridgeRuntime
        }
        let knownHostsFile: URL?
        if let knownHostsStore {
            knownHostsFile = await knownHostsStore.fileURL
        } else {
            knownHostsFile = nil
        }
        let launch = try SSH2BridgeTransport.launchConfiguration(
            host: host,
            bridgeScript: bridgeScript,
            runtime: runtime,
            connectionID: descriptor.sshConnectionID,
            sessionID: descriptor.id,
            knownHostsFile: knownHostsFile,
            autoAcceptHostKeys: AppPreferences.isAutoAcceptSSHHostKeysEnabled
        )
        let terminalRuntime = TerminalSessionRuntime(
            descriptor: descriptor,
            launchConfiguration: launch,
            registry: registry,
            startOnDisplay: startOnDisplay
        )
        let autocompleteDirectoryProvider =
            TerminalAutocompleteRemoteDirectoryProvider { [weak self] in
                guard let self else {
                    throw SSH2SFTPBridgeError.closed
                }
                return try self.makeSFTPClient(
                    for: host,
                    sourceConnectionID: descriptor.sshConnectionID,
                    sourceSessionID: descriptor.id,
                    opensFileChannel: false
                )
            }
        terminalRuntime.configureAutocompleteRemoteDirectoryProvider(
            listDirectory: { path, foldersOnly, filterPrefix, limit in
                await autocompleteDirectoryProvider.entries(
                    path: path,
                    foldersOnly: foldersOnly,
                    filterPrefix: filterPrefix,
                    limit: limit
                )
            },
            close: {
                await autocompleteDirectoryProvider.close()
            }
        )
        configurePasswordPromptAssist(
            for: terminalRuntime,
            host: host
        )
        return terminalRuntime
    }

    func updatePasswordPromptAssistMode(_ rawValue: String) {
        let mode = PasswordPromptAssistMode(rawValue: rawValue) ?? .hint
        for runtime in runtimes.values {
            runtime.configurePasswordPromptAssist(
                mode: mode,
                credentials: passwordPromptCredentials(
                    for: sessionHosts[runtime.descriptor.id]
                )
            )
        }
    }

    private func refreshActivePasswordPromptAssistConfigurations() {
        for (sessionID, runtime) in runtimes {
            guard runtime.descriptor.kind == .ssh,
                  let host = sessionHosts[sessionID]
                    ?? (try? sshHost(for: runtime.descriptor))
            else {
                continue
            }
            configurePasswordPromptAssist(for: runtime, host: host)
        }
    }

    private func configurePasswordPromptAssist(
        for runtime: TerminalSessionRuntime,
        host: TermPilotDomain.Host
    ) {
        let rawMode = UserDefaults.standard.string(
            forKey: AppPreferences.passwordPromptAssistMode
        ) ?? AppPreferences.defaultPasswordPromptAssistMode
        runtime.configurePasswordPromptAssist(
            mode: PasswordPromptAssistMode(rawValue: rawMode) ?? .hint,
            credentials: passwordPromptCredentials(for: host)
        )
    }

    private func passwordPromptCredentials(
        for host: TermPilotDomain.Host?
    ) -> [PasswordPromptCredential] {
        guard let host else {
            return []
        }
        var result: [PasswordPromptCredential] = []
        var seenPasswords = Set<String>()

        let quickFillPassword = PasswordPromptQuickFillResolver.password(
            for: host,
            credentials: credentials
        )

        if let password = quickFillPassword,
           !password.isEmpty,
           seenPasswords.insert(password).inserted
        {
            result.append(
                PasswordPromptCredential(
                    id: "host",
                    label: host.label,
                    username: host.username,
                    password: password,
                    isHostCredential: true
                )
            )
        }

        for credential in credentials where credential.kind == .password {
            guard let password = credential.password,
                  !password.isEmpty,
                  seenPasswords.insert(password).inserted
            else {
                continue
            }
            result.append(
                PasswordPromptCredential(
                    id: "credential:\(credential.id.uuidString)",
                    label: credential.label,
                    username: credential.username,
                    password: password
                )
            )
        }
        return result
    }

    private func restoredRuntime(
        descriptor: SessionDescriptor,
        startOnDisplay: Bool
    ) async throws -> TerminalSessionRuntime {
        switch descriptor.kind {
        case .local:
            let shell = descriptor.shell
                ?? ProcessInfo.processInfo.environment["SHELL"]
                ?? "/bin/zsh"
            return TerminalSessionRuntime(
                descriptor: descriptor,
                launchConfiguration: LocalShellLaunch.configuration(
                    shell: shell,
                    workingDirectory: descriptor.workingDirectory
                ),
                registry: registry,
                startOnDisplay: startOnDisplay
            )
        case .ssh:
            let host = try sshHost(for: descriptor)
            return try await makeRuntime(
                descriptor: descriptor,
                host: host,
                startOnDisplay: startOnDisplay
            )
        }
    }

    private func restore(
        _ snapshot: WorkspaceSnapshot,
        startsSessionsOnDisplay: Bool = false
    ) async throws {
        var restoredSessions: [UUID: SessionDescriptor] = [:]
        var restoredRuntimes: [UUID: TerminalSessionRuntime] = [:]
        sessionHosts = [:]

        for var descriptor in snapshot.sessions {
            if descriptor.kind == .ssh,
               descriptor.sshConnectionID == nil
            {
                descriptor.sshConnectionID = UUID()
            }
            let runtime = try await restoredRuntime(
                descriptor: descriptor,
                startOnDisplay: startsSessionsOnDisplay
            )
            restoredSessions[descriptor.id] = descriptor
            restoredRuntimes[descriptor.id] = runtime
            if descriptor.kind == .ssh,
               let host = try? sshHost(for: descriptor)
            {
                sessionHosts[descriptor.id] = host
            }
            await registry.insert(descriptor: descriptor)
        }

        sessions = restoredSessions
        runtimes = restoredRuntimes
        workspaces = snapshot.workspaces.filter {
            $0.root.sessionIDs.allSatisfy { restoredSessions[$0] != nil }
        }
        activeWorkspaceID = snapshot.activeWorkspaceID.flatMap { activeID in
            workspaces.contains { $0.id == activeID } ? activeID : workspaces.first?.id
        } ?? workspaces.first?.id
    }

    private func sshHost(for descriptor: SessionDescriptor) throws -> TermPilotDomain.Host {
        if let host = sessionHosts[descriptor.id] {
            return try host.applyingConnectionSettings(
                credentials: credentials,
                proxyProfiles: proxyProfiles
            )
        }
        if let hostID = descriptor.hostID,
           let savedHost = hosts.first(where: { $0.id == hostID })
        {
            return try savedHost.applyingConnectionSettings(
                credentials: credentials,
                proxyProfiles: proxyProfiles
            )
        }
        guard let hostname = descriptor.hostname,
              let username = descriptor.username
        else {
            throw AppStateError.invalidSession
        }
        guard descriptor.customProxyConfigured != true else {
            throw AppStateError.invalidSession
        }
        return try TermPilotDomain.Host(
            id: descriptor.hostID ?? UUID(),
            label: descriptor.title,
            hostname: hostname,
            port: descriptor.port ?? 22,
            username: username,
            authentication: descriptor.authentication ?? .agent,
            identityFile: descriptor.identityFile,
            credentialID: descriptor.credentialID,
            proxyProfileID: descriptor.proxyProfileID,
            sftpFileProtocol: descriptor.sftpFileProtocol ?? .auto,
            sftpFilenameEncoding: descriptor.sftpFilenameEncoding ?? .auto,
            sftpUsesSudo: descriptor.sftpUsesSudo ?? false,
            sftpFollowsTerminalCWD: descriptor.sftpFollowsTerminalCWD,
            serverToolsUseRoot: descriptor.serverToolsUseRoot ?? false,
            serverToolsElevationMethod:
                descriptor.serverToolsElevationMethod ?? .sudo
        ).applyingConnectionSettings(
            credentials: credentials,
            proxyProfiles: proxyProfiles
        )
    }

    private func replacedConnectionID(
        for source: UUID?,
        replacements: inout [UUID: UUID]
    ) -> UUID {
        guard let source else {
            return UUID()
        }
        if let existing = replacements[source] {
            return existing
        }
        let replacement = UUID()
        replacements[source] = replacement
        return replacement
    }

    private func observeRegistry() {
        registryTask?.cancel()
        registryTask = Task { [weak self] in
            let events = await self?.registry.events()
            guard let events else {
                return
            }
            for await event in events {
                guard case let .changed(record) = event else {
                    continue
                }
                switch record.lifecycle {
                case .connected:
                    self?.reconnectVisibleSFTPConnections(
                        sharing: record.descriptor
                    )
                    guard self?.knownHostRefreshSessionIDs
                        .insert(record.descriptor.id)
                        .inserted == true
                    else {
                        continue
                    }
                    self?.openSystemOverviewOnSSHConnectIfNeeded(for: record.descriptor)
                    await self?.refreshKnownHosts()
                    await self?.detectHostDistro(for: record.descriptor)
                case let .exited(code):
                    self?.knownHostRefreshSessionIDs.remove(record.descriptor.id)
                    await self?.recordHistoryIfNeeded(
                        descriptor: record.descriptor,
                        exitCode: code
                    )
                case .connecting, .disconnected, .failed:
                    self?.knownHostRefreshSessionIDs.remove(record.descriptor.id)
                }
            }
        }
    }

    private func detectHostDistro(for descriptor: SessionDescriptor) async {
        guard descriptor.kind == .ssh,
              let hostID = descriptor.hostID,
              let host = hosts.first(where: { $0.id == hostID }),
              host.distroMode == .auto,
              host.distro == nil,
              let sourceConnectionID = descriptor.sshConnectionID,
              hostDistroDetectionHostIDs.insert(hostID).inserted
        else {
            return
        }
        defer {
            hostDistroDetectionHostIDs.remove(hostID)
        }

        if let vendor = HostDistroID.detectVendor(
            fromSSHVersion: runtimes[descriptor.id]?.remoteServerVersion
        ) {
            await persistDetectedDistro(vendor, hostID: hostID)
            return
        }
        guard host.effectiveDistro?.isNetworkVendor != true else {
            return
        }

        let client: SSH2SFTPBridgeClient
        do {
            client = try makeSFTPClient(
                for: host,
                sourceConnectionID: sourceConnectionID,
                sourceSessionID: descriptor.id,
                opensFileChannel: false
            )
        } catch {
            return
        }

        let response: RemoteExecResponse
        do {
            response = try await client.exec(
                command: "cat /etc/os-release 2>/dev/null || uname -a",
                timeoutMS: 5_000
            )
            await client.close()
        } catch {
            await client.close()
            return
        }
        guard let distro = HostDistroID.detect(
            from: "\(response.stdout)\n\(response.stderr)"
        ) else {
            return
        }
        await persistDetectedDistro(distro, hostID: hostID)
    }

    private func persistDetectedDistro(
        _ distro: HostDistroID,
        hostID: UUID
    ) async {
        guard let vaultStore,
              var host = hosts.first(where: { $0.id == hostID }),
              host.distro != distro
        else {
            return
        }
        host.distro = distro
        do {
            try await vaultStore.saveHost(host)
            await refreshHosts()
            notifyVaultChanged()
        } catch {
            // Appearance detection is best effort and must not interrupt SSH.
        }
    }

    private func openSystemOverviewOnSSHConnectIfNeeded(
        for descriptor: SessionDescriptor
    ) {
        guard descriptor.kind == .ssh,
              allowsAutomaticSystemOverview(for: descriptor.id),
              !isSessionInSplitLayout(descriptor.id),
              AppPreferences.isAutoOpenSystemOverviewOnSSHConnectEnabled,
              let workspaceID = workspaces.first(where: {
                  $0.root.sessionIDs.contains(descriptor.id)
              })?.id
        else {
            return
        }
        openTerminalSidePanel(
            in: workspaceID,
            for: descriptor.id,
            tab: .system
        )
    }

    func allowsAutomaticSystemOverview(
        for sessionID: UUID
    ) -> Bool {
        !automaticSystemOverviewSuppressedSessionIDs.contains(sessionID)
    }

    private func isSessionInSplitLayout(_ sessionID: UUID) -> Bool {
        workspaces.contains { workspace in
            guard workspace.root.sessionIDs.contains(sessionID) else {
                return false
            }
            if case .split = workspace.root {
                return true
            }
            return false
        }
    }

    private func observeVaultChanges() {
        vaultChangeTask?.cancel()
        vaultChangeTask = Task { @MainActor [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: .termPilotVaultDidChange
            ).map { _ in () }
            for await _ in notifications {
                guard !Task.isCancelled else {
                    return
                }
                await self?.refreshHosts()
                do {
                    try await self?.refreshLocalWorkflows()
                } catch {
                    await MainActor.run {
                        self?.presentedError = AppLocalization.errorDescription(error)
                    }
                }
            }
        }
    }

    private func notifyVaultChanged() {
        NotificationCenter.default.post(
            name: .termPilotVaultDidChange,
            object: self
        )
    }

    private func startAskPassRequestObserver() {
        askPassRequestTask?.cancel()
        guard let directory = try? ensureAskPassRequestDirectory() else {
            return
        }
        askPassRequestTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.processAskPassRequests(in: directory)
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func ensureAskPassRequestDirectory() throws -> URL {
        if let askPassRequestDirectory {
            return askPassRequestDirectory
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "TermPilot-askpass-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        askPassRequestDirectory = directory
        return directory
    }

    private func processAskPassRequests(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        let requests = files
            .filter { $0.lastPathComponent.hasPrefix("request-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for requestURL in requests {
            guard let request = decodeAskPassRequest(at: requestURL),
                  !handledAskPassRequestIDs.contains(request.id)
            else {
                continue
            }
            let responseURL = directory
                .appendingPathComponent("response-\(request.id).txt")
            guard !FileManager.default.fileExists(atPath: responseURL.path) else {
                handledAskPassRequestIDs.insert(request.id)
                continue
            }
            if portForwardHostKeyPrompt != nil {
                continue
            }
            handledAskPassRequestIDs.insert(request.id)
            portForwardHostKeyPrompt = PortForwardHostKeyPrompt(
                id: request.id,
                prompt: request.prompt,
                responseURL: responseURL
            )
            break
        }
    }

    private func decodeAskPassRequest(at url: URL) -> AskPassHostKeyRequest? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(AskPassHostKeyRequest.self, from: data)
    }

    private func recordHistoryIfNeeded(
        descriptor: SessionDescriptor,
        exitCode: Int32?
    ) async {
        guard descriptor.kind == .ssh,
              recordedHistorySessionIDs.insert(descriptor.id).inserted
        else {
            return
        }
        let category = SSHExitCategory.classify(exitCode: exitCode)
        let entry = ConnectionHistoryEntry(
            hostID: descriptor.hostID,
            endedAt: Date(),
            succeeded: category == .clean,
            errorCategory: category == .clean ? nil : category.rawValue
        )
        try? await vaultStore?.appendHistory(entry)
    }

}

enum PasswordPromptQuickFillResolver {
    static func password(
        for host: TermPilotDomain.Host,
        credentials: [SSHCredential]
    ) -> String? {
        if let elevationPassword = host.elevationPassword,
           !elevationPassword.isEmpty
        {
            return elevationPassword
        }
        if let credentialID = host.credentialID,
           let credential = credentials.first(where: { $0.id == credentialID }),
           let elevationPassword = credential.elevationPassword,
           !elevationPassword.isEmpty
        {
            return elevationPassword
        }
        return host.authentication == .password ? host.password : nil
    }
}

enum AppStateError: Error, LocalizedError {
    case notReady
    case invalidSession
    case invalidCredential
    case invalidProxyProfile
    case invalidProxyCredential
    case invalidGroup
    case invalidHost
    case missingProxyBridge
    case missingSFTPBridge
    case missingSSH2Bridge
    case missingCredentialKeyGenerator
    case missingSSH2BridgeRuntime
    case workflowRunFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            "TermPilot is still starting."
        case .invalidSession:
            "The saved session is missing its connection details."
        case .invalidCredential:
            "The selected credential no longer exists."
        case .invalidProxyProfile:
            "The selected proxy no longer exists."
        case .invalidProxyCredential:
            "The selected proxy credential must contain a username and password."
        case .invalidGroup:
            "The selected group no longer exists."
        case .invalidHost:
            "Choose a saved host before starting this workflow."
        case .missingProxyBridge:
            "The TermPilot proxy helper is missing from the app bundle."
        case .missingSFTPBridge:
            "The TermPilot SFTP bridge helper is missing from the app bundle."
        case .missingSSH2Bridge:
            "The TermPilot ssh2 bridge helper is missing from the app bundle."
        case .missingCredentialKeyGenerator:
            "The TermPilot SSH key generator is missing from the app bundle."
        case .missingSSH2BridgeRuntime:
            "The bundled TermPilot ssh2 bridge runtime is missing. Rebuild the app with scripts/build-app.sh."
        case let .workflowRunFailed(message):
            message
        }
    }
}

private extension SSHCredentialKind {
    var authenticationMethod: AuthenticationMethod {
        switch self {
        case .password:
            .password
        case .identityKey:
            .identityFile
        }
    }
}

extension TermPilotDomain.Host {
    func applyingConnectionSettings(
        credentials: [SSHCredential],
        proxyProfiles: [SSHProxyProfile]
    ) throws -> TermPilotDomain.Host {
        var copy = try applyingCredential(from: credentials)
        let proxyConfiguration: SSHProxyConfiguration
        if let customConfiguration = copy.proxyConfiguration {
            proxyConfiguration = customConfiguration
        } else if let proxyProfileID = copy.proxyProfileID {
            guard let profile = proxyProfiles.first(where: {
                $0.id == proxyProfileID
            }) else {
                throw AppStateError.invalidProxyProfile
            }
            proxyConfiguration = profile.configuration
        } else {
            return copy
        }

        var resolvedProxy = try proxyConfiguration.validated()
        if let proxyCredentialID = resolvedProxy.credentialID {
            guard let credential = credentials.first(where: {
                $0.id == proxyCredentialID
            }),
            credential.kind == .password,
            let password = credential.password,
            !credential.username.isEmpty,
            !password.isEmpty
            else {
                throw AppStateError.invalidProxyCredential
            }
            resolvedProxy.username = credential.username
            resolvedProxy.password = password
        }
        copy.proxyConfiguration = resolvedProxy
        return copy
    }

    func applyingCredential(
        from credentials: [SSHCredential]
    ) throws -> TermPilotDomain.Host {
        guard let credentialID else {
            return self
        }
        guard let credential = credentials.first(where: { $0.id == credentialID }) else {
            throw AppStateError.invalidCredential
        }
        var copy = self
        if copy.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.username = credential.username
        }
        copy.authentication = credential.kind.authenticationMethod
        copy.password = credential.password
        copy.identityFile = nil
        copy.identityKey = credential.privateKey
        copy.publicKey = credential.publicKey
        copy.certificate = credential.certificate
        copy.passphrase = credential.passphrase
        return copy
    }
}

enum QuickConnectFormError: Error, LocalizedError {
    case missingPassword

    var errorDescription: String? {
        "Enter the SSH password."
    }
}
