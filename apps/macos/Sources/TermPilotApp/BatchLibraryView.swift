import SwiftUI
import TermPilotPersistence

struct BatchLibraryView: View {
    @EnvironmentObject private var workspace: BatchJobWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var renaming: SavedBatchJob?
    @State private var deleting: SavedBatchJob?
    @State private var name = ""

    private var filtered: [SavedBatchJob] {
        workspace.library.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(AppLocalization.string("Job library")).font(.title2.bold())
                Spacer()
                TextField(AppLocalization.string("Search jobs"), text: $search).frame(width: 240)
            }
            if !workspace.storageError.isEmpty { Text(AppLocalization.string(workspace.storageError)).foregroundStyle(.red).textSelection(.enabled) }
            if filtered.isEmpty {
                ContentUnavailableView(AppLocalization.string(search.isEmpty ? "No saved jobs" : "No matching jobs"),
                    systemImage: "square.stack", description: Text(AppLocalization.string("Save a job to reuse its configuration and hosts.")))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { item in
                            HStack(spacing: 16) {
                                Button {
                                    if workspace.openSavedJob(item) { dismiss() }
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.name).fontWeight(.medium)
                                        Text(summary(item)).font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Text(Date(timeIntervalSince1970: Double(item.updatedMs) / 1000).formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Button(AppLocalization.string("Open job")) { if workspace.openSavedJob(item) { dismiss() } }
                                Menu {
                                    Button(AppLocalization.string("Open copy")) { if workspace.openSavedJob(item, asCopy: true) { dismiss() } }
                                    Button(AppLocalization.string("Rename")) { name = item.name; renaming = item }
                                    Button(AppLocalization.string("Delete"), role: .destructive) { deleting = item }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
                            }.padding(.vertical, 12)
                            Divider()
                        }
                    }
                }
            }
            HStack { Text(AppLocalization.string("Opening a job does not run it.")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(AppLocalization.string("Done")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 760, height: 460).textFieldStyle(.roundedBorder)
        .alert(AppLocalization.string("Rename job"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(AppLocalization.string("Name"), text: $name)
            Button(AppLocalization.string("Cancel"), role: .cancel) { renaming = nil }
            Button(AppLocalization.string("Save")) { if let item = renaming { workspace.renameSavedJob(item, to: name) }; renaming = nil }
        }
        .alert(AppLocalization.string("Delete saved job?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(AppLocalization.string("Cancel"), role: .cancel) { deleting = nil }
            Button(AppLocalization.string("Delete"), role: .destructive) { if let item = deleting { workspace.deleteSavedJob(item) }; deleting = nil }
        } message: { Text(AppLocalization.string("Open drafts and execution history will be kept.")) }
    }
    private func summary(_ item: SavedBatchJob) -> String {
        guard let configuration = try? JSONDecoder().decode(BatchSavedConfiguration.self, from: Data(item.configuration.utf8)) else { return AppLocalization.string("Invalid or unsupported saved job.") }
        let type = ["execute": "Batch execution", "upload": "Batch upload", "collect": "File collection"][configuration.job.kind] ?? "Batch Jobs"
        return "\(AppLocalization.string(type)) · \(configuration.targets.count) \(AppLocalization.string("hosts"))"
    }
}

struct BatchSaveJobView: View {
    @EnvironmentObject private var workspace: BatchJobWorkspace
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: BatchJobController
    let asCopy: Bool
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppLocalization.string(asCopy ? "Save job as" : "Save job")).font(.title2.bold())
            TextField(AppLocalization.string("Job name"), text: $name)
            Text(AppLocalization.string("Saves configuration and host references. Temporary passwords must be entered again.")).font(.caption).foregroundStyle(.secondary)
            if !workspace.storageError.isEmpty { Text(AppLocalization.string(workspace.storageError)).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(AppLocalization.string("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(AppLocalization.string("Save")) {
                    if workspace.saveJob(controller, name: name, asCopy: asCopy) { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 160)
            }
        }.padding(24).frame(width: 480).textFieldStyle(.roundedBorder)
        .onAppear { name = controller.title }
    }
}
