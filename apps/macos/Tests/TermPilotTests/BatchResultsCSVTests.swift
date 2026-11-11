import Foundation
import TabularData
@testable import TermPilotApp
import XCTest

final class BatchResultsCSVTests: XCTestCase {
    private func event(_ ip: String, _ stage: String, _ status: String, _ details: [String: Any] = [:]) -> BatchEvent {
        BatchEvent(value: ["type": "batchHost", "targetId": "id-\(ip)", "ip": ip, "port": 2222,
                           "stage": stage, "status": status].merging(details) { _, new in new })
    }

    private func chineseCSV(_ hosts: [BatchHostResult], _ scope: BatchCSVScope) -> String {
        let bundle = AppResourceLocator.localizedBundle(for: "zh-Hans")
        let document = BatchResultsCSV(hosts: hosts, scope: scope) { bundle.localizedString(forKey: $0, value: $0, table: nil) }
        XCTAssertEqual(Array(document.data.prefix(3)), [0xEF, 0xBB, 0xBF])
        return String(decoding: document.data.dropFirst(3), as: UTF8.self)
    }

    func testThreeScopesUseFinalStatusAcrossTheWholeJob() {
        let events = (1...159).map { event("192.0.2.\($0)", "finished", $0 <= 109 ? "success" : "failed",
            $0 <= 109 ? [:] : ["message": "Connection timed out"]) }
        let hosts = batchHostResults(events, running: false)
        let all = chineseCSV(hosts, .all)
        let failed = chineseCSV(hosts, .failed)
        let success = chineseCSV(hosts, .success)
        for (csv, count) in [(all, 159), (failed, 50), (success, 109)] {
            XCTAssertEqual(csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count, count + 1)
            XCTAssertTrue(csv.hasSuffix("\r\n"))
        }
        XCTAssertTrue(all.hasPrefix("\"主机 IP\",\"状态\",\"失败原因\"\r\n"))
        XCTAssertTrue(failed.contains("\"192.0.2.110\",\"失败\",\"连接超时\"\r\n"))
        XCTAssertFalse(failed.contains("\"成功\""))
        XCTAssertTrue(success.hasPrefix("\"主机 IP\",\"状态\"\r\n"))
        XCTAssertTrue(success.contains("\"192.0.2.109\",\"成功\"\r\n"))
        XCTAssertFalse(success.contains("\"失败\""))
    }

    func testDetailedFailuresAndCSVQuoting() {
        let hosts = batchHostResults([
            event("2001:db8::1", "authenticate", "failed", ["message": "SSH authentication rejected"]),
            event("2001:db8::1", "finished", "failed", ["message": "SSH authentication rejected"]),
            event("db.local", "execute", "failed", ["exitCode": 7, "stderr": "缺少文件,\"目录\"\npermission denied"]),
            event("db.local", "finished", "failed", ["message": "execute script failed (exit 7)"]),
            event("=1+1", "finished", "failed", ["message": "=1+2"]),
            event("legacy", "finished", "failed"),
        ], running: false)
        let csv = chineseCSV(hosts, .failed)
        XCTAssertTrue(csv.contains("\"2001:db8::1\",\"失败\",\"认证 · SSH 服务器拒绝了身份认证\"\r\n"))
        XCTAssertTrue(csv.contains("缺少文件,\"\"目录\"\"\npermission denied\n退出码 7\nexecute script failed (exit 7)"))
        XCTAssertTrue(csv.contains("\"'=1+1\",\"失败\",\"'=1+2\""))
        XCTAssertTrue(csv.contains("\"legacy\",\"失败\",\"未记录具体失败原因。\""))
    }

    func testOtherStatusesStayInAllIncludingAnUnknownBackgroundOutcome() {
        let hosts = batchHostResults([
            event("a", "finished", "cancelled"), event("b", "finished", "skipped"),
            event("c", "authenticate", "pending"), event("d", "finished", "running", ["background": true]),
            event("e", "authenticate", "failed", ["message": "Connection timed out"]),
            event("e", "finished", "unknown", ["background": true, "remoteStateUnknown": true]),
        ], running: true)
        XCTAssertEqual(chineseCSV(hosts, .failed), "\"主机 IP\",\"状态\",\"失败原因\"\r\n")
        XCTAssertEqual(chineseCSV(hosts, .success), "\"主机 IP\",\"状态\"\r\n")
        let all = chineseCSV(hosts, .all)
        for status in ["已取消", "跳过", "等待中", "运行中", "状态未知"] {
            XCTAssertTrue(all.contains("\"\(status)\",\"\"\r\n"))
        }
    }

    func testExportedFileCanBeReadAsATableWithMultilineDiagnostics() throws {
        let hosts = batchHostResults([
            event("2001:db8::5", "finished", "failed", ["message": "缺少 \"a,b\"\n第二行"]),
            event("db.local", "finished", "success"),
        ], running: false)
        let document = BatchResultsCSV(hosts: hosts, scope: .all, localize: { $0 })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        try document.data.write(to: file)
        let table = try DataFrame(contentsOfCSVFile: file)
        XCTAssertEqual(table.columns.map(\.name), ["Host IP", "Status", "Failure reason"])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[0]["Host IP", String.self], "2001:db8::5")
        XCTAssertEqual(table.rows[0]["Failure reason", String.self], "缺少 \"a,b\"\n第二行")
    }
}
