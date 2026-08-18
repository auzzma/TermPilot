import Foundation

public enum SplitAxis: String, Codable, Sendable {
    /// Panes are stacked from top to bottom.
    case horizontal
    /// Panes are arranged from left to right.
    case vertical
}

public enum SplitPlacement: Sendable {
    case before
    case after
}

public indirect enum WorkspaceNode: Codable, Equatable, Identifiable, Sendable {
    case pane(id: UUID, sessionID: UUID)
    case tabGroup(id: UUID, sessionIDs: [UUID], activeSessionID: UUID)
    case split(id: UUID, axis: SplitAxis, children: [WorkspaceNode], sizes: [Double])

    public var id: UUID {
        switch self {
        case let .pane(id, _),
             let .tabGroup(id, _, _),
             let .split(id, _, _, _):
            id
        }
    }

    public var sessionIDs: [UUID] {
        switch self {
        case let .pane(_, sessionID):
            [sessionID]
        case let .tabGroup(_, sessionIDs, _):
            sessionIDs
        case let .split(_, _, children, _):
            children.flatMap(\.sessionIDs)
        }
    }

    public var paneCount: Int {
        switch self {
        case .pane, .tabGroup:
            1
        case let .split(_, _, children, _):
            children.reduce(0) { $0 + $1.paneCount }
        }
    }

    public func inserting(
        sessionID: UUID,
        nextTo targetSessionID: UUID?,
        axis: SplitAxis,
        placement: SplitPlacement = .after
    ) -> WorkspaceNode {
        guard !sessionIDs.contains(sessionID) else {
            return self
        }

        let newPane = WorkspaceNode.pane(id: UUID(), sessionID: sessionID)
        guard let targetSessionID else {
            return .split(
                id: UUID(),
                axis: axis,
                children: placement == .before ? [newPane, self] : [self, newPane],
                sizes: [0.5, 0.5]
            )
        }

        switch self {
        case let .pane(_, existingSessionID) where existingSessionID == targetSessionID:
            return .split(
                id: UUID(),
                axis: axis,
                children: placement == .before ? [newPane, self] : [self, newPane],
                sizes: [0.5, 0.5]
            )
        case .pane:
            return self
        case let .tabGroup(_, tabSessionIDs, _) where tabSessionIDs.contains(targetSessionID):
            return .split(
                id: UUID(),
                axis: axis,
                children: placement == .before ? [newPane, self] : [self, newPane],
                sizes: [0.5, 0.5]
            )
        case .tabGroup:
            return self
        case let .split(id, currentAxis, children, sizes):
            return .split(
                id: id,
                axis: currentAxis,
                children: children.map {
                    $0.inserting(
                        sessionID: sessionID,
                        nextTo: targetSessionID,
                        axis: axis,
                        placement: placement
                    )
                },
                sizes: normalizedSizes(sizes, count: children.count)
            )
        }
    }

    public func insertingPane(
        _ pane: WorkspaceNode,
        nextTo targetSessionID: UUID,
        axis: SplitAxis,
        placement: SplitPlacement = .after
    ) -> WorkspaceNode {
        guard pane.paneCount == 1,
              Set(sessionIDs).isDisjoint(with: pane.sessionIDs)
        else {
            return self
        }

        switch self {
        case let .pane(_, existingSessionID)
            where existingSessionID == targetSessionID:
            return .split(
                id: UUID(),
                axis: axis,
                children: placement == .before ? [pane, self] : [self, pane],
                sizes: [0.5, 0.5]
            )
        case .pane:
            return self
        case let .tabGroup(_, tabSessionIDs, _)
            where tabSessionIDs.contains(targetSessionID):
            return .split(
                id: UUID(),
                axis: axis,
                children: placement == .before ? [pane, self] : [self, pane],
                sizes: [0.5, 0.5]
            )
        case .tabGroup:
            return self
        case let .split(id, currentAxis, children, sizes):
            return .split(
                id: id,
                axis: currentAxis,
                children: children.map {
                    $0.insertingPane(
                        pane,
                        nextTo: targetSessionID,
                        axis: axis,
                        placement: placement
                    )
                },
                sizes: normalizedSizes(sizes, count: children.count)
            )
        }
    }

    public func addingTab(
        sessionID: UUID,
        nextTo targetSessionID: UUID?
    ) -> WorkspaceNode {
        guard !sessionIDs.contains(sessionID) else {
            return self
        }

        switch self {
        case let .pane(id, existingSessionID)
            where targetSessionID == nil || existingSessionID == targetSessionID:
            return .tabGroup(
                id: id,
                sessionIDs: [existingSessionID, sessionID],
                activeSessionID: sessionID
            )
        case .pane:
            return self
        case let .tabGroup(id, tabSessionIDs, _)
            where targetSessionID.map(tabSessionIDs.contains) ?? true:
            return .tabGroup(
                id: id,
                sessionIDs: tabSessionIDs + [sessionID],
                activeSessionID: sessionID
            )
        case .tabGroup:
            return self
        case let .split(id, axis, children, sizes):
            return .split(
                id: id,
                axis: axis,
                children: children.map {
                    $0.addingTab(
                        sessionID: sessionID,
                        nextTo: targetSessionID
                    )
                },
                sizes: normalizedSizes(sizes, count: children.count)
            )
        }
    }

    public func selectingTab(sessionID: UUID) -> WorkspaceNode {
        switch self {
        case .pane:
            return self
        case let .tabGroup(id, sessionIDs, _):
            guard sessionIDs.contains(sessionID) else {
                return self
            }
            return .tabGroup(
                id: id,
                sessionIDs: sessionIDs,
                activeSessionID: sessionID
            )
        case let .split(id, axis, children, sizes):
            return .split(
                id: id,
                axis: axis,
                children: children.map {
                    $0.selectingTab(sessionID: sessionID)
                },
                sizes: normalizedSizes(sizes, count: children.count)
            )
        }
    }

    public func movingTab(
        sessionID: UUID,
        toIndex rawDestination: Int
    ) -> WorkspaceNode {
        switch self {
        case .pane:
            return self
        case let .tabGroup(id, sessionIDs, activeSessionID):
            guard let source = sessionIDs.firstIndex(of: sessionID) else {
                return self
            }
            var destination = min(max(rawDestination, 0), sessionIDs.count)
            if source < destination {
                destination -= 1
            }
            guard source != destination else {
                return self
            }
            var reordered = sessionIDs
            let moved = reordered.remove(at: source)
            reordered.insert(moved, at: destination)
            return .tabGroup(
                id: id,
                sessionIDs: reordered,
                activeSessionID: activeSessionID
            )
        case let .split(id, axis, children, sizes):
            return .split(
                id: id,
                axis: axis,
                children: children.map {
                    $0.movingTab(
                        sessionID: sessionID,
                        toIndex: rawDestination
                    )
                },
                sizes: normalizedSizes(sizes, count: children.count)
            )
        }
    }

    public func splittingTab(
        sessionID: UUID,
        nextTo targetSessionID: UUID,
        axis: SplitAxis,
        placement: SplitPlacement = .after
    ) -> WorkspaceNode {
        guard let sourceTabIDs = tabGroupSessionIDs(
                  containing: sessionID
              ),
              sourceTabIDs.count > 1,
              sessionIDs.contains(targetSessionID),
              let remaining = removing(sessionID: sessionID)
        else {
            return self
        }

        let resolvedTargetID: UUID?
        if targetSessionID != sessionID,
           remaining.sessionIDs.contains(targetSessionID)
        {
            resolvedTargetID = targetSessionID
        } else {
            resolvedTargetID = sourceTabIDs.first {
                $0 != sessionID && remaining.sessionIDs.contains($0)
            }
        }
        guard let resolvedTargetID else {
            return self
        }

        return remaining.inserting(
            sessionID: sessionID,
            nextTo: resolvedTargetID,
            axis: axis,
            placement: placement
        )
    }

    public func removing(sessionID: UUID) -> WorkspaceNode? {
        switch self {
        case let .pane(_, currentSessionID):
            return currentSessionID == sessionID ? nil : self
        case let .tabGroup(id, tabSessionIDs, activeSessionID):
            guard tabSessionIDs.contains(sessionID) else {
                return self
            }
            let remaining = tabSessionIDs.filter { $0 != sessionID }
            if remaining.isEmpty {
                return nil
            }
            if remaining.count == 1 {
                return .pane(id: id, sessionID: remaining[0])
            }
            return .tabGroup(
                id: id,
                sessionIDs: remaining,
                activeSessionID: activeSessionID == sessionID
                    ? remaining[0]
                    : activeSessionID
            )
        case let .split(id, axis, children, sizes):
            let originalSizes = normalizedSizes(sizes, count: children.count)
            let remaining = children.enumerated().compactMap { index, child -> (WorkspaceNode, Double)? in
                guard let node = child.removing(sessionID: sessionID) else {
                    return nil
                }
                return (node, originalSizes[index])
            }

            if remaining.isEmpty {
                return nil
            }
            if remaining.count == 1 {
                return remaining[0].0
            }

            let total = remaining.reduce(0) { $0 + $1.1 }
            return .split(
                id: id,
                axis: axis,
                children: remaining.map(\.0),
                sizes: remaining.map { total > 0 ? $0.1 / total : 1 / Double(remaining.count) }
            )
        }
    }

    private func tabGroupSessionIDs(
        containing sessionID: UUID
    ) -> [UUID]? {
        switch self {
        case .pane:
            return nil
        case let .tabGroup(_, sessionIDs, _):
            return sessionIDs.contains(sessionID) ? sessionIDs : nil
        case let .split(_, _, children, _):
            return children.lazy.compactMap {
                $0.tabGroupSessionIDs(containing: sessionID)
            }.first
        }
    }

    public func extractingPane(
        containing sessionID: UUID
    ) -> (remaining: WorkspaceNode?, detached: WorkspaceNode?) {
        guard sessionIDs.contains(sessionID) else {
            return (self, nil)
        }

        switch self {
        case .pane, .tabGroup:
            return (nil, self)
        case let .split(id, axis, children, sizes):
            guard let targetIndex = children.firstIndex(where: {
                $0.sessionIDs.contains(sessionID)
            }) else {
                return (self, nil)
            }

            let extraction = children[targetIndex].extractingPane(
                containing: sessionID
            )
            guard let detached = extraction.detached else {
                return (self, nil)
            }

            var remainingChildren = children
            var remainingSizes = normalizedSizes(
                sizes,
                count: children.count
            )
            if let remaining = extraction.remaining {
                remainingChildren[targetIndex] = remaining
            } else {
                remainingChildren.remove(at: targetIndex)
                remainingSizes.remove(at: targetIndex)
            }

            let remainingRoot: WorkspaceNode?
            if remainingChildren.isEmpty {
                remainingRoot = nil
            } else if remainingChildren.count == 1 {
                remainingRoot = remainingChildren[0]
            } else {
                remainingRoot = .split(
                    id: id,
                    axis: axis,
                    children: remainingChildren,
                    sizes: normalizedSizes(
                        remainingSizes,
                        count: remainingChildren.count
                    )
                )
            }
            return (remainingRoot, detached)
        }
    }

    public func updatingSplitSizes(
        splitID: UUID,
        sizes: [Double]
    ) -> WorkspaceNode {
        switch self {
        case .pane, .tabGroup:
            return self
        case let .split(id, axis, children, currentSizes):
            return .split(
                id: id,
                axis: axis,
                children: children.map {
                    $0.updatingSplitSizes(splitID: splitID, sizes: sizes)
                },
                sizes: id == splitID
                    ? normalizedSizes(sizes, count: children.count)
                    : normalizedSizes(currentSizes, count: children.count)
            )
        }
    }

    public func replacingSessionIDs(
        _ replacements: [UUID: UUID]
    ) -> WorkspaceNode {
        switch self {
        case let .pane(_, sessionID):
            return .pane(
                id: UUID(),
                sessionID: replacements[sessionID] ?? sessionID
            )
        case let .tabGroup(_, sessionIDs, activeSessionID):
            return .tabGroup(
                id: UUID(),
                sessionIDs: sessionIDs.map { replacements[$0] ?? $0 },
                activeSessionID: replacements[activeSessionID] ?? activeSessionID
            )
        case let .split(_, axis, children, sizes):
            return .split(
                id: UUID(),
                axis: axis,
                children: children.map {
                    $0.replacingSessionIDs(replacements)
                },
                sizes: normalizedSizes(sizes, count: children.count)
            )
        }
    }

    public func pruned(validSessionIDs: Set<UUID>) -> WorkspaceNode? {
        switch self {
        case let .pane(_, sessionID):
            return validSessionIDs.contains(sessionID) ? self : nil
        case let .tabGroup(id, sessionIDs, activeSessionID):
            let remaining = sessionIDs.filter { validSessionIDs.contains($0) }
            if remaining.isEmpty {
                return nil
            }
            if remaining.count == 1 {
                return .pane(id: id, sessionID: remaining[0])
            }
            return .tabGroup(
                id: id,
                sessionIDs: remaining,
                activeSessionID: remaining.contains(activeSessionID)
                    ? activeSessionID
                    : remaining[0]
            )
        case let .split(id, axis, children, sizes):
            let originalSizes = normalizedSizes(sizes, count: children.count)
            let remaining = children.enumerated().compactMap { index, child -> (WorkspaceNode, Double)? in
                guard let node = child.pruned(validSessionIDs: validSessionIDs) else {
                    return nil
                }
                return (node, originalSizes[index])
            }

            if remaining.isEmpty {
                return nil
            }
            if remaining.count == 1 {
                return remaining[0].0
            }

            let total = remaining.reduce(0) { $0 + $1.1 }
            return .split(
                id: id,
                axis: axis,
                children: remaining.map(\.0),
                sizes: remaining.map { total > 0 ? $0.1 / total : 1 / Double(remaining.count) }
            )
        }
    }
}

public struct WorkspaceDocument: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var root: WorkspaceNode
    public var focusedSessionID: UUID
    public var pinned: Bool

    public init(
        id: UUID = UUID(),
        title: String,
        root: WorkspaceNode,
        focusedSessionID: UUID,
        pinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.root = root
        self.focusedSessionID = focusedSessionID
        self.pinned = pinned
    }

    public static func single(session: SessionDescriptor) -> WorkspaceDocument {
        WorkspaceDocument(
            title: session.title,
            root: .pane(id: UUID(), sessionID: session.id),
            focusedSessionID: session.id
        )
    }
}

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var savedAt: Date
    public var activeWorkspaceID: UUID?
    public var sessions: [SessionDescriptor]
    public var workspaces: [WorkspaceDocument]

    public init(
        version: Int = WorkspaceSnapshot.currentVersion,
        savedAt: Date = Date(),
        activeWorkspaceID: UUID?,
        sessions: [SessionDescriptor],
        workspaces: [WorkspaceDocument]
    ) {
        self.version = version
        self.savedAt = savedAt
        self.activeWorkspaceID = activeWorkspaceID
        self.sessions = sessions
        self.workspaces = workspaces
    }

    public func sanitized() -> WorkspaceSnapshot? {
        guard version == WorkspaceSnapshot.currentVersion else {
            return nil
        }

        var seen = Set<UUID>()
        let safeSessions = sessions.filter { seen.insert($0.id).inserted }
        let validSessionIDs = Set(safeSessions.map(\.id))
        let safeWorkspaces = workspaces.compactMap { workspace -> WorkspaceDocument? in
            guard let root = workspace.root.pruned(validSessionIDs: validSessionIDs),
                  let fallbackFocus = root.sessionIDs.first
            else {
                return nil
            }
            var copy = workspace
            copy.root = root
            if !root.sessionIDs.contains(copy.focusedSessionID) {
                copy.focusedSessionID = fallbackFocus
            }
            return copy
        }
        let validWorkspaceIDs = Set(safeWorkspaces.map(\.id))

        return WorkspaceSnapshot(
            savedAt: savedAt,
            activeWorkspaceID: activeWorkspaceID.flatMap {
                validWorkspaceIDs.contains($0) ? $0 : safeWorkspaces.first?.id
            } ?? safeWorkspaces.first?.id,
            sessions: safeSessions.filter { session in
                safeWorkspaces.contains { $0.root.sessionIDs.contains(session.id) }
            },
            workspaces: safeWorkspaces
        )
    }
}

private func normalizedSizes(_ sizes: [Double], count: Int) -> [Double] {
    guard count > 0,
          sizes.count == count,
          sizes.allSatisfy({ $0.isFinite && $0 > 0 })
    else {
        return Array(repeating: 1 / Double(max(count, 1)), count: count)
    }
    let total = sizes.reduce(0, +)
    return sizes.map { $0 / total }
}
