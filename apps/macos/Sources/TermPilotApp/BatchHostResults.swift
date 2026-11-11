import AppKit
import SwiftUI

struct BatchHostResults: View {
    let rows: [BatchHostResult]
    let running: Bool
    var conflicts: [BatchEvent] = []
    var progress: [String: BatchEvent] = [:]
    var initiallyExpanded = false
    @State private var status = "all"
    @State private var phase = ""
    @State private var host = ""
    @State private var expanded = Set<String>()
    @State private var showingConflicts = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if rows.isEmpty { Text(AppLocalization.string("Run a task or load history to view results.")).foregroundStyle(.secondary) }
            else {
                overview(rows)
                phaseTags(rows)
                filters(rows)
                if !conflicts.isEmpty {
                    DisclosureGroup(isExpanded: $showingConflicts) {
                        BatchConflictList(events: conflicts, onSelect: { id in
                            host = id; phase = ""; status = "all"; expanded.insert(id); showingConflicts = false
                        })
                    } label: { Text("\(AppLocalization.string("Upload conflicts")) · \(Set(conflicts.map { $0.text("targetId") }).count) \(AppLocalization.string("Hosts"))") }
                }
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text(AppLocalization.string("Host")).frame(maxWidth: .infinity, alignment: .leading)
                        Text(AppLocalization.string("Task status")).frame(width: 110, alignment: .leading)
                        Text(AppLocalization.string("Elapsed")).frame(width: 65, alignment: .trailing)
                    }.font(.caption).foregroundStyle(.secondary).padding(12)
                    let visible = batchFilterHostResults(rows, status: status, phase: phase, host: host)
                    if visible.isEmpty { Text(AppLocalization.string("No hosts match these filters.")).foregroundStyle(.secondary).padding(20) }
                    ForEach(visible) { row in
                        Divider()
                        BatchHostResultRow(host: row, progress: progress[row.id], expanded: Binding(get: { expanded.contains(row.id) }, set: { if $0 { expanded.insert(row.id) } else { expanded.remove(row.id) } }))
                    }
                }
            }
        }.onAppear { if initiallyExpanded { expanded = Set(rows.map(\.id)) } }
    }
    private func overview(_ rows: [BatchHostResult]) -> some View {
        let finished = rows.filter { !["pending", "running", "unknown"].contains($0.status) }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text("\(AppLocalization.string("Hosts")) \(rows.count)").bold()
                Text("\(AppLocalization.string("Completed")) \(finished) / \(rows.count)").foregroundStyle(.secondary)
                ForEach(["success", "failed", "running", "pending", "cancelled", "skipped", "unknown"], id: \.self) { value in
                    let count = rows.filter { $0.status == value }.count
                    if count > 0 { Text("\(AppLocalization.string(value)) \(count)").foregroundStyle(batchStatusColor(value)) }
                }
            }.font(.caption)
            if running { ProgressView(value: Double(finished), total: Double(rows.count)).tint(.blue) }
        }
    }
    private func phaseTags(_ rows: [BatchHostResult]) -> some View {
        let groups = batchCheckGroups(rows.flatMap { [$0.authentication, $0.elevation] }, running: running).prefix(2)
        return HStack(spacing: 10) {
            ForEach(Array(groups)) { group in
                Button {
                    phase = phase == group.id ? "" : group.id; status = "all"; host = ""
                } label: {
                    HStack(spacing: 7) {
                        Text(AppLocalization.string(group.id)).fontWeight(.medium)
                        Circle().fill(batchIndicatorColor(group.indicator)).frame(width: 8, height: 8).accessibilityLabel(AppLocalization.string(batchIndicatorLabel(group.indicator)))
                        Text(phaseCounts(group)).foregroundStyle(.secondary)
                    }.font(.caption).padding(.vertical, 4)
                }.tint(phase == group.id ? .blue : nil).help("Show hosts that failed this check")
            }
        }
    }
    private func phaseCounts(_ group: BatchCheckGroup) -> String {
        ["success", "failed", "skipped"].filter { $0 != "skipped" || group.counts[$0, default: 0] > 0 }.map { "\(AppLocalization.string($0)) \(group.counts[$0, default: 0])" }.joined(separator: " · ")
    }
    private func filters(_ rows: [BatchHostResult]) -> some View {
        HStack(spacing: 10) {
            Picker("Result filter", selection: Binding(get: { phase.isEmpty ? status : "" }, set: { status = $0; phase = "" })) {
                Text(AppLocalization.string("All")).tag("all"); Text(AppLocalization.string("Failed only")).tag("failed"); Text(AppLocalization.string("In progress")).tag("running")
            }.pickerStyle(.segmented).frame(width: 220).labelsHidden()
            Picker("Host", selection: $host) { Text(AppLocalization.string("All hosts")).tag(""); ForEach(rows) { row in Text(row.endpoint).tag(row.id) } }.labelsHidden().frame(maxWidth: 280)
            if !phase.isEmpty { Text(AppLocalization.string(phase == "authenticate" ? "Authentication failed" : "Elevation failed")).font(.caption).foregroundStyle(.secondary) }
            if !host.isEmpty || !phase.isEmpty || status != "all" { Button(AppLocalization.string("Clear filters")) { host = ""; phase = ""; status = "all" } }
            Spacer(minLength: 0)
        }
    }
}
private struct BatchHostResultRow: View {
    let host: BatchHostResult
    var progress: BatchEvent?
    @Binding var expanded: Bool
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let transfer = batchTransferProgress(host, event: progress) {
                    ProgressView(value: transfer.transferred, total: transfer.total) { Text("\(Int(min(100, transfer.transferred / transfer.total * 100)))% · \(Int(transfer.transferred)) / \(Int(transfer.total)) bytes").font(.caption) }
                }
                ForEach(host.information.filter { $0.text("status") == "failed" }, id: \.textID) { event in Text(event.text("message")).foregroundStyle(.red).textSelection(.enabled) }
                ForEach(host.steps, id: \.textID) { event in BatchStepDetails(event: event) }
                if let final = host.final {
                    if !final.text("message").isEmpty && !(host.steps + host.information).contains(where: { $0.text("message") == final.text("message") }) {
                        Text(AppLocalization.string(final.text("message"))).font(.caption).foregroundStyle(host.status == "failed" ? .red : .secondary).textSelection(.enabled)
                    }
                    if final.value["remoteStateUnknown"] as? Bool == true { Text(AppLocalization.string("Remote process state is unknown. Verify the host before rerunning.")).font(.caption).foregroundStyle(.orange) }
                }
                if !host.information.isEmpty {
                    DisclosureGroup(AppLocalization.string("Remote temporary directory") + " · " + AppLocalization.string(batchWorkspaceCleanupLabel(host.information[0]))) { ForEach(host.information, id: \.textID) { event in BatchStepOutput(event: event) } }.font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.leading, 12).padding(.vertical, 8)
        } label: {
            HStack(spacing: 12) {
                Text(host.endpoint).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Text(AppLocalization.string(host.label) + (batchTransferProgress(host, event: progress).map { " · \(Int(min(100, $0.transferred / $0.total * 100)))%" } ?? "")).foregroundStyle(batchStatusColor(host.status)).frame(width: 110, alignment: .leading)
                Text((host.final?.value["elapsedMs"] as? Double).map { String(format: "%.1f s", $0 / 1000) } ?? "—").foregroundStyle(.secondary).frame(width: 65, alignment: .trailing)
            }.font(.caption).padding(.vertical, 5)
        }.padding(12)
    }
    private func status(_ value: String) -> some View { Text(AppLocalization.string(value)).foregroundStyle(batchStatusColor(value)) }
}
private extension BatchEvent { var textID: String { batchStepKey(self) } }
private struct BatchStepDetails: View {
    let event: BatchEvent
    var body: some View {
        DisclosureGroup {
            BatchStepOutput(event: event).padding(.leading, 8).padding(.vertical, 8)
        } label: {
            HStack(spacing: 14) {
                Text(AppLocalization.string(event.text("stage"))).fontWeight(.medium)
                Text(AppLocalization.string(event.text("status"))).foregroundStyle(batchStatusColor(event.text("status")))
                if !event.text("remotePath").isEmpty { Text(event.text("remotePath")).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).help(event.text("remotePath")) }
                Spacer(minLength: 0)
            }.font(.caption).padding(.vertical, 5)
        }
    }
}
private struct BatchStepOutput: View {
    let event: BatchEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(["message", "stdout", "stderr", "remoteWorkDirectory", "remoteLogDirectory"], id: \.self) { key in
                if !event.text(key).isEmpty {
                    if ["stdout", "stderr"].contains(key) { Text(key).foregroundStyle(.secondary) }
                    if key == "remoteLogDirectory" { Text(AppLocalization.string("Remote log directory")).foregroundStyle(.secondary) }
                    if key == "remoteWorkDirectory" { Text(AppLocalization.string("Remote temporary directory")).foregroundStyle(.secondary) }
                    Text(key == "message" ? AppLocalization.string(event.text(key)) : event.text(key)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            if event.value["stdoutTruncated"] as? Bool == true || event.value["stderrTruncated"] as? Bool == true { Text(AppLocalization.string("Showing the latest 64 KiB per stream. Download complete logs for earlier output.")).foregroundStyle(.secondary) }
            if let code = event.value["exitCode"] as? Int { Text("Exit: \(code)") }
            if !event.text("localPath").isEmpty { Button(event.text("localPath")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: event.text("localPath"))]) } }
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }
}
private func batchStatusColor(_ status: String) -> Color {
    switch status { case "success": .green; case "failed": .red; case "running": .blue; case "unknown": .orange; default: .secondary }
}
private func batchIndicatorColor(_ indicator: String) -> Color {
    switch indicator { case "success": .green; case "failed": .red; case "mixed": .yellow; case "running": .blue; default: .gray }
}
private func batchIndicatorLabel(_ indicator: String) -> String {
    switch indicator { case "success": "All succeeded"; case "failed": "All failed"; case "mixed": "Partially succeeded"; case "running": "Checks in progress"; default: "Not all checks completed" }
}
