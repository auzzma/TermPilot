import AppKit
import Combine
import TermPilotDomain
import TermPilotPersistence
@testable import TermPilotApp
import XCTest

private actor PreferenceRecorder {
    var batches: [[String: Data]] = []
    private var nextFailure: (@Sendable () async throws -> Void)?
    func failOnce(_ failure: @escaping @Sendable () async throws -> Void) { nextFailure = failure }
    func save(_ fields: [String: Data]) async throws {
        batches.append(fields)
        if let failure = nextFailure {
            nextFailure = nil
            try await failure()
        }
    }
}

final class ResponsivenessTests: XCTestCase {
    @MainActor
    func testSessionPresentationSurvivesMissingCredentials() {
        let state = AppState()
        let host = TermPilotDomain.Host(label: "Presentation fixture", hostname: "fixture.invalid", username: "user", credentialID: UUID(), proxyProfileID: UUID())
        let descriptor = SessionDescriptor.ssh(host: host)
        state.openWorkspaceForTesting(host: host, descriptor: descriptor)
        XCTAssertEqual(state.sessionHost(for: descriptor)?.label, host.label)
        // Actual connection resolution must still report these invalid references.
        XCTAssertThrowsError(try host.applyingConnectionSettings(credentials: [], proxyProfiles: []))
    }

    @MainActor
    func testTransferProgressDoesNotInvalidateEntireAppState() {
        let state = AppState()
        var global = 0
        var transfers = 0
        let a = state.objectWillChange.sink { global += 1 }
        let b = state.transferActivity.objectWillChange.sink { transfers += 1 }
        let record = FileTransferRecord(kind: .upload, name: "fixture", sourcePath: "", destinationPath: "", totalBytes: 100)
        state.recordFileTransfer(record)
        state.finishFileTransfer(id: record.id, status: .succeeded, bytesTransferred: 100)
        XCTAssertEqual(global, 0)
        XCTAssertGreaterThan(transfers, 0)
        withExtendedLifetime([a, b]) {}
    }

    @MainActor
    func testBlockingWorkLeavesMainActorResponsiveAndDiscardsCancelledResult() async throws {
        let started = expectation(description: "Background operation started")
        let release = DispatchSemaphore(value: 0)
        let work = Task {
            try await ConnectionPreparationService.run {
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                release.wait()
                return 42
            }
        }
        // The main actor must resume while the background operation is blocked.
        await fulfillment(of: [started], timeout: 10)
        work.cancel()
        release.signal()
        do { _ = try await work.value; XCTFail("Cancelled preparation returned a usable result") }
        catch is CancellationError {}
    }

    @MainActor
    func testWorkspaceActivityRequiresSelectionAndVisibleWindow() {
        let activity = WorkspaceActivity()
        XCTAssertFalse(activity.isActive)
        activity.selected = true
        XCTAssertFalse(activity.isActive)
        activity.windowVisible = true
        XCTAssertTrue(activity.isActive)
        activity.selected = false
        XCTAssertFalse(activity.isActive)
    }

    @MainActor
    func testCancelledBackgroundCreationCleansUpItsResult() async throws {
        let started = expectation(description: "Resource creation started")
        let cleaned = expectation(description: "Created resource released")
        let release = DispatchSemaphore(value: 0)
        let work = Task {
            try await ConnectionPreparationService.run(onCancellation: { value in
                XCTAssertEqual(value, 42)
                cleaned.fulfill()
            }) {
                started.fulfill()
                release.wait()
                return 42
            }
        }
        await fulfillment(of: [started], timeout: 10)
        work.cancel()
        release.signal()
        do { _ = try await work.value; XCTFail("Cancelled creation succeeded") }
        catch is CancellationError {}
        await fulfillment(of: [cleaned], timeout: 10)
    }

    @MainActor
    func testPreferenceEditsCoalesceAndFlushLatestValue() async throws {
        let recorder = PreferenceRecorder()
        let queue = PreferenceSaveQueue { try await recorder.save($0) }
        for value in 8...36 { queue.enqueue(Data(String(value).utf8), field: "fontSize") }
        queue.enqueue(Data("\"dark\"".utf8), field: "theme")
        try await queue.flush()
        let batches = await recorder.batches
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0]["fontSize"], Data("36".utf8))
        XCTAssertEqual(batches[0]["theme"], Data("\"dark\"".utf8))
        XCTAssertNil(queue.error)
        XCTAssertFalse(queue.hasPending("fontSize"))
    }

    @MainActor
    func testFailedSaveRetainsNewerEditForRetry() async throws {
        let recorder = PreferenceRecorder()
        let started = expectation(description: "First preference save started")
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        await recorder.failOnce {
            started.fulfill()
            for await _ in release {}
            throw CocoaError(.fileWriteUnknown)
        }
        let queue = PreferenceSaveQueue { try await recorder.save($0) }
        let firstFlush = Task {
            queue.enqueue(Data("12".utf8), field: "fontSize")
            try await queue.flush()
        }
        // Hold the first write until the newer edit is actually queued. Await
        // that flush's failure before retrying, independent of runner speed.
        await fulfillment(of: [started], timeout: 10)
        queue.enqueue(Data("18".utf8), field: "fontSize")
        continuation.finish()
        do {
            try await firstFlush.value
            XCTFail("The first flush should report its save failure")
        } catch AppStateError.workflowRunFailed {}
        XCTAssertNotNil(queue.error)
        XCTAssertTrue(queue.hasPending("fontSize"))
        try await queue.flush()
        let batches = await recorder.batches
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches.first?["fontSize"], Data("12".utf8))
        XCTAssertEqual(batches.last?["fontSize"], Data("18".utf8))
        XCTAssertNil(queue.error)
        XCTAssertFalse(queue.hasPending("fontSize"))
    }
}
