import Foundation
@testable import TermPilotApp
import XCTest

final class SFTPBridgeResourceTests: XCTestCase {
    func testExecActionIsAvailableForSFTPAndSCPModes() throws {
        let url = try XCTUnwrap(
            AppResourceLocator.url(
                forResource: "termpilot-sftp-bridge",
                withExtension: "cjs",
                subdirectory: "sftp-bridge"
            )
        )
        let source = try String(contentsOf: url, encoding: .utf8)
        let execCases = source.components(
            separatedBy: #"case "exec":"#
        ).count - 1

        XCTAssertEqual(execCases, 2)
        XCTAssertTrue(source.contains("async function executeRequestCommand"))
        XCTAssertTrue(source.contains("executeRequestCommand,"))
    }

    func testTextWriteCompletesWhenRemoteHandleCloses() throws {
        let url = try XCTUnwrap(
            AppResourceLocator.url(
                forResource: "termpilot-sftp-bridge",
                withExtension: "cjs",
                subdirectory: "sftp-bridge"
            )
        )
        let source = try String(contentsOf: url, encoding: .utf8)
        let closeResolvesWrite = try NSRegularExpression(
            pattern: #"stream\.on\("close",[\s\S]{0,700}resolve\(\)"#
        )
        let fullRange = NSRange(source.startIndex..., in: source)

        XCTAssertNotNil(
            closeResolvesWrite.firstMatch(
                in: source,
                range: fullRange
            )
        )
        XCTAssertFalse(source.contains(#"stream.on("finish", resolve)"#))
    }
}
