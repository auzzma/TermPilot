import AppKit
import SwiftUI
import TermPilotDomain
import TermPilotPersistence
@testable import TermPilotApp
import XCTest

@MainActor
final class BatchLibraryTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("termpilot-library-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func testDraftRestartPreservesTabsAndConfigurationWithoutRuntimeOrPasswords() async throws {
        let directory = try directory()
        let vault = try VaultStore(databaseURL: directory.appendingPathComponent("vault.sqlite"))
        let state = AppState(vaultStore: vault), workspace = state.batchJobs
        var host = TermPilotDomain.Host(label: "生产", hostname: "192.0.2.10", username: "ops", authentication: .password)
        host.password = "login-secret"; try await vault.saveHost(host); await state.refreshHosts()
        workspace.restoreDrafts(state: state, directory: directory, workspace: "fixture")
        let first = workspace.selected, second = workspace.newJob()
        first.rename(to: "巡检"); first.job.script.body = "echo test"; first.job.script.environment = ["TOKEN":"script-secret"]
        first.targets = [BatchTarget(host: host, elevation: "su", elevationPassword: "root-secret", savedHostID: host.id)]
        first.targetDefaults.ipList = "192.0.2.12"; first.targetDefaults.password = "default-secret"
        first.running = true; first.job.remoteWorkDirectory = "/old"; first.job.sourceTaskId = "old"
        workspace.move(second.id, before: first.id); workspace.selected = first
        XCTAssertTrue(workspace.flushDrafts())
        let raw = try BatchLibraryStore(directory: directory).request(["operation":"loadDraft","workspace":"fixture"])["payload"] as! String
        for secret in ["login-secret","root-secret","default-secret"] { XCTAssertFalse(raw.contains(secret)) }
        let next = AppState(vaultStore: vault); await next.refreshHosts()
        next.batchJobs.restoreDrafts(state: next, directory: directory, workspace: "fixture")
        XCTAssertEqual(next.batchJobs.jobs.map(\.id), [second.id, first.id])
        let restored = next.batchJobs.selected
        XCTAssertEqual(restored.id, first.id); XCTAssertEqual(restored.title, "巡检")
        XCTAssertEqual(restored.job.script.body, "echo test"); XCTAssertEqual(restored.job.script.environment["TOKEN"], "script-secret")
        XCTAssertEqual(restored.targets.first?.savedHostID, host.id)
        XCTAssertEqual(restored.targets.first?.elevationPassword, ""); XCTAssertEqual(restored.targetDefaults.password, "")
        XCTAssertFalse(restored.running); XCTAssertTrue(restored.events.isEmpty)
        XCTAssertEqual(restored.job.remoteWorkDirectory, ""); XCTAssertEqual(restored.job.sourceTaskId, "")
        next.batchJobs.shutdown()
    }
    func testSaveAsAndDraftsNeverChangeTheOriginalAndClosingDoesNotDeleteLibrary() throws {
        let directory = try directory(), state = AppState(), workspace = state.batchJobs
        workspace.restoreDrafts(state: state, directory: directory, workspace: "fixture")
        let job = workspace.selected; job.job.script.body = "original"
        XCTAssertTrue(workspace.saveJob(job, name: "巡检", asCopy: false))
        let original = try XCTUnwrap(workspace.library.first)
        job.job.script.body = "temporary"; workspace.flushDrafts()
        XCTAssertEqual(try JSONDecoder().decode(BatchSavedConfiguration.self, from: Data(original.configuration.utf8)).job.script.body, "original")
        XCTAssertTrue(workspace.saveJob(job, name: "副本", asCopy: true)); XCTAssertNotEqual(job.savedJobID, original.id)
        XCTAssertEqual(workspace.library.count, 2)
        XCTAssertTrue(workspace.openSavedJob(original)); XCTAssertEqual(workspace.selected.job.script.body, "original")
        let count = workspace.jobs.count; XCTAssertTrue(workspace.openSavedJob(original)); XCTAssertEqual(workspace.jobs.count, count)
        workspace.close(job); workspace.loadLibrary(); XCTAssertEqual(workspace.library.count, 2)
        workspace.shutdown()
    }
    func testAutosaveAndConflictProtectNewerSavedVersion() async throws {
        let directory = try directory(), state = AppState(), workspace = state.batchJobs
        workspace.restoreDrafts(state: state, directory: directory, workspace: "fixture")
        let job = workspace.selected; job.job.script.body = "first"
        XCTAssertTrue(workspace.saveJob(job, name: "shared", asCopy: false))
        let initial = workspace.library[0]
        let other = BatchLibraryStore(directory: directory)
        _ = try other.save(name: "newer", configuration: initial.configuration, id: initial.id, revision: initial.revision)
        job.job.script.body = "my local change"
        XCTAssertFalse(workspace.saveJob(job, name: "old", asCopy: false))
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(workspace.draftStatus, "Draft saved")
        XCTAssertFalse(workspace.storageError.isEmpty)
        XCTAssertEqual(try other.list().first?.name, "newer")
        XCTAssertTrue(workspace.saveJob(job, name: "keep my edits", asCopy: true))
        workspace.shutdown()
    }
    func testBackupCarriesSavedJobsAndRemapsHostReferences() async throws {
        let a = try directory(), b = try directory()
        let source = try VaultStore(databaseURL: a.appendingPathComponent("vault.sqlite"))
        let target = try VaultStore(databaseURL: b.appendingPathComponent("vault.sqlite"))
        let host = TermPilotDomain.Host(label: "source", hostname: "192.0.2.8", username: "ops", authentication: .agent)
        let duplicate = TermPilotDomain.Host(label: "existing", hostname: host.hostname, username: "ops", authentication: .agent)
        try await source.saveHost(host); try await target.saveHost(duplicate)
        let state = AppState(vaultStore: source); await state.refreshHosts()
        state.batchJobs.restoreDrafts(state: state, directory: a, workspace: "fixture")
        state.batchJobs.selected.targets = [BatchTarget(host: host, savedHostID: host.id)]
        XCTAssertTrue(state.batchJobs.saveJob(state.batchJobs.selected, name: "备份巡检", asCopy: false))
        let snapshot = try await source.makeBackupSnapshot()
        XCTAssertEqual(snapshot.batchJobs?.count, 1)
        _ = try await target.importBackupSnapshot(snapshot)
        let item = try XCTUnwrap(BatchLibraryStore(directory: b).list().first)
        let restored = try JSONDecoder().decode(BatchSavedConfiguration.self, from: Data(item.configuration.utf8))
        XCTAssertEqual(restored.targets.first?.savedHostId, duplicate.id)
        XCTAssertEqual(try BatchLibraryStore(directory: b).request(["operation":"loadDraft","workspace":"fixture"])["revision"] as? Int, 0)
        state.batchJobs.shutdown()
    }
    func testLibraryAndWorkspaceRenderAtMinimumWidth() throws {
        let directory = try directory(), state = AppState(), workspace = state.batchJobs
        workspace.restoreDrafts(state: state, directory: directory, workspace: "render")
        workspace.selected.job.script.body = "hostname\nid"
        XCTAssertTrue(workspace.saveJob(workspace.selected, name: "生产环境巡检", asCopy: false))
        let second = workspace.newJob(); second.job.kind = "collect"; second.job.remotePaths = ["/var/log/syslog"]
        XCTAssertTrue(workspace.saveJob(second, name: "故障日志收集", asCopy: false))
        workspace.loadLibrary()
        for scheme in [ColorScheme.light, .dark] {
            for kind in ["workspace", "library", "save"] {
                let size = NSSize(width: kind == "workspace" ? 900 : kind == "library" ? 760 : 480,
                                  height: kind == "workspace" ? 620 : kind == "library" ? 460 : 260)
                let content: AnyView
                switch kind {
                case "library": content = AnyView(BatchLibraryView())
                case "save": content = AnyView(BatchSaveJobView(controller: second, asCopy: true))
                default: content = AnyView(BatchWorkspaceView())
                }
                let host = NSHostingView(rootView: content.environmentObject(state).environmentObject(workspace)
                    .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "zh-Hans"))
                    .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
                host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 1000)
                if let path = ProcessInfo.processInfo.environment["TERMPILOT_BATCH_SNAPSHOT_DIR"] {
                    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                    try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("library-\(kind)-\(scheme).png"))
                }
                window.contentView = nil; window.close()
            }
        }
        workspace.shutdown()
    }

}
