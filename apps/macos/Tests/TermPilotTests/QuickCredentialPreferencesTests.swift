import Foundation
import XCTest
import TermPilotDomain

final class QuickCredentialPreferencesTests: XCTestCase {
    func testProtocolsKeepIndependentFixedAndRecentChoicesAcrossRestart() {
        let suite = "TermPilot.tests.quick-credentials.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = QuickCredentialPreferences(defaults: defaults)
        for kind in QuickCredentialProtocol.allCases { XCTAssertEqual(preferences.strategy(kind), .manual) }
        preferences.configure(.ssh, strategy: .fixed, credentialID: "ssh-key")
        preferences.configure(.standardVNC, strategy: .recent, credentialID: "")
        preferences.configure(.highPerformance, strategy: .fixed, credentialID: "mac-account")
        preferences.configure(.rdp, strategy: .recent, credentialID: "")
        preferences.connected(.ssh, credentialID: "one-time-key")
        preferences.connected(.rdp, credentialID: "windows-account")
        preferences.connected(.standardVNC, credentialID: "vnc-account")
        let reopened = QuickCredentialPreferences(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(reopened.selectedID(.ssh), "ssh-key")
        XCTAssertEqual(reopened.selectedID(.standardVNC), "vnc-account")
        XCTAssertEqual(reopened.selectedID(.highPerformance), "mac-account")
        XCTAssertEqual(reopened.selectedID(.rdp), "windows-account")
        preferences.configure(.rdp, strategy: .manual, credentialID: "")
        XCTAssertEqual(reopened.selectedID(.rdp), "")
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("TermPilot.quickCredential.") }.allSatisfy {
            $0.hasSuffix("strategy") || $0.hasSuffix("fixed") || $0.hasSuffix("recent")
        })
    }

    func testProtocolMappingAndCredentialCompatibility() {
        XCTAssertEqual(QuickCredentialProtocol.resolve(kind: "screenSharing", mode: "highPerformance"), .highPerformance)
        XCTAssertEqual(QuickCredentialProtocol.resolve(kind: "screen", mode: "standardVNC"), .standardVNC)
        XCTAssertEqual(QuickCredentialProtocol.resolve(kind: "rdp", mode: "highPerformance"), .rdp)
        for kind in QuickCredentialProtocol.allCases {
            XCTAssertTrue(kind.supports(kind: "password"))
            XCTAssertEqual(kind.supports(kind: "identityKey"), kind == .ssh)
            XCTAssertFalse(kind.supports(kind: "unknown"))
        }
    }
}
