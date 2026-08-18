import SwiftUI
import TermPilotDomain

enum TopTabQuickSwitcherSearch {
    static func hosts(
        matching query: String,
        hosts: [TermPilotDomain.Host],
        groups: [HostGroup]
    ) -> [TermPilotDomain.Host] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return hosts
        }
        let groupPaths = groupPaths(from: groups)
        return hosts.filter { host in
            [
                host.label,
                host.hostname,
                host.username,
                "\(host.username)@\(host.hostname)",
                host.groupID.flatMap { groupPaths[$0] } ?? "",
            ].contains { matches(query, in: $0) }
        }
    }

    static func groupPaths(from groups: [HostGroup]) -> [UUID: String] {
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map {
            ($0.id, $0)
        })
        return Dictionary(uniqueKeysWithValues: groups.map { group in
            var names = [String]()
            var current: HostGroup? = group
            var visited = Set<UUID>()
            while let item = current, visited.insert(item.id).inserted {
                names.append(item.name)
                current = item.parentGroupID.flatMap { groupsByID[$0] }
            }
            return (group.id, names.reversed().joined(separator: " / "))
        })
    }

    static func matches(_ query: String, in candidate: String) -> Bool {
        candidate.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }
}

struct TopTabQuickSwitcher: View {
    let hosts: [TermPilotDomain.Host]
    let groups: [HostGroup]
    let onSelectHost: (TermPilotDomain.Host) -> Void
    let onOpenLocalTerminal: () -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    AppLocalization.string(
                        "Search hosts or local terminal..."
                    ),
                    text: $query
                )
                .textFieldStyle(.plain)
                .focused($searchIsFocused)
                .onSubmit(activateFirstResult)
                .onExitCommand(perform: onDismiss)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showsLocalTerminal {
                        sectionTitle("Local Shells")
                        TopTabQuickSwitcherLocalRow(
                            shellName: localShellName,
                            action: onOpenLocalTerminal
                        )
                    }

                    if !filteredHosts.isEmpty {
                        sectionTitle("Hosts")
                        ForEach(filteredHosts) { host in
                            TopTabQuickSwitcherHostRow(
                                host: host,
                                groupPath: groupPath(for: host)
                            ) {
                                onSelectHost(host)
                            }
                        }
                    }

                    if filteredHosts.isEmpty && !showsLocalTerminal {
                        ContentUnavailableView(
                            AppLocalization.string(
                                "No matching hosts or local terminal"
                            ),
                            systemImage: "magnifyingglass"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: 420, height: desiredHeight)
        .task {
            await Task.yield()
            searchIsFocused = true
        }
    }

    private var filteredHosts: [TermPilotDomain.Host] {
        TopTabQuickSwitcherSearch.hosts(
            matching: query,
            hosts: hosts,
            groups: groups
        )
    }

    private var groupPaths: [UUID: String] {
        TopTabQuickSwitcherSearch.groupPaths(from: groups)
    }

    private var showsLocalTerminal: Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return true
        }
        return [
            AppLocalization.string("Local Terminal"),
            AppLocalization.string("Local Shells"),
            localShellName,
        ].contains {
            TopTabQuickSwitcherSearch.matches(query, in: $0)
        }
    }

    private var localShellName: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return URL(fileURLWithPath: shell).lastPathComponent
    }

    private var desiredHeight: CGFloat {
        let hostRows = min(filteredHosts.count, 7)
        let localRows = showsLocalTerminal ? 1 : 0
        let sectionCount = (!filteredHosts.isEmpty ? 1 : 0)
            + (showsLocalTerminal ? 1 : 0)
        let contentHeight = 58
            + CGFloat(hostRows + localRows) * 50
            + CGFloat(sectionCount) * 25
        return min(max(contentHeight, 170), 480)
    }

    private func groupPath(for host: TermPilotDomain.Host) -> String {
        guard let groupID = host.groupID else {
            return AppLocalization.string("No Group")
        }
        return groupPaths[groupID] ?? AppLocalization.string("No Group")
    }

    private func sectionTitle(_ key: String) -> some View {
        Text(verbatim: AppLocalization.string(key))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 4)
    }

    private func activateFirstResult() {
        if showsLocalTerminal {
            onOpenLocalTerminal()
        } else if let host = filteredHosts.first {
            onSelectHost(host)
        }
    }
}

private struct TopTabQuickSwitcherHostRow: View {
    let host: TermPilotDomain.Host
    let groupPath: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HostIconView(host: host, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.label)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(host.username)@\(host.hostname):\(host.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(groupPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 130, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
            .background(
                isHovered
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct TopTabQuickSwitcherLocalRow: View {
    let shellName: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        verbatim: AppLocalization.string("Local Terminal")
                    )
                        .font(.subheadline.weight(.medium))
                    Text(shellName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
            .background(
                isHovered
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
