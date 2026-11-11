import AppKit
import SwiftUI
import TermPilotDomain

struct BatchJobsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var controller: BatchJobController
    @State private var showingSave = false
    @State private var saveAsCopy = false
    @State private var showingTargets = false
    @State private var showingHistory = false
    @State private var csvDocument: BatchResultsCSV?
    @State private var csvFilename = ""
    @State private var showingCSVExporter = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
            HStack {
                Picker(AppLocalization.string("Batch workspace"), selection: $controller.section) {
                    Text(AppLocalization.string("Task configuration")).tag("configuration")
                    Text(AppLocalization.string("Execution results")).tag("results")
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if controller.running { ProgressView().controlSize(.small); Text(AppLocalization.string("Configuration is read-only while running.")).font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            if !controller.error.isEmpty { Text(controller.error).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.top, 12) }
            // Keep both panes mounted so disclosures, editors and result filters survive navigation.
            ZStack {
                ScrollView { configuration.padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity) }
                    .opacity(controller.section == "configuration" ? 1 : 0).disabled(controller.section != "configuration").allowsHitTesting(controller.section == "configuration").accessibilityHidden(controller.section != "configuration")
                ScrollView { results.padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity) }
                    .opacity(controller.section == "results" ? 1 : 0).disabled(controller.section != "results").allowsHitTesting(controller.section == "results").accessibilityHidden(controller.section != "results")
            }
        }.textFieldStyle(.roundedBorder)
        .onChange(of: controller.job.kind) { _, kind in if kind != "execute" { controller.job.executionMode = "foreground" } }
        .sheet(isPresented: $showingTargets) { BatchTargetManager(defaults: $controller.targetDefaults) }
        .sheet(isPresented: $showingHistory) { history }
        .sheet(isPresented: $showingSave) { BatchSaveJobView(controller: controller, asCopy: saveAsCopy).environmentObject(state.batchJobs) }
    }
    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.string("Batch Jobs")).font(.title2.bold())
                Text(AppLocalization.string("Configure once. Run across your hosts.")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            BatchSaveControls(workspace: state.batchJobs, controller: controller) { asCopy in
                saveAsCopy = asCopy; showingSave = true
            }
            Button { controller.loadHistory(); showingHistory = true } label: { Label(AppLocalization.string("Job history"), systemImage: "clock.arrow.circlepath") }
            if controller.running {
                Button(AppLocalization.string(controller.backgroundTasks.isEmpty && controller.job.executionMode != "background" ? "Cancel" : "Stop submitting or querying")) { Task { await controller.cancel() } }
            } else {
                Button(AppLocalization.string("Run batch")) { Task { await controller.start(state: state) } }.buttonStyle(.borderedProminent).disabled(controller.targets.isEmpty)
            }
        }
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image(systemName: "server.rack").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(AppLocalization.string("Target hosts")) · \(controller.targets.count)").font(.headline)
                    Text(targetSummary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(AppLocalization.string("Manage hosts")) { showingTargets = true }.disabled(controller.running)
            }.padding(16).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            taskForm.disabled(controller.running)
            Divider()
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading) { Text(AppLocalization.string(controller.job.executionMode == "background" ? "Submission concurrency" : "Concurrency")).font(.caption); TextField(AppLocalization.string("Concurrency"), value: $controller.job.concurrency, format: .number) }
                        VStack(alignment: .leading) { Text(AppLocalization.string("Connection timeout (s)")).font(.caption); TextField(AppLocalization.string("Connection timeout (s)"), value: $controller.job.connectTimeout, format: .number) }
                        VStack(alignment: .leading) { Text(AppLocalization.string("Execution timeout (s)")).font(.caption); TextField(AppLocalization.string("Execution timeout (s)"), value: $controller.job.stepTimeout, format: .number); Text(AppLocalization.string("0 means no time limit. You can still cancel the task.")).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Toggle(AppLocalization.string(controller.job.executionMode == "background" ? "Stop submitting hosts after a submission failure" : "Stop scheduling new hosts after a failure"), isOn: $controller.job.stopOnFailure)
                }.padding(.top, 12)
            } label: { disclosureLabel("Run options", runtimeSummary) }.disabled(controller.running)
            HStack {
                Button(AppLocalization.string("Check connections & elevation")) { Task { await controller.start(state: state, kind: "check") } }.disabled(controller.running || controller.targets.isEmpty)
                Text(AppLocalization.string("Verify authentication and elevation before running.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var targetSummary: String {
        if controller.targets.isEmpty { return AppLocalization.string("Add saved hosts or enter IP addresses to get started.") }
        let credentials = Set(controller.targets.compactMap { $0.host.credentialID })
        let usesHostCredentials = controller.targets.contains { $0.host.credentialID == nil }
        let authentication = credentials.count == 1 && !usesHostCredentials ? state.credentials.first { $0.id == credentials.first }?.label ?? AppLocalization.string("Credentials") : AppLocalization.string("Per-host credentials")
        let methods = Set(controller.targets.map(\.elevation))
        let elevation = methods.count == 1 ? (methods.first == "none" ? AppLocalization.string("No elevation") : methods.first!) : AppLocalization.string("Per-host elevation")
        return "\(authentication) · \(elevation)"
    }
    private var runtimeSummary: String {
        "\(AppLocalization.string(controller.job.executionMode == "background" ? "Submission concurrency" : "Concurrency")) \(controller.job.concurrency) · " + (controller.job.stepTimeout == 0 ? AppLocalization.string("No execution time limit") : "\(AppLocalization.string("Execution timeout")) \(controller.job.stepTimeout) s") + (controller.job.stopOnFailure ? " · \(AppLocalization.string("Stop on failure"))" : "")
    }
    private func disclosureLabel(_ title: String, _ summary: String) -> some View {
        HStack { Text(AppLocalization.string(title)).fontWeight(.medium); Spacer(); Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }.padding(.vertical, 5)
    }
    private var taskForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker(AppLocalization.string("Task"), selection: $controller.job.kind) { Text(AppLocalization.string("Batch execution")).tag("execute"); Text(AppLocalization.string("Batch upload")).tag("upload"); Text(AppLocalization.string("File collection")).tag("collect") }.pickerStyle(.segmented).labelsHidden()
            if controller.job.kind == "execute" {
                Picker(AppLocalization.string("Execution mode"), selection: $controller.job.executionMode) {
                    Text(AppLocalization.string("Foreground execution")).tag("foreground")
                    Text(AppLocalization.string("Background execution")).tag("background")
                }.pickerStyle(.segmented)
                if controller.job.executionMode == "background" {
                    Text(AppLocalization.string("Submitted tasks continue after disconnect, sleep or app exit. Remote Python 3.8+ is required. View logs and results from job history.")).font(.caption).foregroundStyle(.secondary)
                }
                BatchScriptEditor(value: $controller.job.script, title: "Command or script")
            }
            if controller.job.kind == "upload" { uploadForm }
            if controller.job.kind == "collect" { collectionForm }
        }
    }
    private var uploadForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("\(AppLocalization.string("Files to upload")) · \(controller.job.localPaths.count)").font(.subheadline.bold()); Spacer(); Button(AppLocalization.string("Add files")) { chooseUploads(directory: false) }; Button(AppLocalization.string("Add directory")) { chooseUploads(directory: true) }; if !controller.job.localPaths.isEmpty { Button(AppLocalization.string("Clear")) { controller.job.localPaths = [] } } }
            if controller.job.localPaths.isEmpty { Text(AppLocalization.string("Choose files or directories to upload.")).foregroundStyle(.secondary).padding(.vertical, 12) }
            ForEach(controller.job.localPaths, id: \.self) { path in HStack { Image(systemName: "doc").foregroundStyle(.secondary); Text(path).font(.caption).textSelection(.enabled); Spacer(); Button { controller.job.localPaths.removeAll { $0 == path } } label: { Image(systemName: "xmark") }.help("Remove") } }
            VStack(alignment: .leading, spacing: 6) { Text(AppLocalization.string("Remote directory")).font(.caption); TextField(AppLocalization.string("Remote directory"), text: $controller.job.remoteDirectory) }
            Picker(AppLocalization.string("Existing destination"), selection: $controller.job.overwrite) { Text(AppLocalization.string("Skip")).tag("skip"); Text(AppLocalization.string("Overwrite")).tag("overwrite"); Text(AppLocalization.string("Backup then replace")).tag("backup") }
            Text(AppLocalization.string("Conflict policies apply to each selected file or directory. Replacing a directory replaces its entire contents.")).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { VStack(alignment: .leading) { Text(AppLocalization.string("File permissions")).font(.caption); TextField(AppLocalization.string("File permissions"), text: $controller.job.fileMode) }; VStack(alignment: .leading) { Text(AppLocalization.string("Directory permissions")).font(.caption); TextField(AppLocalization.string("Directory permissions"), text: $controller.job.directoryMode) } }
                    HStack { TextField(AppLocalization.string("Owner (optional)"), text: $controller.job.owner); TextField(AppLocalization.string("Group (optional)"), text: $controller.job.group) }
                    Toggle(AppLocalization.string("Apply permissions recursively"), isOn: $controller.job.recursivePermissions)
                }.padding(.top, 12)
            } label: { disclosureLabel("Permissions & ownership", [controller.job.fileMode, controller.job.directoryMode, controller.job.owner, controller.job.group, controller.job.recursivePermissions ? AppLocalization.string("Recursive") : ""].filter { !$0.isEmpty }.joined(separator: " · ")) }
        }
    }
    private var collectionForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppLocalization.string("Remote files · one absolute path per line")).font(.subheadline.bold())
                BatchTextEditor(text: Binding(get: { controller.job.remotePaths.joined(separator: "\n") }, set: { controller.job.remotePaths = $0.components(separatedBy: "\n") }), label: AppLocalization.string("Remote files · one absolute path per line"), monospaced: true)
                    .frame(height: 110).border(.secondary.opacity(0.25))
                Text("/var/log/syslog\n${REMOTE_WORK_DIR}/diagnostics.tar.gz").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) { Text(AppLocalization.string("Collection directory")).font(.caption); HStack { TextField(AppLocalization.string("Collection directory"), text: $controller.job.localDirectory); Button(AppLocalization.string("Browse")) { let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; if p.runModal() == .OK, let url = p.url { controller.job.localDirectory = url.path } } } }
            Text(AppLocalization.string("Files use IP-UTC time-filename; collisions receive a suffix. SHA-256 is verified before cleanup.")).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup { BatchScriptEditor(value: $controller.job.before, title: "Preparation (optional)") } label: { disclosureLabel("Preparation script", scriptSummary(controller.job.before)) }
            DisclosureGroup {
                BatchScriptEditor(value: $controller.job.after, title: "Cleanup (optional)")
                Picker(AppLocalization.string("Run cleanup"), selection: $controller.job.cleanupPolicy) { Text(AppLocalization.string("Only after successful collection")).tag("success"); Text(AppLocalization.string("Only after failure")).tag("failure"); Text(AppLocalization.string("After success or failure")).tag("always") }
                Text(AppLocalization.string("Cancellation skips the cleanup script. The remote temporary directory is always cleaned up after the task.")).font(.caption).foregroundStyle(.secondary)
            } label: { disclosureLabel("Cleanup script", scriptSummary(controller.job.after)) }
        }
    }
    private func scriptSummary(_ script: BatchScript) -> String { AppLocalization.string(script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Not configured" : "Configured") }
    private var results: some View {
        let rows = batchHostResults(Array(controller.steps.values) + Array(controller.checks.values), running: controller.running)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(AppLocalization.string("Execution results")).font(.headline)
                Spacer()
                Menu {
                    ForEach(BatchCSVScope.allCases, id: \.self) { scope in
                        Button(AppLocalization.string(scope.title)) {
                            csvDocument = BatchResultsCSV(hosts: rows, scope: scope)
                            csvFilename = ["TermPilot", controller.historyJobId, scope.rawValue].filter { !$0.isEmpty }.joined(separator: "-")
                            showingCSVExporter = true
                        }.disabled(!rows.contains(where: scope.includes))
                    }
                } label: {
                    Label(AppLocalization.string("Export CSV"), systemImage: "square.and.arrow.up")
                }.disabled(rows.isEmpty).fixedSize()
                Menu(AppLocalization.string("Result actions")) {
                    Button(AppLocalization.string("Open report folder")) { NSWorkspace.shared.open(URL(fileURLWithPath: controller.reportDirectory)) }.disabled(controller.reportDirectory.isEmpty)
                    Button(AppLocalization.string("Open collection folder")) { NSWorkspace.shared.open(URL(fileURLWithPath: controller.job.localDirectory)) }.disabled(controller.job.localDirectory.isEmpty)
                }.fixedSize()
            }
            if !controller.backgroundTasks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(AppLocalization.string("Background tasks are independent of this window. Refresh to reconnect; failed queries do not stop or rerun remote tasks.")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(AppLocalization.string("Refresh background tasks")) { Task { await controller.start(state: state, backgroundAction: "status") } }
                        Button(AppLocalization.string("Download complete logs")) { Task { await controller.start(state: state, backgroundAction: "logs") } }
                        Button(AppLocalization.string("Reconnect credentials")) { controller.restoreBackgroundTargets(state: state); showingTargets = true }
                        Button(AppLocalization.string("Stop background tasks"), role: .destructive) { Task { await controller.start(state: state, backgroundAction: "cancel") } }
                    }.disabled(controller.running)
                }
            }
            BatchHostResults(rows: rows, running: controller.running, conflicts: controller.conflicts, progress: controller.progress).id(controller.reportDirectory)
            if !controller.running && controller.backgroundTasks.isEmpty && hasRetryableResults {
                Divider()
                if controller.isHistoryReport {
                    Text(AppLocalization.string("History contains results only. Review the task and credentials before retrying."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(AppLocalization.string("Rerun failed hosts")) { Task { await controller.start(state: state, retry: "failed") } }
                        .disabled(controller.isHistoryReport && controller.job.kind == "execute" && controller.job.script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if controller.job.kind == "collect" { Button(AppLocalization.string("Retry download only (one failed host)")) { Task { await controller.start(state: state, retry: "download") } }.disabled(!controller.downloadRetryError.isEmpty).help(AppLocalization.string(controller.downloadRetryError)) }
                }
            }
        }.fileExporter(isPresented: $showingCSVExporter, document: csvDocument, contentType: .commaSeparatedText, defaultFilename: csvFilename) { result in
            csvDocument = nil
            if case .failure(let error) = result { controller.error = error.localizedDescription }
        }
    }
    private var hasRetryableResults: Bool {
        (Array(controller.steps.values) + Array(controller.checks.values)).contains { $0.text("stage") == "finished" && ["failed", "cancelled"].contains($0.text("status")) }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppLocalization.string("Job history")).font(.title2.bold())
            if !controller.error.isEmpty { Text(controller.error).foregroundStyle(.red) }
            if controller.history.isEmpty { Text(AppLocalization.string("No previous jobs.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120) }
            else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(controller.history.indices, id: \.self) { i in
                            let item = controller.history[i], id = item["id"] as? String ?? ""
                            let date = Date(timeIntervalSince1970: item["time"] as? Double ?? 0)
                            Button {
                                if state.batchJobs.openHistory(id, state: state) { showingHistory = false }
                            } label: { HStack { Text(date.formatted()); if item["background"] as? Bool == true { Text(AppLocalization.string("Background execution")).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(String(id.prefix(8))).foregroundStyle(.secondary); Image(systemName: "chevron.right").foregroundStyle(.secondary) }.padding(.vertical, 12).contentShape(Rectangle()) }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }.frame(maxHeight: 360)
            }
            HStack { Spacer(); Button(AppLocalization.string("Done")) { showingHistory = false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 520)
    }
    private func chooseUploads(directory: Bool) { let p = NSOpenPanel(); p.canChooseDirectories = directory; p.canChooseFiles = !directory; p.allowsMultipleSelection = true; if p.runModal() == .OK { for url in p.urls where !controller.job.localPaths.contains(url.path) { controller.job.localPaths.append(url.path) } } }
}

struct BatchConflictList: View {
    let events: [BatchEvent]
    var onSelect: ((String) -> Void)? = nil
    var body: some View {
        let conflicts = events.filter { $0.text("stage") == "conflict" }
        if !conflicts.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppLocalization.string("Upload conflicts")).font(.headline)
                    Text(AppLocalization.string("Hosts remain listed even when the conflict was handled successfully.")).font(.caption).foregroundStyle(.secondary)
                    ForEach(conflicts) { conflict in
                        let outcome = events.last { $0.text("stage") == "upload" && $0.text("targetId") == conflict.text("targetId") && $0.text("remotePath") == conflict.text("remotePath") && $0.text("status") != "running" }
                        HStack { if let onSelect { Button(conflict.text("ip") + ((conflict.value["port"] as? Int).map { ":\($0)" } ?? "")) { onSelect(conflict.text("targetId")) }.help("Locate host") } else { Text(conflict.text("ip")) }; VStack(alignment: .leading) { Text(conflict.text("remotePath")); if !conflict.text("backupPath").isEmpty { Text(conflict.text("backupPath")).foregroundStyle(.secondary) } }.textSelection(.enabled); Spacer(); Text(AppLocalization.string(conflict.text("policy"))); Text(AppLocalization.string(conflict.text("status").isEmpty ? (outcome?.text("status") ?? "") : conflict.text("status"))) }.font(.caption)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct BatchScriptEditor: View {
    @EnvironmentObject private var state: AppState
    @Binding var value: BatchScript
    let title: String
    @State private var options = false
    @State private var environmentText = ""
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.string(title)).font(.subheadline.bold())
            BatchTextEditor(text: $value.body, label: AppLocalization.string(title), monospaced: true)
                .frame(minHeight: 180).border(.secondary.opacity(0.25))
            HStack {
                Menu(AppLocalization.string("Choose saved script")) { ForEach(state.automationScripts) { script in Button(script.title) { value.body = script.body; value.shell = script.shell } } }
                Button(AppLocalization.string("Import script")) { let p = NSOpenPanel(); if p.runModal() == .OK, let url = p.url { do { let data = try Data(contentsOf: url); guard data.count <= 128 * 1024, let body = String(data: data, encoding: .utf8) else { throw BatchError.message("Script must be a UTF-8 file up to 128 KiB") }; value.body = body } catch { self.error = error.localizedDescription } } }
                Button(AppLocalization.string("Script options")) { options.toggle() }
                Button(AppLocalization.string("Clear")) { value = BatchScript(); environmentText = ""; error = "" }
            }
            if options {
                HStack { VStack(alignment: .leading) { Text(AppLocalization.string("Interpreter")).font(.caption); TextField(AppLocalization.string("Interpreter"), text: $value.shell) }; VStack(alignment: .leading) { Text(AppLocalization.string("Working directory")).font(.caption); TextField(AppLocalization.string("Working directory"), text: $value.cwd) } }
                Picker(AppLocalization.string("Step elevation"), selection: $value.elevation) { Text(AppLocalization.string("Inherit host setting")).tag(""); Text(AppLocalization.string("No elevation")).tag("none"); Text(AppLocalization.string("sudo")).tag("sudo"); Text(AppLocalization.string("su")).tag("su") }
                Text(AppLocalization.string("Arguments · one per line")).font(.caption)
                BatchTextEditor(text: Binding(get: { value.args.joined(separator: "\n") }, set: { value.args = $0.isEmpty ? [] : $0.components(separatedBy: "\n") }), label: AppLocalization.string("Arguments · one per line"))
                    .frame(height: 45).border(.secondary.opacity(0.25))
                Text(AppLocalization.string("Environment · KEY=value per line")).font(.caption)
                BatchTextEditor(text: $environmentText, label: AppLocalization.string("Environment · KEY=value per line")).frame(height: 45).border(.secondary.opacity(0.25)).onChange(of: environmentText) { _, text in
                    var env: [String: String] = [:]
                    for line in text.components(separatedBy: "\n") where !line.isEmpty { guard let i = line.firstIndex(of: "="), i != line.startIndex else { error = "Use KEY=value"; value.environment = ["": text]; return }; env[String(line[..<i])] = String(line[line.index(after: i)...]) }
                    value.environment = env; error = ""
                }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            Text(AppLocalization.string("Available variables: TASK_ID, HOST_IP, REMOTE_WORK_DIR")).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 8).onAppear { environmentText = value.environment[""] ?? value.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") }
    }
}

private struct BatchSaveControls: View {
    @ObservedObject var workspace: BatchJobWorkspace
    @ObservedObject var controller: BatchJobController
    let showSave: (Bool) -> Void
    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Menu {
                Button(AppLocalization.string("Save job")) { save() }
                Button(AppLocalization.string("Save job as")) { showSave(true) }
            } label: { Label(AppLocalization.string("Save job"), systemImage: "square.and.arrow.down") }
                primaryAction: { save() }
                .disabled(!workspace.storageAvailable)
            if !workspace.draftStatus.isEmpty {
                Text(AppLocalization.string(workspace.draftStatus)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private func save() {
        if controller.savedJobID == nil { showSave(false) }
        else { workspace.saveJob(controller, name: controller.title, asCopy: false) }
    }
}
