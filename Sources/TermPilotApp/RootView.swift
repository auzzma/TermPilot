import AppKit
import SwiftUI
import TermPilotDomain
import TermPilotRemote
import UniformTypeIdentifiers

private enum HostGroupBatchSelectionState {
    case none
    case partial
    case all

    var systemImage: String {
        switch self {
        case .none:
            "square"
        case .partial:
            "minus.square.fill"
        case .all:
            "checkmark.square.fill"
        }
    }
}

private struct EmptyWorkspaceGridBackground: View {
    var body: some View {
        Canvas { context, size in
            var grid = Path()
            for x in stride(from: 0.5, through: size.width, by: 28) {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0.5, through: size.height, by: 28) {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(
                grid,
                with: .color(Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                    if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                        return NSColor.white.withAlphaComponent(0.015)
                    }
                    return NSColor.black.withAlphaComponent(0.03)
                }))),
                lineWidth: 1
            )
        }
        .background(
            Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                    return NSColor(srgbRed: 13.0 / 255.0, green: 17.0 / 255.0, blue: 23.0 / 255.0, alpha: 1)
                }
                return NSColor.controlBackgroundColor
            }))
        )
        .ignoresSafeArea()
    }
}

private struct EmptyWorkspacePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(
                Color(
                    red: 13 / 255,
                    green: 17 / 255,
                    blue: 23 / 255
                )
            )
            .padding(.horizontal, 11)
            .frame(minHeight: 29)
            .background(
                Color(
                    red: 88 / 255,
                    green: 166 / 255,
                    blue: 255 / 255
                ),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(
                .easeOut(duration: 0.1),
                value: configuration.isPressed
            )
    }
}

struct RootView: View {
    private static let expandedGroupFolderSystemImage =
        NSImage(
            systemSymbolName: "folder.open",
            accessibilityDescription: nil
        ) == nil
            ? "folder.fill"
            : "folder.open"

    @EnvironmentObject private var state: AppState
    @State private var editingHost: TermPilotDomain.Host?
    @State private var newHostEditorRequest: NewHostEditorRequest?
    @State private var groupNameEdit: HostGroupNameEdit?
    @State private var isSavingGroupName = false
    @State private var deletingGroup: HostGroup?
    @FocusState private var focusedGroupNameEditorID: UUID?
    @State private var showingQuickConnect = false
    @State private var showingHostGroupSettings = false
    @State private var showingTransferCenter = false
    @State private var activeDetailSurface = DetailSurface.workspace
    @State private var isSettingsTabOpen = false
    @State private var settingsSection = WorkflowSection.general
    @State private var isBatchManagingHosts = false
    @State private var selectedHostIDs = Set<UUID>()
    @State private var hoveredHostID: UUID?
    @State private var hoveredHostEditButtonID: UUID?
    @State private var isSettingsEntryHovered = false
    @State private var collapsedGroupIDs = Set<UUID>()
    @State private var knownGroupIDs = Set<UUID>()
    @State private var hostTreeDropTarget: HostTreeDropTarget?
    @State private var isHostTreeDropSettling = false
    @State private var draggingWorkspaceID: UUID?
    @State private var workspaceTabFrames: [UUID: CGRect] = [:]
    @State private var workspaceDropIndicatorX: CGFloat?
    @State private var workspaceTabBarFrame = CGRect.zero
    @State private var workspacePaneFrames: [UUID: CGRect] = [:]
    @State private var workspaceSplitDropHint: WorkspaceSplitDropHint?
    @State private var terminalTabSplitDropHint: TerminalTabSplitDropHint?
    @State private var draggingPaneSessionID: UUID?
    @State private var showingTopTabQuickSwitcher = false

    var body: some View {
        NavigationSplitView {
            vaultSidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 380)
        } detail: {
            VStack(spacing: 0) {
                tabBar
                Divider()
                workspaceContent
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .top
            )
            .background(Color(nsColor: .windowBackgroundColor))
            .coordinateSpace(name: WorkspaceDragLayout.coordinateSpace)
        }
        .navigationTitle("TermPilot")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task {
                        await state.openLocalShell()
                        activeDetailSurface = .workspace
                    }
                } label: {
                    Label("Local Shell", systemImage: "terminal")
                }
                .help("Open Local Shell")

                Button {
                    showingQuickConnect = true
                } label: {
                    Label("Quick Connect", systemImage: "bolt.horizontal.circle")
                }
                .help("Quick Connect")

                Button {
                    showingTransferCenter.toggle()
                } label: {
                    Label("Transfers", systemImage: "arrow.up.arrow.down")
                }
                .help("Transfer Center")
                .popover(isPresented: $showingTransferCenter) {
                    TransferCenterView()
                        .environmentObject(state)
                        .frame(width: 440, height: 380)
                }
            }
        }
        .sheet(isPresented: $showingQuickConnect) {
            QuickConnectView {
                activeDetailSurface = .workspace
            }
                .environmentObject(state)
        }
        .sheet(item: $newHostEditorRequest) { request in
            HostEditorView(
                host: nil,
                defaultGroupID: request.groupID
            )
                .environmentObject(state)
                
        }
        .sheet(item: $editingHost) { host in
            HostEditorView(host: host)
                .environmentObject(state)
                
        }
        .sheet(item: $deletingGroup) { group in
            DeleteHostGroupSheet(
                group: group,
                onCancel: {
                    deletingGroup = nil
                },
                onDelete: {
                    deleteGroup(group)
                }
            )
        }
        .sheet(isPresented: $showingHostGroupSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text("Group Settings")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("Done") {
                        showingHostGroupSettings = false
                    }
                }
                .padding(20)
                Divider()
                HostGroupManagerView()
                    .environmentObject(state)
            }
            .frame(width: 460, height: 420)
        }
        .alert(
            "TermPilot",
            isPresented: Binding(
                get: { state.presentedError != nil },
                set: { if !$0 { state.presentedError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                state.presentedError = nil
            }
        } message: {
            Text(state.presentedError ?? "")
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .showQuickConnect)
        ) { notification in
            guard let target = notification.object as? AppState,
                  target === state
            else {
                return
            }
            showingQuickConnect = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .showSettingsSurface)
        ) { notification in
            guard let target = notification.object as? AppState,
                  target === state
            else {
                return
            }
            showSettingsSurface()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .showAboutSettingsSurface)
        ) { notification in
            guard let target = notification.object as? AppState,
                  target === state
            else {
                return
            }
            showSettingsSurface(section: .about)
        }
        .onChange(
            of: state.groups.map(\.id),
            initial: true
        ) { _, groupIDs in
            let currentGroupIDs = Set(groupIDs)
            let newGroupIDs = currentGroupIDs.subtracting(knownGroupIDs)
            collapsedGroupIDs.formIntersection(currentGroupIDs)
            collapsedGroupIDs.formUnion(newGroupIDs)
            knownGroupIDs = currentGroupIDs
        }
        .onChange(of: focusedGroupNameEditorID) { previousID, nextID in
            guard let edit = groupNameEdit,
                  previousID == edit.groupID,
                  nextID != edit.groupID
            else {
                return
            }
            commitGroupNameEdit()
        }
    }

    private var vaultSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TermPilot")
                        .font(.title2.weight(.semibold))
                    Text("SSH Workspace")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showNewHostEditor()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add Host")
                .accessibilityLabel("Add Host")
            }
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 8)

            HStack(spacing: 8) {
                Button {
                    showingHostGroupSettings = true
                } label: {
                    Label("Group Settings", systemImage: "folder.badge.gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    isBatchManagingHosts.toggle()
                    if !isBatchManagingHosts {
                        selectedHostIDs.removeAll()
                    }
                } label: {
                    Text(LocalizedStringKey(isBatchManagingHosts ? "Done" : "Batch Manage"))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(state.filteredHosts.isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 10)

            TextField("Search hosts", text: $state.hostSearch)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 10)

            if isBatchManagingHosts {
                hostBatchBar
            }

            if !state.isReady {
                ProgressView("Loading Vault...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.filteredHosts.isEmpty {
                emptyHostTreeList
            } else {
                hostTreeList
            }

            Divider()
            HStack {
                Button {
                    showSettingsSurface()
                } label: {
                    HStack {
                        Image(systemName: "gearshape")
                        Text("Settings")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(
                                activeDetailSurface == .settings
                                    || isSettingsEntryHovered
                                    ? Color.accentColor.opacity(0.18)
                                    : .clear
                            )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .help("Settings")
                .accessibilityLabel("Settings")
                .onHover { isSettingsEntryHovered = $0 }
                .animation(
                    .easeOut(duration: 0.1),
                    value: isSettingsEntryHovered
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var emptyHostTreeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Hosts")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 6) {
                    Label("No Hosts", systemImage: "server.rack")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Add a host or use Quick Connect.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Add Host") {
                        showNewHostEditor()
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.08))
                )
                .padding(.horizontal, 8)
            }
            .padding(.bottom, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var hostTreeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ungroupedHostSection
                ForEach(visibleHostTreeRows) { row in
                    switch row {
                    case let .group(group, depth, hostCount):
                        groupTreeRow(
                            group: group,
                            depth: depth,
                            hostCount: hostCount
                        )
                    case let .host(host, depth):
                        hostRow(host)
                            .padding(.leading, CGFloat(depth) * 14)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var ungroupedHostSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Hosts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !ungroupedHosts.isEmpty {
                    Text("\(ungroupedHosts.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            ForEach(ungroupedHosts) { host in
                hostRow(host)
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    hostTreeDropTarget == .ungrouped
                        ? Color.accentColor.opacity(0.14)
                        : Color.clear
                )
        )
        .onDrop(
            of: HostTreeDragPayload.acceptedTypes,
            delegate: HostTreeDropDelegate(
                acceptedTypes: HostTreeDragPayload.acceptedTypes,
                rowHeight: 1,
                target: { _, _ in .ungrouped },
                activeTarget: $hostTreeDropTarget,
                isSettling: $isHostTreeDropSettling,
                performDrop: performHostTreeDrop
            )
        )
    }

    private var hostBatchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Batch Manage Hosts", systemImage: "checklist")
                .font(.caption.weight(.semibold))
            Text("Select hosts or groups, then switch their group or manage their proxy.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("Selected Hosts")
                    .foregroundStyle(.secondary)
                Text("\(selectedHostIDs.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                Spacer()
                Button("Select All") {
                    selectedHostIDs.formUnion(state.filteredHosts.map(\.id))
                }
                .buttonStyle(.borderless)
                Button("Clear") {
                    selectedHostIDs.removeAll()
                }
                .buttonStyle(.borderless)
            }

            Menu {
                Button("No Group") {
                    moveSelectedHosts(toGroup: nil)
                }
                if !state.groups.isEmpty {
                    Divider()
                    ForEach(HostGroupHierarchy.flattenedOptions(from: state.groups)) { option in
                        Button(option.displayName) {
                            moveSelectedHosts(toGroup: option.group.id)
                        }
                    }
                }
            } label: {
                Label("Switch Group", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .disabled(selectedHostIDs.isEmpty)

            Menu {
                Button("Disable Proxy") {
                    disableProxyForSelectedHosts()
                }
                Divider()
                if state.proxyProfiles.isEmpty {
                    Text("Configure a proxy in Settings first.")
                } else {
                    ForEach(state.proxyProfiles) { profile in
                        Button(profile.label) {
                            assignProxyProfileToSelectedHosts(profile.id)
                        }
                    }
                }
            } label: {
                Label("Assign Proxy", systemImage: "network")
                    .frame(maxWidth: .infinity)
            }
            .disabled(selectedHostIDs.isEmpty)
        }
        .font(.caption)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
        )
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func groupTreeRow(
        group: HostGroup,
        depth: Int,
        hostCount: Int
    ) -> some View {
        let groupHostIDs = hostIDs(includingDescendantsOf: group)
        let selectionState = batchSelectionState(for: groupHostIDs)

        return HStack(spacing: 8) {
            if isBatchManagingHosts {
                Button {
                    toggleGroupSelection(group)
                } label: {
                    Image(systemName: selectionState.systemImage)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    selectionState == .none ? Color.secondary : Color.accentColor
                )
                .disabled(groupHostIDs.isEmpty)
                .accessibilityLabel(
                    selectionState == .all
                        ? "Deselect Group Hosts"
                        : "Select Group Hosts"
                )
            }

            Button {
                toggleGroup(group.id)
            } label: {
                Image(
                    systemName: collapsedGroupIDs.contains(group.id)
                        ? "chevron.right"
                        : "chevron.down"
                )
            }
            .buttonStyle(.plain)

            Image(
                systemName: collapsedGroupIDs.contains(group.id)
                    ? "folder"
                    : Self.expandedGroupFolderSystemImage
            )
            .frame(width: 18)
            if groupNameEdit?.groupID == group.id {
                TextField(
                    "",
                    text: Binding(
                        get: {
                            groupNameEdit?.name ?? group.name
                        },
                        set: { name in
                            groupNameEdit?.name = name
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption.weight(.semibold))
                .focused(
                    $focusedGroupNameEditorID,
                    equals: group.id
                )
                .onSubmit {
                    commitGroupNameEdit()
                }
                .onExitCommand {
                    cancelGroupNameEdit()
                }
                .background {
                    GroupNameOutsideClickMonitor {
                        commitGroupNameEdit()
                    }
                }
            } else {
                Text(group.name)
                    .font(.caption.weight(.semibold))
            }
            Spacer()
            if hostCount > 0 {
                Text("\(hostCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if groupNameEdit?.groupID == group.id {
                return
            } else if isBatchManagingHosts {
                toggleGroupSelection(group)
            } else {
                toggleGroup(group.id)
            }
        }
        .contextMenu {
            if !isBatchManagingHosts {
                Button {
                    showNewHostEditor(in: group)
                } label: {
                    Label {
                        Text(
                            verbatim: AppLocalization.string(
                                "New Host in This Group"
                            )
                        )
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                Button {
                    createSubgroup(in: group)
                } label: {
                    Label {
                        Text(
                            verbatim: AppLocalization.string(
                                "New Subgroup"
                            )
                        )
                    } icon: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
                Button {
                    beginGroupNameEdit(group, isNew: false)
                } label: {
                    Label {
                        Text(
                            verbatim: AppLocalization.string(
                                "Rename Group"
                            )
                        )
                    } icon: {
                        Image(systemName: "pencil")
                    }
                }
                Button(role: .destructive) {
                    deletingGroup = group
                } label: {
                    Label {
                        Text(
                            verbatim: AppLocalization.string(
                                "Delete Group"
                            )
                        )
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
                Divider()
            }
            Button {
                isBatchManagingHosts.toggle()
                if !isBatchManagingHosts {
                    selectedHostIDs.removeAll()
                }
            } label: {
                Text(LocalizedStringKey(isBatchManagingHosts ? "Done" : "Batch Manage"))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    hostTreeDropTarget == .group(group.id, .inside)
                        ? Color.accentColor.opacity(0.16)
                        : isBatchManagingHosts && selectionState != .none
                            ? Color.accentColor.opacity(
                                selectionState == .all ? 0.12 : 0.06
                            )
                            : Color.clear
                )
        )
        .overlay(alignment: .top) {
            if hostTreeDropTarget == .group(group.id, .before) {
                hostTreeDropLine
            }
        }
        .overlay(alignment: .bottom) {
            if hostTreeDropTarget == .group(group.id, .after) {
                hostTreeDropLine
            }
        }
        .onDrag {
            HostGroupDragPayload.provider(for: group.id)
        } preview: {
            HStack(spacing: 8) {
                Image(
                    systemName: collapsedGroupIDs.contains(group.id)
                        ? "folder"
                        : "folder.open"
                )
                Text(group.name)
            }
            .padding(8)
        }
        .onDrop(
            of: HostTreeDragPayload.acceptedTypes,
            delegate: HostTreeDropDelegate(
                acceptedTypes: HostTreeDragPayload.acceptedTypes,
                rowHeight: 34,
                target: { info, rowHeight in
                    groupDropTarget(
                        for: info,
                        group: group,
                        rowHeight: rowHeight
                    )
                },
                activeTarget: $hostTreeDropTarget,
                isSettling: $isHostTreeDropSettling,
                performDrop: performHostTreeDrop
            )
        )
    }

    private func hostRow(_ host: TermPilotDomain.Host) -> some View {
        let isHovered = hoveredHostID == host.id
        let isEditButtonHovered = hoveredHostEditButtonID == host.id

        return HStack(spacing: 10) {
            if isBatchManagingHosts {
                Button {
                    toggleHostSelection(host)
                } label: {
                    Image(
                        systemName: selectedHostIDs.contains(host.id)
                            ? "checkmark.square.fill"
                            : "square"
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    selectedHostIDs.contains(host.id) ? Color.accentColor : .secondary
                )
                .accessibilityLabel(
                    selectedHostIDs.contains(host.id) ? "Deselect Host" : "Select Host"
                )
            }
            HostIconView(host: host, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.label)
                    .lineLimit(1)
                Text("\(host.username)@\(host.hostname):\(host.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.trailing, isBatchManagingHosts ? 0 : 36)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isBatchManagingHosts && selectedHostIDs.contains(host.id)
                        ? Color.accentColor.opacity(0.12)
                        : Color.clear
                )
        )
        .overlay(alignment: .trailing) {
            if isHovered && !isBatchManagingHosts {
                Button {
                    showHostEditor(host)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    isEditButtonHovered
                        ? Color.black.opacity(0.86)
                        : Color.secondary
                )
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isEditButtonHovered
                                ? Color(nsColor: .systemBlue)
                                : Color.clear
                        )
                )
                .padding(.trailing, 8)
                .accessibilityLabel("Edit Host")
                .help(AppLocalization.string("Edit Host"))
                .onHover { hovering in
                    hoveredHostEditButtonID = hovering ? host.id : nil
                }
            }
        }
        .onTapGesture {
            if isBatchManagingHosts {
                toggleHostSelection(host)
            }
        }
        .onTapGesture(count: 2) {
            guard !isBatchManagingHosts else {
                return
            }
            connectHost(host)
        }
        .contextMenu {
            if isBatchManagingHosts {
                Button {
                    toggleHostSelection(host)
                } label: {
                    Label(
                        selectedHostIDs.contains(host.id) ? "Deselect Host" : "Select Host",
                        systemImage: selectedHostIDs.contains(host.id)
                            ? "checkmark.square.fill"
                            : "square"
                    )
                }
            } else {
                Button {
                    copyToPasteboard(host.hostname)
                } label: {
                    Label("Copy IP/Host", systemImage: "doc.on.doc")
                }
                Divider()
                Button {
                    connectHost(host)
                } label: {
                    Label("Connect", systemImage: "desktopcomputer")
                }
                Button {
                    connectHost(host, splitAxis: .vertical)
                } label: {
                    Label(
                        "Connect in Vertical Split",
                        systemImage: "rectangle.split.2x1"
                    )
                }
                Button {
                    connectHost(host, splitAxis: .horizontal)
                } label: {
                    Label(
                        "Connect in Horizontal Split",
                        systemImage: "rectangle.split.1x2"
                    )
                }
                Menu {
                    if state.automationScripts.isEmpty {
                        Button {} label: {
                            Label("No Scripts", systemImage: "nosign")
                        }
                            .disabled(true)
                    } else {
                        ForEach(state.automationScripts) { script in
                            Button {
                                Task {
                                    await state.runAutomationScript(script, on: host)
                                    activeDetailSurface = .workspace
                                }
                            } label: {
                                Label {
                                    Text(script.title)
                                } icon: {
                                    Image(systemName: "play.fill")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Run Script", systemImage: "curlybraces.square")
                }
                Divider()
                Button {
                    copyToPasteboard(host.hostname)
                } label: {
                    Label("Copy IP", systemImage: "network")
                }
                Button {
                    guard let password = hostLoginPassword(for: host) else {
                        return
                    }
                    copyToPasteboard(password)
                } label: {
                    Label("Copy Password", systemImage: "key")
                }
                .disabled(hostLoginPassword(for: host) == nil)
                Divider()
                Button {
                    showHostEditor(host)
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                Button {
                    Task {
                        if let copiedHost = await state.duplicateHost(host) {
                            showHostEditor(copiedHost)
                        }
                    }
                } label: {
                    Label("Duplicate", systemImage: "square.on.square")
                }
                Button(role: .destructive) {
                    Task {
                        await state.deleteHost(host)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .accessibilityLabel("\(host.label), \(host.username) at \(host.hostname)")
        .accessibilityHint("Double-click to connect")
        .help("Drag to reorder or move to a group")
        .offset(y: isHovered ? -2 : 0)
        .zIndex(isHovered ? 1 : 0)
        .animation(
            .easeOut(duration: 0.14),
            value: isHovered
        )
        .pointingHandCursor()
        .onHover { hovering in
            if hovering {
                hoveredHostID = host.id
            } else if hoveredHostID == host.id {
                hoveredHostID = nil
                if hoveredHostEditButtonID == host.id {
                    hoveredHostEditButtonID = nil
                }
            }
        }
        .overlay(alignment: .top) {
            if hostTreeDropTarget == .host(host.id, .before) {
                hostTreeDropLine
            }
        }
        .overlay(alignment: .bottom) {
            if hostTreeDropTarget == .host(host.id, .after) {
                hostTreeDropLine
            }
        }
        .onDrag {
            HostDragPayload.provider(for: host.id)
        } preview: {
            HStack(spacing: 8) {
                HostIconView(host: host, size: 24)
                Text(host.label)
            }
                .padding(8)
        }
        .onDrop(
            of: HostDragPayload.acceptedTypes,
            delegate: HostTreeDropDelegate(
                acceptedTypes: HostDragPayload.acceptedTypes,
                rowHeight: 58,
                target: { info, rowHeight in
                    hostDropTarget(
                        for: info,
                        host: host,
                        rowHeight: rowHeight
                    )
                },
                activeTarget: $hostTreeDropTarget,
                isSettling: $isHostTreeDropSettling,
                performDrop: performHostTreeDrop
            )
        )
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if isSettingsTabOpen {
                    SettingsTab(
                        isActive: activeDetailSurface == .settings,
                        onSelect: {
                            activeDetailSurface = .settings
                        },
                        onClose: closeSettingsSurface
                    )
                }
                ForEach(state.workspaces) { workspace in
                    WorkspaceTab(
                        workspace: workspace,
                        isActive: activeDetailSurface == .workspace
                            && workspace.id == state.activeWorkspaceID,
                        draggingWorkspaceID: $draggingWorkspaceID,
                        onSelect: {
                            activeDetailSurface = .workspace
                            state.activeWorkspaceID = workspace.id
                            state.focus(
                                sessionID: workspace.focusedSessionID,
                                workspaceID: workspace.id
                            )
                        },
                        onDragChanged: { workspaceID, location in
                            updateWorkspaceDrag(workspaceID, at: location)
                        },
                        onDragEnded: { workspaceID, location in
                            finishWorkspaceDrag(workspaceID, at: location)
                        }
                    )
                    .environmentObject(state)
                }
                Button {
                    showingTopTabQuickSwitcher.toggle()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(AppLocalization.string("Open Quick Switcher"))
                .popover(
                    isPresented: $showingTopTabQuickSwitcher,
                    arrowEdge: .top
                ) {
                    TopTabQuickSwitcher(
                        hosts: state.hosts,
                        groups: state.groups,
                        onSelectHost: { host in
                            showingTopTabQuickSwitcher = false
                            connectHost(host)
                        },
                        onOpenLocalTerminal: {
                            showingTopTabQuickSwitcher = false
                            Task {
                                await state.openLocalShell()
                                activeDetailSurface = .workspace
                            }
                        },
                        onDismiss: {
                            showingTopTabQuickSwitcher = false
                        }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: WorkspaceTabBarFramePreferenceKey.self,
                    value: proxy.frame(
                        in: .named(WorkspaceDragLayout.coordinateSpace)
                    )
                )
            }
        }
        .overlay(alignment: .leading) {
            if let workspaceDropIndicatorX {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 26)
                    .offset(x: workspaceDropIndicatorX - 1.5)
                    .transition(.opacity)
            }
        }
        .onPreferenceChange(WorkspaceTabFramePreferenceKey.self) { frames in
            workspaceTabFrames = frames
        }
        .onPreferenceChange(WorkspaceTabBarFramePreferenceKey.self) { frame in
            workspaceTabBarFrame = frame
        }
        .onChange(of: draggingWorkspaceID) { _, nextID in
            if nextID == nil {
                workspaceDropIndicatorX = nil
                workspaceSplitDropHint = nil
            }
        }
        .animation(.easeInOut(duration: 0.14), value: workspaceDropIndicatorX)
        .animation(.easeInOut(duration: 0.16), value: state.workspaces.map(\.id))
    }

    private var workspaceContent: some View {
        ZStack {
            if state.workspaces.isEmpty {
                ZStack {
                    EmptyWorkspaceGridBackground()
                    VStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 11)
                                .fill(
                                    Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                                if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                                    return NSColor(srgbRed: 19.0 / 255.0, green: 43.0 / 255.0, blue: 69.0 / 255.0, alpha: 1)
                                }
                                return NSColor.controlAccentColor.withAlphaComponent(0.12)
                            }))
                                )
                            RoundedRectangle(cornerRadius: 11)
                                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                            Image(systemName: "terminal")
                                .font(.system(size: 28, weight: .regular))
                                .foregroundStyle(Color.accentColor)
                        }
                        .frame(width: 48, height: 48)
                        .padding(.bottom, 4)

                        Text("Ready to Connect")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.primary)

                        Text(
                            "Open a local shell, double-click a saved host, or use Quick Connect."
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)

                        HStack(spacing: 8) {
                            Button("Local Terminal") {
                                Task {
                                    await state.openLocalShell()
                                }
                            }
                            .buttonStyle(EmptyWorkspacePrimaryButtonStyle())
                            Button("Quick Connect") {
                                showingQuickConnect = true
                            }
                            .buttonStyle(EmptyWorkspacePrimaryButtonStyle())
                        }
                    }
                }
                .opacity(activeDetailSurface == .workspace ? 1 : 0)
                .allowsHitTesting(activeDetailSurface == .workspace)
            } else {
                ForEach(state.workspaces) { workspace in
                    let isActive =
                        activeDetailSurface == .workspace
                        && workspace.id == state.activeWorkspaceID
                    WorkspaceView(
                        workspace: workspace,
                        isActive: isActive
                    )
                    .environmentObject(state)
                    .environment(
                        \.workspacePaneDragHandlers,
                        WorkspacePaneDragHandlers(
                            onChanged: updatePaneDetachDrag,
                            onEnded: finishPaneDetachDrag
                        )
                    )
                    .environment(
                        \.workspaceTerminalTabDragHandlers,
                        WorkspaceTerminalTabDragHandlers(
                            onChanged: updateTerminalTabDrag,
                            onEnded: finishTerminalTabDrag
                        )
                    )
                    .opacity(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                    .accessibilityHidden(!isActive)
                    .zIndex(isActive ? 1 : 0)
                }
            }

            if activeDetailSurface == .settings {
                SettingsSurfaceView(section: $settingsSection)
                    .environmentObject(state)
                    .zIndex(2)
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .top
        )
        .overlay(alignment: .topLeading) {
            GeometryReader { proxy in
                if let previewFrame = splitDropPreviewFrame {
                    let containerFrame = proxy.frame(
                        in: .named(WorkspaceDragLayout.coordinateSpace)
                    )
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.green.opacity(0.24))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.green.opacity(0.78), lineWidth: 1.5)
                        )
                        .frame(
                            width: previewFrame.width,
                            height: previewFrame.height
                        )
                        .offset(
                            x: previewFrame.minX - containerFrame.minX,
                            y: previewFrame.minY - containerFrame.minY
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        .overlay {
            if draggingPaneSessionID != nil {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.accentColor.opacity(0.72), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .onPreferenceChange(WorkspacePaneFramePreferenceKey.self) { frames in
            workspacePaneFrames = frames
        }
        .onChange(of: state.activeWorkspaceID) { _, _ in
            workspaceSplitDropHint = nil
            terminalTabSplitDropHint = nil
        }
        .animation(
            .easeInOut(duration: 0.14),
            value: splitDropPreviewFrame
        )
    }

    private var splitDropPreviewFrame: CGRect? {
        terminalTabSplitDropHint?.previewFrame
            ?? workspaceSplitDropHint?.previewFrame
    }

    private var ungroupedHosts: [TermPilotDomain.Host] {
        state.filteredHosts.filter { $0.groupID == nil }
    }

    private var visibleHostTreeRows: [HostTreeRow] {
        let hostsByGroup = Dictionary(grouping: state.filteredHosts.compactMap { host in
            host.groupID.map { (groupID: $0, host: host) }
        }) { item in
            item.groupID
        }
        var rows: [HostTreeRow] = []

        func append(_ node: HostGroupNode, depth: Int) {
            let hosts = hostsByGroup[node.group.id]?.map(\.host) ?? []
            rows.append(
                .group(
                    node.group,
                    depth: depth,
                    hostCount: hosts.count
                )
            )
            guard !collapsedGroupIDs.contains(node.id) else {
                return
            }
            for host in hosts {
                rows.append(.host(host, depth: depth + 1))
            }
            for child in node.children {
                append(child, depth: depth + 1)
            }
        }

        for root in HostGroupHierarchy.roots(from: state.groups) {
            append(root, depth: 0)
        }
        return rows
    }

    private func toggleHostSelection(_ host: TermPilotDomain.Host) {
        if selectedHostIDs.contains(host.id) {
            selectedHostIDs.remove(host.id)
        } else {
            selectedHostIDs.insert(host.id)
        }
    }

    private func hostIDs(
        includingDescendantsOf group: HostGroup
    ) -> Set<UUID> {
        HostGroupHierarchy.hostIDs(
            includingDescendantsOf: group.id,
            groups: state.groups,
            hosts: state.hosts
        )
    }

    private func batchSelectionState(
        for hostIDs: Set<UUID>
    ) -> HostGroupBatchSelectionState {
        guard !hostIDs.isEmpty else {
            return .none
        }
        let selectedCount = hostIDs.intersection(selectedHostIDs).count
        if selectedCount == 0 {
            return .none
        }
        return selectedCount == hostIDs.count ? .all : .partial
    }

    private func toggleGroupSelection(_ group: HostGroup) {
        let hostIDs = hostIDs(includingDescendantsOf: group)
        guard !hostIDs.isEmpty else {
            return
        }
        if hostIDs.isSubset(of: selectedHostIDs) {
            selectedHostIDs.subtract(hostIDs)
        } else {
            selectedHostIDs.formUnion(hostIDs)
        }
    }

    private func connectHost(
        _ host: TermPilotDomain.Host,
        splitAxis: SplitAxis? = nil
    ) {
        Task {
            await state.connect(host: host, splitAxis: splitAxis)
            activeDetailSurface = .workspace
        }
    }

    private func hostLoginPassword(
        for host: TermPilotDomain.Host
    ) -> String? {
        let password: String?
        if let credentialID = host.credentialID {
            guard let credential = state.credentials.first(where: {
                $0.id == credentialID && $0.kind == .password
            }) else {
                return nil
            }
            password = credential.password
        } else if host.authentication == .password {
            password = host.password
        } else {
            return nil
        }
        guard let password, !password.isEmpty else {
            return nil
        }
        return password
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func showSettingsSurface(
        section: WorkflowSection = .general
    ) {
        settingsSection = section
        isSettingsTabOpen = true
        activeDetailSurface = .settings
    }

    private func closeSettingsSurface() {
        isSettingsTabOpen = false
        activeDetailSurface = .workspace
    }

    private func showNewHostEditor(
        in group: HostGroup? = nil
    ) {
        editingHost = nil
        newHostEditorRequest = NewHostEditorRequest(groupID: group?.id)
    }

    private func showHostEditor(_ host: TermPilotDomain.Host) {
        newHostEditorRequest = nil
        editingHost = host
    }

    private func createSubgroup(in parent: HostGroup) {
        let group = HostGroup(
            name: availableGroupName(parentGroupID: parent.id),
            parentGroupID: parent.id,
            sortOrder: state.groups.filter {
                $0.parentGroupID == parent.id
            }.count
        )
        Task {
            if await state.saveGroup(group) {
                collapsedGroupIDs.remove(parent.id)
                beginGroupNameEdit(group, isNew: true)
            }
        }
    }

    private func availableGroupName(parentGroupID: UUID?) -> String {
        let baseName = AppLocalization.string("New group")
        let siblingNames = Set(
            state.groups
                .filter { $0.parentGroupID == parentGroupID }
                .map(\.name)
        )
        guard siblingNames.contains(baseName) else {
            return baseName
        }

        var suffix = 2
        while siblingNames.contains("\(baseName) \(suffix)") {
            suffix += 1
        }
        return "\(baseName) \(suffix)"
    }

    private func beginGroupNameEdit(
        _ group: HostGroup,
        isNew: Bool
    ) {
        groupNameEdit = HostGroupNameEdit(
            groupID: group.id,
            name: group.name,
            isNew: isNew
        )
        isSavingGroupName = false
        focusGroupNameEditor(group.id)
    }

    private func focusGroupNameEditor(_ groupID: UUID) {
        Task { @MainActor in
            await Task.yield()
            focusedGroupNameEditorID = groupID
        }
    }

    private func commitGroupNameEdit() {
        guard let edit = groupNameEdit,
              !isSavingGroupName,
              let group = state.groups.first(where: {
                  $0.id == edit.groupID
              })
        else {
            return
        }

        let trimmedName = edit.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedName.isEmpty else {
            if edit.isNew {
                cancelGroupNameEdit()
            } else {
                state.presentedError = AppLocalization.string(
                    "Group name is required."
                )
                focusGroupNameEditor(edit.groupID)
            }
            return
        }
        guard !trimmedName.contains("/"),
              !trimmedName.contains("\\")
        else {
            state.presentedError = AppLocalization.string(
                "Group names cannot contain slash characters."
            )
            focusGroupNameEditor(edit.groupID)
            return
        }
        guard !state.groups.contains(where: {
            $0.id != group.id
                && $0.parentGroupID == group.parentGroupID
                && $0.name == trimmedName
        }) else {
            state.presentedError = AppLocalization.string(
                "A group with this name already exists here."
            )
            focusGroupNameEditor(edit.groupID)
            return
        }

        guard trimmedName != group.name else {
            groupNameEdit = nil
            focusedGroupNameEditorID = nil
            return
        }

        var renamedGroup = group
        renamedGroup.name = trimmedName
        isSavingGroupName = true
        Task {
            let saved = await state.saveGroup(renamedGroup)
            isSavingGroupName = false
            if saved {
                groupNameEdit = nil
                focusedGroupNameEditorID = nil
            } else {
                focusGroupNameEditor(edit.groupID)
            }
        }
    }

    private func cancelGroupNameEdit() {
        guard let edit = groupNameEdit else {
            return
        }
        let newGroup = edit.isNew
            ? state.groups.first(where: { $0.id == edit.groupID })
            : nil
        groupNameEdit = nil
        isSavingGroupName = false
        focusedGroupNameEditorID = nil
        if let newGroup {
            Task {
                await state.deleteGroup(newGroup)
            }
        }
    }

    private func deleteGroup(_ group: HostGroup) {
        let removedGroupIDs = HostGroupHierarchy.groupIDs(
            includingDescendantsOf: group.id,
            groups: state.groups
        )
        if let edit = groupNameEdit,
           removedGroupIDs.contains(edit.groupID)
        {
            groupNameEdit = nil
            isSavingGroupName = false
            focusedGroupNameEditorID = nil
        }
        collapsedGroupIDs.subtract(removedGroupIDs)
        deletingGroup = nil
        Task {
            await state.deleteGroup(group)
        }
    }

    private func moveSelectedHosts(toGroup groupID: UUID?) {
        let ids = selectedHostIDs
        Task {
            if await state.moveHosts(ids: ids, toGroup: groupID) {
                selectedHostIDs.removeAll()
                isBatchManagingHosts = false
            }
        }
    }

    private func assignProxyProfileToSelectedHosts(_ proxyProfileID: UUID) {
        let ids = selectedHostIDs
        Task {
            if await state.assignProxyProfile(
                toHosts: ids,
                proxyProfileID: proxyProfileID
            ) {
                selectedHostIDs.removeAll()
                isBatchManagingHosts = false
            }
        }
    }

    private func disableProxyForSelectedHosts() {
        let ids = selectedHostIDs
        Task {
            if await state.disableProxy(forHosts: ids) {
                selectedHostIDs.removeAll()
                isBatchManagingHosts = false
            }
        }
    }

    private var hostTreeDropLine: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 6)
    }

    private func hostDropTarget(
        for info: DropInfo,
        host: TermPilotDomain.Host,
        rowHeight: CGFloat
    ) -> HostTreeDropTarget {
        guard info.location.y >= max(rowHeight, 1) / 2 else {
            return .host(host.id, .before)
        }
        guard let nextHost = nextVisibleHost(after: host) else {
            return .host(host.id, .after)
        }
        return .host(nextHost.id, .before)
    }

    private func nextVisibleHost(
        after host: TermPilotDomain.Host
    ) -> TermPilotDomain.Host? {
        let siblings = state.filteredHosts.filter {
            $0.groupID == host.groupID
        }
        guard let index = siblings.firstIndex(where: { $0.id == host.id })
        else {
            return nil
        }
        return siblings.dropFirst(index + 1).first
    }

    private func groupDropTarget(
        for info: DropInfo,
        group: HostGroup,
        rowHeight: CGFloat
    ) -> HostTreeDropTarget {
        let ratio = info.location.y / max(rowHeight, 1)
        if ratio < 0.28 {
            return .group(group.id, .before)
        }
        if ratio > 0.72 {
            return .group(group.id, .after)
        }
        return .group(group.id, .inside)
    }

    private func performHostTreeDrop(
        _ providers: [NSItemProvider],
        target: HostTreeDropTarget
    ) -> Bool {
        guard !providers.isEmpty else {
            return false
        }

        let dispatchGroup = DispatchGroup()
        let collector = HostTreeDropItemCollector()
        for provider in providers {
            dispatchGroup.enter()
            HostTreeDragPayload.loadItem(from: provider) { item in
                if let item {
                    collector.insert(item)
                }
                dispatchGroup.leave()
            }
        }

        dispatchGroup.notify(queue: .main) {
            let snapshot = collector.snapshot()
            if !snapshot.hostIDs.isEmpty {
                moveDroppedHosts(snapshot.hostIDs, to: target)
            } else if let groupID = snapshot.groupIDs.first {
                moveDroppedGroup(groupID, to: target)
            }
            hostTreeDropTarget = nil
        }
        return true
    }

    private func moveDroppedHosts(
        _ ids: Set<UUID>,
        to target: HostTreeDropTarget
    ) {
        guard !ids.isEmpty else {
            return
        }
        switch target {
        case .ungrouped:
            Task {
                _ = await state.moveHosts(ids: ids, toGroup: nil)
            }
        case let .host(targetHostID, placement):
            guard !ids.contains(targetHostID),
                  let targetHost = state.hosts.first(where: {
                      $0.id == targetHostID
                  })
            else {
                return
            }
            let beforeHostID = beforeHostID(
                moving: ids,
                targetHost: targetHost,
                placement: placement
            )
            Task {
                _ = await state.reorderHosts(
                    ids: ids,
                    toGroup: targetHost.groupID,
                    beforeHostID: beforeHostID
                )
            }
        case let .group(groupID, _):
            Task {
                _ = await state.moveHosts(ids: ids, toGroup: groupID)
            }
        }
    }

    private func beforeHostID(
        moving ids: Set<UUID>,
        targetHost: TermPilotDomain.Host,
        placement: HostDropPlacement
    ) -> UUID? {
        guard placement == .after else {
            return targetHost.id
        }
        let siblings = state.hosts.filter {
            $0.groupID == targetHost.groupID && !ids.contains($0.id)
        }
        guard let targetIndex = siblings.firstIndex(where: {
            $0.id == targetHost.id
        }) else {
            return nil
        }
        return siblings.dropFirst(targetIndex + 1).first?.id
    }

    private func moveDroppedGroup(
        _ groupID: UUID,
        to target: HostTreeDropTarget
    ) {
        guard let group = state.groups.first(where: { $0.id == groupID })
        else {
            return
        }
        let parentGroupID: UUID?
        let targetBeforeGroupID: UUID?
        switch target {
        case .ungrouped:
            parentGroupID = nil
            targetBeforeGroupID = nil
        case .host:
            return
        case let .group(targetGroupID, placement):
            guard groupID != targetGroupID,
                  let targetGroup = state.groups.first(where: {
                      $0.id == targetGroupID
                  })
            else {
                return
            }
            switch placement {
            case .inside:
                parentGroupID = targetGroup.id
                targetBeforeGroupID = nil
            case .before, .after:
                parentGroupID = targetGroup.parentGroupID
                targetBeforeGroupID = beforeGroupID(
                    moving: group.id,
                    targetGroup: targetGroup,
                    placement: placement
                )
            }
        }

        if let parentGroupID,
           HostGroupHierarchy.groupIDs(
               includingDescendantsOf: groupID,
               groups: state.groups
           ).contains(parentGroupID)
        {
            return
        }

        Task {
            if await state.moveGroup(
                id: groupID,
                toParent: parentGroupID,
                beforeGroupID: targetBeforeGroupID
            ) {
                if let parentGroupID {
                    collapsedGroupIDs.remove(parentGroupID)
                }
            }
        }
    }

    private func beforeGroupID(
        moving groupID: UUID,
        targetGroup: HostGroup,
        placement: GroupDropPlacement
    ) -> UUID? {
        guard placement == .after else {
            return targetGroup.id
        }
        let siblings = siblingGroups(parentGroupID: targetGroup.parentGroupID)
            .filter { $0.id != groupID }
        guard let targetIndex = siblings.firstIndex(where: {
            $0.id == targetGroup.id
        }) else {
            return nil
        }
        return siblings.dropFirst(targetIndex + 1).first?.id
    }

    private func siblingGroups(parentGroupID: UUID?) -> [HostGroup] {
        state.groups
            .filter { $0.parentGroupID == parentGroupID }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    == .orderedAscending
            }
    }

    private func moveDraggedWorkspace(_ workspaceID: UUID, at location: CGPoint) {
        guard draggingWorkspaceID == workspaceID else {
            return
        }
        let targets = workspaceTabFrames.filter { id, frame in
            id != workspaceID && frame.insetBy(dx: -4, dy: -10).contains(location)
        }
        guard let target = targets.min(by: { lhs, rhs in
            abs(lhs.value.midX - location.x) < abs(rhs.value.midX - location.x)
        }) else {
            workspaceDropIndicatorX = nil
            return
        }
        guard let targetIndex = state.workspaces.firstIndex(where: {
            $0.id == target.key
        }) else {
            return
        }

        let destination = location.x < target.value.midX
            ? targetIndex
            : targetIndex + 1
        workspaceDropIndicatorX = location.x < target.value.midX
            ? target.value.minX
            : target.value.maxX
        withAnimation(.easeInOut(duration: 0.16)) {
            state.moveWorkspace(id: workspaceID, toIndex: destination)
        }
    }

    private func updateWorkspaceDrag(
        _ workspaceID: UUID,
        at location: CGPoint
    ) {
        terminalTabSplitDropHint = nil
        let hint = workspaceSplitHint(
            sourceWorkspaceID: workspaceID,
            at: location
        )
        workspaceSplitDropHint = hint
        if hint == nil {
            moveDraggedWorkspace(workspaceID, at: location)
        } else {
            workspaceDropIndicatorX = nil
        }
    }

    private func finishWorkspaceDrag(
        _ workspaceID: UUID,
        at location: CGPoint
    ) {
        let hint = workspaceSplitHint(
            sourceWorkspaceID: workspaceID,
            at: location
        ) ?? workspaceSplitDropHint
        draggingWorkspaceID = nil
        workspaceDropIndicatorX = nil
        workspaceSplitDropHint = nil

        guard let hint,
              hint.sourceWorkspaceID == workspaceID
        else {
            return
        }
        Task { @MainActor in
            let merged = await state.mergeWorkspace(
                sourceWorkspaceID: hint.sourceWorkspaceID,
                into: hint.targetWorkspaceID,
                nextTo: hint.targetSessionID,
                axis: hint.axis,
                placement: hint.placement
            )
            if merged {
                activeDetailSurface = .workspace
            }
        }
    }

    private func updatePaneDetachDrag(
        _ sessionID: UUID,
        _ workspaceID: UUID,
        _ location: CGPoint
    ) {
        guard activeDetailSurface == .workspace,
              state.activeWorkspaceID == workspaceID,
              let workspace = state.activeWorkspace,
              workspace.root.sessionIDs.count > 1,
              workspace.root.sessionIDs.contains(sessionID)
        else {
            draggingPaneSessionID = nil
            workspaceDropIndicatorX = nil
            return
        }
        draggingPaneSessionID = sessionID
        workspaceSplitDropHint = nil
        terminalTabSplitDropHint = nil
        workspaceDropIndicatorX = paneDetachTarget(at: location)?.indicatorX
    }

    private func finishPaneDetachDrag(
        _ sessionID: UUID,
        _ workspaceID: UUID,
        _ location: CGPoint
    ) {
        let target = paneDetachTarget(at: location)
        draggingPaneSessionID = nil
        workspaceDropIndicatorX = nil
        guard let target else {
            return
        }
        let detached = state.detachPane(
            containing: sessionID,
            from: workspaceID,
            toIndex: target.insertionIndex
        )
        if detached {
            activeDetailSurface = .workspace
        }
    }

    private func updateTerminalTabDrag(
        _ sessionID: UUID,
        _ workspaceID: UUID,
        _ location: CGPoint?
    ) {
        workspaceSplitDropHint = nil
        workspaceDropIndicatorX = nil
        guard let location else {
            terminalTabSplitDropHint = nil
            return
        }
        terminalTabSplitDropHint = terminalTabSplitHint(
            sourceSessionID: sessionID,
            workspaceID: workspaceID,
            at: location
        )
    }

    private func finishTerminalTabDrag(
        _ sessionID: UUID,
        _ workspaceID: UUID,
        _ location: CGPoint?
    ) {
        let hint = location.flatMap {
            terminalTabSplitHint(
                sourceSessionID: sessionID,
                workspaceID: workspaceID,
                at: $0
            )
        }
        terminalTabSplitDropHint = nil
        guard let hint else {
            return
        }

        Task { @MainActor in
            let didSplit = await state.splitTerminalTab(
                sessionID: hint.sourceSessionID,
                workspaceID: hint.workspaceID,
                nextTo: hint.targetSessionID,
                axis: hint.axis,
                placement: hint.placement
            )
            if didSplit {
                activeDetailSurface = .workspace
            }
        }
    }

    private func paneDetachTarget(
        at location: CGPoint
    ) -> WorkspacePaneDetachTarget? {
        let tabFrames = state.workspaces.compactMap {
            workspaceTabFrames[$0.id]
        }
        let fallbackFrame = tabFrames.dropFirst().reduce(
            tabFrames.first ?? .zero
        ) { partial, frame in
            partial.union(frame)
        }
        .insetBy(dx: -8, dy: -8)
        let effectiveTabBarFrame = workspaceTabBarFrame.isEmpty
            ? fallbackFrame
            : workspaceTabBarFrame.union(fallbackFrame)
        return WorkspacePaneDetachDropResolver.resolve(
            location: location,
            tabBarFrame: effectiveTabBarFrame,
            tabFrames: tabFrames
        )
    }

    private func workspaceSplitHint(
        sourceWorkspaceID: UUID,
        at location: CGPoint
    ) -> WorkspaceSplitDropHint? {
        guard activeDetailSurface == .workspace,
              let targetWorkspace = state.activeWorkspace,
              targetWorkspace.id != sourceWorkspaceID,
              let sourceWorkspace = state.workspaces.first(where: {
                  $0.id == sourceWorkspaceID
              }),
              sourceWorkspace.root.paneCount == 1
        else {
            return nil
        }

        let targetSessionIDs = Set(targetWorkspace.root.sessionIDs)
        guard let target = workspacePaneFrames.first(where: {
            targetSessionIDs.contains($0.key)
                && $0.value.width > 0
                && $0.value.height > 0
                && $0.value.contains(location)
        }) else {
            return nil
        }

        guard let resolution = WorkspaceSplitDropResolver.resolve(
            location: location,
            in: target.value
        ) else {
            return nil
        }

        return WorkspaceSplitDropHint(
            sourceWorkspaceID: sourceWorkspaceID,
            targetWorkspaceID: targetWorkspace.id,
            targetSessionID: target.key,
            axis: resolution.axis,
            placement: resolution.placement,
            previewFrame: resolution.previewFrame
        )
    }

    private func terminalTabSplitHint(
        sourceSessionID: UUID,
        workspaceID: UUID,
        at location: CGPoint
    ) -> TerminalTabSplitDropHint? {
        guard activeDetailSurface == .workspace,
              state.activeWorkspaceID == workspaceID,
              let workspace = state.activeWorkspace,
              workspace.root.sessionIDs.contains(sourceSessionID)
        else {
            return nil
        }

        let workspaceSessionIDs = Set(workspace.root.sessionIDs)
        guard let target = workspacePaneFrames.first(where: {
            workspaceSessionIDs.contains($0.key)
                && $0.value.width > 0
                && $0.value.height > 0
                && $0.value.contains(location)
        }),
              let resolution = WorkspaceSplitDropResolver.resolve(
                  location: location,
                  in: target.value
              )
        else {
            return nil
        }

        return TerminalTabSplitDropHint(
            sourceSessionID: sourceSessionID,
            workspaceID: workspaceID,
            targetSessionID: target.key,
            axis: resolution.axis,
            placement: resolution.placement,
            previewFrame: resolution.previewFrame
        )
    }

    private func toggleGroup(_ id: UUID) {
        if collapsedGroupIDs.contains(id) {
            collapsedGroupIDs.remove(id)
        } else {
            collapsedGroupIDs.insert(id)
        }
    }
}

private struct HostGroupNameEdit {
    var groupID: UUID
    var name: String
    var isNew: Bool
}

private struct NewHostEditorRequest: Identifiable {
    let id = UUID()
    var groupID: UUID?
}

private struct GroupNameOutsideClickMonitor: NSViewRepresentable {
    var onOutsideMouseDown: () -> Void

    func makeNSView(context _: Context) -> GroupNameOutsideClickView {
        let view = GroupNameOutsideClickView()
        view.onOutsideMouseDown = onOutsideMouseDown
        return view
    }

    func updateNSView(
        _ nsView: GroupNameOutsideClickView,
        context _: Context
    ) {
        nsView.onOutsideMouseDown = onOutsideMouseDown
    }

    static func dismantleNSView(
        _ nsView: GroupNameOutsideClickView,
        coordinator _: ()
    ) {
        nsView.stopMonitoring()
    }
}

private final class GroupNameOutsideClickView: NSView {
    var onOutsideMouseDown: (() -> Void)?
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else {
            return
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self,
                  let editorWindow = self.window,
                  event.window === editorWindow
            else {
                return event
            }
            let location = self.convert(
                event.locationInWindow,
                from: nil
            )
            if !self.bounds.contains(location) {
                self.onOutsideMouseDown?()
            }
            return event
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    fileprivate func stopMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

struct DeleteHostGroupSheet: View {
    var group: HostGroup
    var onCancel: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                verbatim: AppLocalization.string("Delete Group")
            )
            .font(.title2.weight(.semibold))

            Text(group.name)
                .font(.headline)
                .lineLimit(1)

            Text(
                verbatim: AppLocalization.string(
                    "Deleting this group will also delete its subgroups. Hosts in these groups will be moved to No Group."
                )
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(
                    AppLocalization.string("Cancel"),
                    role: .cancel,
                    action: onCancel
                )
                Button(
                    AppLocalization.string("Delete"),
                    role: .destructive,
                    action: onDelete
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
    }
}

private enum HostDropPlacement: Equatable {
    case before
    case after
}

private enum GroupDropPlacement: Equatable {
    case before
    case after
    case inside
}

private enum HostTreeDropTarget: Equatable {
    case ungrouped
    case host(UUID, HostDropPlacement)
    case group(UUID, GroupDropPlacement)
}

private final class HostTreeDropItemCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var hostIDs = Set<UUID>()
    private var groupIDs: [UUID] = []

    func insert(_ item: HostTreeDragItem) {
        lock.lock()
        switch item {
        case let .host(id):
            hostIDs.insert(id)
        case let .group(id):
            if !groupIDs.contains(id) {
                groupIDs.append(id)
            }
        }
        lock.unlock()
    }

    func snapshot() -> HostTreeDropItemSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return HostTreeDropItemSnapshot(hostIDs: hostIDs, groupIDs: groupIDs)
    }
}

private struct HostTreeDropItemSnapshot {
    var hostIDs: Set<UUID>
    var groupIDs: [UUID]
}

private struct HostTreeDropDelegate: DropDelegate {
    var acceptedTypes: [UTType]
    var rowHeight: CGFloat
    var target: (DropInfo, CGFloat) -> HostTreeDropTarget
    @Binding var activeTarget: HostTreeDropTarget?
    @Binding var isSettling: Bool
    var performDrop: ([NSItemProvider], HostTreeDropTarget) -> Bool

    func dropEntered(info: DropInfo) {
        guard !isSettling else {
            return
        }
        activeTarget = target(info, rowHeight)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if isSettling {
            clearActiveTarget()
        } else {
            activeTarget = target(info, rowHeight)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let currentTarget = activeTarget ?? target(info, rowHeight)
        isSettling = true
        clearActiveTarget()
        let handled = performDrop(
            info.itemProviders(for: acceptedTypes),
            currentTarget
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            clearActiveTarget()
            isSettling = false
        }
        return handled
    }

    func dropExited(info: DropInfo) {
        clearActiveTarget()
    }

    private func clearActiveTarget() {
        activeTarget = nil
    }
}

private enum DetailSurface {
    case workspace
    case settings
}

private enum WorkflowSection: String, CaseIterable, Identifiable {
    case general = "General"
    case credentials = "Credentials"
    case proxies = "Proxies"
    case groups = "Groups"
    case knownHosts = "Known Hosts"
    case forwarding = "Forwarding"
    case scripts = "Scripts"
    case notes = "Notes"
    case backup = "Backup"
    case about = "About"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general:
            "General"
        case .credentials:
            "Credentials"
        case .proxies:
            "Proxies"
        case .groups:
            "Groups"
        case .knownHosts:
            "Known Hosts"
        case .forwarding:
            "Forwarding"
        case .scripts:
            "Scripts"
        case .notes:
            "Notes"
        case .backup:
            "Backup"
        case .about:
            "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gear"
        case .credentials:
            "key"
        case .proxies:
            "network"
        case .groups:
            "folder"
        case .knownHosts:
            "checkmark.shield"
        case .forwarding:
            "arrow.left.arrow.right"
        case .scripts:
            "curlybraces.square"
        case .notes:
            "note.text"
        case .backup:
            "externaldrive.badge.timemachine"
        case .about:
            "info.circle"
        }
    }
}

private struct WorkflowItemDropDelegate: DropDelegate {
    let itemID: UUID
    @Binding var draggingID: UUID?
    let move: (UUID, UUID) -> Void
    let persist: () -> Void

    func dropEntered(info _: DropInfo) {
        guard let draggingID,
              draggingID != itemID
        else {
            return
        }
        move(draggingID, itemID)
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        guard draggingID != nil else {
            return false
        }
        draggingID = nil
        persist()
        return true
    }
}

private struct SettingsSurfaceView: View {
    @EnvironmentObject private var state: AppState
    @Binding var section: WorkflowSection
    @State private var hoveredSection: WorkflowSection?
    @State private var draggingProxyProfileID: UUID?
    @State private var draggingAutomationScriptID: UUID?
    @State private var editingForward: PortForwardRule?
    @State private var editingCredential: SSHCredential?
    @State private var deletingCredential: SSHCredential?
    @State private var creatingCredential = false
    @State private var exportingCredential: SSHCredential?
    @State private var editingProxy: SSHProxyProfile?
    @State private var editingScript: AutomationScript?
    @State private var editingNote: HostNote?

    var body: some View {
        HStack(spacing: 0) {
            workflowSidebar
            Divider()
            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if hasWorkflowEditor {
                Divider()
                workflowEditorPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay {
            if let credential = deletingCredential {
                ZStack {
                    Color.black.opacity(0.42)
                        .ignoresSafeArea()
                    CredentialDeleteConfirmationView(
                        credential: credential,
                        affectedHosts: state.hosts.filter {
                            $0.credentialID == credential.id
                        },
                        onCancel: {
                            deletingCredential = nil
                        },
                        onDelete: {
                            let deleted = await state.deleteCredential(
                                credential
                            )
                            if deleted {
                                if editingCredential?.id == credential.id {
                                    clearWorkflowEditor()
                                }
                                deletingCredential = nil
                            }
                            return deleted
                        }
                    )
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: hasWorkflowEditor)
        .animation(.easeInOut(duration: 0.15), value: deletingCredential?.id)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .general:
            SettingsGeneralView()
        case .credentials:
            workflowScrollContent {
                credentialsSection
            }
        case .proxies:
            workflowScrollContent {
                proxiesSection
            }
        case .groups:
            HostGroupManagerView()
                .environmentObject(state)
        case .knownHosts:
            KnownHostsSettingsView()
                .environmentObject(state)
        case .forwarding:
            workflowScrollContent {
                forwardingSection
            }
        case .scripts:
            workflowScrollContent {
                scriptsSection
            }
        case .notes:
            workflowScrollContent {
                notesSection
            }
        case .backup:
            BackupSettingsView()
                .environmentObject(state)
        case .about:
            AboutSettingsView()
        }
    }

    private func workflowScrollContent<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(16)
        }
    }

    private var workflowSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Settings", systemImage: "gearshape")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ForEach(
                WorkflowSection.allCases.filter { $0 != .about }
            ) { item in
                workflowSidebarButton(item)
            }
            Spacer()
            workflowSidebarButton(.about)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
        .frame(width: 156)
        .background(.bar)
    }

    private func workflowSidebarButton(
        _ item: WorkflowSection
    ) -> some View {
        Button {
            selectSection(item)
        } label: {
            Label(item.title, systemImage: item.systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            section == item
                                || hoveredSection == item
                                ? Color.accentColor.opacity(0.18)
                                : .clear
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredSection = item
            } else if hoveredSection == item {
                hoveredSection = nil
            }
        }
        .animation(
            .easeOut(duration: 0.1),
            value: hoveredSection
        )
    }

    private var hasWorkflowEditor: Bool {
        editingForward != nil
            || editingCredential != nil
            || creatingCredential
            || exportingCredential != nil
            || editingProxy != nil
            || editingScript != nil
            || editingNote != nil
    }

    @ViewBuilder
    private var workflowEditorPanel: some View {
        if creatingCredential {
            CredentialCreationEditor(
                onCancel: clearWorkflowEditor
            )
            .environmentObject(state)
            .workflowEditorPanelStyle(scrollsContent: false)
        } else if let credential = exportingCredential {
            CredentialExportEditor(
                credential: credential,
                onCancel: clearWorkflowEditor
            )
            .environmentObject(state)
            .id(credential.id)
            .workflowEditorPanelStyle(scrollsContent: false)
        } else if let credential = editingCredential {
            CredentialEditor(
                credential: credential,
                onCancel: clearWorkflowEditor
            ) { updated in
                Task { await state.saveCredential(updated) }
                clearWorkflowEditor()
            }
            .id(credential.id)
            .workflowEditorPanelStyle(scrollsContent: false)
        } else if let proxy = editingProxy {
            ProxyProfileEditor(
                profile: proxy,
                credentials: state.credentials,
                onCancel: clearWorkflowEditor
            ) { updated in
                await state.saveProxyProfile(updated)
            }
            .id(proxy.id)
            .workflowEditorPanelStyle()
        } else if let rule = editingForward {
            PortForwardRuleEditor(
                rule: rule,
                onCancel: clearWorkflowEditor
            ) { updated in
                Task { await state.savePortForwardRule(updated) }
                clearWorkflowEditor()
            }
            .id(rule.id)
            .environmentObject(state)
            .workflowEditorPanelStyle()
        } else if let script = editingScript {
            ScriptEditor(
                script: script,
                onCancel: clearWorkflowEditor
            ) { updated in
                Task { await state.saveAutomationScript(updated) }
                clearWorkflowEditor()
            }
            .id(script.id)
            .workflowEditorPanelStyle()
        } else if let note = editingNote {
            HostNoteEditor(
                note: note,
                onCancel: clearWorkflowEditor
            ) { updated in
                Task { await state.saveHostNote(updated) }
                clearWorkflowEditor()
            }
            .id(note.id)
            .environmentObject(state)
            .workflowEditorPanelStyle()
        }
    }

    private func selectSection(_ nextSection: WorkflowSection) {
        section = nextSection
        clearWorkflowEditor()
    }

    private func clearWorkflowEditor() {
        editingForward = nil
        editingCredential = nil
        creatingCredential = false
        exportingCredential = nil
        editingProxy = nil
        editingScript = nil
        editingNote = nil
    }

    private func editForward(_ rule: PortForwardRule) {
        clearWorkflowEditor()
        editingForward = rule
    }

    private func editCredential(_ credential: SSHCredential) {
        clearWorkflowEditor()
        editingCredential = credential
    }

    private func createCredential() {
        clearWorkflowEditor()
        creatingCredential = true
    }

    private func exportCredential(_ credential: SSHCredential) {
        clearWorkflowEditor()
        exportingCredential = credential
    }

    private func editProxy(_ proxy: SSHProxyProfile) {
        clearWorkflowEditor()
        editingProxy = proxy
    }

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Credentials")
                        .font(.title3.weight(.semibold))
                    Text(
                        "Saved SSH usernames, passwords, and private key credentials."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editCredential(
                        SSHCredential(
                            label: "",
                            username: "",
                            kind: .password
                        )
                    )
                } label: {
                    Label("New Credential", systemImage: "plus")
                }
                Button(action: createCredential) {
                    Label("Create Credential", systemImage: "wand.and.stars")
                }
            }
            if state.credentials.isEmpty {
                emptyRow("No credentials yet.")
            } else {
                ForEach(state.credentials) { credential in
                    workflowRow(
                        title: credential.label,
                        detail: "\(credential.username) - \(credential.kind.appLocalizedTitle)",
                        systemImage: credential.kind == .password ? "person.badge.key" : "key"
                    ) {
                        if credential.hasCompleteKeyPair {
                            Button {
                                exportCredential(credential)
                            } label: {
                                Label(
                                    "Export to Hosts",
                                    systemImage: "square.and.arrow.up.on.square"
                                )
                            }
                        }
                        Button("Edit") {
                            editCredential(credential)
                        }
                        Button("Delete", role: .destructive) {
                            deletingCredential = credential
                        }
                    }
                }
            }
        }
    }

    private var proxiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "Proxies",
                subtitle: "Reusable HTTP, SOCKS5, and ProxyCommand configurations.",
                button: "New Proxy"
            ) {
                editProxy(
                    SSHProxyProfile(
                        label: "",
                        configuration: SSHProxyConfiguration(
                            type: .http,
                            port: 8080
                        )
                    )
                )
            }
            if state.proxyProfiles.isEmpty {
                emptyRow("No proxies yet.")
            } else {
                ForEach(state.proxyProfiles) { proxy in
                    workflowRow(
                        title: proxy.label,
                        detail: "\(proxy.configuration.type.appLocalizedTitle) - \(proxy.configuration.appEndpointSummary)",
                        systemImage: proxy.configuration.type == .command
                            ? "terminal"
                            : "network",
                        showsDragHandle: true
                    ) {
                        Button("Edit") {
                            editProxy(proxy)
                        }
                        Button("Delete", role: .destructive) {
                            Task { await state.deleteProxyProfile(proxy) }
                        }
                    }
                    .contentShape(Rectangle())
                    .onDrag {
                        draggingProxyProfileID = proxy.id
                        return NSItemProvider(
                            object: proxy.id.uuidString as NSString
                        )
                    }
                    .onDrop(
                        of: [.text],
                        delegate: WorkflowItemDropDelegate(
                            itemID: proxy.id,
                            draggingID: $draggingProxyProfileID,
                            move: { sourceID, targetID in
                                state.moveProxyProfile(
                                    id: sourceID,
                                    over: targetID
                                )
                            },
                            persist: {
                                Task {
                                    await state.persistProxyProfileOrder()
                                }
                            }
                        )
                    )
                }
            }
        }
        .animation(
            .easeInOut(duration: 0.15),
            value: state.proxyProfiles.map(\.id)
        )
    }

    private func editScript(_ script: AutomationScript) {
        clearWorkflowEditor()
        editingScript = script
    }

    private func editNote(_ note: HostNote) {
        clearWorkflowEditor()
        editingNote = note
    }

    private var forwardingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "Port Forwarding",
                subtitle: "Local, remote, and dynamic forwarding launch as managed terminal sessions.",
                button: "New Forward"
            ) {
                editForward(
                    PortForwardRule(
                        hostID: state.hosts.first?.id,
                        name: AppLocalization.string("Local Forward"),
                        kind: .local,
                        localPort: 8080,
                        remoteHost: "127.0.0.1",
                        remotePort: 80
                    )
                )
            }
            if state.portForwardRules.isEmpty {
                emptyRow("No forwarding rules yet.")
            } else {
                ForEach(state.portForwardRules) { rule in
                    workflowRow(
                        title: rule.name,
                        detail: portForwardRowDetail(rule),
                        systemImage: "arrow.left.arrow.right"
                    ) {
                        if rule.status == .active || rule.status == .connecting {
                            Button("Stop") {
                                Task { await state.stopPortForward(rule) }
                            }
                        } else {
                            Button("Start") {
                                Task { await state.startPortForward(rule) }
                            }
                        }
                        Button("Edit") {
                            editForward(rule)
                        }
                        Button("Delete", role: .destructive) {
                            Task { await state.deletePortForwardRule(rule) }
                        }
                    }
                }
            }
        }
    }

    private var scriptsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "Scripts",
                subtitle: "Create and manage shell scripts for terminal sessions.",
                button: "New Script"
            ) {
                editScript(
                    AutomationScript(
                        title: "",
                        shell: "/bin/sh",
                        body: ""
                    )
                )
            }
            if state.automationScripts.isEmpty {
                emptyRow("No scripts yet.")
            } else {
                ForEach(state.automationScripts) { script in
                    workflowRow(
                        title: script.title,
                        detail: script.body,
                        systemImage: "curlybraces.square",
                        showsDragHandle: true
                    ) {
                        Button("Edit") {
                            editScript(script)
                        }
                        Button("Delete", role: .destructive) {
                            Task { await state.deleteAutomationScript(script) }
                        }
                    }
                    .contentShape(Rectangle())
                    .onDrag {
                        draggingAutomationScriptID = script.id
                        return NSItemProvider(
                            object: script.id.uuidString as NSString
                        )
                    }
                    .onDrop(
                        of: [.text],
                        delegate: WorkflowItemDropDelegate(
                            itemID: script.id,
                            draggingID: $draggingAutomationScriptID,
                            move: { sourceID, targetID in
                                state.moveAutomationScript(
                                    id: sourceID,
                                    over: targetID
                                )
                            },
                            persist: {
                                Task {
                                    await state.persistAutomationScriptOrder()
                                }
                            }
                        )
                    )
                }
            }
        }
        .animation(
            .easeInOut(duration: 0.15),
            value: state.automationScripts.map(\.id)
        )
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "Host Notes",
                subtitle: "Markdown notes for hosts and operational context.",
                button: "New Note"
            ) {
                editNote(
                    HostNote(
                        hostID: state.hosts.first?.id,
                        title: AppLocalization.string("New Note"),
                        body: ""
                    )
                )
            }
            if state.hostNotes.isEmpty {
                emptyRow("No notes yet.")
            } else {
                ForEach(state.hostNotes) { note in
                    workflowRow(
                        title: note.title,
                        detail: note.body,
                        systemImage: "note.text"
                    ) {
                        Button("Edit") {
                            editNote(note)
                        }
                        Button("Delete", role: .destructive) {
                            Task { await state.deleteHostNote(note) }
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        button: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(button, action: action)
        }
    }

    private func emptyRow(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func workflowRow<Actions: View>(
        title: String,
        detail: String,
        systemImage: String,
        showsDragHandle: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 10) {
            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
            }
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            actions()
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func portForwardDetail(_ rule: PortForwardRule) -> String {
        let kind = rule.kind.appLocalizedTitle
        let local = "\(rule.bindAddress):\(rule.localPort)"
        switch rule.kind {
        case .dynamic:
            return "\(kind) \(local)"
        case .local:
            let remotePort = rule.remotePort ?? rule.localPort
            return "\(kind) \(local) -> \(rule.remoteHost):\(remotePort)"
        case .remote:
            let remotePort = rule.remotePort ?? rule.localPort
            return "\(kind) \(rule.remoteHost):\(remotePort) -> \(local)"
        }
    }

    private func portForwardRowDetail(_ rule: PortForwardRule) -> String {
        let base = "\(portForwardDetail(rule)) - \(rule.status.appLocalizedTitle)"
        guard rule.status == .error,
              let error = rule.error,
              !error.isEmpty
        else {
            return base
        }
        return "\(base): \(error)"
    }
}

private struct CredentialEditor: View {
    @State private var credential: SSHCredential
    let onCancel: () -> Void
    let onSave: (SSHCredential) -> Void

    init(
        credential: SSHCredential,
        onCancel: @escaping () -> Void,
        onSave: @escaping (SSHCredential) -> Void
    ) {
        _credential = State(initialValue: credential)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    LocalizedStringKey(
                        credential.label.isEmpty ? "New Credential" : "Edit Credential"
                    )
                )
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Type", selection: $credential.kind) {
                        Text("Password").tag(SSHCredentialKind.password)
                        Text("Private Key").tag(SSHCredentialKind.identityKey)
                    }
                    .pickerStyle(.segmented)

                    credentialTextField(
                        title: "Label *",
                        placeholder: "Credential label",
                        text: $credential.label
                    )
                    credentialTextField(
                        title: "Username *",
                        placeholder: "Username",
                        text: $credential.username
                    )

                    if credential.kind == .password {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Password *")
                                .font(.caption.weight(.semibold))
                            RevealablePasswordField(
                                AppLocalization.string("Password"),
                                text: Binding(
                                    get: { credential.password ?? "" },
                                    set: { credential.password = $0 }
                                )
                            )
                        }
                        Text("The password is stored as an encrypted Vault field.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Private Key *")
                                .font(.caption.weight(.semibold))
                            multilineEditor(
                                text: Binding(
                                    get: { credential.privateKey ?? "" },
                                    set: { credential.privateKey = $0 }
                                ),
                                height: 170,
                                placeholder: "-----BEGIN OPENSSH PRIVATE KEY-----"
                            )
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Public Key")
                                .font(.caption.weight(.semibold))
                            multilineEditor(
                                text: Binding(
                                    get: { credential.publicKey ?? "" },
                                    set: { credential.publicKey = $0 }
                                ),
                                height: 78,
                                placeholder: "ssh-ed25519 AAAA..."
                            )
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Certificate")
                                .font(.caption.weight(.semibold))
                            multilineEditor(
                                text: Binding(
                                    get: { credential.certificate ?? "" },
                                    set: { credential.certificate = $0 }
                                ),
                                height: 78,
                                placeholder: "Certificate content (optional)"
                            )
                        }
                        RevealablePasswordField(
                            AppLocalization.string("Passphrase (optional)"),
                            text: Binding(
                                get: { credential.passphrase ?? "" },
                                set: { credential.passphrase = $0 }
                            )
                        )
                        Toggle(
                            "Save Passphrase",
                            isOn: $credential.savesPassphrase
                        )
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("sudo/su Password (optional)")
                            .font(.caption.weight(.semibold))
                        RevealablePasswordField(
                            "",
                            text: Binding(
                                get: { credential.elevationPassword ?? "" },
                                set: { credential.elevationPassword = $0 }
                            )
                        )
                        Text(
                            "Used by automatic root server tools and Password Prompt Assist."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save") {
                    onSave(credential)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func multilineEditor(
        text: Binding<String>,
        height: CGFloat,
        placeholder: String
    ) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.system(.caption, design: .monospaced))
                .frame(height: height)
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2))
        )
    }

    private func credentialTextField(
        title: LocalizedStringKey,
        placeholder: LocalizedStringKey,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            TextField(placeholder, text: text)
        }
    }
}

private struct PortForwardRuleEditor: View {
    @EnvironmentObject private var state: AppState
    @State private var rule: PortForwardRule
    @State private var localEndpointText: String
    @State private var remoteEndpointText: String
    @State private var validationMessage: String?
    let onCancel: () -> Void
    let onSave: (PortForwardRule) -> Void

    init(
        rule: PortForwardRule,
        onCancel: @escaping () -> Void,
        onSave: @escaping (PortForwardRule) -> Void
    ) {
        _rule = State(initialValue: rule)
        _localEndpointText = State(
            initialValue: PortForwardEndpoint(
                host: rule.bindAddress,
                port: rule.localPort
            ).text
        )
        _remoteEndpointText = State(
            initialValue: PortForwardEndpoint(
                host: rule.remoteHost,
                port: rule.remotePort ?? rule.localPort
            ).text
        )
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        workflowForm(title: "Port Forward") {
            TextField("Name", text: $rule.name)
            Picker("Host", selection: $rule.hostID) {
                Text("First saved host").tag(Optional<UUID>.none)
                ForEach(state.hosts) { host in
                    Text(host.label).tag(Optional(host.id))
                }
            }
            Picker("Kind", selection: $rule.kind) {
                ForEach(PortForwardKind.allCases, id: \.self) { kind in
                    Text(kind.appLocalizedTitleKey).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            Text(rule.kind.appLocalizedDescriptionKey)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Auto Start", isOn: $rule.autoStart)
            endpointField(
                "Local IP:Port",
                text: $localEndpointText
            )
            if rule.kind != .dynamic {
                endpointField(
                    "Remote IP:Port",
                    text: $remoteEndpointText
                )
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func save() {
        guard let localEndpoint = PortForwardEndpoint.parse(localEndpointText) else {
            validationMessage = AppLocalization.string("Enter a valid local IP:port.")
            return
        }
        var updated = rule
        updated.bindAddress = localEndpoint.host
        updated.localPort = localEndpoint.port

        if updated.kind == .dynamic {
            updated.remotePort = nil
        } else {
            guard let remoteEndpoint = PortForwardEndpoint.parse(remoteEndpointText) else {
                validationMessage = AppLocalization.string("Enter a valid remote IP:port.")
                return
            }
            updated.remoteHost = remoteEndpoint.host
            updated.remotePort = remoteEndpoint.port
        }

        validationMessage = nil
        onSave(updated)
    }

    private func endpointField(
        _ title: LocalizedStringKey,
        text: Binding<String>
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func workflowForm<Fields: View>(
        title: String,
        @ViewBuilder fields: () -> Fields
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2.weight(.semibold))
            fields()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ScriptEditor: View {
    @State private var script: AutomationScript
    let onCancel: () -> Void
    let onSave: (AutomationScript) -> Void

    init(
        script: AutomationScript,
        onCancel: @escaping () -> Void,
        onSave: @escaping (AutomationScript) -> Void
    ) {
        _script = State(initialValue: script)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Script")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Title *")
                    .font(.caption.weight(.semibold))
                TextField("Script title", text: $script.title)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Content")
                    .font(.caption.weight(.semibold))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $script.body)
                        .font(.system(.body, design: .monospaced))
                        .padding(.top, 8)
                        .frame(height: 220)
                    if script.body.isEmpty {
                        Text("echo hello")
                            .font(.body.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2))
                )
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save") {
                    script.shell = "/bin/sh"
                    onSave(script)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct HostNoteEditor: View {
    @EnvironmentObject private var state: AppState
    @State private var note: HostNote
    let onCancel: () -> Void
    let onSave: (HostNote) -> Void

    init(
        note: HostNote,
        onCancel: @escaping () -> Void,
        onSave: @escaping (HostNote) -> Void
    ) {
        _note = State(initialValue: note)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Host Note")
                .font(.title2.weight(.semibold))
            TextField("Title", text: $note.title)
            Picker("Host", selection: $note.hostID) {
                Text("General").tag(Optional<UUID>.none)
                ForEach(state.hosts) { host in
                    Text(host.label).tag(Optional(host.id))
                }
            }
            TextEditor(text: $note.body)
                .frame(height: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2))
                )
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save") {
                    onSave(note)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private extension View {
    @ViewBuilder
    func workflowEditorPanelStyle(
        scrollsContent: Bool = true
    ) -> some View {
        Group {
            if scrollsContent {
                ScrollView {
                    self
                        .frame(
                            maxWidth: .infinity,
                            alignment: .topLeading
                        )
                }
            } else {
                self
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
            }
        }
        .frame(width: 460)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private enum HostTreeRow: Identifiable {
    case group(
        HostGroup,
        depth: Int,
        hostCount: Int
    )
    case host(TermPilotDomain.Host, depth: Int)

    var id: String {
        switch self {
        case let .group(group, _, _):
            "group-\(group.id.uuidString)"
        case let .host(host, _):
            "host-\(host.id.uuidString)"
        }
    }
}

enum WorkspaceDragLayout {
    static let coordinateSpace = "workspace-drag-layout"
}

struct WorkspacePaneFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(
        value: inout [UUID: CGRect],
        nextValue: () -> [UUID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct WorkspaceTabBarFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(
        value: inout CGRect,
        nextValue: () -> CGRect
    ) {
        value = nextValue()
    }
}

struct WorkspacePaneDetachTarget {
    let insertionIndex: Int
    let indicatorX: CGFloat
}

enum WorkspacePaneDetachDropResolver {
    static func resolve(
        location: CGPoint,
        tabBarFrame: CGRect,
        tabFrames: [CGRect]
    ) -> WorkspacePaneDetachTarget? {
        guard tabBarFrame.width > 0,
              tabBarFrame.height > 0,
              tabBarFrame.contains(location)
        else {
            return nil
        }

        for (index, frame) in tabFrames.enumerated() {
            if location.x <= frame.midX {
                return WorkspacePaneDetachTarget(
                    insertionIndex: index,
                    indicatorX: frame.minX
                )
            }
            if location.x <= frame.maxX {
                return WorkspacePaneDetachTarget(
                    insertionIndex: index + 1,
                    indicatorX: frame.maxX
                )
            }
        }

        if let lastFrame = tabFrames.last {
            return WorkspacePaneDetachTarget(
                insertionIndex: tabFrames.count,
                indicatorX: lastFrame.maxX
            )
        }
        return WorkspacePaneDetachTarget(
            insertionIndex: 0,
            indicatorX: tabBarFrame.minX + 8
        )
    }
}

struct WorkspaceSplitDropResolution {
    let axis: SplitAxis
    let placement: SplitPlacement
    let previewFrame: CGRect
}

enum WorkspaceSplitDropResolver {
    static func resolve(
        location: CGPoint,
        in targetFrame: CGRect
    ) -> WorkspaceSplitDropResolution? {
        guard targetFrame.width > 0,
              targetFrame.height > 0,
              targetFrame.contains(location)
        else {
            return nil
        }

        let relativeX = (location.x - targetFrame.minX) / targetFrame.width
        let relativeY = (location.y - targetFrame.minY) / targetFrame.height
        let prefersVertical =
            abs(relativeX - 0.5) > abs(relativeY - 0.5)
        let axis: SplitAxis = prefersVertical ? .vertical : .horizontal
        let placement: SplitPlacement
        var previewFrame = targetFrame

        if prefersVertical {
            previewFrame.size.width /= 2
            if relativeX < 0.5 {
                placement = .before
            } else {
                placement = .after
                previewFrame.origin.x += previewFrame.width
            }
        } else {
            previewFrame.size.height /= 2
            if relativeY < 0.5 {
                placement = .before
            } else {
                placement = .after
                previewFrame.origin.y += previewFrame.height
            }
        }

        return WorkspaceSplitDropResolution(
            axis: axis,
            placement: placement,
            previewFrame: previewFrame
        )
    }
}

private struct WorkspaceSplitDropHint {
    let sourceWorkspaceID: UUID
    let targetWorkspaceID: UUID
    let targetSessionID: UUID
    let axis: SplitAxis
    let placement: SplitPlacement
    let previewFrame: CGRect
}

private struct TerminalTabSplitDropHint {
    let sourceSessionID: UUID
    let workspaceID: UUID
    let targetSessionID: UUID
    let axis: SplitAxis
    let placement: SplitPlacement
    let previewFrame: CGRect
}

private struct WorkspaceTabFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(
        value: inout [UUID: CGRect],
        nextValue: () -> [UUID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct TopTabCloseButtonLabel: View {
    let isHovered: Bool

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isHovered ? Color.white : Color.secondary)
            .frame(width: 19, height: 19)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        isHovered
                            ? Color(
                                red: 248 / 255,
                                green: 81 / 255,
                                blue: 73 / 255
                            )
                            : Color.clear
                    )
            )
            .contentShape(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}

private struct WorkspaceTab: View {
    @EnvironmentObject private var state: AppState
    let workspace: WorkspaceDocument
    let isActive: Bool
    @Binding var draggingWorkspaceID: UUID?
    var onSelect: () -> Void
    var onDragChanged: (UUID, CGPoint) -> Void
    var onDragEnded: (UUID, CGPoint) -> Void
    @State private var showingRename = false
    @State private var renameTitle = ""
    @State private var isCloseButtonHovered = false

    private var isDragging: Bool {
        draggingWorkspaceID == workspace.id
    }

    private var paneCount: Int {
        workspace.root.paneCount
    }

    private var isSplitWorkspace: Bool {
        paneCount > 1
    }

    private var displayedTitle: String {
        isSplitWorkspace ? "Workspace" : workspace.title
    }

    private var tooltipTitle: String {
        workspace.title
    }

    private var tooltipSubtitle: String? {
        var parts: [String] = []
        if isSplitWorkspace {
            parts.append("\(displayedTitle) \(paneCount)")
        }
        if let descriptor = state.sessions[workspace.focusedSessionID] {
            switch descriptor.kind {
            case .ssh:
                if let username = descriptor.username,
                   let hostname = descriptor.hostname
                {
                    let port = descriptor.port ?? 22
                    parts.append("\(username)@\(hostname):\(port)")
                }
            case .local:
                if let workingDirectory = descriptor.workingDirectory,
                   !workingDirectory.isEmpty
                {
                    parts.append(workingDirectory)
                } else if let shell = descriptor.shell, !shell.isEmpty {
                    parts.append(shell)
                }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var host: TermPilotDomain.Host? {
        guard let descriptor = state.sessions[workspace.focusedSessionID] else {
            return nil
        }
        return state.sessionHost(for: descriptor)
    }

    var body: some View {
        HStack(spacing: 6) {
            if workspace.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
            }
            if isSplitWorkspace {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            } else if let host {
                HostIconView(host: host, size: 18)
            }
            Text(displayedTitle)
                .lineLimit(1)
            if isSplitWorkspace {
                Text("\(paneCount)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 22)
                    .overlay(
                        Capsule()
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    )
            }
            Spacer(minLength: 0)
            Button {
                Task {
                    await state.closeWorkspace(workspace.id)
                }
            } label: {
                TopTabCloseButtonLabel(isHovered: isCloseButtonHovered)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(displayedTitle)")
            .onHover { isCloseButtonHovered = $0 }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(
            width: TerminalTabLayoutMetrics.fixedWidth,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    isDragging
                        ? Color.accentColor.opacity(0.26)
                        : isActive
                            ? Color.accentColor.opacity(0.18)
                            : .clear
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    isDragging ? Color.accentColor.opacity(0.85) : .clear,
                    lineWidth: 1
                )
        )
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: WorkspaceTabFramePreferenceKey.self,
                    value: [
                        workspace.id: proxy.frame(
                            in: .named(WorkspaceDragLayout.coordinateSpace)
                        )
                    ]
                )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .scaleEffect(isDragging ? 1.04 : 1)
        .shadow(
            color: isDragging ? Color.black.opacity(0.24) : .clear,
            radius: isDragging ? 8 : 0,
            x: 0,
            y: isDragging ? 4 : 0
        )
        .zIndex(isDragging ? 1 : 0)
        .opacity(isDragging ? 0.72 : 1)
        .animation(.easeInOut(duration: 0.14), value: isDragging)
        .pointingHandCursor()
        .tabInfoPopover(
            title: tooltipTitle,
            subtitle: tooltipSubtitle
        )
        .onTapGesture(perform: onSelect)
        .simultaneousGesture(
            DragGesture(
                minimumDistance: 4,
                coordinateSpace: .named(
                    WorkspaceDragLayout.coordinateSpace
                )
            )
            .onChanged { value in
                NSCursor.pointingHand.set()
                if draggingWorkspaceID == nil {
                    draggingWorkspaceID = workspace.id
                }
                onDragChanged(workspace.id, value.location)
            }
            .onEnded { value in
                onDragEnded(workspace.id, value.location)
                NSCursor.arrow.set()
            }
        )
        .contextMenu {
            Button("Reconnect") {
                state.reconnect(sessionID: workspace.focusedSessionID)
            }
            Divider()
            Button("Rename...") {
                renameTitle = workspace.title
                showingRename = true
            }
            Button("Duplicate") {
                Task {
                    await state.duplicateWorkspace(id: workspace.id)
                }
            }
            Button {
                state.togglePinned(id: workspace.id)
            } label: {
                Text(LocalizedStringKey(workspace.pinned ? "Unpin" : "Pin"))
            }
            Button("Move Left") {
                state.moveWorkspace(id: workspace.id, offset: -1)
            }
            Button("Move Right") {
                state.moveWorkspace(id: workspace.id, offset: 1)
            }
            Divider()
            Button("Close Other Tabs") {
                Task {
                    await state.closeOtherWorkspaces(keeping: workspace.id)
                }
            }
            Button("Close All Tabs") {
                Task {
                    await state.closeAllWorkspaces()
                }
            }
            Button("Close", role: .destructive) {
                Task {
                    await state.closeWorkspace(workspace.id)
                }
            }
        }
        .alert("Rename Tab", isPresented: $showingRename) {
            TextField("Name", text: $renameTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                state.renameWorkspace(id: workspace.id, title: renameTitle)
            }
        }
    }
}

private struct SettingsTab: View {
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isCloseButtonHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(
                            isActive ? Color.accentColor : .secondary
                        )
                    Text(verbatim: AppLocalization.string("Settings"))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            Button(action: onClose) {
                TopTabCloseButtonLabel(isHovered: isCloseButtonHovered)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.string("Close Tab"))
            .onHover { isCloseButtonHovered = $0 }
        }
        .padding(.horizontal, 10)
        .frame(
            width: TerminalTabLayoutMetrics.fixedWidth,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? Color.accentColor.opacity(0.18) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .pointingHandCursor()
        .tabInfoPopover(title: AppLocalization.string("Settings"))
    }
}

private enum QuickConnectServerToolsMode: String, CaseIterable {
    case disabled
    case sudo
    case su
}

struct QuickConnectCredentialFields: Equatable {
    var username: String
    var authentication: AuthenticationMethod
    var password: String
    var identityKey: String
    var publicKey: String
    var certificate: String
    var passphrase: String
    var elevationPassword: String

    init(credential: SSHCredential) {
        username = credential.username
        authentication = credential.kind == .identityKey
            ? .identityFile
            : .password
        password = credential.kind == .password
            ? credential.password ?? ""
            : ""
        identityKey = credential.kind == .identityKey
            ? credential.privateKey ?? ""
            : ""
        publicKey = credential.kind == .identityKey
            ? credential.publicKey ?? ""
            : ""
        certificate = credential.kind == .identityKey
            ? credential.certificate ?? ""
            : ""
        passphrase = credential.kind == .identityKey
            ? credential.passphrase ?? ""
            : ""
        elevationPassword = credential.elevationPassword ?? ""
    }
}

private struct QuickConnectView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    var onConnected: () -> Void = {}
    
    @State private var hostname = ""
    @State private var username = ""
    @State private var portText = "22"
    @State private var credentialID: UUID?
    @State private var authentication = AuthenticationMethod.agent
    @State private var password = ""
    @State private var identityFile = ""
    @State private var identityKey = ""
    @State private var publicKey = ""
    @State private var certificate = ""
    @State private var passphrase = ""
    @State private var serverToolsMode = QuickConnectServerToolsMode.disabled
    @State private var elevationPassword = ""
    
    @FocusState private var isHostnameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: localized("Quick Connect"))
                .font(.title2.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    formRow("IP / Host") {
                        TextField("10.0.0.1", text: $hostname)
                            .textFieldStyle(.roundedBorder)
                            .focused($isHostnameFocused)
                            .onSubmit(connect)
                            .onChange(of: hostname) { _, value in
                                applyPastedTargetIfNeeded(value)
                            }
                    }
                    HStack(spacing: 12) {
                        formRow("Username") {
                            TextField("root", text: $username)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(connect)
                        }
                        formRow("Port") {
                            TextField("22", text: $portText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 84)
                                .onSubmit(connect)
                        }
                    }

                    formRow("Credential") {
                        Picker("", selection: $credentialID) {
                            Text(verbatim: localized("Custom Credential"))
                                .tag(UUID?.none)
                            ForEach(state.credentials) { credential in
                                Text(credentialTitle(credential)).tag(UUID?.some(credential.id))
                            }
                        }
                        .labelsHidden()
                    }

                    if credentialID != nil {
                        Text(
                            verbatim: localized(
                                "Credential values were copied and can be edited."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 92)
                    }

                    formRow("Authentication") {
                        Picker("", selection: $authentication) {
                            Text(verbatim: localized("SSH Agent"))
                                .tag(AuthenticationMethod.agent)
                            Text(verbatim: localized("Password"))
                                .tag(AuthenticationMethod.password)
                            Text(verbatim: localized("Private Key"))
                                .tag(AuthenticationMethod.identityFile)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    if authentication == .password {
                        formRow("Password") {
                            SecureField(
                                localized("Password"),
                                text: $password
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                        Text(
                            verbatim: localized(
                                "Used only for this connection and not written to macOS Keychain."
                            )
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 92)
                    }
                    if authentication == .identityFile {
                        formRow("Private key file") {
                            HStack {
                                TextField(
                                    localized("Private key file"),
                                    text: $identityFile
                                )
                                .textFieldStyle(.roundedBorder)
                                Button(localized("Choose...")) {
                                    let panel = NSOpenPanel()
                                    panel.canChooseDirectories = false
                                    panel.allowsMultipleSelection = false
                                    panel.directoryURL = FileManager.default
                                        .homeDirectoryForCurrentUser
                                        .appendingPathComponent(
                                            ".ssh",
                                            isDirectory: true
                                        )
                                    if panel.runModal() == .OK {
                                        identityFile = panel.url?.path ?? ""
                                    }
                                }
                            }
                        }
                        formRow("Private key data") {
                            credentialTextEditor(text: $identityKey, height: 72)
                        }
                        formRow("Passphrase (optional)") {
                            SecureField(
                                localized("Passphrase (optional)"),
                                text: $passphrase
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                        formRow("Public Key") {
                            credentialTextEditor(text: $publicKey, height: 48)
                        }
                        formRow("Certificate") {
                            credentialTextEditor(text: $certificate, height: 48)
                        }
                    }
                    serverToolsSettingsCard
                }
            }
            .frame(maxHeight: 620)

            HStack {
                Spacer()
                Button(localized("Cancel"), role: .cancel) {
                    dismiss()
                }
                Button(localized("Connect")) {
                    if canConnect {
                        connect()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
        }
        .padding(24)
        .frame(width: 500)
        .task {
            await state.refreshCredentials()
            await Task.yield()
            isHostnameFocused = true
        }
        .onChange(of: credentialID) { _, _ in
            if let selectedCredential {
                applyCredential(selectedCredential)
            }
        }
    }

    private func connect() {
        guard let port else {
            return
        }
        Task {
            if await state.quickConnect(
                hostname: hostname,
                username: username,
                port: port,
                authentication: authentication,
                password: password,
                identityFile: trimmedIdentityFile,
                identityKey: trimmedIdentityKey,
                publicKey: trimmedPublicKey,
                certificate: trimmedCertificate,
                passphrase: passphrase.isEmpty ? nil : passphrase,
                elevationPassword: trimmedElevationPassword,
                serverToolsUseRoot: serverToolsMode != .disabled,
                serverToolsElevationMethod:
                    serverToolsMode == .su ? .su : .sudo
            ) {
                onConnected()
                dismiss()
            }
        }
    }

    private var selectedCredential: SSHCredential? {
        guard let credentialID else {
            return nil
        }
        return state.credentials.first { $0.id == credentialID }
    }

    private var port: Int? {
        let value = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(value), (1 ... 65_535).contains(port) else {
            return nil
        }
        return port
    }

    private var trimmedIdentityFile: String? {
        let value = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var trimmedIdentityKey: String? {
        identityKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : identityKey
    }

    private var trimmedPublicKey: String? {
        publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : publicKey
    }

    private var trimmedCertificate: String? {
        certificate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : certificate
    }

    private var trimmedElevationPassword: String? {
        guard serverToolsMode != .disabled else {
            return nil
        }
        return elevationPassword.isEmpty ? nil : elevationPassword
    }

    private var canConnect: Bool {
        let hasHost = !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasUsername = !username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let hasAuthentication = authentication != .password
            || !password.isEmpty
        let hasIdentity = authentication != .identityFile
            || trimmedIdentityFile != nil
            || trimmedIdentityKey != nil
        return hasHost
            && port != nil
            && hasUsername
            && hasAuthentication
            && hasIdentity
    }

    private var serverToolsSettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: localized("Server Tools"))
                .font(.headline.weight(.semibold))

            HStack {
                Text(verbatim: localized("Privilege Escalation"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $serverToolsMode) {
                    Text(verbatim: localized("Disabled"))
                        .tag(QuickConnectServerToolsMode.disabled)
                    Text("sudo")
                        .tag(QuickConnectServerToolsMode.sudo)
                    Text("su")
                        .tag(QuickConnectServerToolsMode.su)
                }
                    .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120, alignment: .trailing)
            }

            if serverToolsMode != .disabled {
                SecureField(
                    localized("Elevation Password"),
                    text: $elevationPassword
                )
                .textFieldStyle(.roundedBorder)

                Text(
                    verbatim: localized(
                        "Leave blank to use the login password when available."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

        }
        .padding(12)
        .background(
            Color.secondary.opacity(0.06),
            in: RoundedRectangle(
                cornerRadius: 6,
                style: .continuous
            )
        )
    }

    private func formRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: localized(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            content()
        }
    }

    private func credentialTextEditor(
        text: Binding<String>,
        height: CGFloat
    ) -> some View {
        TextEditor(text: text)
            .font(.system(.caption, design: .monospaced))
            .frame(height: height)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3))
            )
    }

    private func localized(_ key: String) -> String {
        AppLocalization.string(key)
    }

    private func credentialTitle(_ credential: SSHCredential) -> String {
        "\(credential.label) [\(credential.kind.appLocalizedTitle)]"
    }

    private func applyCredential(_ credential: SSHCredential) {
        let fields = QuickConnectCredentialFields(credential: credential)
        username = fields.username
        authentication = fields.authentication
        password = fields.password
        identityFile = ""
        identityKey = fields.identityKey
        publicKey = fields.publicKey
        certificate = fields.certificate
        passphrase = fields.passphrase
        elevationPassword = fields.elevationPassword
    }

    private func applyPastedTargetIfNeeded(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("ssh://") || trimmed.contains("@"),
              let target = try? QuickConnectParser.parse(trimmed)
        else {
            return
        }
        hostname = target.hostname
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            username = target.username
        }
        portText = String(target.port)
    }
}
