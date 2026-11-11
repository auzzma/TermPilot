import Foundation
@testable import TermPilotApp
import XCTest

final class ProcessPipeLinesTests: XCTestCase, @unchecked Sendable {
    func testIdlePipeDoesNotDelayBatchProgressOrPromptsBeforeEOF() async throws {
        let idle = Pipe(), batch = Pipe()
        let idleStarted = expectation(description: "AI pipe is being read")
        let progress = expectation(description: "Batch progress arrives while AI stays idle")
        progress.expectedFulfillmentCount = 3
        let recorder = Frames()
        let aiReader = Task {
            try await ProcessPipeLines.read(from: idle.fileHandleForReading) { _ in idleStarted.fulfill() }
        }
        let batchReader = Task {
            try await ProcessPipeLines.read(from: batch.fileHandleForReading) { data in
                await recorder.append(data)
                progress.fulfill()
            }
        }
        defer { aiReader.cancel(); batchReader.cancel() }
        try idle.fileHandleForWriting.write(contentsOf: Data("ready\n".utf8))
        await fulfillment(of: [idleStarted], timeout: 2)
        // Leave the AI writer open and silent, as it is in the application.
        try await Task.sleep(for: .milliseconds(100))
        let expected = ["{\"type\":\"batchStarted\"}", "{\"type\":\"hostKeyPrompt\"}", "{\"type\":\"batchFinished\"}"]
        for line in expected { try batch.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
        await fulfillment(of: [progress], timeout: 2)
        let values = await recorder.values
        XCTAssertEqual(values, expected.map { Data($0.utf8) })
        try idle.fileHandleForWriting.close()
        try batch.fileHandleForWriting.close()
        try await aiReader.value
        try await batchReader.value
    }

    func testFragmentedUTF8AndMultipleFramesPreserveFullOutput() async throws {
        let pipe = Pipe(), recorder = Frames()
        let reader = Task { try await ProcessPipeLines.read(from: pipe.fileHandleForReading) { await recorder.append($0) } }
        let lines = ["中文日志", String(repeating: "结果", count: 50_000), "", "finished"]
        let bytes = Data((lines.joined(separator: "\n") + "\n").utf8)
        // A separate writer avoids blocking the test's cooperative executor.
        let written = expectation(description: "Fragmented frames written")
        DispatchQueue(label: "pipe-test-writer").async {
            for offset in stride(from: 0, to: bytes.count, by: 8191) {
                try! pipe.fileHandleForWriting.write(contentsOf: bytes.subdata(in: offset..<min(offset + 8191, bytes.count)))
            }
            try! pipe.fileHandleForWriting.close()
            written.fulfill()
        }
        await fulfillment(of: [written], timeout: 3)
        try await reader.value
        let values = await recorder.values
        XCTAssertEqual(values, lines.map { Data($0.utf8) })
    }

    func testCancellingIdleReadFinishesWithoutWaitingForWriter() async throws {
        let pipe = Pipe()
        let ready = expectation(description: "Reader started")
        let stopped = expectation(description: "Cancelled reader exited")
        let reader = Task {
            do {
                try await ProcessPipeLines.read(from: pipe.fileHandleForReading) { _ in ready.fulfill() }
                XCTFail("Cancelled read must throw")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            stopped.fulfill()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("ready\n".utf8))
        await fulfillment(of: [ready], timeout: 2)
        reader.cancel()
        await fulfillment(of: [stopped], timeout: 2)
        try pipe.fileHandleForWriting.close()
        await reader.value
    }

    func testIncompleteAndOversizedFramesFailWithoutDeliveringPartialJSON() async throws {
        for (payload, limit, expected) in [("partial", 64, ProcessPipeLines.ReadError.incompleteLine), ("12345\n", 4, .lineTooLarge), ("12345", 4, .lineTooLarge)] {
            let pipe = Pipe()
            try pipe.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
            try pipe.fileHandleForWriting.close()
            do {
                try await ProcessPipeLines.read(from: pipe.fileHandleForReading, maximumLineBytes: limit) { _ in XCTFail("Invalid frame delivered") }
                XCTFail("Expected framing error")
            } catch let error as ProcessPipeLines.ReadError { XCTAssertEqual(error, expected) }
        }
    }
}

private actor Frames {
    var values: [Data] = []
    func append(_ data: Data) { values.append(data) }
}
