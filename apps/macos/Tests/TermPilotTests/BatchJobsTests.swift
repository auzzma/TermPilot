import AppKit
import SwiftUI
import TermPilotCore
import TermPilotDomain
@testable import TermPilotApp
import XCTest

final class BatchJobsTests: XCTestCase {
    @MainActor
    func testEditorDefersModelReplacementAndPreservesMarkedInput() async {
        var model = "abc"
        let binding = Binding(get: { model }, set: { model = $0 })
        let coordinator = BatchTextEditor.Coordinator(text: binding)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        editor.string = model
        editor.setSelectedRange(NSRange(location: 2, length: 1))
        editor.delegate = coordinator

        model = "first import"
        coordinator.syncAfterLayout(editor)
        model = "新脚本"
        coordinator.syncAfterLayout(editor)
        XCTAssertEqual(editor.string, "abc")
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        XCTAssertEqual(editor.string, "新脚本")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 1))

        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.hasMarkedText())
        coordinator.syncAfterLayout(editor)
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(editor.string.contains("ni"))
        editor.insertText("你", replacementRange: editor.markedRange())
        XCTAssertEqual(model, editor.string)
        XCTAssertTrue(model.contains("你"))
    }

    @MainActor
    func testBatchConnectionReadsCurrentHostKeyPreferenceAndKeepsResolvedCredentials() throws {
        let defaults = UserDefaults.standard
        let key = AppPreferences.autoAcceptSSHHostKeys
        let previous = defaults.object(forKey: key)
        defer { defaults.set(previous, forKey: key) }
        let target = BatchTarget(host: TermPilotDomain.Host(label: "Fixture", hostname: "192.0.2.10",
            username: "", authentication: .password, credentialID: UUID()), elevation: "sudo")
        var resolved = target.host
        resolved.username = "fixture"
        resolved.password = "fixture-password"
        let knownHosts = URL(fileURLWithPath: "/tmp/termpilot-batch-fixture-known-hosts")

        for enabled in [nil, true, false, true] as [Bool?] {
            defaults.set(enabled, forKey: key)
            let config = try BatchJobController.connectionConfiguration(for: target,
                resolvedHost: resolved, knownHostsFile: knownHosts)
            XCTAssertEqual(config["autoAcceptHostKeys"] as? Bool, enabled ?? false)
            XCTAssertEqual(config["knownHostsFile"] as? String, knownHosts.path)
            XCTAssertEqual(config["username"] as? String, "fixture")
            XCTAssertEqual(config["password"] as? String, "fixture-password")
            XCTAssertEqual(config["batchCredentialId"] as? String, target.host.credentialID?.uuidString)
            XCTAssertEqual(config["batchElevation"] as? String, "sudo")
            XCTAssertEqual(config["elevationPassword"] as? String, "fixture-password")
        }
    }

    @MainActor
    func testBackgroundRecoveryPreservesOriginalEndpointAndCredentialReference() throws {
        let state = AppState(), controller = BatchJobController()
        let hostID = UUID(), credential = UUID()
        controller.backgroundTasks = [BatchBackgroundTask(targetId: hostID.uuidString, remoteTaskId: UUID().uuidString, hostname: "192.0.2.10", port: 2222, username: "ops", credentialId: credential.uuidString, elevation: "su")]
        let restored = try XCTUnwrap(controller.restoredBackgroundTargets(state: state).first)
        XCTAssertEqual(restored.host.id, hostID)
        XCTAssertEqual(restored.host.hostname, "192.0.2.10")
        XCTAssertEqual(restored.host.port, 2222)
        XCTAssertEqual(restored.host.credentialID, credential)
        XCTAssertNil(restored.host.password)
        XCTAssertEqual(restored.elevation, "su")
        XCTAssertEqual(BatchJob().executionMode, "foreground")
        let job = BatchJob()
        XCTAssertEqual([job.script.shell, job.before.shell, job.after.shell],
            ["/bin/bash", "/bin/bash", "/bin/bash"])
    }
    func testBackgroundRunningSurvivesLocalWorkerExitInResults() {
        let final = BatchEvent(value: ["type":"batchHost", "targetId":"1", "ip":"192.0.2.1", "stage":"finished", "status":"running", "background":true])
        let workspace = BatchEvent(value: ["type":"batchHost", "targetId":"1", "stage":"workspace", "status":"success", "cleanupStatus":"pending"])
        let rows = batchHostResults([phase("1", "authenticate", "success"), phase("1", "elevation", "success"), phase("1", "execute", "running"), workspace, final], running: false)
        XCTAssertEqual(rows[0].status, "running")
        XCTAssertEqual(rows[0].label, "Background running")
        XCTAssertEqual(rows[0].steps.last?.text("status"), "running")
        XCTAssertEqual(rows[0].information.first?.text("cleanupStatus"), "pending")
    }

    private func phase(_ id: String, _ stage: String, _ status: String) -> BatchEvent {
        BatchEvent(value: ["type": "batchHost", "targetId": id, "ip": "192.0.2.\(id)", "port": 22, "stage": stage, "status": status])
    }
    func testWorkspaceCleanupOutcomePersistsAndLabelsFailures() {
        let workspace = BatchEvent(value: phase("1", "workspace", "success").value.merging(["remoteWorkDirectory":"/tmp/ssh-batch-a6e2a19e-6902-428d-bbcf-c50e9e85ace1", "cleanupStatus":"pending"]) { _, new in new })
        var cleanup = workspace; cleanup.value["status"] = "running"; cleanup.value["cleanupStatus"] = "running"
        var events = [phase("1", "authenticate", "success"), phase("1", "elevation", "success"), workspace, phase("1", "execute", "success"), cleanup]
        XCTAssertEqual(batchHostResults(events, running: true)[0].label, "Cleaning temporary directory")
        XCTAssertEqual(batchWorkspaceCleanupLabel(batchHostResults(events, running: false)[0].information[0]), "Cleanup status unknown")
        cleanup.value["status"] = "failed"; cleanup.value["cleanupStatus"] = "failed"
        events += [cleanup, phase("1", "finished", "failed")]
        var steps: [String: BatchEvent] = [:]; for event in events { batchUpdateSteps(&steps, event) }
        let row = batchHostResults(Array(steps.values), running: false)[0]
        XCTAssertEqual(row.label, "Temporary directory cleanup failed"); XCTAssertTrue(row.hasFailure)
        XCTAssertEqual(row.information.count, 1)
        XCTAssertEqual(batchWorkspaceCleanupLabel(row.information[0]), "Temporary directory cleanup failed")
        XCTAssertEqual(batchWorkspaceCleanupLabel(phase("1", "workspace", "success")), "Cleanup status unknown")
    }
    @MainActor
    func testDownloadRetryUsesPersistedStepsAndRejectsCleanedTemporaryFiles() throws {
        let host = TermPilotDomain.Host(label: "Fixture", hostname: "192.0.2.1", username: "ops")
        let target = BatchTarget(host: host)
        let directory = "/tmp/ssh-batch-a6e2a19e-6902-428d-bbcf-c50e9e85ace1"
        var workspace = BatchEvent(value: phase(host.id.uuidString, "workspace", "success").value.merging(["remoteWorkDirectory":directory, "sourceTaskId":"source"]) { _, new in new })
        let final = phase(host.id.uuidString, "finished", "failed")
        var job = BatchJob(); job.kind = "collect"; job.remotePaths = ["${REMOTE_WORK_DIR}/result.log"]
        XCTAssertEqual(try batchDownloadRetryPlan(job: job, events: [workspace, final], targets: [target]).directory, directory)
        let controller = BatchJobController(); controller.targets = [target]
        for status in ["pending", "running", "success", "failed"] {
            workspace.value["cleanupStatus"] = status
            controller.steps = [:]; batchUpdateSteps(&controller.steps, workspace); batchUpdateSteps(&controller.steps, final)
            for path in ["${REMOTE_WORK_DIR}/result.log", directory + "/result.log"] {
                job.remotePaths = [path]; controller.job = job
                XCTAssertThrowsError(try batchDownloadRetryPlan(job: job, events: [workspace, final], targets: [target]))
                XCTAssertFalse(controller.downloadRetryError.isEmpty)
            }
        }
        job.remotePaths = ["/var/log/app-${TASK_ID}.log"]; controller.job = job
        let retry = try batchDownloadRetryPlan(job: job, events: Array(controller.steps.values), targets: [target])
        XCTAssertEqual(retry.directory, ""); XCTAssertEqual(retry.sourceTaskID, "source")
        XCTAssertTrue(controller.downloadRetryError.isEmpty)
    }
    func testCheckCategoryIndicatorsAndPendingHosts() {
        for (statuses, indicator) in [(["success", "success"], "success"), (["failed", "failed"], "failed"), (["success", "failed"], "mixed")] {
            let events = statuses.enumerated().flatMap { index, status in batchCheckStages.map { phase(String(index), $0, status) } }
            XCTAssertEqual(batchCheckGroups(events, running: false).map(\.indicator), Array(repeating: indicator, count: 3))
        }
        let groups = batchCheckGroups([phase("1", "finished", "success"), phase("2", "authenticate", "pending")], running: true)
        XCTAssertEqual(groups.map(\.indicator), ["running", "running", "running"])
        XCTAssertEqual(groups[0].counts["success"], 1)
        XCTAssertEqual(groups[0].counts["pending"], 1)
        XCTAssertEqual(batchCheckGroups([phase("1", "finished", "success")], running: false).map(\.indicator), ["success", "success", "success"])
    }
    func testLegacyHistoryKeepsAuthenticationSeparateFromElevationFailure() {
        let groups = batchCheckGroups([phase("1", "connect", "running"), phase("1", "authenticate", "success"), phase("1", "finished", "failed"), phase("2", "connect", "running"), phase("2", "finished", "failed")], running: false)
        XCTAssertEqual(groups[0].indicator, "mixed")
        XCTAssertEqual(groups[1].counts["failed"], 1)
        XCTAssertEqual(groups[1].counts["skipped"], 1)
        XCTAssertEqual(groups[2].indicator, "failed")
        XCTAssertEqual(batchCheckGroups([phase("1", "authenticate", "running")], running: false)[0].hosts[0].event.text("status"), "unknown")
        XCTAssertEqual(batchCheckGroups([phase("1", "finished", "cancelled")], running: false)[2].indicator, "neutral")
    }
    func testStepsMergeWithoutLosingOutputsOrRepeatedCollections() {
        let events = [phase("1", "authenticate", "success"), phase("1", "elevation", "success"),
            BatchEvent(value: phase("1", "collect", "running").value.merging(["stepId":"collect-0", "remotePath":"/log", "localPath":"/saved/log"]) { _, new in new }),
            BatchEvent(value: phase("1", "collect", "success").value.merging(["stepId":"collect-0", "remotePath":"/log"]) { _, new in new }),
            BatchEvent(value: phase("1", "collect", "success").value.merging(["stepId":"collect-1", "remotePath":"/log", "localPath":"/saved/log-1"]) { _, new in new }),
            phase("1", "collection", "success"), phase("1", "finished", "success")]
        var saved: [String: BatchEvent] = [:]
        for event in events { batchUpdateSteps(&saved, event) }
        let row = batchHostResults(Array(saved.values), running: false)[0]
        XCTAssertEqual(row.steps.filter { $0.text("stage") == "collect" }.count, 2)
        XCTAssertEqual(row.steps.first { $0.text("stepId") == "collect-0" }?.text("localPath"), "/saved/log")
        XCTAssertFalse(row.steps.contains { $0.text("status") == "running" || $0.text("stage") == "collection" || $0.text("stage") == "finished" })
    }
    func testHostFiltersCancellationAndProgressAreScopedToCurrentStep() {
        let transfer = BatchEvent(value: ["event":["message":["id":"upload-1", "transferred":40.0, "total":100.0]]])
        let events = [phase("1", "authenticate", "success"), phase("1", "elevation", "success"),
            BatchEvent(value: phase("1", "upload", "running").value.merging(["stepId":"upload-1", "remotePath":"/new"]) { _, new in new }),
            phase("2", "authenticate", "success"), phase("2", "elevation", "failed"), phase("2", "finished", "failed")]
        let rows = batchHostResults(events, running: true)
        XCTAssertEqual(rows[0].id, "2"); XCTAssertEqual(rows[0].label, "Elevation failed")
        XCTAssertEqual(batchFilterHostResults(rows, status: "failed", phase: "", host: "").map(\.id), ["2"])
        XCTAssertTrue(batchFilterHostResults(rows, status: "all", phase: "authenticate", host: "").isEmpty)
        XCTAssertEqual(batchFilterHostResults(rows, status: "all", phase: "elevation", host: "").map(\.id), ["2"])
        XCTAssertEqual(batchFilterHostResults(rows, status: "running", phase: "", host: "").map(\.id), ["1"])
        XCTAssertEqual(batchTransferProgress(rows[1], event: transfer)?.transferred, 40)
        let stopped = batchHostResults(events + [phase("1", "finished", "cancelled")], running: false)
        XCTAssertEqual(stopped[1].steps.first { $0.text("stage") == "upload" }?.text("status"), "cancelled")
        XCTAssertNil(batchTransferProgress(stopped[1], event: transfer))
        XCTAssertFalse(batchHostResults(events, running: false).flatMap(\.steps).contains { $0.text("status") == "running" })
    }
    func testGroupSelectionIncludesDescendantsAndPreservesAddedHosts() {
        let parent = HostGroup(name: "生产环境"), childID = UUID()
        let groups = [parent, HostGroup(id: childID, name: "数据库", parentGroupID: parent.id)]
        let first = TermPilotDomain.Host(label: "Web", hostname: "192.0.2.1", username: "ops", groupID: parent.id)
        let second = TermPilotDomain.Host(label: "DB", hostname: "192.0.2.2", username: "ops", groupID: childID)
        let other = TermPilotDomain.Host(label: "Other", hostname: "192.0.2.3", username: "ops")
        let rdp = TermPilotDomain.Host(label: "RDP", hostname: "192.0.2.4", connectionKind: .rdp, username: "ops")
        let available = batchSelectableHosts([first, second, other, rdp, first])
        XCTAssertEqual(available.count, 3)
        let ids = batchGroupHostIDs(parent.id, hosts: available, groups: groups)
        XCTAssertEqual(ids, Set([first.id, second.id]))
        XCTAssertEqual(batchGroupHostIDs(nil, hosts: available, groups: groups), Set([other.id]))
        XCTAssertEqual(batchGroupPath(childID, groups: groups), "生产环境 / 数据库")
        let selected = batchToggleSelection([], ids: ids, alreadyAdded: [first.id])
        XCTAssertEqual(selected, Set([second.id]))
        XCTAssertTrue(batchToggleSelection(selected, ids: ids, alreadyAdded: [first.id]).isEmpty)
        let closed = batchHostTreeRows(hosts: available, groups: groups, query: "", expanded: [])
        XCTAssertEqual(closed.map(\.id), [parent.id.uuidString, "ungrouped"])
        let open = Set([parent.id.uuidString, childID.uuidString])
        let rows = batchHostTreeRows(hosts: available, groups: groups, query: "", expanded: open)
        XCTAssertEqual(rows.map(\.id), [parent.id.uuidString, "host:\(first.id)", childID.uuidString, "host:\(second.id)", "ungrouped"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 2, 0])
        XCTAssertEqual(batchHostTreeRows(hosts: available, groups: groups, query: "192.0.2.2", expanded: open).map(\.id), [parent.id.uuidString, childID.uuidString, "host:\(second.id)"])
    }
    @MainActor
    func testTemporaryIPsKeepCredentialReferenceAndElevationWithoutSavingHosts() throws {
        let batch = BatchJobController()
        let id = UUID()
        try batch.addIPs("192.0.2.10\n192.0.2.10:22\n[::1]:2222", port: 22, credential: id, elevation: "su", password: "fixture-root")
        XCTAssertEqual(batch.targets.count, 2)
        XCTAssertEqual(batch.targets[0].host.credentialID, id)
        XCTAssertNil(batch.targets[0].host.password)
        XCTAssertEqual(batch.targets[0].elevation, "su")
        XCTAssertEqual(batch.targets[0].elevationPassword, "fixture-root")
        XCTAssertEqual(batch.targets[1].host.port, 2222)
        XCTAssertThrowsError(try batch.addIPs("192.0.2.1:0", port: 22, credential: id, elevation: "none", password: ""))
        XCTAssertEqual(batch.targets.count, 2)
    }
    func testSwiftDefinitionMatchesSharedValidationAndRejectsUnsafePermission() throws {
        var job = BatchJob()
        job.kind = "upload"; job.localPaths = ["/tmp/fixture"]; job.remoteDirectory = "/opt/fixture"
        func validate(_ job: BatchJob) throws -> [String: Any] {
            try SharedCore.call(["method": "batch.validate", "job": JSONSerialization.jsonObject(with: JSONEncoder().encode(job))])
        }
        XCTAssertEqual(try validate(job)["valid"] as? Bool, true)
        job.stepTimeout = 0
        XCTAssertEqual(try validate(job)["valid"] as? Bool, true)
        job.fileMode = "0644; touch /tmp/never"
        XCTAssertNotNil(try validate(job)["error"])
    }
    @MainActor
    func testNativeBatchFormsAndConflictListRenderUsingIsolatedFixtures() throws {
        let state = AppState()
        let batch = BatchJobController()
        try batch.addIPs("192.0.2.10\n192.0.2.11", port: 22, credential: UUID(), elevation: "sudo", password: "")
        batch.job.stepTimeout = 0
        batch.job.script.body = "id\nhostname"
        batch.job.before.body = "tar -czf \"$REMOTE_WORK_DIR/diagnostics.tar.gz\" /var/log"
        batch.job.after.body = "rm -rf -- \"$REMOTE_WORK_DIR\""
        batch.job.remotePaths = ["${REMOTE_WORK_DIR}/diagnostics.tar.gz"]
        batch.job.localDirectory = "/tmp/collection"
        batch.job.remoteDirectory = "/opt/app"
        batch.job.localPaths = ["/tmp/diagnostics.sh"]
        let conflict = BatchEvent(value: ["stage":"conflict","targetId":"fixture","ip":"192.0.2.10","remotePath":"/opt/app/diagnostics.sh","policy":"backup","status":"success"])
        let group = HostGroup(name: "生产环境")
        let child = HostGroup(name: "数据库", parentGroupID: group.id)
        let hosts = [TermPilotDomain.Host(label: "Web 01", hostname: "192.0.2.10", username: "ops", groupID: group.id), TermPilotDomain.Host(label: "数据库 01", hostname: "192.0.2.11", username: "ops", groupID: child.id), TermPilotDomain.Host(label: "测试服务器", hostname: "192.0.2.12", username: "ops")]
        let checks = [phase("10", "authenticate", "success"), phase("11", "authenticate", "success"), phase("10", "elevation", "success"), phase("11", "elevation", "failed"), phase("10", "execute", "running"), BatchEvent(value: phase("10", "execute", "success").value.merging(["stdout":"uid=0(root) gid=0(root)\nweb-01", "exitCode":0]) { _, new in new }), BatchEvent(value: phase("10", "finished", "success").value.merging(["elapsedMs":1250.0]) { _, new in new }), phase("11", "finished", "failed")]
        let allEvents = checks + [BatchEvent(value: phase("10", "workspace", "success").value.merging(["remoteWorkDirectory":"/tmp/ssh-batch-a6e2a19e-6902-428d-bbcf-c50e9e85ace1", "cleanupStatus":"success"]) { _, new in new })]
        for scheme in [ColorScheme.light, .dark] {
            for kind in ["execute", "upload", "collect", "conflicts", "host-picker", "host-results", "workspace-results", "target-manager", "background-config", "background-results"] {
                batch.section = kind.hasSuffix("-results") ? "results" : "configuration"
                batch.job.kind = kind.hasPrefix("background") ? "execute" : kind
                batch.job.executionMode = kind.hasPrefix("background") ? "background" : "foreground"
                batch.backgroundTasks = kind.hasPrefix("background") ? [BatchBackgroundTask(targetId: "10", remoteTaskId: UUID().uuidString, hostname: "192.0.2.10", port: 22, username: "ops", elevation: "sudo")] : []
                let content: AnyView
                switch kind {
                case "background-results":
                    batch.steps = [:]
                    for event in [phase("10", "authenticate", "success"), phase("10", "elevation", "success"), phase("10", "execute", "running"), BatchEvent(value: ["type":"batchHost", "targetId":"10", "ip":"192.0.2.10", "stage":"finished", "status":"running", "background":true])] { batchUpdateSteps(&batch.steps, event) }
                    content = AnyView(BatchJobsView().environmentObject(state).environmentObject(batch))
                case "target-manager": content = AnyView(BatchTargetManager(defaults: .constant(BatchTargetDefaults())).environmentObject(state).environmentObject(batch))
                case "workspace-results":
                    batch.steps = [:]
                    for event in allEvents { batchUpdateSteps(&batch.steps, event) }
                    content = AnyView(BatchJobsView().environmentObject(state).environmentObject(batch))
                case "conflicts": content = AnyView(BatchConflictList(events: [conflict]))
                case "host-picker": content = AnyView(BatchHostPicker(hosts: hosts, groups: [group, child], added: [hosts[0]], onAdd: { _ in }))
                case "host-results": content = AnyView(BatchHostResults(rows: batchHostResults(allEvents, running: false), running: false, initiallyExpanded: true).padding(20))
                default: content = AnyView(BatchJobsView().environmentObject(state).environmentObject(batch))
                }
                let size = NSSize(width: kind == "host-picker" || kind == "target-manager" ? 900 : 1000, height: kind == "conflicts" ? 220 : kind == "host-picker" || kind == "host-results" ? 630 : 780)
                let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "zh-Hans")).background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 1000)
                if let path = ProcessInfo.processInfo.environment["TERMPILOT_BATCH_SNAPSHOT_DIR"] {
                    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                    try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("batch-\(kind)-\(scheme).png"))
                }
                window.contentView = nil; window.close()
            }
        }
        XCTAssertFalse(batch.running)
    }
}
