import AppKit
import SwiftUI
import TermPilotDomain
import TermPilotRemote
import UniformTypeIdentifiers

enum SFTPBrowserPresentation {
    case dualPane
    case remoteSidebar
    case localSidebar
}

enum SFTPBrowserDataSource: Equatable {
    case remote
    case local
}

struct SFTPBrowserView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(SFTPPreferences.showsHiddenFilesKey)
    private var globallyShowsHiddenFiles =
        SFTPPreferences.defaultShowsHiddenFiles
    @StateObject private var model: SFTPBrowserModel
    private let presentation: SFTPBrowserPresentation
    private let terminalSessionID: UUID?
    private let terminalCurrentDirectory: String?
    private let closesOnDisappear: Bool

    init(
        host: TermPilotDomain.Host,
        presentation: SFTPBrowserPresentation = .dualPane,
        sourceConnectionID: UUID? = nil,
        sourceSessionID: UUID? = nil,
        terminalCurrentDirectory: String? = nil,
        closesOnDisappear: Bool = true,
        dataSource: SFTPBrowserDataSource = .remote,
        initialLocalDirectory: String? = nil
    ) {
        _model = StateObject(
            wrappedValue: SFTPBrowserModel(
                host: host,
                sourceConnectionID: sourceConnectionID,
                sourceSessionID: sourceSessionID,
                dataSource: dataSource,
                initialLocalDirectory: initialLocalDirectory
            )
        )
        self.presentation = presentation
        terminalSessionID = sourceSessionID
        self.terminalCurrentDirectory = terminalCurrentDirectory
        self.closesOnDisappear = closesOnDisappear
    }

    init(
        model: SFTPBrowserModel,
        presentation: SFTPBrowserPresentation = .dualPane,
        terminalSessionID: UUID? = nil,
        terminalCurrentDirectory: String? = nil,
        closesOnDisappear: Bool = true
    ) {
        _model = StateObject(wrappedValue: model)
        self.presentation = presentation
        self.terminalSessionID = terminalSessionID
        self.terminalCurrentDirectory = terminalCurrentDirectory
        self.closesOnDisappear = closesOnDisappear
    }

    var body: some View {
        content
            .task {
                model.showsHiddenFiles = globallyShowsHiddenFiles
                await model.connect(using: state)
            }
            .onChange(of: globallyShowsHiddenFiles) { _, showsHiddenFiles in
                guard model.showsHiddenFiles != showsHiddenFiles else {
                    return
                }
                model.showsHiddenFiles = showsHiddenFiles
                model.refreshLocal()
                if model.isConnected, !model.usesLocalFilesystemOnly {
                    Task {
                        await model.refreshRemote(using: state)
                    }
                }
            }
            .onDisappear {
                if closesOnDisappear {
                    model.close()
                }
            }
            .alert(
                "SFTP",
                isPresented: Binding(
                    get: {
                        switch presentation {
                        case .dualPane:
                            model.errorMessage != nil
                        case .remoteSidebar:
                            false
                        case .localSidebar:
                            model.errorMessage != nil
                        }
                    },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    model.errorMessage = nil
                }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .sheet(item: $model.renameDraft) { draft in
                RenameRemoteItemView(draft: draft) { newName in
                    Task {
                        await model.renameRemoteItem(
                            draft,
                            to: newName,
                            using: state
                        )
                    }
                }
            }
            .sheet(item: $model.chmodDraft) { draft in
                ChmodRemoteItemView(draft: draft) { permissions in
                    Task {
                        await model.chmodRemoteItem(
                            draft,
                            permissions: permissions,
                            using: state
                        )
                    }
                }
            }
            .sheet(item: $model.textDraft) { draft in
                RemoteTextEditorView(draft: draft) { text in
                    Task {
                        await model.saveTextDraft(
                            draft,
                            text: text,
                            using: state
                        )
                    }
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { model.pendingOverwrite != nil },
                    set: { isPresented in
                        if !isPresented {
                            model.dismissCurrentOverwrite(using: state)
                        }
                    }
                )
            ) {
                if let conflict = model.pendingOverwrite {
                    if let batchID = conflict.batchID {
                        SFTPBatchConflictResolutionView(
                            conflicts: model.pendingOverwriteBatch,
                            onCancel: {
                                model.cancelUploadConflictBatch(
                                    batchID,
                                    using: state
                                )
                            },
                            onStart: { resolutions in
                                model.resolveUploadConflictBatch(
                                    batchID,
                                    resolutions: resolutions,
                                    using: state
                                )
                            }
                        )
                        .id(batchID)
                    } else {
                        SFTPConflictResolutionView(
                            conflict: conflict,
                            sameTypeConflictCount:
                                model.pendingOverwriteSameTypeCount
                        ) { resolution, applyToAll in
                            model.resolveOverwrite(
                                resolution,
                                applyToAll: applyToAll,
                                using: state
                            )
                        }
                        .id(conflict.id)
                    }
                }
            }
            .confirmationDialog(
                "Delete remote item?",
                isPresented: Binding(
                    get: { model.pendingDelete != nil },
                    set: { if !$0 { model.pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let pendingDelete = model.pendingDelete {
                    Button("Delete", role: .destructive) {
                        model.pendingDelete = nil
                        Task {
                            await model.confirmDelete(pendingDelete, using: state)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    model.pendingDelete = nil
                }
            } message: {
                Text(model.pendingDelete?.message ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation {
        case .dualPane:
            dualPaneBody
        case .remoteSidebar:
            remoteSidebarBody
        case .localSidebar:
            localSidebarBody
        }
    }

    private var dualPaneBody: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                localPane
                    .frame(minWidth: 300)
                remotePane()
                    .frame(minWidth: 360)
            }
            Divider()
            TransferCenterView(
                compact: true,
                onCancel: { model.cancelTransfer($0, state: state) },
                onRetry: { model.retryTransfer($0, state: state) },
                onPause: { model.pauseTransfer($0, state: state) },
                onResume: { model.resumeTransfer($0, state: state) }
            )
            .environmentObject(state)
            .frame(height: 132)
        }
        .frame(minWidth: 920, idealWidth: 1080, minHeight: 640, idealHeight: 720)
    }

    private var remoteSidebarBody: some View {
        VStack(spacing: 0) {
            remotePane(isSidebar: true)
            if !sidebarTransfers.isEmpty {
                Divider()
                TransferCenterView(
                    compact: true,
                    sidebar: true,
                    transferIDs: model.transferIDs,
                    onCancel: { model.cancelTransfer($0, state: state) },
                    onRetry: { model.retryTransfer($0, state: state) },
                    onPause: { model.pauseTransfer($0, state: state) },
                    onResume: { model.resumeTransfer($0, state: state) }
                )
                .environmentObject(state)
                .frame(height: sidebarTransferPanelHeight)
            }
        }
        .frame(minWidth: 340, idealWidth: 340, minHeight: 360)
    }

    private var localSidebarBody: some View {
        VStack(spacing: 0) {
            browserToolbar(
                title: "Local Files",
                path: $model.localPathText,
                canGoBack: model.canGoBackLocal,
                canGoForward: model.canGoForwardLocal,
                goBack: model.goBackLocal,
                goForward: model.goForwardLocal,
                goUp: model.goUpLocal,
                goHome: model.goHomeLocal,
                canGoToTerminalDirectory: canGoToLocalTerminalDirectory,
                goToTerminalDirectory: {
                    model.goToLocalTerminalDirectory(
                        terminalCurrentDirectory
                    )
                },
                submitPath: model.commitLocalPath,
                refresh: model.refreshLocal
            )
            localSidebarControls
            fileListHeader
            List(model.visibleLocalEntries) { entry in
                localSidebarEntryRow(entry)
            }
            .listStyle(.plain)
            localSidebarFooter
        }
        .frame(minWidth: 340, idealWidth: 340, minHeight: 360)
        .accessibilityLabel("Local Files")
    }

    private var localSidebarControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $model.localFilterText)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(minWidth: 90)
            Menu {
                Button {
                    model.showsHiddenFiles.toggle()
                    model.refreshLocal()
                } label: {
                    Text(
                        LocalizedStringKey(
                            model.showsHiddenFiles
                                ? "Hide Hidden Files"
                                : "Show Hidden Files"
                        )
                    )
                }
                Button("Choose Folder") {
                    model.chooseLocalDirectory()
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [model.localPath]
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func localSidebarEntryRow(
        _ entry: LocalFileEntry
    ) -> some View {
        FileEntryRow(
            name: entry.name,
            kind: entry.isDirectory ? .directory : .file,
            size: entry.size,
            modifiedAt: entry.modifiedAt,
            isSelected: model.selectedLocalURLs.contains(entry.url)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectLocal(entry)
        }
        .onTapGesture(count: 2) {
            model.activateLocal(entry)
        }
        .contextMenu {
            Button("Open") {
                model.activateLocal(entry)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    entry.url.path,
                    forType: .string
                )
            }
        }
    }

    private var localSidebarFooter: some View {
        HStack(spacing: 10) {
            Text(
                String(
                    format: AppLocalization.string("%@ items"),
                    String(model.visibleLocalEntries.count)
                )
            )
            Spacer()
            Text(model.localPath.path)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var canGoToLocalTerminalDirectory: Bool {
        !(terminalCurrentDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)
    }

    private var sidebarTransfers: [FileTransferRecord] {
        state.fileTransfers.filter {
            model.transferIDs.contains($0.id) && $0.isUnfinished
        }
    }

    private var sidebarTransferPanelHeight: CGFloat {
        min(max(54 + CGFloat(sidebarTransfers.count) * 74, 128), 220)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label(model.host.label, systemImage: "folder.badge.gearshape")
                .font(.headline)
            Text("\(model.host.username)@\(model.host.hostname):\(model.host.port)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
            if model.isConnecting {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(model.isConnected ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(LocalizedStringKey(model.isConnected ? "Connected" : "Disconnected"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.bar)
    }

    private var localPane: some View {
        VStack(spacing: 0) {
            browserToolbar(
                title: "Local",
                path: $model.localPathText,
                canGoBack: model.canGoBackLocal,
                canGoForward: model.canGoForwardLocal,
                goBack: model.goBackLocal,
                goForward: model.goForwardLocal,
                goUp: model.goUpLocal,
                submitPath: model.commitLocalPath,
                refresh: model.refreshLocal
            )
            fileListHeader
            List(model.visibleLocalEntries) { entry in
                FileEntryRow(
                    name: entry.name,
                    kind: entry.isDirectory ? .directory : .file,
                    size: entry.size,
                    modifiedAt: entry.modifiedAt,
                    isSelected: model.selectedLocalURLs.contains(entry.url)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectLocal(entry)
                }
                .onTapGesture(count: 2) {
                    model.openLocal(entry)
                }
                .contextMenu {
                    if entry.isDirectory {
                        Button("Open") {
                            model.openLocal(entry)
                        }
                    }
                    Button("Upload") {
                        model.uploadLocal(entry.url, using: state)
                    }
                    Button("Copy") {
                        model.copySelectedLocal(fallback: entry)
                    }
                    Button("Cut") {
                        model.cutSelectedLocal(fallback: entry)
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            entry.url.path,
                            forType: .string
                        )
                    }
                }
            }
            .listStyle(.plain)
            HStack {
                Button {
                    model.chooseLocalDirectory()
                } label: {
                    Label("Choose Folder", systemImage: "folder")
                }
                TextField("Filter", text: $model.localFilterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                Spacer()
                Button {
                    model.chooseFilesToUpload(using: state)
                } label: {
                    Label("Upload...", systemImage: "arrow.up.doc")
                }
                Button {
                    model.copySelectedLocal()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(model.selectedLocalEntries.isEmpty)
                Button {
                    model.cutSelectedLocal()
                } label: {
                    Label("Cut", systemImage: "scissors")
                }
                .disabled(model.selectedLocalEntries.isEmpty)
                Button {
                    Task {
                        await model.pasteToLocal(using: state)
                    }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .disabled(!model.canPasteToLocal)
                Button {
                    model.uploadSelectedLocal(using: state)
                } label: {
                    Label("Upload", systemImage: "arrow.up.circle")
                }
                .disabled(model.selectedLocalEntry == nil || !model.isConnected)
            }
            .padding(10)
        }
        .accessibilityLabel("Local Files")
    }

    private func remotePane(isSidebar: Bool = false) -> some View {
        VStack(spacing: 0) {
            browserToolbar(
                title: isSidebar ? "Remote Files" : "Remote",
                path: $model.remotePathText,
                canGoBack: model.canGoBackRemote,
                canGoForward: model.canGoForwardRemote,
                goBack: { Task { await model.goBackRemote(using: state) } },
                goForward: { Task { await model.goForwardRemote(using: state) } },
                goUp: { Task { await model.goUpRemote(using: state) } },
                goHome: { Task { await model.goHomeRemote(using: state) } },
                canGoToTerminalDirectory: canGoToTerminalDirectory,
                goToTerminalDirectory: {
                    Task {
                        await model.goToTerminalDirectory(
                            fallback: terminalCurrentDirectory,
                            sourceSessionID: terminalSessionID,
                            using: state
                        )
                    }
                },
                submitPath: { Task { await model.commitRemotePath(using: state) } },
                refresh: { Task { await model.refreshRemote(using: state) } }
            )
            remoteControls(isSidebar: isSidebar)
            fileListHeader
            ZStack {
                if model.remoteViewMode == .list {
                    List(model.visibleRemoteEntries, id: \.name) { entry in
                        remoteEntryRow(
                            entry,
                            fullPath: model.remotePath(for: entry.name),
                            depth: 0,
                            isExpanded: false
                        )
                    }
                    .listStyle(.plain)
                } else {
                    List(model.visibleRemoteTreeRows) { row in
                        remoteEntryRow(
                            row.entry,
                            fullPath: row.path,
                            depth: row.depth,
                            isExpanded: row.isExpanded
                        )
                    }
                    .listStyle(.plain)
                }

                if model.isRemoteLoading {
                    ProgressView("Loading...")
                        .padding(14)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                if let errorMessage = model.errorMessage,
                   !errorMessage.isEmpty,
                   model.remoteEntries.isEmpty
                {
                    remoteErrorState(errorMessage)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $model.isRemoteDropTargeted) {
                providers in
                model.acceptLocalFileDrop(providers, using: state)
            }
            if isSidebar {
                remoteSidebarFooter
            } else {
                HStack {
                    Button {
                        Task {
                            await model.downloadSelectedRemote(using: state)
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .disabled(model.selectedRemoteEntry == nil)
                    Button {
                        Task {
                            await model.openSelectedRemoteText(using: state)
                        }
                    } label: {
                        Label("View/Edit", systemImage: "doc.text")
                    }
                    .disabled(model.selectedRemoteFile == nil)
                    Button {
                        model.copySelectedRemote()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(model.selectedRemoteEntries.isEmpty)
                    Button {
                        model.cutSelectedRemote()
                    } label: {
                        Label("Cut", systemImage: "scissors")
                    }
                    .disabled(model.selectedRemoteEntries.isEmpty)
                    Button {
                        Task {
                            await model.pasteToRemote(using: state)
                        }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .disabled(!model.canPasteToRemote)
                    Spacer()
                    Button(role: .destructive) {
                        model.requestDeleteSelectedRemote()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(model.selectedRemoteEntry == nil)
                }
                .padding(10)
            }
        }
        .alert(
            "Create Remote Folder",
            isPresented: Binding(
                get: { model.newFolderName != nil },
                set: { if !$0 { model.newFolderName = nil } }
            )
        ) {
            TextField("Folder name", text: Binding(
                get: { model.newFolderName ?? "" },
                set: { model.newFolderName = $0 }
            ))
            Button("Create") {
                Task {
                    await model.createRemoteFolder(using: state)
                }
            }
            Button("Cancel", role: .cancel) {
                model.newFolderName = nil
            }
        }
        .alert(
            "Create Remote File",
            isPresented: Binding(
                get: { model.newFileName != nil },
                set: { if !$0 { model.newFileName = nil } }
            )
        ) {
            TextField("File name", text: Binding(
                get: { model.newFileName ?? "" },
                set: { model.newFileName = $0 }
            ))
            Button("Create") {
                Task {
                    await model.createRemoteFile(using: state)
                }
            }
            Button("Cancel", role: .cancel) {
                model.newFileName = nil
            }
        }
        .accessibilityLabel("Remote Files")
    }

    @ViewBuilder
    private func remoteControls(isSidebar: Bool) -> some View {
        if isSidebar {
            remoteSidebarControls
        } else {
            remoteFullControls
        }
    }

    private var remoteFullControls: some View {
        HStack {
            Toggle("Hidden Files", isOn: $model.showsHiddenFiles)
                .toggleStyle(.checkbox)
                .onChange(of: model.showsHiddenFiles) { _, _ in
                    model.refreshLocal()
                    Task {
                        await model.refreshRemote(using: state)
                    }
                }
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $model.remoteFilterText)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(width: 160)
            remoteBookmarkMenu(labelStyle: .full)
            remoteViewModePicker(width: 116)
            Toggle("Auto Sync", isOn: $model.autoSyncExternalEdits)
                .toggleStyle(.checkbox)
            Spacer()
            Button {
                model.newFolderName = AppLocalization.string("New Folder")
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            Button {
                model.newFileName = "untitled.txt"
            } label: {
                Label("New File", systemImage: "doc.badge.plus")
            }
            Button {
                model.startRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(model.selectedRemoteEntry == nil)
            Button {
                model.startChmod()
            } label: {
                Label("Chmod", systemImage: "number")
            }
            .disabled(model.selectedRemoteEntry == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var remoteSidebarControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $model.remoteFilterText)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(minWidth: 90)
            remoteViewModePicker(width: 104)
            Menu {
                Button {
                    model.showsHiddenFiles.toggle()
                    model.refreshLocal()
                    Task {
                        await model.refreshRemote(using: state)
                    }
                } label: {
                    Text(LocalizedStringKey(model.showsHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files"))
                }
                Button {
                    model.autoSyncExternalEdits.toggle()
                } label: {
                    Text(LocalizedStringKey(model.autoSyncExternalEdits ? "Disable Auto Sync" : "Enable Auto Sync"))
                }
                Divider()
                Button("Upload...") {
                    model.chooseFilesToUpload(using: state)
                }
                Button("New Folder") {
                    model.newFolderName = AppLocalization.string("New Folder")
                }
                Button("New File") {
                    model.newFileName = "untitled.txt"
                }
                Divider()
                remoteBookmarkMenu(labelStyle: .menuContent)
                Divider()
                Button("Rename") {
                    model.startRename()
                }
                .disabled(model.selectedRemoteEntry == nil)
                Button("Chmod") {
                    model.startChmod()
                }
                .disabled(model.selectedRemoteEntry == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private enum RemoteBookmarkLabelStyle {
        case full
        case menuContent
    }

    @ViewBuilder
    private func remoteBookmarkMenu(
        labelStyle: RemoteBookmarkLabelStyle
    ) -> some View {
        Menu {
            Button("Add Current Path") {
                model.addRemoteBookmark()
            }
            Divider()
            if model.remoteBookmarks.isEmpty {
                Text("No Bookmarks")
            } else {
                ForEach(model.remoteBookmarks, id: \.self) { path in
                    Button(path) {
                        Task {
                            await model.navigateRemoteBookmark(
                                path,
                                using: state
                            )
                        }
                    }
                }
            }
        } label: {
            switch labelStyle {
            case .full:
                Label("Bookmarks", systemImage: "bookmark")
            case .menuContent:
                Label("Bookmarks", systemImage: "bookmark")
            }
        }
    }

    private func remoteViewModePicker(width: CGFloat) -> some View {
        Picker("View", selection: $model.remoteViewMode) {
            ForEach(SFTPBrowserViewMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: width)
    }

    private func remoteErrorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("SFTP Connection Failed")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
            Button("Retry") {
                Task {
                    await model.reconnect(using: state)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 280)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8, y: 2)
    }

    private var remoteSidebarFooter: some View {
        HStack(spacing: 10) {
            Label(
                model.isRemoteDropTargeted
                    ? "Release to upload"
                    : "Drop files here to upload",
                systemImage: "tray.and.arrow.up"
            )
            .foregroundStyle(model.isRemoteDropTargeted ? Color.accentColor : .secondary)
            Spacer()
            Text("\(remoteVisibleCount) items")
            Text(model.remotePathText)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var remoteVisibleCount: Int {
        switch model.remoteViewMode {
        case .list:
            model.visibleRemoteEntries.count
        case .tree:
            model.visibleRemoteTreeRows.count
        }
    }

    private var canGoToTerminalDirectory: Bool {
        model.canQueryTerminalDirectory || !(terminalCurrentDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)
    }

    private func remoteEntryRow(
        _ entry: SFTPDirectoryEntry,
        fullPath: String,
        depth: Int,
        isExpanded: Bool
    ) -> some View {
        let isParentDirectory = entry.name == ".."
        return FileEntryRow(
            name: entry.name,
            kind: entry.kind,
            size: entry.size,
            modifiedAt: entry.modifiedAt,
            isSelected: model.selectedRemoteNames.contains(entry.name),
            indentation: depth,
            canExpand: model.remoteViewMode == .tree
                && entry.kind == .directory
                && !isParentDirectory,
            isExpanded: isExpanded,
            onToggleExpand: {
                Task {
                    await model.toggleRemoteTreeDirectory(
                        entry,
                        fullPath: fullPath,
                        using: state
                    )
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectRemote(entry)
        }
        .onTapGesture(count: 2) {
            Task {
                if isParentDirectory {
                    await model.goUpRemote(using: state)
                } else if model.remoteViewMode == .tree,
                          entry.kind == .directory
                {
                    await model.toggleRemoteTreeDirectory(
                        entry,
                        fullPath: fullPath,
                        using: state
                    )
                } else {
                    await model.openRemote(entry, fullPath: fullPath, using: state)
                }
            }
        }
        .contextMenu {
            Button("Open") {
                Task {
                    await model.openRemote(entry, fullPath: fullPath, using: state)
                }
            }
            if !isParentDirectory {
                Button("Download") {
                    Task {
                        await model.downloadRemote(
                            entry,
                            fullPath: fullPath,
                            using: state
                        )
                    }
                }
                if entry.kind == .file {
                    Button("View/Edit") {
                        Task {
                            await model.openRemoteText(
                                entry,
                                fullPath: fullPath,
                                using: state
                            )
                        }
                    }
                    Button("Open with Default App") {
                        Task {
                            await model.openRemoteWithDefaultApp(
                                entry,
                                fullPath: fullPath,
                                using: state
                            )
                        }
                    }
                    Button("Open With...") {
                        Task {
                            await model.openRemoteWithSelectedApp(
                                entry,
                                fullPath: fullPath,
                                using: state
                            )
                        }
                    }
                }
                Button("Copy") {
                    model.copySelectedRemote(fallback: entry)
                }
                Button("Cut") {
                    model.cutSelectedRemote(fallback: entry)
                }
                Button("Rename") {
                    model.selectOnlyRemote(entry)
                    model.startRename(entry, fullPath: fullPath)
                }
                Button("Chmod") {
                    model.selectOnlyRemote(entry)
                    model.startChmod(entry, fullPath: fullPath)
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fullPath, forType: .string)
                }
                Divider()
                Button("Delete", role: .destructive) {
                    model.selectOnlyRemote(entry)
                    model.requestDeleteRemote(entry, fullPath: fullPath)
                }
            }
        }
    }

    private var fileListHeader: some View {
        HStack {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Size")
                .frame(width: 86, alignment: .trailing)
            Text("Modified")
                .frame(width: 120, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func browserToolbar(
        title: String,
        path: Binding<String>,
        canGoBack: Bool,
        canGoForward: Bool,
        goBack: @escaping () -> Void,
        goForward: @escaping () -> Void,
        goUp: @escaping () -> Void,
        goHome: (() -> Void)? = nil,
        canGoToTerminalDirectory: Bool = false,
        goToTerminalDirectory: (() -> Void)? = nil,
        submitPath: @escaping () -> Void,
        refresh: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canGoBack)
                Button(action: goForward) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canGoForward)
                Button(action: goUp) {
                    Image(systemName: "arrow.up")
                }
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
            }
            HStack {
                if let goHome {
                    Button(action: goHome) {
                        Image(systemName: "house")
                    }
                    .help("Go to Home Directory")
                }
                TextField("Path", text: path)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.go)
                    .onSubmit {
                        submitPath()
                    }
                if let goToTerminalDirectory {
                    Button(action: goToTerminalDirectory) {
                        Image(systemName: "location")
                    }
                    .disabled(!canGoToTerminalDirectory)
                    .help("Go to Current Terminal Directory")
                }
                Button("Go", action: submitPath)
            }
        }
        .buttonStyle(.borderless)
        .padding(10)
    }
}

@MainActor
final class SFTPBrowserModel: ObservableObject {
    private static let parentDirectoryEntry = SFTPDirectoryEntry(
        name: "..",
        kind: .directory
    )

    static var defaultDownloadDirectory: URL {
        FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
    }

    @Published var localPath: URL
    @Published var localPathText: String
    @Published var localEntries: [LocalFileEntry] = []
    @Published var selectedLocalURL: URL?
    @Published var selectedLocalURLs = Set<URL>()
    @Published var localFilterText = ""
    @Published var remotePathText = "."
    @Published var remoteEntries: [SFTPDirectoryEntry] = []
    @Published var selectedRemoteName: String?
    @Published var selectedRemoteNames = Set<String>()
    @Published var remoteFilterText = ""
    @Published var remoteBookmarks: [String] = []
    @Published var remoteViewMode = SFTPBrowserViewMode.list
    @Published var expandedRemoteTreePaths = Set<String>()
    @Published var remoteTreeChildren: [String: [SFTPDirectoryEntry]] = [:]
    @Published var clipboard: SFTPClipboard?
    @Published var autoSyncExternalEdits = true
    @Published var externalEditSessions: [ExternalEditSession] = []
    @Published var fileAssociations: [String: URL] = [:]
    @Published var showsHiddenFiles: Bool {
        didSet {
            UserDefaults.standard.set(
                showsHiddenFiles,
                forKey: SFTPPreferences.showsHiddenFilesKey
            )
        }
    }
    @Published var isConnecting = false
    @Published var isConnected = false
    @Published var isRemoteLoading = false
    @Published var isRemoteDropTargeted = false
    @Published var errorMessage: String?
    @Published var renameDraft: RemoteRenameDraft?
    @Published var chmodDraft: RemoteChmodDraft?
    @Published var textDraft: RemoteTextDraft?
    @Published private(set) var pendingOverwrites: [PendingSFTPOverwrite] = []
    @Published var pendingDelete: PendingSFTPDelete?
    @Published var newFolderName: String?
    @Published var newFileName: String?
    @Published private(set) var transferIDs = Set<UUID>()
    @Published private(set) var supportsResumablePause = true

    let host: TermPilotDomain.Host
    let sourceConnectionID: UUID?
    let sourceSessionID: UUID?
    let dataSource: SFTPBrowserDataSource

    private var client: SSH2SFTPBridgeClient?
    private var remoteBackStack: [String] = []
    private var remoteForwardStack: [String] = []
    private var localBackStack: [URL] = []
    private var localForwardStack: [URL] = []
    private var transferTasks: [UUID: Task<Void, Never>] = [:]
    private var transferClients: [UUID: SSH2SFTPBridgeClient] = [:]
    private var transferClient: SSH2SFTPBridgeClient?
    private var transferClientOpeningTask:
        Task<SSH2SFTPBridgeClient, any Error>?
    private var transferClientIdleTask: Task<Void, Never>?
    private var transferClientGeneration = 0
    private var pausedTransferIDs = Set<UUID>()
    private var uploadBatchIDsByTransferID: [UUID: UUID] = [:]
    private var uploadTransferIDsByBatchID: [UUID: Set<UUID>] = [:]
    private var uploadSourcesToDeleteAfterSuccess: [UUID: URL] = [:]
    private var pendingUploadCandidatesByBatchID:
        [UUID: [SFTPUploadCandidate]] = [:]
    private var uploadConflictDefaults:
        [SFTPUploadConflictBucket: SFTPConflictResolution] = [:]
    private var externalEditTimer: Timer?

    var pendingOverwrite: PendingSFTPOverwrite? {
        pendingOverwrites.first
    }

    var pendingOverwriteSameTypeCount: Int {
        guard let bucket = pendingOverwrite?.uploadConflictBucket else {
            return 1
        }
        return pendingOverwrites.count {
            $0.uploadConflictBucket == bucket
        }
    }

    var pendingOverwriteBatch: [PendingSFTPOverwrite] {
        guard let pendingOverwrite else {
            return []
        }
        guard let batchID = pendingOverwrite.batchID else {
            return [pendingOverwrite]
        }
        return pendingOverwrites.filter { $0.batchID == batchID }
    }

    init(
        host: TermPilotDomain.Host,
        sourceConnectionID: UUID? = nil,
        sourceSessionID: UUID? = nil,
        dataSource: SFTPBrowserDataSource = .remote,
        initialLocalDirectory: String? = nil
    ) {
        self.host = host
        self.sourceConnectionID = sourceConnectionID
        self.sourceSessionID = sourceSessionID
        self.dataSource = dataSource
        showsHiddenFiles = SFTPPreferences.showsHiddenFiles
        let initialURL = initialLocalDirectory.flatMap { path -> URL? in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        } ?? Self.defaultDownloadDirectory
        localPath = initialURL
        localPathText = initialURL.path
        refreshLocal()
    }

    var canGoBackRemote: Bool { !remoteBackStack.isEmpty }
    var canGoForwardRemote: Bool { !remoteForwardStack.isEmpty }
    var canGoBackLocal: Bool { !localBackStack.isEmpty }
    var canGoForwardLocal: Bool { !localForwardStack.isEmpty }

    var canQueryTerminalDirectory: Bool {
        dataSource == .remote && sourceConnectionID != nil
    }

    var usesLocalFilesystemOnly: Bool {
        dataSource == .local
    }

    var visibleLocalEntries: [LocalFileEntry] {
        let query = localFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return localEntries
        }
        return localEntries.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    var visibleRemoteEntries: [SFTPDirectoryEntry] {
        let query = remoteFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries: [SFTPDirectoryEntry]
        if query.isEmpty {
            entries = remoteEntries
        } else {
            entries = remoteEntries.filter {
                $0.name.localizedCaseInsensitiveContains(query)
            }
        }
        guard hasRemoteParentDirectory else {
            return entries
        }
        return [Self.parentDirectoryEntry]
            + entries.filter { $0.name != ".." }
    }

    var hasRemoteParentDirectory: Bool {
        let path = remotePathText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path != "/" else {
            return false
        }
        return path.range(
            of: #"^[A-Za-z]:[\\/]?$"#,
            options: .regularExpression
        ) == nil
    }

    var selectedLocalEntry: LocalFileEntry? {
        guard let selectedLocalURL = selectedLocalURLs.first ?? selectedLocalURL else {
            return nil
        }
        return localEntries.first { $0.url == selectedLocalURL }
    }

    var selectedLocalEntries: [LocalFileEntry] {
        let ids = selectedLocalURLs
        guard !ids.isEmpty else {
            return selectedLocalEntry.map { [$0] } ?? []
        }
        return localEntries.filter { ids.contains($0.url) }
    }

    var selectedRemoteEntry: SFTPDirectoryEntry? {
        guard let selectedRemoteName = selectedRemoteNames.first ?? selectedRemoteName else {
            return nil
        }
        return remoteEntries.first { $0.name == selectedRemoteName }
    }

    var selectedRemoteEntries: [SFTPDirectoryEntry] {
        let names = selectedRemoteNames
        guard !names.isEmpty else {
            return selectedRemoteEntry.map { [$0] } ?? []
        }
        return remoteEntries.filter { names.contains($0.name) }
    }

    var selectedRemoteFile: SFTPDirectoryEntry? {
        guard let selectedRemoteEntry,
              selectedRemoteEntry.kind == .file
        else {
            return nil
        }
        return selectedRemoteEntry
    }

    var canPasteToLocal: Bool {
        if case .remote = clipboard?.source {
            true
        } else {
            false
        }
    }

    var canPasteToRemote: Bool {
        clipboard != nil && isConnected
    }

    func selectLocal(_ entry: LocalFileEntry) {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            if selectedLocalURLs.contains(entry.url) {
                selectedLocalURLs.remove(entry.url)
            } else {
                selectedLocalURLs.insert(entry.url)
            }
        } else {
            selectedLocalURLs = [entry.url]
        }
        selectedLocalURL = entry.url
    }

    func selectRemote(_ entry: SFTPDirectoryEntry) {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            if selectedRemoteNames.contains(entry.name) {
                selectedRemoteNames.remove(entry.name)
            } else {
                selectedRemoteNames.insert(entry.name)
            }
        } else {
            selectedRemoteNames = [entry.name]
        }
        selectedRemoteName = entry.name
    }

    func selectOnlyRemote(_ entry: SFTPDirectoryEntry) {
        selectedRemoteName = entry.name
        selectedRemoteNames = [entry.name]
    }

    func copySelectedLocal(fallback: LocalFileEntry? = nil) {
        let urls = selectedLocalEntries.map(\.url)
        let finalURLs = urls.isEmpty ? fallback.map { [$0.url] } ?? [] : urls
        guard !finalURLs.isEmpty else {
            return
        }
        clipboard = SFTPClipboard(operation: .copy, source: .local(finalURLs))
    }

    func cutSelectedLocal(fallback: LocalFileEntry? = nil) {
        let urls = selectedLocalEntries.map(\.url)
        let finalURLs = urls.isEmpty ? fallback.map { [$0.url] } ?? [] : urls
        guard !finalURLs.isEmpty else {
            return
        }
        clipboard = SFTPClipboard(operation: .cut, source: .local(finalURLs))
    }

    func copySelectedRemote(fallback: SFTPDirectoryEntry? = nil) {
        let entries = selectedRemoteEntries
        let finalEntries = entries.isEmpty ? fallback.map { [$0] } ?? [] : entries
        guard !finalEntries.isEmpty else {
            return
        }
        clipboard = SFTPClipboard(
            operation: .copy,
            source: .remote(path: remotePathText, entries: finalEntries)
        )
    }

    func cutSelectedRemote(fallback: SFTPDirectoryEntry? = nil) {
        let entries = selectedRemoteEntries
        let finalEntries = entries.isEmpty ? fallback.map { [$0] } ?? [] : entries
        guard !finalEntries.isEmpty else {
            return
        }
        clipboard = SFTPClipboard(
            operation: .cut,
            source: .remote(path: remotePathText, entries: finalEntries)
        )
    }

    var visibleRemoteTreeRows: [RemoteTreeRow] {
        let query = remoteFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [RemoteTreeRow] = []

        func append(entries: [SFTPDirectoryEntry], parentPath: String, depth: Int) {
            for entry in entries {
                if !query.isEmpty,
                   !entry.name.localizedCaseInsensitiveContains(query),
                   entry.kind != .directory
                {
                    continue
                }
                let fullPath = remoteJoin(parentPath, entry.name)
                rows.append(
                    RemoteTreeRow(
                        entry: entry,
                        path: fullPath,
                        depth: depth,
                        isExpanded: expandedRemoteTreePaths.contains(fullPath)
                    )
                )
                if entry.kind == .directory,
                   expandedRemoteTreePaths.contains(fullPath),
                   let children = remoteTreeChildren[fullPath]
                {
                    append(entries: children, parentPath: fullPath, depth: depth + 1)
                }
            }
        }

        append(entries: visibleRemoteEntries, parentPath: remotePathText, depth: 0)
        return rows
    }

    func connect(using state: AppState) async {
        if dataSource == .local {
            refreshLocal()
            isConnected = true
            return
        }
        guard client == nil else {
            return
        }
        isConnecting = true
        errorMessage = nil
        defer {
            isConnecting = false
        }
        let elevatesOperations =
            host.serverToolsUseRoot
            && host.username != "root"
        if let sourceConnectionID, !elevatesOperations {
            do {
                let client = try state.makeSFTPClient(
                    for: host,
                    sourceConnectionID: sourceConnectionID,
                    sourceSessionID: sourceSessionID
                )
                try await establishConnection(
                    client,
                    readyTimeoutSeconds: 5,
                    listTimeoutSeconds: 35
                )
                return
            } catch {
                let failedClient = client
                client = nil
                await failedClient?.close()
            }
        }

        do {
            let client = try state.makeSFTPClient(
                for: host,
                elevatesOperations: elevatesOperations
            )
            try await establishConnection(
                client,
                readyTimeoutSeconds: 35,
                listTimeoutSeconds: 35
            )
        } catch {
            let failedClient = client
            client = nil
            await failedClient?.close()
            errorMessage = AppLocalization.errorDescription(error)
            isConnected = false
        }
    }

    private func establishConnection(
        _ client: SSH2SFTPBridgeClient,
        readyTimeoutSeconds: UInt64,
        listTimeoutSeconds: UInt64
    ) async throws {
        self.client = client
        do {
            try await withSFTPTimeout(seconds: readyTimeoutSeconds) {
                try await client.waitUntilReady()
            }
            supportsResumablePause = await client.supportsResumablePause()
            let requestedPath = remotePathText
            let remotePath = try await withSFTPTimeout(
                seconds: listTimeoutSeconds
            ) {
                try await client.realPath(requestedPath)
            }
            remotePathText = remotePath
            let entries = try await loadRemoteEntries(
                at: remotePath,
                timeoutSeconds: listTimeoutSeconds
            )
            applyRemoteEntries(entries, for: remotePath)
            isConnected = true
        } catch {
            isConnected = false
            await client.close()
            if self.client === client {
                self.client = nil
            }
            throw error
        }
    }

    func reconnect(using state: AppState) async {
        if dataSource == .local {
            errorMessage = nil
            refreshLocal()
            isConnected = true
            return
        }
        errorMessage = nil
        isRemoteLoading = false
        isConnecting = false
        let existingClient = client
        client = nil
        isConnected = false
        await existingClient?.close()
        await connect(using: state)
    }

    func invalidateRemoteConnection() {
        guard dataSource == .remote else {
            return
        }
        let staleClient = client
        client = nil
        isConnected = false
        isConnecting = false
        isRemoteLoading = false
        Task {
            await staleClient?.close()
        }
    }

    func close() {
        let client = client
        self.client = nil
        isConnected = false
        externalEditTimer?.invalidate()
        externalEditTimer = nil
        for task in transferTasks.values {
            task.cancel()
        }
        transferClientIdleTask?.cancel()
        transferClientIdleTask = nil
        transferClientOpeningTask?.cancel()
        transferClientOpeningTask = nil
        transferClientGeneration &+= 1
        let transferClient = transferClient
        self.transferClient = nil
        transferClients.removeAll()
        Task {
            await client?.close()
            await transferClient?.close()
        }
    }

    private func withSFTPTimeout<T: Sendable>(
        seconds: UInt64 = 35,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw SFTPBrowserTimeoutError.timedOut(seconds: seconds)
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    private func withSFTPTransferStallTimeout<T: Sendable>(
        seconds: UInt64 = 30,
        operation: @escaping @Sendable (
            @escaping @Sendable (SFTPTransferProgress) -> Void
        ) async throws -> T
    ) async throws -> T {
        let monitor = SFTPTransferStallMonitor()
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation { progress in
                    Task {
                        await monitor.record(progress)
                    }
                }
            }
            group.addTask {
                try await monitor.waitUntilStalled(seconds: seconds)
                throw CancellationError()
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    func refreshLocal() {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isHiddenKey,
        ]
        do {
            localEntries = try FileManager.default.contentsOfDirectory(
                at: localPath,
                includingPropertiesForKeys: keys
            )
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isHidden == true, !showsHiddenFiles {
                    return nil
                }
                return LocalFileEntry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: values?.isDirectory == true,
                    size: values?.fileSize.map(UInt64.init),
                    modifiedAt: values?.contentModificationDate
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            selectedLocalURLs = selectedLocalURLs.filter { selected in
                localEntries.contains { $0.url == selected }
            }
            localPathText = localPath.path
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
    }

    func refreshRemote(using state: AppState) async {
        guard client != nil else {
            await connect(using: state)
            return
        }
        isRemoteLoading = true
        errorMessage = nil
        defer {
            isRemoteLoading = false
        }
        do {
            let remotePath = remotePathText
            let entries = try await loadRemoteEntries(
                at: remotePath,
                timeoutSeconds: 35
            )
            applyRemoteEntries(entries, for: remotePath)
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
    }

    private func loadRemoteEntries(
        at remotePath: String,
        timeoutSeconds: UInt64
    ) async throws -> [SFTPDirectoryEntry] {
        guard let client else {
            throw SSH2SFTPBridgeError.closed
        }
        let entries = try await withSFTPTimeout(seconds: timeoutSeconds) {
            try await client.listDirectory(at: remotePath)
        }
        let showsHiddenFiles = showsHiddenFiles
        return await Task.detached(priority: .userInitiated) {
            Self.prepareRemoteEntries(
                entries,
                showsHiddenFiles: showsHiddenFiles
            )
        }.value
    }

    private func applyRemoteEntries(
        _ entries: [SFTPDirectoryEntry],
        for remotePath: String
    ) {
        remoteEntries = entries
        let names = Set(entries.map(\.name))
        selectedRemoteNames = selectedRemoteNames.filter { names.contains($0) }
        selectedRemoteName = nil
        remoteTreeChildren[remotePath] = entries
    }

    nonisolated private static func prepareRemoteEntries(
        _ entries: [SFTPDirectoryEntry],
        showsHiddenFiles: Bool
    ) -> [SFTPDirectoryEntry] {
        entries
            .filter { showsHiddenFiles || !$0.name.hasPrefix(".") }
            .sorted(by: Self.sortRemoteEntries)
    }

    func commitLocalPath() {
        let url = URL(fileURLWithPath: localPathText, isDirectory: true)
        navigateLocal(to: url)
    }

    func commitRemotePath(using state: AppState) async {
        await navigateRemote(to: remotePathText, using: state)
    }

    func openLocal(_ entry: LocalFileEntry) {
        if entry.isDirectory {
            navigateLocal(to: entry.url)
        }
    }

    func activateLocal(_ entry: LocalFileEntry) {
        if entry.isDirectory {
            navigateLocal(to: entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    func openRemote(_ entry: SFTPDirectoryEntry, using state: AppState) async {
        let path = remotePath(for: entry.name)
        await openRemote(entry, fullPath: path, using: state)
    }

    func openRemote(
        _ entry: SFTPDirectoryEntry,
        fullPath: String,
        using state: AppState
    ) async {
        if entry.name == ".." {
            await goUpRemote(using: state)
            return
        }
        let path = fullPath
        if entry.kind == .directory {
            await navigateRemote(to: path, using: state)
        } else if entry.kind == .file {
            await openRemoteText(entry, fullPath: path, using: state)
        }
    }

    func toggleRemoteTreeDirectory(
        _ entry: SFTPDirectoryEntry,
        fullPath: String,
        using state: AppState
    ) async {
        guard entry.kind == .directory else {
            return
        }
        if expandedRemoteTreePaths.contains(fullPath) {
            expandedRemoteTreePaths.remove(fullPath)
            return
        }
        expandedRemoteTreePaths.insert(fullPath)
        guard remoteTreeChildren[fullPath] == nil, client != nil else {
            return
        }
        do {
            remoteTreeChildren[fullPath] = try await loadRemoteEntries(
                at: fullPath,
                timeoutSeconds: 35
            )
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
    }

    func goBackLocal() {
        guard let previous = localBackStack.popLast() else {
            return
        }
        localForwardStack.append(localPath)
        localPath = previous
        refreshLocal()
    }

    func goForwardLocal() {
        guard let next = localForwardStack.popLast() else {
            return
        }
        localBackStack.append(localPath)
        localPath = next
        refreshLocal()
    }

    func goUpLocal() {
        navigateLocal(to: localPath.deletingLastPathComponent())
    }

    func goHomeLocal() {
        navigateLocal(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    func goToLocalTerminalDirectory(_ directory: String?) {
        let path = directory?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else {
            return
        }
        navigateLocal(
            to: URL(fileURLWithPath: path, isDirectory: true)
        )
    }

    func goBackRemote(using state: AppState) async {
        guard let previous = remoteBackStack.popLast() else {
            return
        }
        remoteForwardStack.append(remotePathText)
        remotePathText = previous
        await refreshRemote(using: state)
    }

    func goForwardRemote(using state: AppState) async {
        guard let next = remoteForwardStack.popLast() else {
            return
        }
        remoteBackStack.append(remotePathText)
        remotePathText = next
        await refreshRemote(using: state)
    }

    func goUpRemote(using state: AppState) async {
        let parent = remotePathText == "."
            ? ".."
            : NSString(string: remotePathText).deletingLastPathComponent
        await navigateRemote(to: parent.isEmpty ? "/" : parent, using: state)
    }

    func goHomeRemote(using state: AppState) async {
        await navigateRemote(to: ".", using: state)
    }

    func goToTerminalDirectory(
        fallback directory: String?,
        sourceSessionID: UUID?,
        using state: AppState
    ) async {
        let queriedPath: String?
        if let client, sourceConnectionID != nil {
            queriedPath = try? await client.terminalCurrentDirectory(
                sourceSessionID: sourceSessionID
            )
        } else {
            queriedPath = nil
        }
        let path = (queriedPath ?? directory)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else {
            return
        }
        await navigateRemote(to: path, using: state)
    }

    func addRemoteBookmark() {
        guard !remoteBookmarks.contains(remotePathText) else {
            return
        }
        remoteBookmarks.append(remotePathText)
        remoteBookmarks.sort()
    }

    func navigateRemoteBookmark(_ path: String, using state: AppState) async {
        await navigateRemote(to: path, using: state)
    }

    func chooseLocalDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = localPath
        if panel.runModal() == .OK, let url = panel.url {
            navigateLocal(to: url)
        }
    }

    func chooseFilesToUpload(using state: AppState) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = localPath
        if panel.runModal() == .OK {
            enqueueUploadBatch(panel.urls, using: state)
        }
    }

    func uploadSelectedLocal(using state: AppState) {
        let entries = selectedLocalEntries
        guard !entries.isEmpty else {
            return
        }
        enqueueUploadBatch(entries.map(\.url), using: state)
    }

    func uploadLocal(_ url: URL, using state: AppState) {
        enqueueUploadBatch([url], using: state)
    }

    func acceptLocalFileDrop(
        _ providers: [NSItemProvider],
        using state: AppState
    ) -> Bool {
        let providers = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !providers.isEmpty else {
            return false
        }
        let collector = SFTPDroppedURLCollector(count: providers.count)
        for (index, provider) in providers.enumerated() {
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                let urls = collector.store(url, at: index)
                guard let urls else {
                    return
                }
                Task { @MainActor in
                    self.enqueueUploadBatch(urls, using: state)
                }
            }
        }
        return true
    }

    func downloadSelectedRemote(using state: AppState) async {
        let entries = selectedRemoteEntries
        guard !entries.isEmpty else {
            return
        }
        if entries.count == 1, let entry = entries.first {
            await downloadRemote(entry, using: state)
            return
        }
        guard let destinationDirectory = chooseDownloadDirectory() else {
            return
        }
        for entry in entries {
            startRemoteDownload(
                entry,
                fullPath: remotePath(for: entry.name),
                localURL: destinationDirectory.appendingPathComponent(
                    entry.name,
                    isDirectory: entry.kind == .directory
                ),
                using: state
            )
        }
    }

    func downloadRemote(
        _ entry: SFTPDirectoryEntry,
        using state: AppState
    ) async {
        await downloadRemote(
            entry,
            fullPath: remotePath(for: entry.name),
            using: state
        )
    }

    func downloadRemote(
        _ entry: SFTPDirectoryEntry,
        fullPath: String,
        using state: AppState
    ) async {
        guard let destination = chooseDownloadDestination(for: entry) else {
            return
        }
        startRemoteDownload(
            entry,
            fullPath: fullPath,
            localURL: destination.url,
            overwriteConfirmed: destination.overwriteConfirmed,
            using: state
        )
    }

    private func startRemoteDownload(
        _ entry: SFTPDirectoryEntry,
        fullPath: String,
        localURL: URL,
        overwriteConfirmed: Bool = false,
        using state: AppState
    ) {
        if FileManager.default.fileExists(atPath: localURL.path) {
            if overwriteConfirmed {
                download(
                    remotePath: fullPath,
                    name: entry.name,
                    to: localURL,
                    using: state,
                    overwrite: true
                )
                return
            }
            enqueuePendingOverwrite(
                .download(
                    transferID: nil,
                    entry: entry,
                    remotePath: fullPath,
                    localURL: localURL
                ),
                using: state
            )
            return
        }
        download(
            remotePath: fullPath,
            name: entry.name,
            to: localURL,
            using: state,
            overwrite: false
        )
    }

    private func chooseDownloadDestination(
        for entry: SFTPDirectoryEntry
    ) -> (url: URL, overwriteConfirmed: Bool)? {
        if entry.kind == .directory {
            return chooseDownloadDirectory().map {
                (
                    $0.appendingPathComponent(
                        entry.name,
                        isDirectory: true
                    ),
                    false
                )
            }
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = Self.defaultDownloadDirectory
        panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK else {
            return nil
        }
        return panel.url.map { ($0, true) }
    }

    private func chooseDownloadDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.defaultDownloadDirectory
        guard panel.runModal() == .OK else {
            return nil
        }
        return panel.url
    }

    func requestDeleteSelectedRemote() {
        let entries = selectedRemoteEntries
        guard !entries.isEmpty else {
            return
        }
        pendingDelete = PendingSFTPDelete(
            targets: entries.map {
                SFTPDeleteTarget(
                    entry: $0,
                    path: remotePath(for: $0.name)
                )
            }
        )
    }

    func requestDeleteRemote(
        _ entry: SFTPDirectoryEntry,
        fullPath: String
    ) {
        pendingDelete = PendingSFTPDelete(
            targets: [
                SFTPDeleteTarget(entry: entry, path: fullPath),
            ]
        )
    }

    func confirmDelete(
        _ pendingDelete: PendingSFTPDelete,
        using state: AppState
    ) async {
        guard let client else {
            self.pendingDelete = nil
            return
        }
        do {
            for target in pendingDelete.targets {
                try await client.delete(
                    path: target.path,
                    kind: target.entry.kind
                )
            }
            await refreshRemote(using: state)
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
    }

    func startRename() {
        guard let entry = selectedRemoteEntry else {
            return
        }
        startRename(entry, fullPath: remotePath(for: entry.name))
    }

    func startRename(_ entry: SFTPDirectoryEntry, fullPath: String) {
        renameDraft = RemoteRenameDraft(
            path: fullPath,
            currentName: entry.name
        )
    }

    func renameRemoteItem(
        _ draft: RemoteRenameDraft,
        to newName: String,
        using state: AppState
    ) async {
        guard let client else {
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        do {
            let parent = NSString(string: draft.path).deletingLastPathComponent
            let destination = remoteJoin(parent.isEmpty ? "." : parent, trimmed)
            try await client.rename(from: draft.path, to: destination)
            renameDraft = nil
            await refreshRemote(using: state)
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
    }

    func startChmod() {
        guard let entry = selectedRemoteEntry else {
            return
        }
        startChmod(entry, fullPath: remotePath(for: entry.name))
    }

    func startChmod(_ entry: SFTPDirectoryEntry, fullPath: String) {
        chmodDraft = RemoteChmodDraft(
            path: fullPath,
            name: entry.name,
            permissions: String(format: "%o", entry.permissions.map { $0 & 0o777 } ?? 0o644)
        )
    }

    func chmodRemoteItem(
        _ draft: RemoteChmodDraft,
        permissions: String,
        using state: AppState
    ) async {
        guard let client,
              let value = UInt32(permissions, radix: 8)
        else {
            return
        }
        do {
            try await client.setPermissions(value, at: draft.path)
            chmodDraft = nil
            await refreshRemote(using: state)
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
    }

    func createRemoteFolder(using state: AppState) async {
        guard let client,
              let folderName = newFolderName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folderName.isEmpty
        else {
            return
        }
        do {
            try await client.createDirectory(at: remotePath(for: folderName))
            newFolderName = nil
            await refreshRemote(using: state)
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
    }

    func createRemoteFile(using state: AppState) async {
        guard let client,
              let fileName = newFileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fileName.isEmpty
        else {
            return
        }
        do {
            try await client.createFile(at: remotePath(for: fileName))
            newFileName = nil
            await refreshRemote(using: state)
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
    }

    func openSelectedRemoteText(using state: AppState) async {
        guard let entry = selectedRemoteFile else {
            return
        }
        await openRemoteText(entry, using: state)
    }

    func openRemoteText(_ entry: SFTPDirectoryEntry, using state: AppState) async {
        await openRemoteText(
            entry,
            fullPath: remotePath(for: entry.name),
            using: state
        )
    }

    func openRemoteText(
        _ entry: SFTPDirectoryEntry,
        fullPath: String,
        using state: AppState
    ) async {
        guard let client else {
            return
        }
        do {
            let text = try await client.readTextFile(at: fullPath)
            guard text.utf8.count <= 2 * 1_024 * 1_024 else {
                throw SFTPBrowserError.textFileTooLarge
            }
            textDraft = RemoteTextDraft(
                remotePath: fullPath,
                name: entry.name,
                text: text
            )
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
    }

    func saveTextDraft(
        _ draft: RemoteTextDraft,
        text: String,
        using state: AppState
    ) async {
        guard let client else {
            return
        }
        do {
            try await client.writeTextFile(
                text,
                at: draft.remotePath,
                overwrite: true
            )
            textDraft = nil
            await refreshRemote(using: state)
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
    }

    func confirmOverwrite(using state: AppState) {
        resolveOverwrite(.replace, applyToAll: false, using: state)
    }

    func dismissCurrentOverwrite(using state: AppState) {
        guard let pendingOverwrite else {
            return
        }
        if let batchID = pendingOverwrite.batchID {
            cancelUploadConflictBatch(batchID, using: state)
            return
        }
        resolveOverwrite(.skip, applyToAll: false, using: state)
    }

    func cancelUploadConflictBatch(
        _ batchID: UUID,
        using state: AppState
    ) {
        pendingUploadCandidatesByBatchID.removeValue(forKey: batchID)
        stopUploadBatch(batchID, using: state)
    }

    func resolveUploadConflictBatch(
        _ batchID: UUID,
        resolutions: [String: SFTPConflictResolution],
        using state: AppState
    ) {
        let candidates =
            pendingUploadCandidatesByBatchID.removeValue(forKey: batchID) ?? []
        let conflicts = pendingOverwrites.filter { $0.batchID == batchID }
        let conflictTransferIDs = Set(conflicts.compactMap(\.transferID))
        pendingOverwrites.removeAll { $0.batchID == batchID }

        Task {
            for conflict in conflicts {
                let resolution = resolutions[conflict.id] ?? .skip
                if resolution == .skip || resolution == .stop {
                    if let transferID = conflict.transferID {
                        state.finishFileTransfer(
                            id: transferID,
                            status: .cancelled
                        )
                        completeUploadTracking(transferID)
                    }
                    continue
                }
                await applyOverwriteResolution(
                    resolution,
                    to: conflict,
                    using: state
                )
            }

            for candidate in candidates
            where !conflictTransferIDs.contains(candidate.id)
            {
                guard uploadBatchIDsByTransferID[candidate.id] == batchID else {
                    continue
                }
                upload(
                    candidate.localURL,
                    to: candidate.remotePath,
                    using: state,
                    overwrite: false,
                    transferID: candidate.id,
                    batchID: batchID
                )
            }
        }
    }

    func enqueuePendingOverwrite(
        _ conflict: PendingSFTPOverwrite,
        using state: AppState
    ) {
        if let bucket = conflict.uploadConflictBucket,
           let resolution = uploadConflictDefaults[bucket]
        {
            if resolution == .skip {
                if let transferID = conflict.transferID {
                    state.finishFileTransfer(
                        id: transferID,
                        status: .cancelled
                    )
                    completeUploadTracking(transferID)
                }
            } else if resolution == .stop, let batchID = conflict.batchID {
                stopUploadBatch(batchID, using: state)
            } else {
                Task {
                    await applyOverwriteResolution(
                        resolution,
                        to: conflict,
                        using: state
                    )
                }
            }
            return
        }
        guard !pendingOverwrites.contains(where: { $0.id == conflict.id }) else {
            return
        }
        pendingOverwrites.append(conflict)
    }

    func resolveOverwrite(
        _ resolution: SFTPConflictResolution,
        applyToAll: Bool = false,
        using state: AppState
    ) {
        guard let pendingOverwrite else {
            return
        }

        if resolution == .stop {
            if let batchID = pendingOverwrite.batchID {
                stopUploadBatch(batchID, using: state)
            } else {
                pendingOverwrites.removeAll { $0.id == pendingOverwrite.id }
                if let transferID = pendingOverwrite.transferID {
                    cancelTransfer(transferID, state: state)
                }
            }
            return
        }

        let affected: [PendingSFTPOverwrite]
        if applyToAll, let bucket = pendingOverwrite.uploadConflictBucket {
            uploadConflictDefaults[bucket] = resolution
            affected = pendingOverwrites.filter {
                $0.uploadConflictBucket == bucket
            }
        } else {
            affected = [pendingOverwrite]
        }
        let affectedIDs = Set(affected.map(\.id))
        pendingOverwrites.removeAll { affectedIDs.contains($0.id) }

        if resolution == .skip {
            for conflict in affected {
                if let transferID = conflict.transferID {
                    state.finishFileTransfer(
                        id: transferID,
                        status: .cancelled
                    )
                    completeUploadTracking(transferID)
                }
            }
            return
        }

        Task {
            for conflict in affected {
                await applyOverwriteResolution(
                    resolution,
                    to: conflict,
                    using: state
                )
            }
        }
    }

    private func applyOverwriteResolution(
        _ resolution: SFTPConflictResolution,
        to conflict: PendingSFTPOverwrite,
        using state: AppState
    ) async {
        guard resolution != .stop, resolution != .skip else {
            return
        }
        guard resolution != .replace || conflict.canReplace else {
            if let transferID = conflict.transferID {
                state.finishFileTransfer(
                    id: transferID,
                    status: .failed(
                        AppLocalization.string(
                            "The existing item has a different type and cannot be replaced."
                        )
                    )
                )
                completeUploadTracking(transferID)
            }
            return
        }
        guard resolution != .merge || conflict.canMerge else {
            if let transferID = conflict.transferID {
                state.finishFileTransfer(
                    id: transferID,
                    status: .failed(
                        AppLocalization.string(
                            "Only two directories can be merged."
                        )
                    )
                )
                completeUploadTracking(transferID)
            }
            return
        }

        switch conflict {
        case let .upload(
            transferID,
            batchID,
            url,
            remotePath,
            existingEntry
        ):
            let destination = resolution == .duplicate
                ? await duplicateRemotePath(
                    remotePath,
                    isDirectory: conflict.isIncomingDirectory
                )
                : remotePath
            upload(
                url,
                to: destination,
                using: state,
                overwrite: resolution == .replace || resolution == .merge,
                transferID: transferID,
                batchID: batchID,
                replaceExistingTarget:
                    resolution == .replace
                    && conflict.isIncomingDirectory
                    && existingEntry?.kind == .directory
            )
        case let .download(transferID, entry, remotePath, localURL):
            let destination = resolution == .duplicate
                ? duplicateLocalURL(
                    localURL,
                    isDirectory: conflict.isIncomingDirectory
                )
                : localURL
            download(
                remotePath: remotePath,
                name: entry.name,
                to: destination,
                using: state,
                overwrite: resolution == .replace || resolution == .merge,
                transferID: transferID
            )
        }
    }

    func cancelTransfer(_ id: UUID, state: AppState) {
        pausedTransferIDs.remove(id)
        transferTasks[id]?.cancel()
        transferTasks.removeValue(forKey: id)
        transferClients.removeValue(forKey: id)
        pendingOverwrites.removeAll { $0.transferID == id }
        state.finishFileTransfer(id: id, status: .cancelled)
        completeUploadTracking(id)
    }

    func retryTransfer(_ record: FileTransferRecord, state: AppState) {
        switch record.kind {
        case .upload:
            let batchID = UUID()
            upload(
                URL(fileURLWithPath: record.sourcePath),
                to: record.destinationPath,
                using: state,
                overwrite: false,
                transferID: record.id,
                batchID: batchID
            )
        case .download:
            download(
                remotePath: record.sourcePath,
                name: record.name,
                to: URL(fileURLWithPath: record.destinationPath),
                using: state,
                overwrite: false,
                transferID: record.id
            )
        }
    }

    func pauseTransfer(_ id: UUID, state: AppState) {
        guard let client = transferClients[id],
              transferTasks[id] != nil
        else {
            return
        }
        Task { [weak self] in
            do {
                try await client.pauseTransfer(id: id)
                self?.pausedTransferIDs.insert(id)
                state.setFileTransferStatus(id: id, status: .paused)
            } catch {
                self?.errorMessage = AppLocalization.errorDescription(error)
            }
        }
    }

    func resumeTransfer(_ record: FileTransferRecord, state: AppState) {
        guard let client = transferClients[record.id],
              transferTasks[record.id] != nil
        else {
            return
        }
        Task { [weak self] in
            do {
                try await client.resumeTransfer(id: record.id)
                self?.pausedTransferIDs.remove(record.id)
                state.setFileTransferStatus(id: record.id, status: .running)
            } catch {
                self?.errorMessage = AppLocalization.errorDescription(error)
            }
        }
    }

    func pasteToRemote(using state: AppState) async {
        guard let clipboard else {
            return
        }
        switch clipboard.source {
        case .local(let urls):
            enqueueUploadBatch(
                urls,
                removesSourcesOnSuccess: clipboard.operation == .cut,
                using: state
            )
            if clipboard.operation == .cut {
                self.clipboard = nil
            }
        case let .remote(sourcePath, entries):
            guard let client else {
                return
            }
            do {
                for entry in entries {
                    let source = remoteJoin(sourcePath, entry.name)
                    let destination = remotePath(for: entry.name)
                    if clipboard.operation == .cut {
                        if source != destination {
                            try await client.rename(from: source, to: destination)
                        }
                    } else {
                        try await copyRemoteEntry(
                            entry,
                            from: source,
                            to: destination,
                            using: state
                        )
                    }
                }
                if clipboard.operation == .cut {
                    self.clipboard = nil
                }
                await refreshRemote(using: state)
            } catch {
                errorMessage = AppLocalization.errorDescription(error)
            }
        }
    }

    func pasteToLocal(using state: AppState) async {
        guard let clipboard else {
            return
        }
        switch clipboard.source {
        case .local:
            return
        case let .remote(sourcePath, entries):
            for entry in entries {
                let source = remoteJoin(sourcePath, entry.name)
                let destination = localPath.appendingPathComponent(entry.name)
                if FileManager.default.fileExists(atPath: destination.path) {
                    enqueuePendingOverwrite(
                        .download(
                            transferID: nil,
                            entry: entry,
                            remotePath: source,
                            localURL: destination
                        ),
                        using: state
                    )
                } else {
                    download(
                        remotePath: source,
                        name: entry.name,
                        to: destination,
                        using: state,
                        overwrite: false
                    )
                }
            }
            if clipboard.operation == .cut {
                self.clipboard = nil
            }
        }
    }

    func openRemoteWithDefaultApp(
        _ entry: SFTPDirectoryEntry,
        fullPath: String,
        using state: AppState
    ) async {
        let extensionKey = fileExtensionKey(for: entry.name)
        let associatedApp = extensionKey.flatMap { fileAssociations[$0] }
        await openRemoteExternally(
            entry,
            fullPath: fullPath,
            appURL: associatedApp,
            appName: associatedApp?.deletingPathExtension().lastPathComponent
                ?? "Default App",
            using: state
        )
    }

    func openRemoteWithSelectedApp(
        _ entry: SFTPDirectoryEntry,
        fullPath: String,
        using state: AppState
    ) async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let appURL = panel.url else {
            return
        }
        if let extensionKey = fileExtensionKey(for: entry.name) {
            fileAssociations[extensionKey] = appURL
        }
        await openRemoteExternally(
            entry,
            fullPath: fullPath,
            appURL: appURL,
            appName: appURL.deletingPathExtension().lastPathComponent,
            using: state
        )
    }

    private func copyRemoteEntry(
        _ entry: SFTPDirectoryEntry,
        from source: String,
        to destination: String,
        using state: AppState
    ) async throws {
        guard let client else {
            return
        }
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermPilot-sftp-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        let tempURL = tempRoot.appendingPathComponent(entry.name)
        _ = try await client.download(
            remotePath: source,
            to: tempURL,
            overwrite: true,
            options: SFTPPreferences.transferOptions
        )
        _ = try await client.upload(
            localURL: tempURL,
            to: destination,
            overwrite: false,
            options: SFTPPreferences.transferOptions
        )
        state.recordFileTransfer(
            FileTransferRecord(
                kind: .upload,
                name: entry.name,
                sourcePath: source,
                destinationPath: destination,
                status: .succeeded,
                finishedAt: Date()
            )
        )
    }

    private func openRemoteExternally(
        _ entry: SFTPDirectoryEntry,
        fullPath: String,
        appURL: URL?,
        appName: String,
        using state: AppState
    ) async {
        guard let client else {
            return
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermPilot-open-\(UUID().uuidString)-\(entry.name)")
        do {
            _ = try await client.download(
                remotePath: fullPath,
                to: tempURL,
                overwrite: true,
                options: SFTPPreferences.transferOptions
            )
            let modifiedAt = localModificationDate(tempURL)
            if let appURL {
                let configuration = NSWorkspace.OpenConfiguration()
                try await NSWorkspace.shared.open(
                    [tempURL],
                    withApplicationAt: appURL,
                    configuration: configuration
                )
            } else {
                NSWorkspace.shared.open(tempURL)
            }
            if autoSyncExternalEdits {
                externalEditSessions.append(
                    ExternalEditSession(
                        remotePath: fullPath,
                        localURL: tempURL,
                        displayName: entry.name,
                        appName: appName,
                        lastSyncedAt: modifiedAt
                    )
                )
                ensureExternalEditTimer(state: state)
            }
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
    }

    private func ensureExternalEditTimer(state: AppState) {
        guard externalEditTimer == nil else {
            return
        }
        externalEditTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self, weak state] _ in
            guard let self, let state else {
                return
            }
            Task { @MainActor in
                await self.syncExternalEdits(using: state)
            }
        }
    }

    private func syncExternalEdits(using state: AppState) async {
        guard autoSyncExternalEdits, let client else {
            return
        }
        var sessions = externalEditSessions
        for index in sessions.indices {
            let session = sessions[index]
            guard FileManager.default.fileExists(atPath: session.localURL.path),
                  let modifiedAt = localModificationDate(session.localURL)
            else {
                continue
            }
            if let last = session.lastSyncedAt, modifiedAt <= last {
                continue
            }
            do {
                _ = try await client.upload(
                    localURL: session.localURL,
                    to: session.remotePath,
                    overwrite: true,
                    options: SFTPPreferences.transferOptions
                )
                sessions[index].lastSyncedAt = modifiedAt
                state.recordFileTransfer(
                    FileTransferRecord(
                        kind: .upload,
                        name: session.displayName,
                        sourcePath: session.localURL.path,
                        destinationPath: session.remotePath,
                        status: .succeeded,
                        finishedAt: Date()
                    )
                )
                await refreshRemote(using: state)
            } catch {
                errorMessage = AppLocalization.errorDescription(error)
            }
        }
        externalEditSessions = sessions
    }

    private func localModificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    private func fileExtensionKey(for filename: String) -> String? {
        let value = NSString(string: filename).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value.isEmpty ? nil : value
    }

    private func navigateLocal(to url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue
        else {
            errorMessage = "The selected local path is not a folder."
            return
        }
        localBackStack.append(localPath)
        localForwardStack.removeAll()
        localPath = url
        selectedLocalURL = nil
        selectedLocalURLs.removeAll()
        refreshLocal()
    }

    private func navigateRemote(to path: String, using state: AppState) async {
        guard let client else {
            return
        }
        do {
            let resolved = try await client.realPath(path)
            remoteBackStack.append(remotePathText)
            remoteForwardStack.removeAll()
            remotePathText = resolved
            selectedRemoteName = nil
            selectedRemoteNames.removeAll()
            expandedRemoteTreePaths.removeAll()
            remoteTreeChildren.removeAll()
            await refreshRemote(using: state)
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
    }

    private func enqueueUploadBatch(
        _ urls: [URL],
        removesSourcesOnSuccess: Bool = false,
        using state: AppState
    ) {
        guard let client, !urls.isEmpty else {
            return
        }
        let batchID = UUID()
        let candidates = urls.map { url in
            let values = try? url.resourceValues(
                forKeys: [
                    .fileSizeKey,
                ]
            )
            return SFTPUploadCandidate(
                id: UUID(),
                localURL: url,
                remotePath: remotePath(for: url.lastPathComponent),
                size: values?.fileSize.map(UInt64.init)
            )
        }

        for candidate in candidates {
            registerUploadTransfer(candidate.id, batchID: batchID)
            if removesSourcesOnSuccess {
                uploadSourcesToDeleteAfterSuccess[candidate.id] =
                    candidate.localURL
            }
            transferIDs.insert(candidate.id)
            state.recordFileTransfer(
                FileTransferRecord(
                    id: candidate.id,
                    kind: .upload,
                    name: candidate.localURL.lastPathComponent,
                    sourcePath: candidate.localURL.path,
                    destinationPath: candidate.remotePath,
                    totalBytes: candidate.size,
                    supportsPause: supportsResumablePause,
                    status: .queued
                )
            )
        }

        Task { [weak self] in
            var existingEntries: [UUID: SFTPDirectoryEntry] = [:]
            await withTaskGroup(
                of: (UUID, SFTPDirectoryEntry?).self
            ) { group in
                for candidate in candidates {
                    group.addTask {
                        (
                            candidate.id,
                            try? await client.stat(candidate.remotePath)
                        )
                    }
                }
                for await (id, entry) in group {
                    if let entry {
                        existingEntries[id] = entry
                    }
                }
            }

            guard let self else {
                return
            }
            for candidate in candidates {
                guard self.uploadBatchIDsByTransferID[candidate.id] == batchID,
                      let existingEntry = existingEntries[candidate.id]
                else {
                    continue
                }
                let message = AppLocalization.string(
                    "Remote path already exists."
                )
                state.setFileTransferStatus(
                    id: candidate.id,
                    status: .attention(message),
                    totalBytes: candidate.size
                )
                self.enqueuePendingOverwrite(
                    .upload(
                        transferID: candidate.id,
                        batchID: batchID,
                        localURL: candidate.localURL,
                        remotePath: candidate.remotePath,
                        existingEntry: existingEntry
                    ),
                    using: state
                )
            }

            if self.pendingOverwrites.contains(where: { $0.batchID == batchID }) {
                self.pendingUploadCandidatesByBatchID[batchID] = candidates
                return
            }

            for candidate in candidates where existingEntries[candidate.id] == nil {
                guard self.uploadBatchIDsByTransferID[candidate.id] == batchID else {
                    continue
                }
                self.upload(
                    candidate.localURL,
                    to: candidate.remotePath,
                    using: state,
                    overwrite: false,
                    transferID: candidate.id,
                    batchID: batchID
                )
            }
        }
    }

    private func registerUploadTransfer(_ id: UUID, batchID: UUID) {
        if let previousBatchID = uploadBatchIDsByTransferID[id],
           previousBatchID != batchID
        {
            uploadTransferIDsByBatchID[previousBatchID]?.remove(id)
        }
        uploadBatchIDsByTransferID[id] = batchID
        uploadTransferIDsByBatchID[batchID, default: []].insert(id)
    }

    private func completeUploadTracking(
        _ id: UUID,
        removeSourceOnSuccess: Bool = false
    ) {
        let sourceToDelete =
            uploadSourcesToDeleteAfterSuccess.removeValue(forKey: id)
        if removeSourceOnSuccess, let sourceToDelete {
            try? FileManager.default.removeItem(at: sourceToDelete)
            refreshLocal()
        }
        guard let batchID = uploadBatchIDsByTransferID.removeValue(forKey: id) else {
            return
        }
        uploadTransferIDsByBatchID[batchID]?.remove(id)
        guard uploadTransferIDsByBatchID[batchID]?.isEmpty != false else {
            return
        }
        uploadTransferIDsByBatchID.removeValue(forKey: batchID)
        pendingUploadCandidatesByBatchID.removeValue(forKey: batchID)
        uploadConflictDefaults = uploadConflictDefaults.filter {
            $0.key.batchID != batchID
        }
    }

    private func stopUploadBatch(_ batchID: UUID, using state: AppState) {
        let pendingIDs = Set(
            pendingOverwrites.compactMap { conflict in
                conflict.batchID == batchID ? conflict.transferID : nil
            }
        )
        let transferIDs =
            (uploadTransferIDsByBatchID[batchID] ?? []).union(pendingIDs)
        pendingUploadCandidatesByBatchID.removeValue(forKey: batchID)
        pendingOverwrites.removeAll { $0.batchID == batchID }
        for transferID in transferIDs {
            cancelTransfer(transferID, state: state)
        }
        uploadConflictDefaults = uploadConflictDefaults.filter {
            $0.key.batchID != batchID
        }
    }

    private func upload(
        _ url: URL,
        to destination: String,
        using state: AppState,
        overwrite: Bool,
        transferID: UUID? = nil,
        batchID: UUID? = nil,
        replaceExistingTarget: Bool = false
    ) {
        guard client != nil else {
            return
        }
        let id = transferID ?? UUID()
        let batchID =
            batchID
            ?? uploadBatchIDsByTransferID[id]
            ?? UUID()
        registerUploadTransfer(id, batchID: batchID)
        transferIDs.insert(id)
        if transferID == nil {
            state.recordFileTransfer(
                FileTransferRecord(
                    id: id,
                    kind: .upload,
                    name: url.lastPathComponent,
                    sourcePath: url.path,
                    destinationPath: destination,
                    supportsPause: supportsResumablePause
                )
            )
        } else {
            state.restartFileTransfer(
                id: id,
                destinationPath: destination,
                name: NSString(string: destination).lastPathComponent
            )
        }
        let task = Task { [weak self] in
            var existingConflictEntry: SFTPDirectoryEntry?
            do {
                guard let self else {
                    throw CancellationError()
                }
                let transferClient = try await self.acquireTransferClient(
                    for: id,
                    using: state
                )
                let result: SFTPTransferResult
                do {
                    if replaceExistingTarget,
                       let existing = try? await transferClient.stat(destination)
                    {
                        try await transferClient.delete(
                            path: destination,
                            kind: existing.kind
                        )
                    }
                    result = try await withSFTPTransferStallTimeout {
                        recordProgress in
                        try await transferClient.upload(
                            localURL: url,
                            to: destination,
                            overwrite: overwrite,
                            transferID: id,
                            options: SFTPPreferences.transferOptions
                        ) { progress in
                            recordProgress(progress)
                            Task { @MainActor in
                                state.updateFileTransfer(
                                    id: id,
                                    bytesTransferred: progress.bytesTransferred,
                                    totalBytes: progress.totalBytes
                                )
                            }
                        }
                    }
                } catch {
                    if !overwrite,
                       error.localizedDescription
                        .localizedCaseInsensitiveContains("exists")
                    {
                        existingConflictEntry = try? await transferClient.stat(
                            destination
                        )
                    }
                    await self.discardFailedTransferClient(
                        transferClient,
                        for: id
                    )
                    throw error
                }
                self.releaseTransferClient(for: id)
                await MainActor.run {
                    self.pausedTransferIDs.remove(id)
                    state.finishFileTransfer(
                        id: id,
                        status: .succeeded,
                        bytesTransferred: result.bytesTransferred
                    )
                    self.transferTasks.removeValue(forKey: id)
                    self.completeUploadTracking(
                        id,
                        removeSourceOnSuccess: true
                    )
                    Task {
                        await self.refreshRemote(using: state)
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self?.pausedTransferIDs.contains(id) == true {
                        state.setFileTransferStatus(id: id, status: .paused)
                    } else {
                        state.finishFileTransfer(id: id, status: .cancelled)
                        self?.completeUploadTracking(id)
                    }
                    self?.transferTasks.removeValue(forKey: id)
                }
            } catch {
                await MainActor.run {
                    let localizedError = AppLocalization.errorDescription(error)
                    self?.pausedTransferIDs.remove(id)
                    if !overwrite,
                       error.localizedDescription.localizedCaseInsensitiveContains("exists")
                    {
                        state.setFileTransferStatus(
                            id: id,
                            status: .attention(localizedError)
                        )
                        if let self {
                            self.enqueuePendingOverwrite(
                                .upload(
                                    transferID: id,
                                    batchID: batchID,
                                    localURL: url,
                                    remotePath: destination,
                                    existingEntry: existingConflictEntry
                                ),
                                using: state
                            )
                        }
                    } else {
                        state.finishFileTransfer(
                            id: id,
                            status: .failed(localizedError)
                        )
                        self?.errorMessage = localizedError
                        self?.completeUploadTracking(id)
                    }
                    self?.transferTasks.removeValue(forKey: id)
                }
            }
        }
        transferTasks[id] = task
    }

    private func download(
        _ entry: SFTPDirectoryEntry,
        to localURL: URL,
        using state: AppState,
        overwrite: Bool
    ) {
        download(
            remotePath: remotePath(for: entry.name),
            name: entry.name,
            to: localURL,
            using: state,
            overwrite: overwrite
        )
    }

    private func download(
        remotePath: String,
        name: String,
        to localURL: URL,
        using state: AppState,
        overwrite: Bool,
        transferID: UUID? = nil
    ) {
        guard client != nil else {
            return
        }
        let id = transferID ?? UUID()
        transferIDs.insert(id)
        if transferID == nil {
            state.recordFileTransfer(
                FileTransferRecord(
                    id: id,
                    kind: .download,
                    name: name,
                    sourcePath: remotePath,
                    destinationPath: localURL.path,
                    supportsPause: supportsResumablePause
                )
            )
        } else {
            state.restartFileTransfer(
                id: id,
                destinationPath: localURL.path
            )
        }
        let task = Task { [weak self] in
            do {
                guard let self else {
                    throw CancellationError()
                }
                let transferClient = try await self.acquireTransferClient(
                    for: id,
                    using: state
                )
                let result: SFTPTransferResult
                do {
                    result = try await withSFTPTransferStallTimeout {
                        recordProgress in
                        try await transferClient.download(
                            remotePath: remotePath,
                            to: localURL,
                            overwrite: overwrite,
                            transferID: id,
                            options: SFTPPreferences.transferOptions
                        ) { progress in
                            recordProgress(progress)
                            Task { @MainActor in
                                state.updateFileTransfer(
                                    id: id,
                                    bytesTransferred: progress.bytesTransferred,
                                    totalBytes: progress.totalBytes
                                )
                            }
                        }
                    }
                } catch {
                    await self.discardFailedTransferClient(
                        transferClient,
                        for: id
                    )
                    throw error
                }
                self.releaseTransferClient(for: id)
                await MainActor.run {
                    self.pausedTransferIDs.remove(id)
                    state.finishFileTransfer(
                        id: id,
                        status: .succeeded,
                        bytesTransferred: result.bytesTransferred
                    )
                    self.transferTasks.removeValue(forKey: id)
                    self.refreshLocal()
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self?.pausedTransferIDs.contains(id) == true {
                        state.setFileTransferStatus(id: id, status: .paused)
                    } else {
                        state.finishFileTransfer(id: id, status: .cancelled)
                    }
                    self?.transferTasks.removeValue(forKey: id)
                }
            } catch {
                await MainActor.run {
                    let localizedError = AppLocalization.errorDescription(error)
                    self?.pausedTransferIDs.remove(id)
                    state.finishFileTransfer(
                        id: id,
                        status: .failed(localizedError)
                    )
                    self?.transferTasks.removeValue(forKey: id)
                    self?.errorMessage = localizedError
                }
            }
        }
        transferTasks[id] = task
    }

    private func acquireTransferClient(
        for transferID: UUID,
        using state: AppState
    ) async throws -> SSH2SFTPBridgeClient {
        transferClientIdleTask?.cancel()
        transferClientIdleTask = nil
        if let transferClient {
            transferClients[transferID] = transferClient
            return transferClient
        }
        let generation = transferClientGeneration
        let openingTask: Task<SSH2SFTPBridgeClient, any Error>
        if let transferClientOpeningTask {
            openingTask = transferClientOpeningTask
        } else {
            let elevatesOperations =
                host.serverToolsUseRoot
                && host.username != "root"
            openingTask = Task { @MainActor in
                let client = try state.makeSFTPClient(
                    for: host,
                    elevatesOperations: elevatesOperations
                )
                do {
                    try await client.waitUntilReady()
                    return client
                } catch {
                    await client.close()
                    throw error
                }
            }
            transferClientOpeningTask = openingTask
        }

        let openedClient: SSH2SFTPBridgeClient
        do {
            openedClient = try await openingTask.value
        } catch {
            if generation == transferClientGeneration {
                transferClientOpeningTask = nil
            }
            throw error
        }
        guard generation == transferClientGeneration else {
            await openedClient.close()
            throw CancellationError()
        }
        transferClientOpeningTask = nil
        if transferClient == nil {
            transferClient = openedClient
        }
        let client = transferClient ?? openedClient
        transferClients[transferID] = client
        return client
    }

    private func discardFailedTransferClient(
        _ failedClient: SSH2SFTPBridgeClient,
        for transferID: UUID
    ) async {
        transferClients.removeValue(forKey: transferID)
        guard transferClients.isEmpty,
              transferClient === failedClient
        else {
            return
        }
        transferClientIdleTask?.cancel()
        transferClientIdleTask = nil
        transferClient = nil
        transferClientGeneration &+= 1
        await failedClient.close()
    }

    private func releaseTransferClient(for transferID: UUID) {
        transferClients.removeValue(forKey: transferID)
        guard transferClients.isEmpty,
              let transferClient
        else {
            return
        }
        transferClientIdleTask?.cancel()
        let idleSeconds = SFTPPreferences.transferConnectionIdleSeconds
        guard idleSeconds > 0 else {
            transferClientIdleTask = nil
            return
        }
        let generation = transferClientGeneration
        transferClientIdleTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(idleSeconds) * 1_000_000_000
            )
            guard !Task.isCancelled,
                  let self,
                  generation == self.transferClientGeneration,
                  self.transferClients.isEmpty,
                  self.transferClient === transferClient
            else {
                return
            }
            self.transferClient = nil
            self.transferClientIdleTask = nil
            self.transferClientGeneration &+= 1
            await transferClient.close()
        }
    }

    func remotePath(for name: String) -> String {
        remoteJoin(remotePathText, name)
    }

    private func remoteJoin(_ base: String, _ name: String) -> String {
        if base.isEmpty || base == "." {
            return name
        }
        if base == "/" {
            return "/\(name)"
        }
        if base.hasSuffix("/") {
            return "\(base)\(name)"
        }
        return "\(base)/\(name)"
    }

    nonisolated private static func sortRemoteEntries(
        _ lhs: SFTPDirectoryEntry,
        _ rhs: SFTPDirectoryEntry
    ) -> Bool {
        if lhs.kind == .directory, rhs.kind != .directory {
            return true
        }
        if lhs.kind != .directory, rhs.kind == .directory {
            return false
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            == .orderedAscending
    }

    private func duplicateRemotePath(
        _ path: String,
        isDirectory: Bool
    ) async -> String {
        let parent = NSString(string: path).deletingLastPathComponent
        let name = NSString(string: path).lastPathComponent
        for index in 1 ..< 1_000 {
            let duplicateName = Self.duplicateName(
                for: name,
                isDirectory: isDirectory,
                index: index
            )
            let candidate = remoteJoin(
                parent.isEmpty ? "." : parent,
                duplicateName
            )
            guard let client else {
                return candidate
            }
            if (try? await client.stat(candidate)) == nil {
                return candidate
            }
        }
        let fallback = Self.duplicateName(
            for: name,
            isDirectory: isDirectory,
            suffix: String(Int(Date().timeIntervalSince1970))
        )
        return remoteJoin(parent.isEmpty ? "." : parent, fallback)
    }

    private func duplicateLocalURL(
        _ url: URL,
        isDirectory: Bool
    ) -> URL {
        let parent = url.deletingLastPathComponent()
        for index in 1 ..< 1_000 {
            let name = Self.duplicateName(
                for: url.lastPathComponent,
                isDirectory: isDirectory,
                index: index
            )
            let candidate = parent.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return parent.appendingPathComponent(
            Self.duplicateName(
                for: url.lastPathComponent,
                isDirectory: isDirectory,
                suffix: String(Int(Date().timeIntervalSince1970))
            )
        )
    }

    private static func duplicateName(
        for name: String,
        isDirectory: Bool,
        index: Int
    ) -> String {
        duplicateName(
            for: name,
            isDirectory: isDirectory,
            suffix: index == 1 ? "copy" : "copy \(index)"
        )
    }

    private static func duplicateName(
        for name: String,
        isDirectory: Bool,
        suffix: String
    ) -> String {
        let ext = isDirectory ? "" : NSString(string: name).pathExtension
        let stem = ext.isEmpty
            ? name
            : NSString(string: name).deletingPathExtension
        return ext.isEmpty
            ? "\(stem) (\(suffix))"
            : "\(stem) (\(suffix)).\(ext)"
    }

}

struct LocalFileEntry: Identifiable, Equatable {
    var id: String { url.path }
    var url: URL
    var name: String
    var isDirectory: Bool
    var size: UInt64?
    var modifiedAt: Date?
}

enum SFTPBrowserViewMode: String, CaseIterable, Identifiable {
    case list
    case tree

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .list:
            "List"
        case .tree:
            "Tree"
        }
    }
}

enum SFTPClipboardOperation {
    case copy
    case cut
}

enum SFTPClipboardSource {
    case local([URL])
    case remote(path: String, entries: [SFTPDirectoryEntry])
}

struct SFTPClipboard {
    var operation: SFTPClipboardOperation
    var source: SFTPClipboardSource
}

struct RemoteTreeRow: Identifiable {
    var entry: SFTPDirectoryEntry
    var path: String
    var depth: Int
    var isExpanded: Bool

    var id: String { path }
}

struct ExternalEditSession: Identifiable, Equatable {
    var id = UUID()
    var remotePath: String
    var localURL: URL
    var displayName: String
    var appName: String
    var lastSyncedAt: Date?
}

struct RemoteRenameDraft: Identifiable {
    var id: String { path }
    var path: String
    var currentName: String
}

struct RemoteChmodDraft: Identifiable {
    var id: String { path }
    var path: String
    var name: String
    var permissions: String
}

struct RemoteTextDraft: Identifiable {
    var id: String { remotePath }
    var remotePath: String
    var name: String
    var text: String
}

struct SFTPDeleteTarget: Identifiable {
    var id: String { path }
    var entry: SFTPDirectoryEntry
    var path: String
}

struct PendingSFTPDelete: Identifiable {
    var targets: [SFTPDeleteTarget]

    var id: String {
        targets.map(\.path).joined(separator: "\n")
    }

    var message: String {
        guard targets.count != 1 else {
            let target = targets[0]
            return "\(AppLocalization.string("This will permanently delete:"))\n\(target.path)"
        }
        return String(
            format: AppLocalization.string("This will permanently delete %@ selected items."),
            String(targets.count)
        )
    }
}

enum SFTPConflictResolution: CaseIterable, Hashable, Sendable {
    case stop
    case skip
    case replace
    case duplicate
    case merge

    var batchTitle: String {
        switch self {
        case .stop:
            AppLocalization.string("Stop")
        case .skip:
            AppLocalization.string("Skip")
        case .replace:
            AppLocalization.string("Overwrite")
        case .duplicate:
            AppLocalization.string("Create Copy")
        case .merge:
            AppLocalization.string("Merge")
        }
    }
}

struct SFTPUploadConflictBucket: Hashable, Sendable {
    var batchID: UUID
    var incomingKind: String
    var existingKind: String
}

enum PendingSFTPOverwrite: Identifiable {
    case upload(
        transferID: UUID,
        batchID: UUID,
        localURL: URL,
        remotePath: String,
        existingEntry: SFTPDirectoryEntry?
    )
    case download(
        transferID: UUID?,
        entry: SFTPDirectoryEntry,
        remotePath: String,
        localURL: URL
    )

    var transferID: UUID? {
        switch self {
        case .upload(let transferID, _, _, _, _):
            transferID
        case .download(let transferID, _, _, _):
            transferID
        }
    }

    var batchID: UUID? {
        switch self {
        case .upload(_, let batchID, _, _, _):
            batchID
        case .download:
            nil
        }
    }

    var id: String {
        switch self {
        case .upload(let transferID, _, _, _, _):
            "upload-\(transferID.uuidString)"
        case .download(let transferID, let entry, let remotePath, let localURL):
            transferID.map {
                "download-\($0.uuidString)"
            } ?? "download-\(entry.name)-\(remotePath)-\(localURL.path)"
        }
    }

    var message: String {
        switch self {
        case .upload(_, _, _, let remotePath, _):
            "\(AppLocalization.string("Remote path already exists:"))\n\(remotePath)"
        case .download(_, _, _, let localURL):
            "\(AppLocalization.string("Local path already exists:"))\n\(localURL.path)"
        }
    }

    var fileName: String {
        switch self {
        case .upload(_, _, let localURL, _, _):
            localURL.lastPathComponent
        case .download(_, let entry, _, _):
            entry.name
        }
    }

    var sourcePath: String {
        switch self {
        case .upload(_, _, let localURL, _, _):
            localURL.path
        case .download(_, _, let remotePath, _):
            remotePath
        }
    }

    var destinationPath: String {
        switch self {
        case .upload(_, _, _, let remotePath, _):
            remotePath
        case .download(_, _, _, let localURL):
            localURL.path
        }
    }

    var incomingKind: SFTPEntryKind {
        switch self {
        case .upload(_, _, let localURL, _, _):
            Self.localKind(at: localURL) ?? .file
        case .download(_, let entry, _, _):
            entry.kind
        }
    }

    var existingKind: SFTPEntryKind? {
        switch self {
        case .upload(_, _, _, _, let existingEntry):
            existingEntry?.kind
        case .download(_, _, _, let localURL):
            Self.localKind(at: localURL)
        }
    }

    var isIncomingDirectory: Bool {
        incomingKind == .directory
    }

    var canReplace: Bool {
        guard let existingKind else {
            return true
        }
        return (existingKind == .directory) == isIncomingDirectory
    }

    var canMerge: Bool {
        isIncomingDirectory && existingKind == .directory
    }

    var availableBatchResolutions: [SFTPConflictResolution] {
        var resolutions: [SFTPConflictResolution] = [.skip]
        if canReplace {
            resolutions.append(.replace)
        }
        resolutions.append(.duplicate)
        if canMerge {
            resolutions.append(.merge)
        }
        return resolutions
    }

    var existingKindTitle: String {
        switch existingKind {
        case .directory:
            AppLocalization.string("Directory")
        case .file:
            AppLocalization.string("File")
        case .symbolicLink:
            AppLocalization.string("Symbolic Link")
        case .other, nil:
            AppLocalization.string("Other")
        }
    }

    var existingSize: UInt64? {
        switch self {
        case .upload(_, _, _, _, let existingEntry):
            existingEntry?.size
        case .download(_, _, _, let localURL):
            Self.localValues(at: localURL)?.fileSize.map(UInt64.init)
        }
    }

    var newSize: UInt64? {
        switch self {
        case .upload(_, _, let localURL, _, _):
            Self.localValues(at: localURL)?.fileSize.map(UInt64.init)
        case .download(_, let entry, _, _):
            entry.size
        }
    }

    var existingModifiedAt: Date? {
        switch self {
        case .upload(_, _, _, _, let existingEntry):
            existingEntry?.modifiedAt
        case .download(_, _, _, let localURL):
            Self.localValues(at: localURL)?.contentModificationDate
        }
    }

    var newModifiedAt: Date? {
        switch self {
        case .upload(_, _, let localURL, _, _):
            Self.localValues(at: localURL)?.contentModificationDate
        case .download(_, let entry, _, _):
            entry.modifiedAt
        }
    }

    var uploadConflictBucket: SFTPUploadConflictBucket? {
        guard let batchID else {
            return nil
        }
        return SFTPUploadConflictBucket(
            batchID: batchID,
            incomingKind: incomingKind.rawValue,
            existingKind: existingKind?.rawValue ?? "unknown"
        )
    }

    private static func localKind(at url: URL) -> SFTPEntryKind? {
        guard let values = localValues(at: url) else {
            return nil
        }
        if values.isDirectory == true {
            return .directory
        }
        if values.isSymbolicLink == true {
            return .symbolicLink
        }
        return .file
    }

    private static func localValues(at url: URL) -> URLResourceValues? {
        try? url.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ]
        )
    }
}

private struct SFTPUploadCandidate: Sendable {
    var id: UUID
    var localURL: URL
    var remotePath: String
    var size: UInt64?
}

private final class SFTPDroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL?]
    private var remaining: Int

    init(count: Int) {
        urls = Array(repeating: nil, count: count)
        remaining = count
    }

    func store(_ url: URL?, at index: Int) -> [URL]? {
        lock.lock()
        defer { lock.unlock() }
        guard urls.indices.contains(index), remaining > 0 else {
            return nil
        }
        urls[index] = url
        remaining -= 1
        return remaining == 0 ? urls.compactMap(\.self) : nil
    }
}

struct SFTPBatchConflictSelections {
    private(set) var resolutions: [String: SFTPConflictResolution]
    private(set) var bulkResolution = SFTPConflictResolution.skip

    init(conflicts: [PendingSFTPOverwrite]) {
        resolutions = Dictionary(
            uniqueKeysWithValues: conflicts.map { ($0.id, .skip) }
        )
    }

    subscript(conflictID: String) -> SFTPConflictResolution? {
        resolutions[conflictID]
    }

    mutating func set(
        _ resolution: SFTPConflictResolution,
        for conflictID: String
    ) {
        resolutions[conflictID] = resolution
    }

    mutating func applyToAll(
        _ resolution: SFTPConflictResolution,
        conflicts: [PendingSFTPOverwrite]
    ) {
        bulkResolution = resolution
        for conflict in conflicts
        where conflict.availableBatchResolutions.contains(resolution)
        {
            resolutions[conflict.id] = resolution
        }
    }
}

private enum SFTPConflictTypography {
    static let text = Font.system(
        size: 12,
        weight: .bold,
        design: .monospaced
    )
}

private struct SFTPBatchConflictResolutionView: View {
    var conflicts: [PendingSFTPOverwrite]
    var onCancel: () -> Void
    var onStart: ([String: SFTPConflictResolution]) -> Void

    @State private var selections: SFTPBatchConflictSelections

    init(
        conflicts: [PendingSFTPOverwrite],
        onCancel: @escaping () -> Void,
        onStart: @escaping ([String: SFTPConflictResolution]) -> Void
    ) {
        self.conflicts = conflicts
        self.onCancel = onCancel
        self.onStart = onStart
        _selections = State(
            initialValue: SFTPBatchConflictSelections(conflicts: conflicts)
        )
    }

    private var commonResolutions: [SFTPConflictResolution] {
        guard let first = conflicts.first else {
            return [.skip]
        }
        return first.availableBatchResolutions.filter { resolution in
            conflicts.allSatisfy {
                $0.availableBatchResolutions.contains(resolution)
            }
        }
    }

    private var windowHeight: CGFloat {
        min(max(240 + CGFloat(conflicts.count) * 46, 313), 453)
    }

    private var usesFourActionRows: Bool {
        conflicts.contains { $0.availableBatchResolutions.count > 3 }
    }

    private var fileColumnWidth: CGFloat {
        usesFourActionRows ? 241 : 253
    }

    private var actionColumnWidth: CGFloat {
        usesFourActionRows ? 170 : 145
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            summaryBar
            conflictTable
            Divider()
            footer
        }
        .frame(width: 800, height: windowHeight)
        .font(SFTPConflictTypography.text)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(
                    AppLocalization.string(
                        "Batch upload name conflicts detected"
                    )
                )
                .font(SFTPConflictTypography.text)
                Text(
                    AppLocalization.string(
                        "Choose how to handle each item, then start the upload."
                    )
                )
                .font(SFTPConflictTypography.text)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var summaryBar: some View {
        HStack(spacing: 12) {
            Text(
                String(
                    format: AppLocalization.string("Conflicts: %@"),
                    String(conflicts.count)
                )
            )
            .font(SFTPConflictTypography.text)
            .foregroundStyle(.secondary)
            Spacer()
            Text(AppLocalization.string("Default action for all conflicts:"))
                .font(SFTPConflictTypography.text)
                .foregroundStyle(.secondary)
            Menu {
                ForEach(commonResolutions, id: \.self) { resolution in
                    Button(resolution.batchTitle) {
                        applyToAll(resolution)
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Text(selections.bulkResolution.batchTitle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var conflictTable: some View {
        VStack(spacing: 0) {
            tableHeader
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(conflicts) { conflict in
                        conflictRow(conflict)
                        if conflict.id != conflicts.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            tableHeaderText("File")
                .frame(width: fileColumnWidth, alignment: .leading)
            Divider()
            tableHeaderText("Remote Path")
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            tableHeaderText("Action")
                .frame(width: actionColumnWidth, alignment: .leading)
        }
        .frame(height: 32)
        .background(Color.secondary.opacity(0.055))
    }

    private func tableHeaderText(_ key: String) -> some View {
        Text(AppLocalization.string(key))
            .font(SFTPConflictTypography.text)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
    }

    private func conflictRow(_ conflict: PendingSFTPOverwrite) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(conflict.fileName)
                    .font(SFTPConflictTypography.text)
                    .lineLimit(1)
                    .help(conflict.fileName)
                Text(conflict.sourcePath)
                    .font(SFTPConflictTypography.text)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(conflict.sourcePath)
            }
            .padding(.horizontal, 9)
            .frame(width: fileColumnWidth, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(conflict.destinationPath)
                    .font(SFTPConflictTypography.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(conflict.destinationPath)
                Text(
                    String(
                        format: AppLocalization.string("Type: %@"),
                        conflict.existingKindTitle
                    )
                )
                .font(SFTPConflictTypography.text)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            resolutionButtons(for: conflict)
                .padding(.horizontal, 6)
                .frame(width: actionColumnWidth, alignment: .leading)
        }
        .frame(height: 52)
    }

    private func resolutionButtons(
        for conflict: PendingSFTPOverwrite
    ) -> some View {
        HStack(spacing: 3) {
            ForEach(conflict.availableBatchResolutions, id: \.self) {
                resolutionButton($0, for: conflict)
            }
        }
    }

    private func resolutionButton(
        _ resolution: SFTPConflictResolution,
        for conflict: PendingSFTPOverwrite
    ) -> some View {
        let isSelected = selections[conflict.id] == resolution
        return Button {
            selections.set(resolution, for: conflict.id)
        } label: {
            Text(resolution.batchTitle)
                .font(SFTPConflictTypography.text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 3)
                .frame(height: 26)
                .foregroundStyle(
                    isSelected ? Color.accentColor : Color.secondary
                )
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            isSelected
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            isSelected
                                ? Color.accentColor.opacity(0.7)
                                : Color.secondary.opacity(0.22),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.1), value: isSelected)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(AppLocalization.string("Cancel"), action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(AppLocalization.string("Start Upload")) {
                onStart(selections.resolutions)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func applyToAll(_ resolution: SFTPConflictResolution) {
        selections.applyToAll(resolution, conflicts: conflicts)
    }
}

private struct SFTPConflictResolutionView: View {
    var conflict: PendingSFTPOverwrite
    var sameTypeConflictCount: Int
    var onResolve: (SFTPConflictResolution, Bool) -> Void

    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalization.string("File Conflict"))
                        .font(SFTPConflictTypography.text)
                    Text(
                        AppLocalization.string(
                            "An item with the same name already exists at the destination."
                        )
                    )
                    .font(SFTPConflictTypography.text)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onResolve(.skip, false)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }

            Text(conflict.message)
                .font(SFTPConflictTypography.text)
                .textSelection(.enabled)

            HStack(alignment: .top, spacing: 12) {
                conflictSummary(
                    title: AppLocalization.string("Existing item"),
                    size: conflict.existingSize,
                    modifiedAt: conflict.existingModifiedAt
                )
                conflictSummary(
                    title: AppLocalization.string("New item"),
                    size: conflict.newSize,
                    modifiedAt: conflict.newModifiedAt
                )
            }

            if sameTypeConflictCount > 1 {
                Toggle(isOn: $applyToAll) {
                    Text(
                        String(
                            format: AppLocalization.string(
                                "Apply this action to all %@ remaining conflicts"
                            ),
                            String(sameTypeConflictCount)
                        )
                    )
                }
                .toggleStyle(.checkbox)
            }

            Divider()

            HStack(spacing: 10) {
                Button(
                    AppLocalization.string("Stop"),
                    role: .destructive
                ) {
                    onResolve(.stop, false)
                }
                Spacer()
                Button(AppLocalization.string("Skip")) {
                    onResolve(.skip, applyToAll)
                }
                Button(AppLocalization.string("Duplicate")) {
                    onResolve(.duplicate, applyToAll)
                }
                if conflict.isIncomingDirectory {
                    Button(AppLocalization.string("Merge")) {
                        onResolve(.merge, applyToAll)
                    }
                    .disabled(!conflict.canMerge)
                }
                if conflict.canReplace {
                    Button(AppLocalization.string("Replace")) {
                        onResolve(.replace, applyToAll)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .font(SFTPConflictTypography.text)
    }

    private func conflictSummary(
        title: String,
        size: UInt64?,
        modifiedAt: Date?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SFTPConflictTypography.text)
            LabeledContent(
                AppLocalization.string("Size:"),
                value: size.map {
                    ByteCountFormatter.string(
                        fromByteCount: Int64(min($0, UInt64(Int64.max))),
                        countStyle: .file
                    )
                } ?? "-"
            )
            LabeledContent(
                AppLocalization.string("Modified:"),
                value: modifiedAt?.formatted(
                    date: .abbreviated,
                    time: .shortened
                ) ?? "-"
            )
        }
        .font(SFTPConflictTypography.text)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

private enum SFTPBrowserError: Error, LocalizedError {
    case textFileTooLarge

    var errorDescription: String? {
        switch self {
        case .textFileTooLarge:
            AppLocalization.string("Text preview is limited to files up to 2 MB.")
        }
    }
}

private actor SFTPTransferStallMonitor {
    private let clock = ContinuousClock()
    private var lastTransferredBytes: UInt64?
    private var lastProgressAt = ContinuousClock().now

    func record(_ progress: SFTPTransferProgress) {
        guard lastTransferredBytes.map({
                  progress.bytesTransferred > $0
              }) ?? true
        else {
            return
        }
        lastTransferredBytes = progress.bytesTransferred
        lastProgressAt = clock.now
    }

    func waitUntilStalled(seconds: UInt64) async throws {
        let timeout = Duration.seconds(Int64(seconds))
        while true {
            try await Task.sleep(for: .seconds(2))
            if lastProgressAt.duration(to: clock.now) >= timeout {
                throw SFTPBrowserTimeoutError.timedOut(seconds: seconds)
            }
        }
    }
}

private enum SFTPBrowserTimeoutError: Error, LocalizedError {
    case timedOut(seconds: UInt64)

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            String(
                format: AppLocalization.string("SFTP did not respond within %@ seconds. Check the host SFTP/SCP settings or retry."),
                String(seconds)
            )
        }
    }
}

private struct FileEntryRow: View {
    var name: String
    var kind: SFTPEntryKind
    var size: UInt64?
    var modifiedAt: Date?
    var isSelected: Bool
    var indentation = 0
    var canExpand = false
    var isExpanded = false
    var onToggleExpand: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if indentation > 0 {
                Spacer()
                    .frame(width: CGFloat(indentation) * 16)
            }
            if canExpand {
                Button {
                    onToggleExpand?()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer()
                    .frame(width: 12)
            }
            Image(systemName: iconName)
                .foregroundStyle(kind == .directory ? Color.accentColor : .secondary)
                .frame(width: 18)
            Text(name)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(sizeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .trailing)
            Text(modifiedText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
        }
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear)
        )
    }

    private var iconName: String {
        switch kind {
        case .directory:
            "folder"
        case .file:
            "doc"
        case .symbolicLink:
            "link"
        case .other:
            "questionmark.square"
        }
    }

    private var sizeText: String {
        guard kind == .file, let size else {
            return "-"
        }
        return ByteCountFormatter.string(
            fromByteCount: Int64(size),
            countStyle: .file
        )
    }

    private var modifiedText: String {
        guard let modifiedAt else {
            return "-"
        }
        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct RenameRemoteItemView: View {
    @Environment(\.dismiss) private var dismiss
    let draft: RemoteRenameDraft
    let onSave: (String) -> Void
    @State private var name: String

    init(draft: RemoteRenameDraft, onSave: @escaping (String) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _name = State(initialValue: draft.currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename")
                .font(.title3.weight(.semibold))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Save") {
                    onSave(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private struct ChmodRemoteItemView: View {
    @Environment(\.dismiss) private var dismiss
    let draft: RemoteChmodDraft
    let onSave: (String) -> Void
    @State private var permissions: String

    init(draft: RemoteChmodDraft, onSave: @escaping (String) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _permissions = State(initialValue: draft.permissions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Permissions")
                .font(.title3.weight(.semibold))
            Text(draft.name)
                .foregroundStyle(.secondary)
            TextField("644", text: $permissions)
                .textFieldStyle(.roundedBorder)
            Text("Use octal permissions, for example 644 or 755.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Save") {
                    onSave(permissions)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private struct RemoteTextEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let draft: RemoteTextDraft
    let onSave: (String) -> Void
    @State private var text: String

    init(draft: RemoteTextDraft, onSave: @escaping (String) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _text = State(initialValue: draft.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.name)
                    .font(.headline)
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Save") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 720, minHeight: 480)
        }
    }
}

struct TransferCenterView: View {
    @EnvironmentObject private var state: AppState
    var compact = false
    var sidebar = false
    var transferIDs: Set<UUID>?
    var onCancel: (UUID) -> Void = { _ in }
    var onRetry: (FileTransferRecord) -> Void = { _ in }
    var onPause: (UUID) -> Void = { _ in }
    var onResume: (FileTransferRecord) -> Void = { _ in }
    @State private var bucket = FileTransferBucket.all

    private var scopedTransfers: [FileTransferRecord] {
        guard let transferIDs else {
            return state.fileTransfers
        }
        return state.fileTransfers.filter { transferIDs.contains($0.id) }
    }

    private var visibleTransfers: [FileTransferRecord] {
        if sidebar {
            return scopedTransfers.filter(\.isUnfinished)
        }
        return scopedTransfers.filter { $0.belongs(to: bucket) }
    }

    @ViewBuilder
    var body: some View {
        if sidebar {
            sidebarBody
        } else {
            standardBody
        }
    }

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Transfer Center", systemImage: "arrow.up.arrow.down")
                    .font(compact ? .caption.weight(.semibold) : .headline)
                Picker("Bucket", selection: $bucket) {
                    ForEach(FileTransferBucket.allCases) { bucket in
                        Text(bucket.title).tag(bucket)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Spacer()
                Button("Clear Finished") {
                    state.clearFinishedFileTransfers()
                }
                .disabled(!state.fileTransfers.contains { record in
                    record.belongs(to: .completed)
                })
            }
            if visibleTransfers.isEmpty {
                ContentUnavailableView(
                    "No Transfers",
                    systemImage: "arrow.up.arrow.down",
                    description: Text("SFTP uploads and downloads appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(visibleTransfers) { record in
                            transferRow(record)
                        }
                    }
                }
            }
        }
        .padding(compact ? 10 : 16)
        .accessibilityLabel("Transfer Center")
    }

    private var sidebarBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Transfers")
                    .font(.caption.weight(.semibold))
                Text("(\(visibleTransfers.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(visibleTransfers) { record in
                        transferRow(record)
                    }
                }
                .padding(8)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityLabel("Transfer Center")
    }

    private func transferRow(_ record: FileTransferRecord) -> some View {
        HStack(spacing: 10) {
            Image(
                systemName: record.kind == .upload
                    ? "arrow.up.circle"
                    : "arrow.down.circle"
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(record.name)
                        .lineLimit(1)
                    Spacer()
                    Text(LocalizedStringKey(statusText(record.status)))
                        .font(.caption)
                        .foregroundStyle(statusColor(record.status))
                }
                ProgressView(value: record.progressFraction ?? 0)
                    .opacity(record.status == .running ? 1 : 0.55)
                Text(progressText(record))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if record.status == .running {
                if record.supportsPause {
                    Button {
                        onPause(record.id)
                    } label: {
                        Image(systemName: "pause")
                    }
                    .buttonStyle(.borderless)
                    .help("Pause Transfer")
                }
                cancelButton(record.id)
            } else if record.status == .paused {
                Button {
                    onResume(record)
                } label: {
                    Image(systemName: "play")
                }
                .buttonStyle(.borderless)
                .help("Resume Transfer")
                cancelButton(record.id)
            } else if record.status == .queued {
                cancelButton(record.id)
            } else if record.canRetry {
                Button {
                    onRetry(record)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Retry Transfer")
                cancelButton(record.id)
            }
        }
        .controlSize(.small)
        .padding(sidebar ? 7 : 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(sidebar ? 0.05 : 0.08))
        )
    }

    private func cancelButton(_ id: UUID) -> some View {
        Button {
            onCancel(id)
        } label: {
            Image(systemName: "xmark")
                .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
        .help("Cancel Transfer")
    }

    private func progressText(_ record: FileTransferRecord) -> String {
        var components: [String] = []
        if record.status == .running, record.bytesPerSecond > 0 {
            components.append("\(byteText(record.bytesPerSecond))/s")
        }
        let current = byteText(record.bytesTransferred)
        guard let total = record.totalBytes else {
            components.append(current)
            return components.joined(separator: " • ")
        }
        components.append("\(current) / \(byteText(total))")
        if let fraction = record.progressFraction {
            components.append("\(Int((fraction * 100).rounded(.down)))%")
        }
        return components.joined(separator: " • ")
    }

    private func byteText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(bytes, UInt64(Int64.max))),
            countStyle: .file
        )
    }

    private func byteText(_ bytes: Double) -> String {
        let clampedBytes: Int64
        if !bytes.isFinite || bytes <= 0 {
            clampedBytes = 0
        } else if bytes >= Double(Int64.max) {
            clampedBytes = Int64.max
        } else {
            clampedBytes = Int64(bytes.rounded())
        }
        return ByteCountFormatter.string(
            fromByteCount: clampedBytes,
            countStyle: .file
        )
    }

    private func statusText(_ status: FileTransferStatus) -> String {
        switch status {
        case .queued:
            "Queued"
        case .running:
            "Running"
        case .paused:
            "Paused"
        case .attention:
            "Attention"
        case .succeeded:
            "Transfer Done"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        }
    }

    private func statusColor(_ status: FileTransferStatus) -> Color {
        switch status {
        case .queued, .running:
            .secondary
        case .paused:
            .blue
        case .attention:
            .yellow
        case .succeeded:
            .green
        case .failed:
            .red
        case .cancelled:
            .orange
        }
    }
}
