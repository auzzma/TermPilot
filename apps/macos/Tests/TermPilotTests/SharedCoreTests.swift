import XCTest
import TermPilotCore
import TermPilotDomain

final class SharedCoreTests: XCTestCase {
    func testNativeUIActuallyCallsRust() throws {
        XCTAssertEqual(SharedCore.apiVersion, 1)
        XCTAssertEqual(try SharedCore.call(["method": "info"])["implementation"] as? String, "termpilot-core")
        XCTAssertTrue(ScreenSharingEndpoint.isValid(host: "::1", port: 5900, username: "", mode: .standardVNC))
        XCTAssertFalse(ScreenSharingEndpoint.isValid(host: "bad\nhost", port: 5900, username: "", mode: .standardVNC))
    }

    func testMissingProxyCannotSilentlyBecomeDirect() {
        XCTAssertThrowsError(try SharedCore.validateConnection([
            "protocol": "standardVNC", "host": "mac.example", "port": 5900, "proxyRequired": true,
        ])) { error in XCTAssertEqual((error as? SharedCoreError)?.code, "missingProxy") }
    }

    func testEngineLaunchPreservesArgumentBoundaries() throws {
        let plan = try SharedCore.engineLaunch(engine: "screenSharing", runtime: "/test dir/python",
                                              script: "/test dir/bridge.py", modules: "/test dir/modules")
        XCTAssertEqual(plan.arguments, ["screen-sharing"])
        XCTAssertThrowsError(try SharedCore.engineLaunch(engine: "ssh", runtime: "node", script: "script"))
    }
}

