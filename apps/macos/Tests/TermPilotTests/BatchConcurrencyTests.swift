import AppKit
import SwiftUI
@testable import TermPilotApp
import TermPilotDomain
import TermPilotPersistence
import XCTest

@MainActor
final class BatchConcurrencyTests: XCTestCase {
    func testSwitchingJobsKeepsDraftsIsolatedAndRunningTabsOpen() throws {
        let state = AppState(), workspace = state.batchJobs
        let first = workspace.selected
        first.job.script.body = "first-script"
        first.targetDefaults.port = 2201
        let second = workspace.newJob()
        XCTAssertTrue(second.job.script.body.isEmpty && second.targets.isEmpty)
        XCTAssertEqual(second.targetDefaults.port, 22)
        second.job.script.body = "second-script"
        first.running = true
        workspace.close(first)
        XCTAssertEqual(workspace.jobs.count, 2)

        let view = NSHostingView(rootView: BatchWorkspaceView().environmentObject(workspace).environmentObject(state)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close(); workspace.shutdown() }
        window.orderFront(nil)
        func editors(_ v: NSView) -> [NSTextView] { (v as? NSTextView).map { [$0] } ?? v.subviews.flatMap(editors) }
        for job in [second, first, second] {
            workspace.selected = job
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            XCTAssertTrue(editors(view).contains { $0.string == job.job.script.body })
        }
        if let folder = ProcessInfo.processInfo.environment["TERMPILOT_BATCH_SNAPSHOT_DIR"] {
            let directory = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("concurrent-jobs.png"))
        }
        workspace.close(second)
        XCTAssertTrue(workspace.selected === first)
        let copied = workspace.newJob(copying: first)
        XCTAssertEqual(copied.number, 3)
        XCTAssertEqual(copied.job.script.body, "first-script")
        XCTAssertEqual(copied.targetDefaults.port, 2201)
        XCTAssertFalse(copied.running)
        XCTAssertTrue(copied.checks.isEmpty && copied.historyJobId.isEmpty)
        copied.job.script.body = "changed-copy"
        XCTAssertEqual(first.job.script.body, "first-script")
    }

    func testTwoWorkersRunOnTheSameSSHHostAndCancelIndependently() async throws {
        guard let engine = ProcessInfo.processInfo.environment["TERMPILOT_TEST_ENGINE"],
              ProcessInfo.processInfo.environment["TERMPILOT_TEST_DATA_DIRECTORY"] != nil else {
            throw XCTSkip("Requires the local SSH fixture, engine, and an isolated data directory")
        }
        _ = try VaultStore.openDefault()
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let fixture = Process(), input = Pipe(), output = Pipe()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        fixture.arguments = ["node", root.appendingPathComponent("tests/node/batch-worker.test.cjs").path, "--fixture"]
        fixture.standardInput = input; fixture.standardOutput = output
        try fixture.run()
        defer { try? input.fileHandleForWriting.close(); fixture.waitUntilExit() }
        let info = try XCTUnwrap(try JSONSerialization.jsonObject(with: output.fileHandleForReading.availableData) as? [String: Any])
        let directory = URL(fileURLWithPath: try XCTUnwrap(info["directory"] as? String))
        let gate = directory.appendingPathComponent("release-script")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("engine"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("engine/termpilot-engine").path,
                                                   withDestinationPath: engine)
        let state = AppState(), workspace = BatchJobWorkspace(resources: directory)
        defer { try? Data().write(to: gate); workspace.shutdown() }

        let key = AppPreferences.autoAcceptSSHHostKeys
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set(false, forKey: key)
        let host = TermPilotDomain.Host(label: "fixture", hostname: "127.0.0.1", port: try XCTUnwrap(info["port"] as? Int),
                                        username: "fixture", authentication: .password, password: "batch-fixture-login-password")
        let first = workspace.selected
        first.append([BatchTarget(host: host)])
        first.job.script.body = "while [ ! -e '\(gate.path)' ]; do sleep .1; done; printf FIRST"
        first.job.stepTimeout = 20
        async let launch: Void = first.start(state: state)
        async let repeatedClick: Void = first.start(state: state)
        _ = await (launch, repeatedClick)
        try await waitFor("first worker prompt", jobs: [first]) { !first.prompts.isEmpty }

        let second = workspace.newJob()
        second.append([BatchTarget(host: host)])
        second.job.script.body = "while [ ! -e '\(gate.path)' ]; do sleep .1; done; printf SECOND"
        second.job.stepTimeout = 20
        await second.start(state: state)
        try await waitFor("both workers waiting", jobs: [first, second]) { workspace.awaitingConfirmation.count == 2 }
        XCTAssertTrue(workspace.awaitingConfirmation.first === first)
        XCTAssertTrue(workspace.promptJob === second)
        workspace.selected = first
        XCTAssertTrue(workspace.promptJob === first)
        await first.reply(try XCTUnwrap(first.prompts.first), accepted: true, secret: "")
        XCTAssertTrue(workspace.awaitingConfirmation.first === second)
        await second.reply(try XCTUnwrap(second.prompts.first), accepted: true, secret: "")
        func executing(_ job: BatchJobController) -> Bool {
            job.steps.values.contains { $0.text("stage") == "execute" && $0.text("status") == "running" }
        }
        try await waitFor("both scripts executing", jobs: [first, second]) { executing(first) && executing(second) }
        XCTAssertNotEqual(first.reportDirectory, second.reportDirectory)
        XCTAssertTrue(workspace.openHistory(first.historyJobId, state: state))
        XCTAssertTrue(workspace.selected === first)
        XCTAssertEqual(workspace.jobs.count, 2)
        let firstID = first.historyJobId
        await first.start(state: state)
        XCTAssertEqual(first.historyJobId, firstID)
        await first.cancel()
        try await waitFor("only first cancelled", jobs: [first, second]) { !first.running }
        XCTAssertTrue(second.running && executing(second))
        XCTAssertTrue(first.checks.values.contains { $0.text("stage") == "finished" && $0.text("status") == "cancelled" })
        first.job.script.body = "printf RETRIED"
        await first.start(state: state, retry: "failed")
        try await waitFor("first retried while second runs", jobs: [first, second]) { !first.running }
        XCTAssertNotEqual(first.historyJobId, firstID)
        XCTAssertTrue(first.steps.values.contains { $0.text("stdout") == "RETRIED" })
        XCTAssertTrue(second.running && executing(second))
        try Data().write(to: gate)
        try await waitFor("second completed", jobs: [second]) { !second.running }
        XCTAssertTrue(second.steps.values.contains { $0.text("stdout") == "SECOND" })
        XCTAssertTrue(second.checks.values.contains { $0.text("stage") == "finished" && $0.text("status") == "success" })
        workspace.close(first)
        XCTAssertTrue(workspace.openHistory(firstID, state: state))
        XCTAssertTrue(workspace.selected.checks.values.contains { $0.text("status") == "cancelled" })
        XCTAssertTrue(workspace.selected.job.script.body.isEmpty)
        XCTAssertEqual(workspace.selected.targets.map(\.id), [host.id])
        XCTAssertNil(workspace.selected.targets.first?.host.password)
        XCTAssertTrue(second.steps.values.contains { $0.text("stdout") == "SECOND" })
    }

    private func waitFor(_ name: String, jobs: [BatchJobController], condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline {
            if jobs.contains(where: { !$0.running && !$0.error.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        if !condition() {
            XCTFail("\(name): \(jobs.map { [$0.title, $0.statusLabel, $0.error] })")
            throw CocoaError(.executableRuntimeMismatch)
        }
    }
}
