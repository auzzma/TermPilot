import Foundation

func batchStepKey(_ event: BatchEvent) -> String {
    let parts = [event.text("targetId"), event.text("stage"), event.text("stepId").isEmpty ? event.text("remotePath") : event.text("stepId")]
    return String(data: try! JSONSerialization.data(withJSONObject: parts), encoding: .utf8)!
}
func batchUpdateSteps(_ steps: inout [String: BatchEvent], _ event: BatchEvent) {
    guard event.text("type") == "batchHost", !event.text("targetId").isEmpty, !event.text("stage").isEmpty else { return }
    let key = batchStepKey(event)
    steps[key] = BatchEvent(value: (steps[key]?.value ?? [:]).merging(event.value) { _, new in new })
}
struct BatchHostResult: Identifiable {
    var id: String
    var ip: String
    var endpoint: String
    var status: String
    var label: String
    var authentication: BatchEvent
    var elevation: BatchEvent
    var steps: [BatchEvent]
    var information: [BatchEvent]
    var final: BatchEvent?
    var hasFailure: Bool
    var failedSteps: [BatchEvent]
}
func batchHostResults(_ events: [BatchEvent], running: Bool) -> [BatchHostResult] {
    var latest: [String: BatchEvent] = [:]
    for event in events { batchUpdateSteps(&latest, event) }
    let values = Array(latest.values)
    let checks = batchCheckGroups(values, running: running)
    let hosts = Dictionary(grouping: values, by: { $0.text("targetId") })
    let order = ["authenticate", "elevation", "workspace", "prepare", "execute", "upload", "collect", "collection", "cleanup"]
    let failures = ["authenticate":"Authentication failed", "elevation":"Elevation failed", "workspace":"Workspace failed", "prepare":"Preparation failed", "execute":"Execution failed", "upload":"Upload failed", "collect":"Collection failed", "collection":"Collection failed", "cleanup":"Cleanup failed"]
    return hosts.map { id, records in
        let final = records.first { $0.text("stage") == "finished" }
        let base = records.first { !$0.text("ip").isEmpty } ?? records[0]
        func normalize(_ original: BatchEvent) -> BatchEvent {
            var event = original
            if final?.value["background"] as? Bool == true && ["running", "unknown"].contains(final?.text("status") ?? "") { return event }
            if (!running || final != nil) && ["pending", "running"].contains(event.text("cleanupStatus")) { event.value["cleanupStatus"] = "unknown" }
            guard ["running", "pending"].contains(event.text("status")), !(running && final == nil) else { return event }
            var value = event.value
            let status = final?.text("status") ?? ""
            value["status"] = ["cancelled", "skipped"].contains(status) ? status : status == "failed" && event.text("status") == "running" ? "failed" : "unknown"
            if event.text("message").isEmpty { value["message"] = final?.value["message"] }
            return BatchEvent(value: value)
        }
        func check(_ index: Int, stage: String) -> BatchEvent {
            normalize(checks[index].hosts.first { $0.id == id }?.event ?? BatchEvent(value: base.value.merging(["stage":stage,"status":"unknown"]) { _, new in new }))
        }
        let authentication = check(0, stage: "authenticate"), elevation = check(1, stage: "elevation")
        var steps = records.filter { !["connect", "authenticate", "elevation", "finished", "conflict"].contains($0.text("stage")) }.map(normalize)
        steps = steps.filter { event in event.text("stage") != "collection" || (event.text("status") == "failed" && !steps.contains { ["prepare", "collect"].contains($0.text("stage")) && $0.text("status") == "failed" }) }
        func precedes(_ a: BatchEvent, _ b: BatchEvent) -> Bool {
            let lhs = order.firstIndex(of: a.text("stage")) ?? order.count, rhs = order.firstIndex(of: b.text("stage")) ?? order.count
            if lhs != rhs { return lhs < rhs }
            let aKey = a.text("stepId").isEmpty ? a.text("remotePath") : a.text("stepId")
            let bKey = b.text("stepId").isEmpty ? b.text("remotePath") : b.text("stepId")
            return aKey.localizedStandardCompare(bKey) == .orderedAscending
        }
        steps = ([authentication, elevation] + steps).sorted(by: precedes)
        let failed = steps.first { $0.text("status") == "failed" }
        let active = steps.last { $0.text("status") == "running" }
        let status = final?.text("status") ?? (running ? (active != nil || authentication.text("status") != "pending" ? "running" : "pending") : "unknown")
        let label: String
        if status == "failed", let failed { label = failed.text("cleanupStatus") == "failed" ? "Temporary directory cleanup failed" : failures[failed.text("stage")] ?? "Failed" }
        else if status == "running", final?.value["background"] as? Bool == true { label = "Background running" }
        else if status == "running", let active { label = active.text("cleanupStatus") == "running" ? "Cleaning temporary directory" : active.text("stage") }
        else { label = status == "failed" ? "Failed" : status }
        let ip = base.text("ip").isEmpty ? id : base.text("ip")
        let endpoint = (ip.contains(":") ? "[\(ip)]" : ip) + ((base.value["port"] as? Int).map { ":\($0)" } ?? "")
        // Older histories may only have a final error. Keep actual failed steps
        // distinct from the inferred phase indicators used by the result table.
        let failedSteps = records.filter { $0.text("stage") != "finished" && $0.text("status") == "failed" }.sorted(by: precedes)
        return BatchHostResult(id: id, ip: base.text("ip"), endpoint: endpoint, status: status, label: label, authentication: authentication, elevation: elevation, steps: steps.filter { $0.text("stage") != "workspace" }, information: steps.filter { $0.text("stage") == "workspace" }, final: final, hasFailure: failed != nil || status == "failed", failedSteps: failedSteps)
    }.sorted { a, b in
        if a.hasFailure != b.hasFailure { return a.hasFailure }
        if a.endpoint != b.endpoint { return a.endpoint < b.endpoint }
        return a.id < b.id
    }
}
func batchFilterHostResults(_ hosts: [BatchHostResult], status: String, phase: String, host: String) -> [BatchHostResult] {
    hosts.filter { h in (host.isEmpty || h.id == host) && (status != "failed" || h.hasFailure) && (status != "running" || ["pending", "running"].contains(h.status)) && (phase != "authenticate" || h.authentication.text("status") == "failed") && (phase != "elevation" || h.elevation.text("status") == "failed") }
}
func batchTransferProgress(_ host: BatchHostResult, event: BatchEvent?) -> (transferred: Double, total: Double)? {
    guard host.final == nil, let raw = event?.value["event"] as? [String: Any], let message = raw["message"] as? [String: Any], let id = message["id"] as? String, let total = message["total"] as? Double, total > 0,
          host.steps.contains(where: { $0.text("status") == "running" && $0.text("stepId") == id && ["upload", "collect"].contains($0.text("stage")) }) else { return nil }
    return (message["transferred"] as? Double ?? 0, total)
}

/// Fresh workspaces are finalized even on failure. Only legacy history can reuse one.
func batchDownloadRetryPlan(job: BatchJob, events: [BatchEvent], targets: [BatchTarget]) throws -> (directory: String, sourceTaskID: String) {
    let failed = Set(events.filter { $0.text("stage") == "finished" && ["failed", "cancelled"].contains($0.text("status")) }.map { $0.text("targetId") })
    let selected = targets.filter { failed.contains($0.id.uuidString) }
    guard selected.count == 1 else { throw BatchError.message("Select one failed host for download-only retry.") }
    let records = events.filter { $0.text("targetId") == selected[0].id.uuidString }
    guard let workspace = records.first(where: { !$0.text("remoteWorkDirectory").isEmpty })?.text("remoteWorkDirectory") else { throw BatchError.message("No remote workspace is available for this host.") }
    let managed = records.contains { !$0.text("cleanupStatus").isEmpty }
    if managed && job.remotePaths.contains(where: { $0.contains("${REMOTE_WORK_DIR}") || $0.contains(workspace) }) {
        throw BatchError.message("Temporary collection files cannot be reused. Rerun collection to recreate them.")
    }
    return (managed ? "" : workspace, records.first(where: { !$0.text("sourceTaskId").isEmpty })?.text("sourceTaskId") ?? "")
}
func batchWorkspaceCleanupLabel(_ event: BatchEvent) -> String {
    switch event.text("cleanupStatus") {
    case "pending": "Cleanup pending"
    case "running": "Cleaning temporary directory"
    case "success": "Temporary directory removed"
    case "failed": "Temporary directory cleanup failed"
    default: "Cleanup status unknown"
    }
}
