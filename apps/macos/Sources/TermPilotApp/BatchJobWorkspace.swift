import Combine
import SwiftUI
import TermPilotDomain
import UniformTypeIdentifiers
import TermPilotPersistence

@MainActor
final class BatchJobWorkspace: ObservableObject {
    @Published private(set) var jobs: [BatchJobController]
    @Published var selected: BatchJobController { didSet { scheduleDraftSave() } }
    @Published private(set) var awaitingConfirmation: [BatchJobController] = []
    var promptJob: BatchJobController? {
        awaitingConfirmation.first { $0 === selected } ?? awaitingConfirmation.first
    }
    private var promptSubscriptions: [UUID: AnyCancellable] = [:]
    private var nextNumber = 2
    private let resources: URL?
    @Published var library: [SavedBatchJob] = []
    @Published var storageError = ""
    @Published var draftError = ""
    var persistenceError: String { [storageError, draftError].filter { !$0.isEmpty }.joined(separator: "\n") }
    @Published var draftStatus = ""
    private var storage: BatchLibraryStore?
    var storageAvailable: Bool { storage != nil }
    private var storageDirectory: URL?
    private weak var appState: AppState?
    private var workspaceID = ""
    private var draftRevision = 0
    private var draftSubscriptions: [UUID: AnyCancellable] = [:]
    private var pendingSave: Task<Void, Never>?
    private var restoring = false
    private static var nextStorageSlot = 0


    init(resources: URL? = Bundle.main.resourceURL) {
        self.resources = resources
        let first = BatchJobController(number: 1, resources: resources)
        jobs = [first]
        selected = first
        observePrompts(first)
    }

    @discardableResult
    func newJob(copying source: BatchJobController? = nil) -> BatchJobController {
        let job = BatchJobController(number: nextNumber, resources: resources)
        if let source {
            job.job = source.job
            job.job.remoteWorkDirectory = ""
            job.job.sourceTaskId = ""
            job.targets = source.targets
            job.targetDefaults = source.targetDefaults
        }
        add(job)
        return job
    }

    private func add(_ job: BatchJobController) {
        nextNumber += 1
        jobs.append(job)
        observePrompts(job)
        observeDraft(job)
        selected = job
    }

    private func observePrompts(_ job: BatchJobController) {
        // Only changes to the prompt queue should redraw the window-level notice.
        promptSubscriptions[job.id] = job.$prompts.map { !$0.isEmpty }.removeDuplicates().sink { [weak self, weak job] waiting in
            guard let self, let job else { return }
            if waiting { awaitingConfirmation.append(job) }
            else if awaitingConfirmation.contains(where: { $0 === job }) {
                awaitingConfirmation.removeAll { $0 === job }
            }
        }
    }

    func close(_ job: BatchJobController) {
        guard !job.running, jobs.count > 1, let index = jobs.firstIndex(where: { $0 === job }) else { return }
        if selected === job { selected = jobs[index == 0 ? 1 : index - 1] }
        job.shutdown()
        promptSubscriptions[job.id] = nil
        draftSubscriptions[job.id] = nil
        jobs.remove(at: index)
        scheduleDraftSave()
    }

    func move(_ id: UUID, before nextID: UUID?) {
        guard let source = jobs.firstIndex(where: { $0.id == id }) else { return }
        let destination: Int
        if let nextID {
            guard let index = jobs.firstIndex(where: { $0.id == nextID }) else { return }
            destination = index
        } else {
            destination = jobs.endIndex
        }
        guard destination != source && destination != source + 1 else { return }
        jobs.move(fromOffsets: IndexSet(integer: source), toOffset: destination)
        scheduleDraftSave()
    }

    func openHistory(_ id: String, state: AppState) -> Bool {
        if let open = jobs.first(where: { $0.historyJobId == id }) {
            open.section = "results"
            selected = open
            return true
        }
        let job = BatchJobController(number: nextNumber, resources: resources)
        job.loadHistory(id)
        guard job.error.isEmpty else { selected.error = job.error; return false }
        if job.backgroundTasks.isEmpty {
            // The historical report has addresses and target IDs but no script.
            // Rebuild its targets without borrowing another job's command or credentials.
            let saved = Dictionary(uniqueKeysWithValues: state.hosts.map { ($0.id, $0) })
            var targets: [UUID: BatchTarget] = [:]
            for event in job.steps.values {
                let ip = event.text("ip")
                guard !ip.isEmpty, let id = UUID(uuidString: event.text("targetId")), targets[id] == nil else { continue }
                let port = event.value["port"] as? Int ?? 22
                let stored = saved[id].flatMap { $0.hostname == ip && $0.port == port ? $0 : nil }
                let host = stored ?? TermPilotDomain.Host(id: id, label: ip, hostname: ip, port: port, username: "", authentication: .password)
                targets[id] = BatchTarget(host: host)
            }
            job.targets = targets.values.sorted { $0.host.hostname < $1.host.hostname }
        } else {
            job.restoreBackgroundTargets(state: state)
        }
        job.section = "results"
        add(job)
        return true
    }

    func restoreDrafts(state: AppState, directory: URL, workspace: String? = nil) {
        guard storage == nil else { return }
        storageDirectory = directory
        let store = BatchLibraryStore(directory: directory)
        if workspaceID.isEmpty {
            workspaceID = workspace ?? "macos-\(Self.nextStorageSlot)"
            Self.nextStorageSlot += 1
        }
        do {
            let result = try store.request(["operation": "loadDraft", "workspace": workspaceID])
            let revision = result["revision"] as? Int ?? 0
            var restored: [BatchJobController] = []
            var selectedID: UUID?
            if let payload = result["payload"] as? String {
                let document = try JSONDecoder().decode(BatchDraftDocument.self, from: Data(payload.utf8))
                guard document.version == 1 else { throw BatchError.message("Invalid or unsupported saved job.") }
                for tab in document.tabs {
                    let configuration = try JSONDecoder().decode(BatchSavedConfiguration.self, from: Data(tab.configuration.utf8))
                    guard configuration.version == 1 else { throw BatchError.message("Invalid or unsupported saved job.") }
                    let controller = BatchJobController(id: tab.id, number: tab.number, resources: resources)
                    if let name = tab.name { controller.rename(to: name) }
                    controller.savedJobID = tab.savedId; controller.savedJobRevision = tab.savedRevision
                    configuration.apply(to: controller, hosts: state.hosts)
                    restored.append(controller)
                }
                selectedID = document.selected
            }
            restoring = true
            defer { restoring = false }
            if !restored.isEmpty {
                for job in jobs { job.shutdown() }
                promptSubscriptions.removeAll(); draftSubscriptions.removeAll()
                jobs = restored
                selected = restored.first { $0.id == selectedID } ?? restored[0]
                nextNumber = (restored.map(\.number).max() ?? 0) + 1
                for job in jobs { observePrompts(job) }
            }
            storage = store; appState = state; draftRevision = revision
            for job in jobs { observeDraft(job) }
            draftError = ""; draftStatus = restored.isEmpty ? "" : "Drafts restored"
        } catch { draftError = error.localizedDescription }
    }

    private func observeDraft(_ job: BatchJobController) {
        draftSubscriptions[job.id] = Publishers.MergeMany([
            job.$job.map { _ in () }.eraseToAnyPublisher(),
            job.$targets.map { _ in () }.eraseToAnyPublisher(),
            job.$targetDefaults.map { _ in () }.eraseToAnyPublisher(),
            job.$customTitle.map { _ in () }.eraseToAnyPublisher()
        ]).dropFirst(4).sink { [weak self] in self?.scheduleDraftSave() }
    }

    private func scheduleDraftSave() {
        guard storage != nil, !restoring else { return }
        pendingSave?.cancel()
        draftStatus = "Saving draft…"
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            self?.flushDrafts()
        }
    }

    @discardableResult
    func flushDrafts() -> Bool {
        pendingSave?.cancel(); pendingSave = nil
        guard let storage, !restoring else { return true }
        do {
            let tabs = try jobs.map { job in
                BatchDraftDocument.Tab(id: job.id, name: job.customTitle, number: job.number,
                    savedId: job.savedJobID, savedRevision: job.savedJobRevision,
                    configuration: try BatchSavedConfiguration(job, hosts: appState?.hosts ?? []).encoded())
            }
            let document = BatchDraftDocument(tabs: tabs, selected: selected.id)
            let payload = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
            let result = try storage.request(["operation": "saveDraft", "workspace": workspaceID,
                "payload": payload, "revision": draftRevision])
            draftRevision = result["revision"] as? Int ?? draftRevision
            draftError = ""; draftStatus = "Draft saved"
            return true
        } catch { draftError = error.localizedDescription; draftStatus = "Draft not saved"; return false }
    }

    func retryStorage(state: AppState) {
        if storage != nil { flushDrafts() }
        else if let directory = storageDirectory { restoreDrafts(state: state, directory: directory) }
    }

    func loadLibrary() {
        do { library = try storage?.list() ?? []; storageError = "" }
        catch { storageError = error.localizedDescription }
    }

    @discardableResult
    func saveJob(_ job: BatchJobController, name: String, asCopy: Bool) -> Bool {
        guard let storage else { return false }
        do {
            let item = try storage.save(name: name,
                configuration: BatchSavedConfiguration(job, hosts: appState?.hosts ?? []).encoded(),
                id: asCopy ? nil : job.savedJobID, revision: asCopy ? nil : job.savedJobRevision)
            job.savedJobID = item.id; job.savedJobRevision = item.revision; job.rename(to: item.name)
            loadLibrary(); flushDrafts()
            return true
        } catch { storageError = error.localizedDescription; return false }
    }

    @discardableResult
    func openSavedJob(_ item: SavedBatchJob, asCopy: Bool = false) -> Bool {
        if !asCopy, let existing = jobs.first(where: { $0.savedJobID == item.id }) { selected = existing; return true }
        do {
            let configuration = try JSONDecoder().decode(BatchSavedConfiguration.self, from: Data(item.configuration.utf8))
            guard configuration.version == 1 else { throw BatchError.message("Invalid or unsupported saved job.") }
            let job = BatchJobController(number: nextNumber, resources: resources)
            job.rename(to: item.name)
            job.savedJobID = asCopy ? nil : item.id; job.savedJobRevision = asCopy ? nil : item.revision
            configuration.apply(to: job, hosts: appState?.hosts ?? [])
            add(job); storageError = ""
            return true
        } catch { storageError = error.localizedDescription; return false }
    }

    func renameSavedJob(_ item: SavedBatchJob, to name: String) {
        do {
            guard let updated = try storage?.save(name: name, configuration: item.configuration, id: item.id, revision: item.revision) else { return }
            for job in jobs where job.savedJobID == item.id {
                job.rename(to: updated.name)
                if job.savedJobRevision == item.revision { job.savedJobRevision = updated.revision }
            }
            loadLibrary(); flushDrafts()
        } catch { storageError = error.localizedDescription }
    }

    func deleteSavedJob(_ item: SavedBatchJob) {
        do {
            try storage?.delete(item)
            for job in jobs where job.savedJobID == item.id { job.savedJobID = nil; job.savedJobRevision = nil }
            loadLibrary(); flushDrafts()
        } catch { storageError = error.localizedDescription }
    }

    func shutdown() { flushDrafts(); for job in jobs { job.shutdown() } }

}

struct BatchWorkspaceView: View {
    @EnvironmentObject private var workspace: BatchJobWorkspace
    @EnvironmentObject private var state: AppState
    @State private var showingLibrary = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                BatchJobTabStrip(workspace: workspace)
                Button { workspace.loadLibrary(); showingLibrary = true } label: {
                    Label(AppLocalization.string("Job library"), systemImage: "square.stack")
                }.fixedSize().disabled(!workspace.storageAvailable).accessibilityIdentifier("batch-job-library")
                Menu {
                    Button(AppLocalization.string("New blank job")) { workspace.newJob() }
                    Button(AppLocalization.string("New job with current configuration")) {
                        workspace.newJob(copying: workspace.selected)
                    }
                } label: {
                    Label(AppLocalization.string("New batch job"), systemImage: "plus")
                } primaryAction: { workspace.newJob() }
                .fixedSize().accessibilityIdentifier("batch-new-job")
            }.padding(.horizontal, 24).padding(.vertical, 10)
            Divider()
            if !workspace.persistenceError.isEmpty {
                HStack {
                    Text(AppLocalization.string(workspace.persistenceError)).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button(AppLocalization.string("Retry saving")) { workspace.retryStorage(state: state) }
                }.font(.caption).padding(.horizontal, 24).padding(.vertical, 8)
            }
            BatchJobsView().environmentObject(workspace.selected).id(workspace.selected.id)
                .disabled(!workspace.storageAvailable && !workspace.draftError.isEmpty)
        }.sheet(isPresented: $showingLibrary) { BatchLibraryView() }
    }
}

private struct BatchJobTabStrip: View {
    @ObservedObject var workspace: BatchJobWorkspace
    @State private var frames: [UUID: CGRect] = [:]
    @State private var indicatorX: CGFloat?
    private let coordinateSpace = "batchJobTabStrip"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(workspace.jobs) { job in
                        BatchJobTab(job: job, selected: workspace.selected === job, canClose: workspace.jobs.count > 1,
                            select: { workspace.selected = job }, close: { workspace.close(job) })
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: WorkspaceTabFramePreferenceKey.self,
                                        value: [job.id: geometry.frame(in: .named(coordinateSpace))])
                                }
                            }.id(job.id)
                    }
                }
            }.scrollIndicators(.hidden)
            .coordinateSpace(name: coordinateSpace)
            .onPreferenceChange(WorkspaceTabFramePreferenceKey.self) { frames = $0 }
            .overlay(alignment: .leading) {
                if let indicatorX {
                    Capsule().fill(Color.accentColor).frame(width: 2).offset(x: indicatorX).allowsHitTesting(false)
                }
            }
            .onDrop(of: [BatchJobTabDrag.type], delegate: BatchJobTabDrop(workspace: workspace, frames: frames, indicatorX: $indicatorX))
            .onChange(of: workspace.selected.id) { _, id in proxy.scrollTo(id) }
        }
    }
}

struct BatchJobTabDrag: Codable, Transferable {
    let id: UUID
    static let type = UTType(exportedAs: "com.termpilot.batch-job-tab")
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: type).visibility(.ownProcess)
    }
}

struct BatchJobTabDrop: DropDelegate {
    let workspace: BatchJobWorkspace
    let frames: [UUID: CGRect]
    @Binding var indicatorX: CGFloat?

    // A nil neighbor appends to the strip, including drops in the space after the last tab.
    private func target(at x: CGFloat) -> (nextID: UUID?, edge: CGFloat)? {
        var lastEdge: CGFloat?
        for job in workspace.jobs {
            guard let frame = frames[job.id] else { return nil }
            if x < frame.midX { return (job.id, frame.minX) }
            lastEdge = frame.maxX
        }
        return lastEdge.map { (nil, $0) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        indicatorX = target(at: info.location.x)?.edge
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { indicatorX = nil }

    func performDrop(info: DropInfo) -> Bool {
        indicatorX = nil
        guard let provider = info.itemProviders(for: [BatchJobTabDrag.type]).first else { return false }
        return accept(provider, at: info.location.x)
    }

    func accept(_ provider: NSItemProvider, at x: CGFloat) -> Bool {
        guard let target = target(at: x) else { return false }
        _ = provider.loadTransferable(type: BatchJobTabDrag.self) { result in
            guard case .success(let drag) = result else { return }
            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.16)) { workspace.move(drag.id, before: target.nextID) }
            }
        }
        return true
    }
}

private struct BatchJobTab: View {
    @ObservedObject var job: BatchJobController
    let selected: Bool
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if editing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder).frame(width: 150)
                    .focused($nameFocused)
                    .onAppear { nameFocused = true }
                    .onSubmit { finishEditing() }
                    .onExitCommand { editing = false }
                    .accessibilityIdentifier("batch-job-name")
            } else {
                Button(action: select) {
                    HStack(spacing: 6) {
                        Text(job.title).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180)
                            .fontWeight(selected ? .semibold : .regular)
                        Text(AppLocalization.string(job.statusLabel)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    select()
                    draft = job.title
                    editing = true
                })
                .draggable(BatchJobTabDrag(id: job.id))
                .help(job.title + "\n" + AppLocalization.string("Double-click to rename. Drag to reorder."))
            }
            if canClose && !job.running {
                Button(action: close) { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.plain).help(AppLocalization.string("Close job tab"))
            }
        }.padding(.horizontal, 9)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .onChange(of: nameFocused) { _, focused in if !focused { finishEditing() } }
        .onChange(of: selected) { _, active in if !active { finishEditing() } }
    }

    private func finishEditing() {
        guard editing else { return }
        editing = false
        job.rename(to: draft)
    }
}

struct BatchPromptQueueView: View {
    @ObservedObject var workspace: BatchJobWorkspace

    var body: some View {
        if let job = workspace.promptJob {
            BatchPromptView(controller: job).id(job.id)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 8).padding()
        }
    }
}
