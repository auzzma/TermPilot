import Foundation
import XCTest
import TermPilotDomain
import TermPilotRemote

final class RemoteWindowsMonitorTests: XCTestCase {
    /// Opt-in, read-only integration test. Credentials arrive over private stdin.
    func testLiveWindowsMonitor() async throws {
        guard ProcessInfo.processInfo.environment["TERMPILOT_MONITOR_LIVE"] == "1" else {
            throw XCTSkip("Set TERMPILOT_MONITOR_LIVE and pass the authorized SSH configuration on stdin.")
        }
        struct Configuration: Decodable {
            let host: String
            let username: String
            let password: String
            let engine: String
        }
        let config = try JSONDecoder().decode(Configuration.self, from: FileHandle.standardInput.readDataToEndOfFile())
        let host = Host(label: "Windows monitor acceptance", hostname: config.host, username: config.username, authentication: .password, password: config.password)
        let client = try SSH2SFTPBridgeClient(host: host,
            runtime: SSH2BridgeRuntime(executable: URL(fileURLWithPath: config.engine)), opensFileChannel: false)
        do {
            try await client.waitUntilReady()
            let info = try await client.systemInfo()
            XCTAssertTrue(info.isWindows)
            XCTAssertEqual(info.username.lowercased(), config.username.lowercased())
            _ = try await client.windowsOverview()
            try await Task.sleep(for: .seconds(1))
            let overview = try await client.windowsOverview()
            XCTAssertGreaterThan(overview.memoryTotal, 0)
            XCTAssertGreaterThan(overview.uptimeSeconds, 0)
            XCTAssertFalse(overview.disks.isEmpty)
            XCTAssertFalse(overview.networkInterfaces.isEmpty)
            let processes = try await client.windowsProcesses()
            XCTAssertGreaterThan(processes.processes.count, 10)
            let result = try await client.windowsExec(command: "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false); Write-Output 'TermPilot-中文-monitor-ok'")
            XCTAssertTrue(result.stdout.contains("TermPilot-中文-monitor-ok"))
            await client.close()
        } catch {
            await client.close()
            throw error
        }
    }
}
