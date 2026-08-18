import AppKit
import SwiftUI
import TermPilotDomain
import TermPilotTerminal

struct WorkspacePaneDragHandlers: @unchecked Sendable {
    var onChanged: (UUID, UUID, CGPoint) -> Void
    var onEnded: (UUID, UUID, CGPoint) -> Void

    static let inactive = WorkspacePaneDragHandlers(
        onChanged: { _, _, _ in },
        onEnded: { _, _, _ in }
    )
}

private struct WorkspacePaneDragHandlersKey: EnvironmentKey {
    static let defaultValue = WorkspacePaneDragHandlers.inactive
}

extension EnvironmentValues {
    var workspacePaneDragHandlers: WorkspacePaneDragHandlers {
        get { self[WorkspacePaneDragHandlersKey.self] }
        set { self[WorkspacePaneDragHandlersKey.self] = newValue }
    }
}

struct WorkspaceTerminalTabDragHandlers: @unchecked Sendable {
    var onChanged: (UUID, UUID, CGPoint?) -> Void
    var onEnded: (UUID, UUID, CGPoint?) -> Void

    static let inactive = WorkspaceTerminalTabDragHandlers(
        onChanged: { _, _, _ in },
        onEnded: { _, _, _ in }
    )
}

private struct WorkspaceTerminalTabDragHandlersKey: EnvironmentKey {
    static let defaultValue = WorkspaceTerminalTabDragHandlers.inactive
}

extension EnvironmentValues {
    var workspaceTerminalTabDragHandlers: WorkspaceTerminalTabDragHandlers {
        get { self[WorkspaceTerminalTabDragHandlersKey.self] }
        set { self[WorkspaceTerminalTabDragHandlersKey.self] = newValue }
    }
}

enum TerminalTabLayoutMetrics {
    static let fixedWidth: CGFloat = 172
}

private struct WorkspacePaneFramePublishingEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var workspacePaneFramePublishingEnabled: Bool {
        get { self[WorkspacePaneFramePublishingEnabledKey.self] }
        set { self[WorkspacePaneFramePublishingEnabledKey.self] = newValue }
    }
}

private struct PulsingCircle: View {
    let color: Color
    @State private var isPulsing = false
    
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 24, height: 24)
            .scaleEffect(isPulsing ? 1.0 : 0.85)
            .opacity(isPulsing ? 1.0 : 0.6)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

struct WorkspaceView: View {
    @EnvironmentObject private var state: AppState
    let workspace: WorkspaceDocument
    let isActive: Bool
    @State private var sidePanelContentWidth: CGFloat = 0

    @ViewBuilder
    var body: some View {
        if state.isTerminalSidePanelVisible(in: workspace.id) {
            TerminalSidePanelSplitView(
                contentUpdateID: workspace.id.uuidString,
                sidebarUpdateID: state.terminalSidePanelUpdateID(
                    in: workspace.id
                ),
                content: AnyView(
                    WorkspaceContentView(workspaceID: workspace.id)
                        .environmentObject(state)
                        .environment(
                            \.workspacePaneFramePublishingEnabled,
                            false
                        )
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                ),
                sidebar: AnyView(
                    WorkspaceTerminalSidePanel(workspaceID: workspace.id)
                        .environmentObject(state)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                ),
                onContentWidthChange: {
                    sidePanelContentWidth = $0
                }
            )
            .background {
                GeometryReader { proxy in
                    let containerFrame = proxy.frame(
                        in: .named(WorkspaceDragLayout.coordinateSpace)
                    )
                    let paneFrame =
                        WorkspaceSidePanelDropFrameResolver.contentFrame(
                            containerFrame: containerFrame,
                            contentWidth: sidePanelContentWidth
                        )
                    Color.clear.preference(
                        key: WorkspacePaneFramePreferenceKey.self,
                        value: isActive && workspace.root.paneCount == 1
                            ? paneFrame.map {
                                [workspace.focusedSessionID: $0]
                            } ?? [:]
                            : [:]
                    )
                }
            }
        } else {
            WorkspaceContentView(workspaceID: workspace.id)
                .environmentObject(state)
                .environment(
                    \.workspacePaneFramePublishingEnabled,
                    isActive
                )
        }
    }
}

enum WorkspaceSidePanelDropFrameResolver {
    static let terminalTopInset: CGFloat = 33

    static func contentFrame(
        containerFrame: CGRect,
        contentWidth: CGFloat
    ) -> CGRect? {
        guard containerFrame.width > 0,
              containerFrame.height > 0,
              contentWidth > 0
        else {
            return nil
        }
        return CGRect(
            x: containerFrame.minX,
            y: containerFrame.minY + terminalTopInset,
            width: min(contentWidth, containerFrame.width),
            height: max(containerFrame.height - terminalTopInset, 0)
        )
    }
}

private struct WorkspaceContentView: View {
    @EnvironmentObject private var state: AppState
    let workspaceID: UUID

    @ViewBuilder
    var body: some View {
        if let workspace = state.workspaces.first(where: {
            $0.id == workspaceID
        }) {
            WorkspaceNodeView(
                node: workspace.root,
                workspaceID: workspaceID
            )
            .environmentObject(state)
        }
    }
}

private struct WorkspaceTerminalSidePanel: View {
    @EnvironmentObject private var state: AppState
    let workspaceID: UUID

    @ViewBuilder
    var body: some View {
        if let sessionID = state.terminalSidePanelSessionID(in: workspaceID),
           let runtime = state.runtimes[sessionID],
           let host = state.sessionHost(for: runtime.descriptor),
           let sftpModel = state.sftpSidePanelModel(in: workspaceID),
           let commandHistoryModel = state.commandHistoryModel(in: workspaceID)
        {
            TerminalSessionSidePanel(
                workspaceID: workspaceID,
                host: host,
                runtime: runtime,
                sftpModel: sftpModel,
                commandHistoryModel: commandHistoryModel
            )
            .environmentObject(state)
        }
    }
}

private struct WorkspaceNodeView: View {
    @EnvironmentObject private var state: AppState
    let node: WorkspaceNode
    let workspaceID: UUID

    @ViewBuilder
    var body: some View {
        switch node {
        case let .pane(_, sessionID):
            TerminalTabGroupPane(
                sessionIDs: [sessionID],
                activeSessionID: sessionID,
                workspaceID: workspaceID,
                showsTabStrip: true
            )
            .environmentObject(state)
        case let .tabGroup(_, sessionIDs, activeSessionID):
            TerminalTabGroupPane(
                sessionIDs: sessionIDs,
                activeSessionID: activeSessionID,
                workspaceID: workspaceID,
                showsTabStrip: true
            )
            .environmentObject(state)
        case let .split(splitID, axis, children, sizes):
            if children.count == 2 {
                ResizableSplitView(
                    axis: axis,
                    sizes: sizes,
                    first: AnyView(
                        WorkspaceNodeView(
                            node: children[0],
                            workspaceID: workspaceID
                        )
                        .environmentObject(state)
                    ),
                    second: AnyView(
                        WorkspaceNodeView(
                            node: children[1],
                            workspaceID: workspaceID
                        )
                        .environmentObject(state)
                    )
                ) { sizes in
                    state.updateSplitSizes(
                        workspaceID: workspaceID,
                        splitID: splitID,
                        sizes: sizes
                    )
                }
            } else if axis == .vertical {
                HSplitView {
                    childrenView(children)
                }
            } else {
                VSplitView {
                    childrenView(children)
                }
            }
        }
    }

    @ViewBuilder
    private func childrenView(_ children: [WorkspaceNode]) -> some View {
        ForEach(children) { child in
            WorkspaceNodeView(node: child, workspaceID: workspaceID)
                .environmentObject(state)
                .frame(minWidth: 220, minHeight: 140)
        }
    }
}

private struct TerminalTabGroupPane: View {
    @EnvironmentObject private var state: AppState
    let sessionIDs: [UUID]
    let activeSessionID: UUID
    let workspaceID: UUID
    let showsTabStrip: Bool

    var body: some View {
        if let activeID {
            ZStack {
                ForEach(sessionIDs, id: \.self) { sessionID in
                    if let runtime = state.runtimes[sessionID] {
                        let isActive = sessionID == activeID
                        SessionPane(
                            runtime: runtime,
                            workspaceID: workspaceID,
                            tabContext: showsTabStrip
                                ? TerminalTabContext(
                                    sessionIDs: sessionIDs,
                                    activeSessionID: activeID
                                )
                                : nil
                        )
                        .environmentObject(state)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .accessibilityHidden(!isActive)
                        .zIndex(isActive ? 1 : 0)
                    }
                }
            }
        } else {
            UnavailableSessionPane(
                sessionID: unavailableSessionID,
                workspaceID: workspaceID
            )
            .environmentObject(state)
        }
    }

    private var activeID: UUID? {
        if sessionIDs.contains(activeSessionID),
           state.runtimes[activeSessionID] != nil
        {
            return activeSessionID
        }
        return sessionIDs.first { state.runtimes[$0] != nil }
    }

    private var unavailableSessionID: UUID? {
        if sessionIDs.contains(activeSessionID) {
            return activeSessionID
        }
        return sessionIDs.first
    }
}

private struct TerminalTabContext {
    var sessionIDs: [UUID]
    var activeSessionID: UUID
}

private struct UnavailableSessionPane: View {
    @EnvironmentObject private var state: AppState
    let sessionID: UUID?
    let workspaceID: UUID

    var body: some View {
        ContentUnavailableView {
            Label("Session Unavailable", systemImage: "exclamationmark.triangle")
        } actions: {
            if let sessionID {
                Button("Close Session") {
                    Task {
                        await state.close(sessionID: sessionID, in: workspaceID)
                    }
                }
            }
            Button("Close Tab") {
                Task {
                    await state.closeWorkspace(workspaceID)
                }
            }
        }
    }
}

private struct TerminalTabFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(
        value: inout [UUID: CGRect],
        nextValue: () -> [UUID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct TerminalTabStripFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(
        value: inout CGRect,
        nextValue: () -> CGRect
    ) {
        let next = nextValue()
        guard next.width > 0,
              next.height > 0
        else {
            return
        }
        value = next
    }
}

enum TerminalTabSplitDragResolver {
    static func tabStripFrame(
        tabFrames: [CGRect]
    ) -> CGRect? {
        let validFrames = tabFrames.filter {
            $0.width > 0 && $0.height > 0
        }
        guard let first = validFrames.first else {
            return nil
        }
        return validFrames.dropFirst().reduce(first) {
            $0.union($1)
        }
        .insetBy(dx: -6, dy: -6)
    }

    static func splitLocation(
        at location: CGPoint,
        tabFrames: [CGRect]
    ) -> CGPoint? {
        guard let tabStripFrame = tabStripFrame(
            tabFrames: tabFrames
        ) else {
            return nil
        }
        return tabStripFrame.contains(location) ? nil : location
    }
}

enum TerminalTabDragLocationResolver {
    static func resolve(
        startLocation: CGPoint,
        location: CGPoint,
        translation: CGSize,
        sourceFrame: CGRect?
    ) -> CGPoint {
        guard let sourceFrame,
              sourceFrame.width > 0,
              sourceFrame.height > 0
        else {
            return location
        }

        let tolerance: CGFloat = 2
        if sourceFrame.insetBy(
            dx: -tolerance,
            dy: -tolerance
        ).contains(startLocation) {
            return CGPoint(
                x: startLocation.x + translation.width,
                y: startLocation.y + translation.height
            )
        }

        let localBounds = CGRect(origin: .zero, size: sourceFrame.size)
            .insetBy(dx: -tolerance, dy: -tolerance)
        if localBounds.contains(startLocation) {
            return CGPoint(
                x: sourceFrame.minX + startLocation.x + translation.width,
                y: sourceFrame.minY + startLocation.y + translation.height
            )
        }

        return location
    }
}

enum TerminalTabDropIndicatorResolver {
    static func localX(
        rootX: CGFloat,
        tabStripFrame: CGRect
    ) -> CGFloat {
        guard tabStripFrame.width > 0,
              tabStripFrame.height > 0
        else {
            return rootX
        }
        return rootX - tabStripFrame.minX
    }
}

struct TerminalTabReorderResolution: Equatable {
    let rawDestinationIndex: Int
    let indicatorX: CGFloat
}

enum TerminalTabReorderResolver {
    static func resolve(
        sessionID: UUID,
        location: CGPoint,
        tabFrames: [UUID: CGRect]
    ) -> TerminalTabReorderResolution? {
        let orderedFrames = tabFrames
            .filter { $0.value.width > 0 && $0.value.height > 0 }
            .sorted {
                if $0.value.minX == $1.value.minX {
                    return $0.key.uuidString < $1.key.uuidString
                }
                return $0.value.minX < $1.value.minX
            }
        guard let sourceIndex = orderedFrames.firstIndex(where: {
                  $0.key == sessionID
              })
        else {
            return nil
        }

        let targetFrames = orderedFrames.filter { $0.key != sessionID }
        guard !targetFrames.isEmpty else {
            return nil
        }
        let insertionIndex = targetFrames.firstIndex {
            location.x < $0.value.midX
        } ?? targetFrames.count
        guard insertionIndex != sourceIndex else {
            return nil
        }

        let indicatorX = insertionIndex < targetFrames.count
            ? targetFrames[insertionIndex].value.minX
            : targetFrames[targetFrames.count - 1].value.maxX
        let rawDestinationIndex = insertionIndex > sourceIndex
            ? insertionIndex + 1
            : insertionIndex
        return TerminalTabReorderResolution(
            rawDestinationIndex: rawDestinationIndex,
            indicatorX: indicatorX
        )
    }
}

private struct SessionPane: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.workspacePaneDragHandlers)
    private var workspacePaneDragHandlers
    @Environment(\.workspaceTerminalTabDragHandlers)
    private var workspaceTerminalTabDragHandlers
    @Environment(\.workspacePaneFramePublishingEnabled)
    private var workspacePaneFramePublishingEnabled
    @ObservedObject var runtime: TerminalSessionRuntime
    let workspaceID: UUID
    var showsTabAddButton = true
    var tabContext: TerminalTabContext?

    @State private var showingSearch = false
    @State private var showingConnectionLog = false
    @State private var dismissedConnectionLogOverlay = false
    @State private var searchTerm = ""
    @State private var searchSummary = ""
    @State private var draggingTerminalTabID: UUID?
    @State private var terminalTabDragSourceFrame: CGRect?
    @State private var terminalTabFrames: [UUID: CGRect] = [:]
    @State private var terminalTabStripFrame = CGRect.zero
    @State private var terminalTabDropIndicatorX: CGFloat?
    @State private var hoveredTerminalTabCloseID: UUID?
    @State private var isDraggingPaneToTabBar = false
    @State private var isHoveringPaneIdentity = false

        @State private var isBelling = false
    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            Divider()
            terminalArea
                
                .overlay {
                    if isBelling {
                        Rectangle()
                            .stroke(Color.primary.opacity(0.8), lineWidth: 4)
                            .allowsHitTesting(false)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .terminalVisualBell)) { notification in
                    guard let id = notification.object as? UUID, id == runtime.descriptor.id else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        isBelling = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isBelling = false
                        }
                    }
                }
                .background {
                    GeometryReader { proxy in
                        let frame = proxy.frame(
                            in: .named(WorkspaceDragLayout.coordinateSpace)
                        )
                        Color.clear
                            .preference(
                                key: WorkspacePaneFramePreferenceKey.self,
                                value: workspacePaneFramePublishingEnabled
                                    ? [
                                        runtime.descriptor.id: frame,
                                    ]
                                    : [:]
                            )
                    }
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .stroke(
                    isFocused ? Color.accentColor : Color.clear,
                    lineWidth: 2
                )
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                state.focus(
                    sessionID: runtime.descriptor.id,
                    workspaceID: workspaceID
                )
            }
        )
        .onChange(of: runtime.lifecycle) { _, lifecycle in
            if case .connecting = lifecycle {
                dismissedConnectionLogOverlay = false
            }
        }
    }

    private var terminalArea: some View {
        ZStack {
            Color(
                red: 0.055,
                green: 0.067,
                blue: 0.09
            )
            if runtime.launchRequested {
                TerminalSurface(
                    runtime: runtime,
                    contextMenuTitles: TerminalContextMenuTitles(
                        copy: AppLocalization.string("Copy"),
                        paste: AppLocalization.string("Paste"),
                        pasteSelectedText: AppLocalization.string(
                            "Paste Selected Text"
                        )
                    )
                )
                    .id(runtime.surfaceIdentity)
                if shouldShowConnectionLogOverlay && !dismissedConnectionLogOverlay {
                    connectionLogOverlay
                }
                if let request = runtime.passwordPromptRequest {
                    PasswordPromptAssistOverlay(
                        request: request,
                        runtime: runtime
                    )
                    .padding(.leading, 16)
                    .padding(.bottom, 44)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottomLeading
                    )
                }
            } else {
                disconnectedState
            }
        }
    }

    private var paneHeader: some View {
        HStack(spacing: 8) {
            if canDetachPane {
                paneDetachHandle
            }
            if let tabContext {
                terminalTabStrip(tabContext)
                    .frame(
                        minWidth: 0,
                        maxWidth: .infinity,
                        alignment: .leading
                    )
            } else {
                paneIdentity
                Spacer()
            }
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let latency = displayedLatency {
                latencyIndicator(latency)
            }
            if !runtime.connectionLog.isEmpty {
                Button {
                    showingConnectionLog.toggle()
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .help("Connection Log")
            }
            if sessionHost != nil {
                Button {
                    state.toggleSFTPSidePanel(
                        in: workspaceID,
                        for: runtime.descriptor.id
                    )
                } label: {
                    Image(systemName: "folder")
                }
                .help("Toggle SFTP Side Panel")
                Button {
                    state.openTerminalSidePanel(
                        in: workspaceID,
                        for: runtime.descriptor.id,
                        tab: .system
                    )
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Open Server Tools")
            }
            Button {
                showingSearch.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .popover(isPresented: $showingSearch, arrowEdge: .top) {
                searchPopover
            }
            .help("Search Terminal")
            if showsTabAddButton {
                Button {
                    Task {
                        state.focus(
                            sessionID: runtime.descriptor.id,
                            workspaceID: workspaceID
                        )
                        await state.openTerminalTab(
                            from: runtime.descriptor.id,
                            in: workspaceID
                        )
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .help("New Terminal Tab")
            }
            Button {
                Task {
                    state.focus(
                        sessionID: runtime.descriptor.id,
                        workspaceID: workspaceID
                    )
                    await state.openSiblingTerminal(
                        from: runtime.descriptor.id,
                        splitAxis: .vertical
                    )
                }
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .help("Split Vertically")
            Button {
                Task {
                    state.focus(
                        sessionID: runtime.descriptor.id,
                        workspaceID: workspaceID
                    )
                    await state.openSiblingTerminal(
                        from: runtime.descriptor.id,
                        splitAxis: .horizontal
                    )
                }
            } label: {
                Image(systemName: "rectangle.split.1x2")
            }
            .help("Split Horizontally")
            Menu {
                Button("Copy") {
                    runtime.copySelection()
                }
                Button("Paste") {
                    runtime.paste()
                }
                Divider()
                Button("Increase Font") {
                    runtime.changeFontSize(by: 1)
                }
                Button("Decrease Font") {
                    runtime.changeFontSize(by: -1)
                }
                Divider()
                Button("Reconnect") {
                    state.reconnect(sessionID: runtime.descriptor.id)
                }
                if state.workspaces.first(where: { $0.id == workspaceID })?
                    .root.sessionIDs.count ?? 0 > 1
                {
                    Button("Move to New Tab") {
                        state.detachSession(
                            sessionID: runtime.descriptor.id,
                            from: workspaceID
                        )
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
            Button {
                Task {
                    await state.close(
                        sessionID: runtime.descriptor.id,
                        in: workspaceID
                    )
                }
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close Session")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(.bar)
        .popover(isPresented: $showingConnectionLog, arrowEdge: .bottom) {
            connectionLogPopover
        }
    }

    private func latencyIndicator(_ milliseconds: Int) -> some View {
        let quality = TerminalLatencyQuality.classify(
            milliseconds: milliseconds
        )
        let color: Color = switch quality {
        case .good:
            .green
        case .elevated:
            .orange
        case .poor:
            .red
        }
        let label = String(
            format: AppLocalization.string("Latency: %@ ms"),
            String(milliseconds)
        )
        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(milliseconds) ms")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .fixedSize()
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var displayedLatency: Int? {
        guard runtime.descriptor.kind == .ssh,
              case .connected = runtime.lifecycle
        else {
            return nil
        }
        return runtime.latencyMilliseconds
    }

    private var canDetachPane: Bool {
        state.workspaces.first(where: { $0.id == workspaceID })?
            .root.paneCount ?? 0 > 1
    }

    @ViewBuilder
    private var paneIdentity: some View {
        if canDetachPane {
            paneIdentityContent
                .onHover { isHoveringPaneIdentity = $0 }
                .highPriorityGesture(paneDetachGesture)
                .help("Move to New Tab")
                .accessibilityHint("Move to New Tab")
        } else {
            paneIdentityContent
        }
    }

    private var paneDetachHandle: some View {
        Image(systemName: "arrow.up.right.square")
            .font(.caption.weight(.semibold))
            .foregroundStyle(
                isDraggingPaneToTabBar ? Color.accentColor : .secondary
            )
            .frame(width: 24, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        isDraggingPaneToTabBar
                            ? Color.accentColor.opacity(0.2)
                            : Color.clear
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .scaleEffect(isDraggingPaneToTabBar ? 1.08 : 1)
            .highPriorityGesture(paneDetachGesture)
            .help("Move to New Tab")
            .accessibilityLabel("Move to New Tab")
            .animation(
                .easeInOut(duration: 0.14),
                value: isDraggingPaneToTabBar
            )
    }

    private var paneIdentityContent: some View {
        HStack(spacing: 6) {
            sessionIcon(for: runtime, size: 20)
            Text(runtime.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if let currentDirectory = runtime.currentDirectory {
                Text(currentDirectory)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    isDraggingPaneToTabBar
                        ? Color.accentColor.opacity(0.2)
                        : isHoveringPaneIdentity && canDetachPane
                            ? Color.primary.opacity(0.07)
                            : Color.clear
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .scaleEffect(isDraggingPaneToTabBar ? 1.03 : 1)
        .animation(
            .easeInOut(duration: 0.14),
            value: isDraggingPaneToTabBar
        )
        .animation(
            .easeInOut(duration: 0.1),
            value: isHoveringPaneIdentity
        )
    }

    private var paneDetachGesture: some Gesture {
        DragGesture(
            minimumDistance: 2,
            coordinateSpace: .named(
                WorkspaceDragLayout.coordinateSpace
            )
        )
        .onChanged { value in
            isDraggingPaneToTabBar = true
            workspacePaneDragHandlers.onChanged(
                runtime.descriptor.id,
                workspaceID,
                value.location
            )
        }
        .onEnded { value in
            workspacePaneDragHandlers.onEnded(
                runtime.descriptor.id,
                workspaceID,
                value.location
            )
            isDraggingPaneToTabBar = false
            isHoveringPaneIdentity = false
        }
    }

    private var sessionHost: TermPilotDomain.Host? {
        state.sessionHost(for: runtime.descriptor)
    }

    private func terminalTabStrip(_ context: TerminalTabContext) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(context.sessionIDs, id: \.self) { sessionID in
                    if let runtime = state.runtimes[sessionID] {
                        terminalTab(
                            runtime: runtime,
                            isActive: sessionID == context.activeSessionID
                        )
                    }
                }
            }
            .padding(.vertical, 3)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TerminalTabStripFramePreferenceKey.self,
                    value: proxy.frame(
                        in: .named(WorkspaceDragLayout.coordinateSpace)
                    )
                )
            }
        }
        .overlay(alignment: .leading) {
            if let terminalTabDropIndicatorX {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 22)
                    .offset(x: terminalTabDropIndicatorX - 1.5)
                    .transition(.opacity)
            }
        }
        .onPreferenceChange(TerminalTabFramePreferenceKey.self) { frames in
            terminalTabFrames = frames
        }
        .onPreferenceChange(
            TerminalTabStripFramePreferenceKey.self
        ) { frame in
            if frame.width > 0,
               frame.height > 0
            {
                terminalTabStripFrame = frame
            }
        }
        .onChange(of: draggingTerminalTabID) { _, nextID in
            if nextID == nil {
                terminalTabDropIndicatorX = nil
            }
        }
        .animation(.easeInOut(duration: 0.14), value: terminalTabDropIndicatorX)
        .animation(.easeInOut(duration: 0.16), value: context.sessionIDs)
    }

    private func terminalTab(
        runtime: TerminalSessionRuntime,
        isActive: Bool
    ) -> some View {
        let isDragging = draggingTerminalTabID == runtime.descriptor.id
        return terminalTabContent(
            runtime: runtime,
            isActive: isActive,
            isDragging: isDragging
        )
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TerminalTabFramePreferenceKey.self,
                    value: [
                        runtime.descriptor.id: proxy.frame(
                            in: .named(WorkspaceDragLayout.coordinateSpace)
                        ),
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
        .animation(.easeInOut(duration: 0.14), value: isDragging)
        .pointingHandCursor()
        .simultaneousGesture(
            DragGesture(
                minimumDistance: 4,
                coordinateSpace: .named(
                    WorkspaceDragLayout.coordinateSpace
                )
            )
            .onChanged { value in
                NSCursor.pointingHand.set()
                if draggingTerminalTabID == nil {
                    draggingTerminalTabID = runtime.descriptor.id
                    terminalTabDragSourceFrame =
                        terminalTabFrames[runtime.descriptor.id]
                }
                let dragLocation = TerminalTabDragLocationResolver.resolve(
                    startLocation: value.startLocation,
                    location: value.location,
                    translation: value.translation,
                    sourceFrame: terminalTabDragSourceFrame
                )
                let splitLocation = terminalTabSplitLocation(
                    at: dragLocation
                )
                if splitLocation == nil {
                    moveDraggedTerminalTab(
                        runtime.descriptor.id,
                        at: dragLocation
                    )
                } else {
                    terminalTabDropIndicatorX = nil
                }
                workspaceTerminalTabDragHandlers.onChanged(
                    runtime.descriptor.id,
                    workspaceID,
                    splitLocation
                )
            }
            .onEnded { value in
                let dragLocation = TerminalTabDragLocationResolver.resolve(
                    startLocation: value.startLocation,
                    location: value.location,
                    translation: value.translation,
                    sourceFrame: terminalTabDragSourceFrame
                )
                workspaceTerminalTabDragHandlers.onEnded(
                    runtime.descriptor.id,
                    workspaceID,
                    terminalTabSplitLocation(at: dragLocation)
                )
                draggingTerminalTabID = nil
                terminalTabDragSourceFrame = nil
                NSCursor.arrow.set()
            }
        )
    }

    private func terminalTabContent(
        runtime: TerminalSessionRuntime,
        isActive: Bool,
        isDragging: Bool
    ) -> some View {
        HStack(spacing: 5) {
            Button {
                state.selectTerminalTab(
                    sessionID: runtime.descriptor.id,
                    workspaceID: workspaceID
                )
            } label: {
                HStack(spacing: 5) {
                    sessionIcon(for: runtime, size: 18)
                    Text(runtime.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 120, alignment: .leading)
                }
                .padding(.leading, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task {
                    await state.close(
                        sessionID: runtime.descriptor.id,
                        in: workspaceID
                    )
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        hoveredTerminalTabCloseID == runtime.descriptor.id
                            ? Color.white
                            : Color.secondary
                    )
                    .frame(width: 19, height: 19)
                    .background(
                        RoundedRectangle(
                            cornerRadius: 4,
                            style: .continuous
                        )
                        .fill(
                            hoveredTerminalTabCloseID
                                == runtime.descriptor.id
                                ? Color(
                                    red: 248 / 255,
                                    green: 81 / 255,
                                    blue: 73 / 255
                                )
                                : Color.clear
                        )
                    )
                    .contentShape(
                        RoundedRectangle(
                            cornerRadius: 4,
                            style: .continuous
                        )
                    )
                    .animation(
                        .easeOut(duration: 0.1),
                        value: hoveredTerminalTabCloseID
                            == runtime.descriptor.id
                    )
            }
            .buttonStyle(.plain)
            .help("Close Terminal Tab")
            .onHover { hovering in
                if hovering {
                    hoveredTerminalTabCloseID = runtime.descriptor.id
                } else if hoveredTerminalTabCloseID
                    == runtime.descriptor.id
                {
                    hoveredTerminalTabCloseID = nil
                }
            }
        }
        .frame(
            width: TerminalTabLayoutMetrics.fixedWidth,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    isDragging
                        ? Color.accentColor.opacity(0.26)
                        : isActive
                            ? Color.accentColor.opacity(0.18)
                            : Color.secondary.opacity(0.08)
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isDragging
                        ? Color.accentColor.opacity(0.85)
                        : isActive
                            ? Color.accentColor.opacity(0.45)
                            : Color.secondary.opacity(0.14),
                    lineWidth: 1
                )
        }
    }

    @ViewBuilder
    private func sessionIcon(
        for runtime: TerminalSessionRuntime,
        size: CGFloat
    ) -> some View {
        if let host = state.sessionHost(for: runtime.descriptor) {
            HostIconView(host: host, size: size)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(tabStatusColor(for: runtime.lifecycle))
                        .frame(width: 6, height: 6)
                        .overlay {
                            Circle()
                                .stroke(
                                    Color(nsColor: .windowBackgroundColor),
                                    lineWidth: 1
                                )
                        }
                }
        } else {
            Circle()
                .fill(tabStatusColor(for: runtime.lifecycle))
                .frame(width: 7, height: 7)
        }
    }

    private func terminalTabSplitLocation(
        at location: CGPoint
    ) -> CGPoint? {
        TerminalTabSplitDragResolver.splitLocation(
            at: location,
            tabFrames: Array(terminalTabFrames.values)
        )
    }

    private func moveDraggedTerminalTab(
        _ sessionID: UUID,
        at location: CGPoint
    ) {
        guard draggingTerminalTabID == sessionID else {
            return
        }
        guard let resolution = TerminalTabReorderResolver.resolve(
            sessionID: sessionID,
            location: location,
            tabFrames: terminalTabFrames
        ) else {
            terminalTabDropIndicatorX = nil
            return
        }
        terminalTabDropIndicatorX = TerminalTabDropIndicatorResolver.localX(
            rootX: resolution.indicatorX,
            tabStripFrame: terminalTabStripFrame
        )
        withAnimation(.easeInOut(duration: 0.16)) {
            state.moveTerminalTab(
                sessionID: sessionID,
                workspaceID: workspaceID,
                toIndex: resolution.rawDestinationIndex
            )
        }
    }

    private func tabStatusColor(for lifecycle: SessionLifecycle) -> Color {
        switch lifecycle {
        case .connected:
            .green
        case .connecting:
            .orange
        case .failed:
            .red
        case .exited, .disconnected:
            .secondary
        }
    }

    private var disconnectedState: some View {
        ContentUnavailableView {
            Label("Session Disconnected", systemImage: "bolt.slash")
        } description: {
            Text("The saved layout does not restore terminal process state.")
        } actions: {
            Button("Reconnect") {
                state.reconnect(sessionID: runtime.descriptor.id)
            }
        }
        .foregroundStyle(.white)
    }

    private var connectionLogPopover: some View {
        connectionLogPanel {
            showingConnectionLog = false
        }
        .frame(width: 380, height: 280)
        .padding(6)
    }

    private var connectionLogOverlay: some View {
        connectionLogPanel {
            dismissedConnectionLogOverlay = true
        }
        .frame(maxWidth: 380)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func connectionLogPanel(onClose: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            connectionLogPanelHeader(onClose: onClose)
            connectionStageProgress
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 10)
            if let prompt = runtime.hostKeyPrompt {
                hostKeyPromptCard(prompt)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Divider()
                .overlay(connectionPanelDivider)
            connectionLogConsole
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
                .overlay(connectionPanelDivider)
            connectionLogPanelFooter
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
        }
        .background(connectionPanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(connectionPanelBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.26), radius: 18, x: 0, y: 10)
    }

    private func connectionLogPanelHeader(onClose: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(connectionPanelIconBackground)
                    .frame(width: 30, height: 30)
                if case .connecting = runtime.lifecycle {
                    ProgressView()
                        .scaleEffect(0.65)
                        .tint(connectionBlue)
                } else {
                    Image(systemName: connectionPanelIconName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(connectionPanelIconColor)
                }
            }
            Text(connectionPanelTitle)
                .font(.headline.weight(.bold))
                .foregroundStyle(connectionPanelTitleColor)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(connectionMutedBlue)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(connectionPanelCloseBackground)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(connectionPanelBorder, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var connectionStageProgress: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(connectionStageTitles.indices, id: \.self) { index in
                connectionStageItem(
                    title: connectionStageTitles[index],
                    index: index
                )
                if index < connectionStageTitles.count - 1 {
                    Capsule()
                        .fill(connectionStageConnectorColor(after: index))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
        }
    }

    private func connectionStageItem(
        title: LocalizedStringKey,
        index: Int
    ) -> some View {
        let status = connectionStageStatus(for: index)
        return VStack(spacing: 5) {
            ZStack {
                if status == .active {
                    PulsingCircle(color: connectionStageCircleColor(status))
                } else {
                    Circle()
                        .fill(connectionStageCircleColor(status))
                        .frame(width: 24, height: 24)
                }
                switch status {
                case .completed:
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                case .active:
                    ProgressView()
                        .scaleEffect(0.55)
                        .tint(.white)
                case .failed:
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                case .pending:
                    Text("\(index + 1)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(connectionPendingText)
                }
            }
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(connectionStageTextColor(status))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(width: 64)
    }

    private var connectionLogConsole: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(">_")
                    .font(.caption.monospaced())
                    .foregroundStyle(connectionLogHeaderMuted)
                Text("Connection Log")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(connectionLogHeaderMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
                .overlay(connectionPanelDivider)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if connectionLogEntries.isEmpty {
                        Text("No connection logs yet.")
                            .font(.caption2.monospaced())
                            .foregroundStyle(connectionLogHeaderMuted)
                    } else {
                        ForEach(connectionLogEntries) { entry in
                            Text(entry.message)
                                .font(.caption2.monospaced())
                                .foregroundStyle(connectionLogColor(entry.message))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 118)
        .background(connectionConsoleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.35), lineWidth: 1)
        }
    }

    private func hostKeyPromptCard(_ prompt: SSHHostKeyPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(connectionBlue)
                Text("SSH Fingerprint Confirmation")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(connectionPanelTitleColor)
                Spacer()
            }
            Text(
                prompt.hasExistingHostPattern
                    ? "The stored SSH fingerprint for this host is different. Only accept it if you trust this change."
                    : "This is the first time connecting to this host. Confirm the SSH fingerprint before continuing."
            )
            .font(.caption2)
            .foregroundStyle(connectionLogText)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                hostKeyPromptRow(title: "Host", value: prompt.hostPattern)
                hostKeyPromptRow(title: "Algorithm", value: prompt.algorithm)
                hostKeyPromptRow(title: "Fingerprint", value: prompt.fingerprint)
            }
        }
        .padding(10)
        .background(connectionConsoleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(connectionPanelBorder, lineWidth: 1)
        }
    }

    private func hostKeyPromptRow(
        title: LocalizedStringKey,
        value: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(connectionLogHeaderMuted)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(connectionPanelTitleColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connectionLogPanelFooter: some View {
        HStack(spacing: 8) {
            Spacer()
            if runtime.hostKeyPrompt != nil {
                Button("Reject") {
                    runtime.respondToHostKeyPrompt(accepted: false)
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(connectionPanelTitleColor)
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(connectionPanelCloseBackground)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(connectionPanelBorder, lineWidth: 1)
                }
                Button("Accept Fingerprint") {
                    runtime.respondToHostKeyPrompt(accepted: true)
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(connectionBlue)
                )
            } else {
                if shouldShowCopyLogsButton {
                    Button("Copy Logs") {
                        copyConnectionLogs()
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(connectionPanelTitleColor)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(connectionPanelCloseBackground)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(connectionPanelBorder, lineWidth: 1)
                    }
                }
                Button(connectionLogPrimaryActionTitle) {
                    performConnectionLogPrimaryAction()
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(connectionLogPrimaryActionColor)
                )
            }
        }
    }

    private var connectionStageTitles: [LocalizedStringKey] {
        [
            "Establish Connection",
            "Authentication",
            "Open Channel",
            "Ready",
        ]
    }

    private var connectionLogEntries: [ConnectionLogEntry] {
        Array(runtime.connectionLog.suffix(120))
    }

    private var shouldShowCopyLogsButton: Bool {
        guard !runtime.connectionLog.isEmpty else {
            return false
        }
        switch runtime.lifecycle {
        case .failed:
            return true
        case let .exited(code):
            return code != 0 || hasConnectionErrorLog
        case .connecting, .connected, .disconnected:
            return false
        }
    }

    private var hasConnectionErrorLog: Bool {
        runtime.connectionLog.contains { entry in
            let message = entry.message.lowercased()
            return message.contains("error")
                || message.contains("failed")
                || message.contains("denied")
                || message.contains("timeout")
                || message.contains("closed before shell")
        }
    }

    private var shouldUseErrorPrimaryActionStyle: Bool {
        switch runtime.lifecycle {
        case .connecting, .failed:
            return true
        case .exited:
            return shouldShowCopyLogsButton
        case .connected, .disconnected:
            return false
        }
    }

    private var connectionLogPrimaryActionColor: Color {
        if shouldUseErrorPrimaryActionStyle {
            return connectionPink
        }
        switch runtime.lifecycle {
        case .connected:
            return connectionGreen
        case .exited, .disconnected:
            return connectionBlue
        case .connecting, .failed:
            return connectionPink
        }
    }

    private var connectionPanelTitle: LocalizedStringKey {
        if runtime.hostKeyPrompt != nil {
            return "SSH Fingerprint Confirmation"
        }
        switch runtime.lifecycle {
        case .connecting:
            return "SSH Connecting..."
        case .connected:
            return "SSH Connected"
        case .failed:
            return "SSH Connection Failed"
        case .exited where shouldShowCopyLogsButton:
            return "SSH Connection Failed"
        case .exited:
            return "SSH Connection Closed"
        case .disconnected:
            return "SSH Disconnected"
        }
    }

    private var connectionPanelIconName: String {
        switch runtime.lifecycle {
        case .connected:
            "checkmark"
        case .failed:
            "xmark"
        case .exited where shouldShowCopyLogsButton:
            "xmark"
        case .exited, .disconnected:
            "bolt.slash"
        case .connecting:
            "circle"
        }
    }

    private var connectionPanelIconColor: Color {
        switch runtime.lifecycle {
        case .connected:
            connectionGreen
        case .failed:
            connectionRed
        case .exited where shouldShowCopyLogsButton:
            connectionRed
        case .exited, .disconnected:
            connectionLogHeaderMuted
        case .connecting:
            connectionBlue
        }
    }

    private var connectionLogPrimaryActionTitle: LocalizedStringKey {
        switch runtime.lifecycle {
        case .connecting:
            "Cancel Connection"
        case .failed, .exited, .disconnected:
            "Reconnect"
        case .connected:
            "Close"
        }
    }

    private var connectionCurrentStageIndex: Int {
        if runtime.hostKeyPrompt != nil {
            return 1
        }
        switch runtime.lifecycle {
        case .connected:
            return 3
        case .connecting, .failed, .exited:
            return connectionStageIndexFromLogs
        case .disconnected:
            return 0
        }
    }

    private var connectionStageIndexFromLogs: Int {
        var stage = 0
        for entry in runtime.connectionLog {
            let message = entry.message.lowercased()
            if message.contains("ssh2 connected")
                || message.contains("interactive shell channel established")
            {
                stage = max(stage, 3)
            } else if message.contains("ssh2 shell")
                || message.contains("opening interactive shell")
                || message.contains("open shell")
            {
                stage = max(stage, 2)
            } else if message.contains("ssh2 auth")
                || message.contains("authentication")
                || message.contains("keyboard-interactive")
                || message.contains("identity")
                || message.contains("host-key")
            {
                stage = max(stage, 1)
            }
        }
        return stage
    }

    private func connectionStageStatus(for index: Int) -> ConnectionStageStatus {
        let current = connectionCurrentStageIndex
        switch runtime.lifecycle {
        case .connected:
            return .completed
        case .failed:
            if index < current {
                return .completed
            }
            return index == current ? .failed : .pending
        case .exited:
            return index <= current ? .completed : .pending
        case .connecting:
            if index < current {
                return .completed
            }
            return index == current ? .active : .pending
        case .disconnected:
            return index == 0 ? .active : .pending
        }
    }

    private func connectionStageCircleColor(_ status: ConnectionStageStatus) -> Color {
        switch status {
        case .completed:
            connectionGreen
        case .active:
            connectionBlue
        case .failed:
            connectionRed
        case .pending:
            connectionPendingCircle
        }
    }

    private func connectionStageTextColor(_ status: ConnectionStageStatus) -> Color {
        switch status {
        case .completed:
            connectionGreen
        case .active:
            connectionBlue
        case .failed:
            connectionRed
        case .pending:
            connectionLogHeaderMuted
        }
    }

    private func connectionStageConnectorColor(after index: Int) -> Color {
        if index < connectionCurrentStageIndex {
            return connectionGreen.opacity(0.72)
        }
        if index == connectionCurrentStageIndex,
           case .connecting = runtime.lifecycle
        {
            return connectionBlue.opacity(0.45)
        }
        return connectionPanelDivider
    }

    private func connectionLogColor(_ message: String) -> Color {
        let lowercased = message.lowercased()
        if lowercased.contains("error")
            || lowercased.contains("failed")
            || lowercased.contains("exit")
        {
            return connectionRed
        }
        if lowercased.contains("connected")
            || lowercased.contains("completed")
            || lowercased.contains("established")
        {
            return connectionGreen
        }
        if lowercased.contains("auth")
            || lowercased.contains("host-key")
            || lowercased.contains("shell")
            || lowercased.contains("tcp")
            || lowercased.contains("debug")
            || lowercased.contains("init")
        {
            return connectionBlue
        }
        return connectionLogText
    }

    private func performConnectionLogPrimaryAction() {
        switch runtime.lifecycle {
        case .connecting:
            runtime.terminate()
            dismissedConnectionLogOverlay = true
        case .failed, .exited, .disconnected:
            dismissedConnectionLogOverlay = false
            state.reconnect(sessionID: runtime.descriptor.id)
        case .connected:
            showingConnectionLog = false
            dismissedConnectionLogOverlay = true
        }
    }

    private func copyConnectionLogs() {
        let lines: [String] = runtime.connectionLog
            .map { entry in
                let timestamp = entry.timestamp.formatted(
                    date: .omitted,
                    time: .standard
                )
                return "[\(timestamp)] \(entry.message)"
            }
        let contents: String = lines.joined(separator: "\n")
        guard !contents.isEmpty else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(contents, forType: .string)
    }

    private var connectionPanelBackground: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 0.075, green: 0.078, blue: 0.09, alpha: 1)
            }
            return NSColor.windowBackgroundColor
        }))
    }

    private var connectionConsoleBackground: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 0.045, green: 0.047, blue: 0.055, alpha: 1)
            }
            return NSColor.controlBackgroundColor
        }))
    }

    private var connectionPanelBorder: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 0.18, green: 0.18, blue: 0.20, alpha: 1)
            }
            return NSColor.separatorColor
        }))
    }

    private var connectionPanelDivider: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 0.18, green: 0.18, blue: 0.20, alpha: 1)
            }
            return NSColor.separatorColor
        }))
    }

    private var connectionPanelIconBackground: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 0.12, green: 0.15, blue: 0.22, alpha: 1)
            }
            return NSColor.controlAccentColor.withAlphaComponent(0.15)
        }))
    }

    private var connectionPanelCloseBackground: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor.white.withAlphaComponent(0.08)
            }
            return NSColor.black.withAlphaComponent(0.05)
        }))
    }

    private var connectionPanelTitleColor: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 0.75, green: 0.78, blue: 0.92, alpha: 1)
            }
            return NSColor.labelColor
        }))
    }

    private var connectionLogHeaderMuted: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 0.45, green: 0.46, blue: 0.50, alpha: 1)
            }
            return NSColor.secondaryLabelColor
        }))
    }

    private var connectionLogText: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 0.72, green: 0.76, blue: 0.84, alpha: 1)
            }
            return NSColor.labelColor
        }))
    }

    private var connectionPendingCircle: Color {
        Color(nsColor: .quaternaryLabelColor)
    }

    private var connectionPendingText: Color {
        Color.secondary
    }

    private var connectionGreen: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 0.56, green: 0.78, blue: 0.38, alpha: 1)
            }
            return NSColor.systemGreen
        }))
    }

    private var connectionBlue: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 0.45, green: 0.62, blue: 0.95, alpha: 1)
            }
            return NSColor.systemBlue
        }))
    }

    private var connectionMutedBlue: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 0.34, green: 0.39, blue: 0.60, alpha: 1)
            }
            return NSColor.systemBlue.withAlphaComponent(0.15)
        }))
    }

    private var connectionPink: Color {
        Color(nsColor: .systemPink)
    }

    private var connectionRed: Color {
        Color(nsColor: .systemRed)
    }

    private var shouldShowConnectionLogOverlay: Bool {
        switch runtime.lifecycle {
        case .connecting, .failed:
            true
        case .exited:
            true
        case .connected, .disconnected:
            false
        }
    }

    private var searchPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Find", text: $searchTerm)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit {
                    findNext()
                }
            HStack {
                Button {
                    let found = runtime.findPrevious(searchTerm)
                    searchSummary = AppLocalization.string(
                        found ? "Match selected" : "No matches"
                    )
                } label: {
                    Image(systemName: "chevron.up")
                }
                Button {
                    findNext()
                } label: {
                    Image(systemName: "chevron.down")
                }
                Text(searchSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    runtime.clearSearch()
                    showingSearch = false
                }
            }
        }
        .padding(12)
    }

    private var isFocused: Bool {
        state.workspaces.first(where: { $0.id == workspaceID })?
            .focusedSessionID == runtime.descriptor.id
    }

    private var statusColor: Color {
        switch runtime.lifecycle {
        case .connected:
            .green
        case .connecting:
            .orange
        case .disconnected:
            .secondary
        case .exited, .failed:
            .red
        }
    }

    private var statusText: String {
        switch runtime.lifecycle {
        case .connected:
            AppLocalization.string("Connected")
        case .connecting:
            AppLocalization.string("Connecting")
        case .disconnected:
            AppLocalization.string("Disconnected")
        case let .exited(code):
            code.map {
                String(
                    format: AppLocalization.string("Exited %@"),
                    String($0)
                )
            } ?? AppLocalization.string("Exited")
        case let .failed(message):
            message
        }
    }

    private func findNext() {
        let found = runtime.findNext(searchTerm)
        searchSummary = AppLocalization.string(
            found ? "Match selected" : "No matches"
        )
    }
}

private enum ConnectionStageStatus {
    case completed
    case active
    case pending
    case failed
}

enum TerminalSidePanelDividerResolver {
    static func resolve(
        totalWidth: CGFloat,
        dividerThickness: CGFloat,
        terminalMinWidth: CGFloat,
        sidebarMinWidth: CGFloat,
        sidebarMaxWidth: CGFloat,
        preferredContentWidth: CGFloat?
    ) -> CGFloat {
        guard totalWidth.isFinite,
              dividerThickness.isFinite,
              terminalMinWidth.isFinite,
              sidebarMinWidth.isFinite,
              sidebarMaxWidth.isFinite
        else {
            return 0
        }
        let availableWidth = max(totalWidth - dividerThickness, 0)
        let minimum = min(
            max(terminalMinWidth, availableWidth - sidebarMaxWidth),
            availableWidth
        )
        let maximum = max(minimum, availableWidth - sidebarMinWidth)
        let preferred = preferredContentWidth.flatMap {
            $0.isFinite ? $0 : nil
        } ?? maximum
        return min(max(preferred, minimum), maximum)
    }
}

private struct TerminalSidePanelSplitView: NSViewRepresentable {
    private static let terminalMinWidth: CGFloat = 360
    private static let sidebarMinWidth: CGFloat = 350
    private static let sidebarMaxWidth: CGFloat = 760

    let contentUpdateID: String
    let sidebarUpdateID: String
    let content: AnyView
    let sidebar: AnyView
    let onContentWidthChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            terminalMinWidth: Self.terminalMinWidth,
            sidebarMinWidth: Self.sidebarMinWidth,
            sidebarMaxWidth: Self.sidebarMaxWidth,
            onContentWidthChange: onContentWidthChange
        )
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator

        let contentVC = NSHostingController(rootView: content)
        let sidebarVC = NSHostingController(rootView: sidebar)

        splitView.addArrangedSubview(contentVC.view)
        splitView.addArrangedSubview(sidebarVC.view)

        context.coordinator.contentView = contentVC.view
        context.coordinator.sidebarView = sidebarVC.view
        context.coordinator.contentUpdateID = contentUpdateID
        context.coordinator.sidebarUpdateID = sidebarUpdateID

        splitView.adjustSubviews()
        return splitView
    }

    func updateNSView(_ nsView: NSSplitView, context: Context) {
        guard nsView.arrangedSubviews.count == 2 else { return }

        let contentVC = context.coordinator.contentView?.nextResponder as? NSHostingController<AnyView>
        let sidebarVC = context.coordinator.sidebarView?.nextResponder as? NSHostingController<AnyView>

        if context.coordinator.contentUpdateID != contentUpdateID {
            contentVC?.rootView = content
            context.coordinator.contentUpdateID = contentUpdateID
        }

        if context.coordinator.sidebarUpdateID != sidebarUpdateID {
            sidebarVC?.rootView = sidebar
            context.coordinator.sidebarUpdateID = sidebarUpdateID
        }

        context.coordinator.applyInitialSidebarWidthIfNeeded(to: nsView)
    }

    @MainActor
    class Coordinator: NSObject, NSSplitViewDelegate {
        let terminalMinWidth: CGFloat
        let sidebarMinWidth: CGFloat
        let sidebarMaxWidth: CGFloat
        let onContentWidthChange: (CGFloat) -> Void

        var contentUpdateID: String?
        var sidebarUpdateID: String?

        weak var contentView: NSView?
        weak var sidebarView: NSView?
        private var didApplyInitialSidebarWidth = false

        init(
            terminalMinWidth: CGFloat,
            sidebarMinWidth: CGFloat,
            sidebarMaxWidth: CGFloat,
            onContentWidthChange: @escaping (CGFloat) -> Void
        ) {
            self.terminalMinWidth = terminalMinWidth
            self.sidebarMinWidth = sidebarMinWidth
            self.sidebarMaxWidth = sidebarMaxWidth
            self.onContentWidthChange = onContentWidthChange
            super.init()
        }

        @MainActor
        func applyInitialSidebarWidthIfNeeded(to splitView: NSSplitView) {
            guard !didApplyInitialSidebarWidth,
                  splitView.bounds.width.isFinite,
                  splitView.bounds.width
                    >= terminalMinWidth
                        + sidebarMinWidth
                        + splitView.dividerThickness
            else {
                return
            }
            splitView.setPosition(
                TerminalSidePanelDividerResolver.resolve(
                    totalWidth: splitView.bounds.width,
                    dividerThickness: splitView.dividerThickness,
                    terminalMinWidth: terminalMinWidth,
                    sidebarMinWidth: sidebarMinWidth,
                    sidebarMaxWidth: sidebarMaxWidth,
                    preferredContentWidth: nil
                ),
                ofDividerAt: 0
            )
            didApplyInitialSidebarWidth = true
            publishContentWidth(contentView?.frame.width ?? 0)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            TerminalSidePanelDividerResolver.resolve(
                totalWidth: splitView.frame.width,
                dividerThickness: splitView.dividerThickness,
                terminalMinWidth: terminalMinWidth,
                sidebarMinWidth: sidebarMinWidth,
                sidebarMaxWidth: sidebarMaxWidth,
                preferredContentWidth: 0
            )
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            TerminalSidePanelDividerResolver.resolve(
                totalWidth: splitView.frame.width,
                dividerThickness: splitView.dividerThickness,
                terminalMinWidth: terminalMinWidth,
                sidebarMinWidth: sidebarMinWidth,
                sidebarMaxWidth: sidebarMaxWidth,
                preferredContentWidth: nil
            )
        }

        func splitView(
            _ splitView: NSSplitView,
            resizeSubviewsWithOldSize oldSize: CGSize
        ) {
            guard let contentView, let sidebarView else {
                splitView.adjustSubviews()
                return
            }
            guard splitView.frame.width.isFinite,
                  splitView.frame.height.isFinite,
                  splitView.dividerThickness.isFinite
            else {
                return
            }
            let appliesInitialLayout =
                !didApplyInitialSidebarWidth
                && splitView.frame.width
                    >= terminalMinWidth
                        + sidebarMinWidth
                        + splitView.dividerThickness
            let preferredContentWidth: CGFloat?
            if appliesInitialLayout {
                preferredContentWidth = nil
                didApplyInitialSidebarWidth = true
            } else {
                preferredContentWidth = contentView.frame.width
            }
            var resolvedPreferredWidth = preferredContentWidth
            if !appliesInitialLayout, oldSize.width > 0 {
                let ratio = oldSize.width / splitView.frame.width
                if abs(ratio - 1.0) > 0.001 {
                    resolvedPreferredWidth =
                        splitView.frame.width
                        - sidebarView.frame.width
                        - splitView.dividerThickness
                }
            }
            let divider = TerminalSidePanelDividerResolver.resolve(
                totalWidth: splitView.frame.width,
                dividerThickness: splitView.dividerThickness,
                terminalMinWidth: terminalMinWidth,
                sidebarMinWidth: sidebarMinWidth,
                sidebarMaxWidth: sidebarMaxWidth,
                preferredContentWidth: resolvedPreferredWidth
            )
            let availableWidth = max(
                splitView.frame.width - splitView.dividerThickness,
                0
            )
            let height = max(splitView.frame.height, 0)
            contentView.frame = CGRect(
                x: 0,
                y: 0,
                width: divider,
                height: height
            )
            sidebarView.frame = CGRect(
                x: divider + splitView.dividerThickness,
                y: 0,
                width: max(availableWidth - divider, 0),
                height: height
            )
            publishContentWidth(contentView.frame.width)
        }

        private func publishContentWidth(_ width: CGFloat) {
            guard width.isFinite, width >= 0 else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.onContentWidthChange(width)
            }
        }
    }
}

private struct ResizableSplitView: View {
    let axis: SplitAxis
    let sizes: [Double]
    let first: AnyView
    let second: AnyView
    let onSizesChanged: ([Double]) -> Void

    @State private var ratio: CGFloat
    @State private var dragging = false
    @State private var dragStartRatio: CGFloat

    init(
        axis: SplitAxis,
        sizes: [Double],
        first: AnyView,
        second: AnyView,
        onSizesChanged: @escaping ([Double]) -> Void
    ) {
        self.axis = axis
        self.sizes = sizes
        self.first = first
        self.second = second
        self.onSizesChanged = onSizesChanged
        let initialRatio = Self.normalizedRatio(sizes)
        _ratio = State(initialValue: initialRatio)
        _dragStartRatio = State(initialValue: initialRatio)
    }

    var body: some View {
        GeometryReader { proxy in
            if axis == .vertical {
                HStack(spacing: 0) {
                    first
                        .frame(
                            width: availableLength(proxy.size) * ratio,
                            height: proxy.size.height
                        )
                    divider(totalLength: availableLength(proxy.size))
                    second
                        .frame(
                            width: availableLength(proxy.size) * (1 - ratio),
                            height: proxy.size.height
                        )
                }
            } else {
                VStack(spacing: 0) {
                    first
                        .frame(
                            width: proxy.size.width,
                            height: availableLength(proxy.size) * ratio
                        )
                    divider(totalLength: availableLength(proxy.size))
                    second
                        .frame(
                            width: proxy.size.width,
                            height: availableLength(proxy.size) * (1 - ratio)
                        )
                }
            }
        }
        .onChange(of: sizes) { _, nextSizes in
            if !dragging {
                ratio = Self.normalizedRatio(nextSizes)
            }
        }
    }

    private func divider(totalLength: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(
                width: axis == .vertical ? 6 : nil,
                height: axis == .horizontal ? 6 : nil
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            dragStartRatio = ratio
                        }
                        let translation = axis == .vertical
                            ? value.translation.width
                            : value.translation.height
                        ratio = min(
                            max(
                                dragStartRatio + translation / max(totalLength, 1),
                                0.15
                            ),
                            0.85
                        )
                        onSizesChanged([Double(ratio), Double(1 - ratio)])
                    }
                    .onEnded { _ in
                        dragging = false
                        onSizesChanged([Double(ratio), Double(1 - ratio)])
                    }
            )
            .help("Drag to resize panes")
    }

    private func availableLength(_ size: CGSize) -> CGFloat {
        max((axis == .vertical ? size.width : size.height) - 6, 0)
    }

    private static func normalizedRatio(_ sizes: [Double]) -> CGFloat {
        guard sizes.count == 2,
              sizes.allSatisfy({ $0.isFinite && $0 > 0 })
        else {
            return 0.5
        }
        return CGFloat(sizes[0] / (sizes[0] + sizes[1]))
    }
}
