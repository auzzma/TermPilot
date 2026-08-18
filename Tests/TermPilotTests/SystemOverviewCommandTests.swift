import Foundation
import XCTest
@testable import TermPilotApp
import TermPilotDomain

final class SystemOverviewCommandTests: XCTestCase {
    func testSystemMonitorRefreshPausesUntilSSHReconnects() {
        for lifecycle in [
            SessionLifecycle.disconnected,
            .connecting,
            .failed("Connection lost"),
            .exited(256),
        ] {
            XCTAssertFalse(
                SessionSystemMonitorRefreshPolicy.isEnabled(
                    sessionKind: .ssh,
                    lifecycle: lifecycle
                )
            )
        }

        XCTAssertTrue(
            SessionSystemMonitorRefreshPolicy.isEnabled(
                sessionKind: .ssh,
                lifecycle: .connected
            )
        )
        XCTAssertTrue(
            SessionSystemMonitorRefreshPolicy.isEnabled(
                sessionKind: .local,
                lifecycle: .disconnected
            )
        )
    }

    func testLocalCommandFallsBackToHomeForInvalidWorkingDirectory() async throws {
        let result = try await LocalCommandExecutor.run(
            command: "pwd",
            shell: "/bin/sh",
            workingDirectory: "fixture-user",
            timeoutMS: 2_000
        )

        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    func testOverviewCommandCollectsMacOSStatsWithoutBlockingTop() async throws {
        let command = SystemOverviewCommand.command
        XCTAssertTrue(command.contains(#""$ostype" = "Darwin""#))
        XCTAssertTrue(command.contains("vm_stat"))
        XCTAssertTrue(command.contains("netstat -ibn"))
        XCTAssertTrue(command.contains("/proc/stat"))
        XCTAssertFalse(command.contains("top -l"))

        let result = try await LocalCommandExecutor.run(
            command: command,
            shell: "/bin/sh",
            timeoutMS: 12_000
        )
        let output = result.stdout + result.stderr
        XCTAssertEqual(result.code, 0, output)

        for key in [
            "CPU=",
            "CPU_CORES=",
            "MEM_USED_MB=",
            "MEM_TOTAL_MB=",
            "MEM_PERCENT=",
            "DISK_USED_GB=",
            "DISK_TOTAL_GB=",
            "DISK_PERCENT=",
            "NET_RX_BYTES=",
            "NET_TX_BYTES=",
            "LOAD=",
            "UPTIME_DAYS=",
            "UPTIME_HOURS=",
            "OS=macOS",
            "KERNEL=",
        ] {
            XCTAssertTrue(output.contains(key), "Missing \(key) in:\n\(output)")
        }
    }

    func testLinuxOverviewCommandUsesBusyBoxCompatibleCollectors() {
        let command = SystemOverviewCommand.command

        XCTAssertTrue(command.contains("CPU_RAW="))
        XCTAssertTrue(command.contains("CPU_CORE_RAW="))
        XCTAssertTrue(command.contains("CPU_CORES="))
        XCTAssertTrue(command.contains("df -kP"))
        XCTAssertTrue(command.contains("$6==\"/\""))
        XCTAssertTrue(command.contains("top -b -n 1"))
        XCTAssertTrue(command.contains("ps ww"))
        XCTAssertFalse(command.contains("sleep 0.2"))
        XCTAssertFalse(command.contains("df -P -B1"))
        XCTAssertFalse(command.contains(" -x tmpfs"))
        XCTAssertFalse(command.contains("MemAvailable"))
    }

    func testCPUUsageUsesJiffyDeltasLikeOriginalProject() throws {
        let previous = SystemCPUJiffyCounters(
            total: 1_000,
            idle: 700,
            user: 200,
            system: 100,
            cores: [
                SystemCPUCoreJiffyCounters(
                    id: 0,
                    total: 500,
                    idle: 350
                ),
                SystemCPUCoreJiffyCounters(
                    id: 1,
                    total: 500,
                    idle: 350
                ),
            ]
        )
        let current = SystemCPUJiffyCounters(
            total: 1_200,
            idle: 800,
            user: 250,
            system: 130,
            cores: [
                SystemCPUCoreJiffyCounters(
                    id: 0,
                    total: 600,
                    idle: 390
                ),
                SystemCPUCoreJiffyCounters(
                    id: 1,
                    total: 600,
                    idle: 410
                ),
            ]
        )

        let usage = try XCTUnwrap(
            SystemCPUUsageCalculator.usage(
                current: current,
                previous: previous
            )
        )

        XCTAssertEqual(usage.total, 50)
        XCTAssertEqual(usage.user, 25, accuracy: 0.001)
        XCTAssertEqual(usage.system, 15, accuracy: 0.001)
        XCTAssertEqual(usage.perCore, [60, 40])
    }

    func testCPUUsageRejectsCounterReset() {
        let previous = SystemCPUJiffyCounters(
            total: 1_000,
            idle: 700,
            user: 200,
            system: 100,
            cores: []
        )
        let current = SystemCPUJiffyCounters(
            total: 100,
            idle: 70,
            user: 20,
            system: 10,
            cores: []
        )

        XCTAssertNil(
            SystemCPUUsageCalculator.usage(
                current: current,
                previous: previous
            )
        )
    }
}
