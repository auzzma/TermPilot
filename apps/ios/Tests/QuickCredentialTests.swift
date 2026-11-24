import XCTest
@testable import TermPilot

@MainActor final class QuickCredentialTests: XCTestCase {
  func testRemoteAuthenticationRemembersOnlyQuickConnectionsAndConsumesOnce() {
    let suite = "TermPilot.tests.quick.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel()
    model.quickCredentials = QuickCredentialPreferences(defaults: defaults)
    model.quickCredentials.configure(.standardVNC, strategy: .recent, credentialID: "")
    model.quickCredentials.configure(.highPerformance, strategy: .recent, credentialID: "")
    model.records["credentials"] = [["id":"vnc","kind":"password"],["id":"other","kind":"password"]]
    let session = MobileSession(id: 999, host: [:], kind: "screen", terminal: "")
    session.quickCredential = (.standardVNC, "vnc")
    model.sessions = [session]
    model.receive(MobilePacket(header:["session":999,"kind":"desktopSize","width":1280,"height":720], data:Data()))
    XCTAssertEqual(model.quickCredentials.selectedID(.standardVNC), "")
    model.receive(MobilePacket(header:["session":999,"kind":"connected","width":1280,"height":720], data:Data()))
    XCTAssertEqual(model.quickCredentials.selectedID(.standardVNC), "vnc")
    XCTAssertEqual(model.quickCredentials.selectedID(.highPerformance), "")
    XCTAssertNil(session.quickCredential)
    model.quickCredentials.connected(.standardVNC, credentialID: "other")
    model.receive(MobilePacket(header:["session":999,"kind":"connected"], data:Data()))
    XCTAssertEqual(model.quickCredentials.selectedID(.standardVNC), "other")
    session.quickCredential = (.standardVNC, "deleted")
    model.receive(MobilePacket(header:["session":999,"kind":"connected"], data:Data()))
    XCTAssertEqual(model.quickCredentials.selectedID(.standardVNC), "other")
    for event in ["error", "credentialPrompt"] {
      session.quickCredential = (.standardVNC, "vnc")
      model.receive(MobilePacket(header:["session":999,"type":event,"message":"fixture"], data:Data()))
      XCTAssertNil(session.quickCredential)
      model.receive(MobilePacket(header:["session":999,"kind":"connected"], data:Data()))
      XCTAssertEqual(model.quickCredentials.selectedID(.standardVNC), "other")
    }
  }
}
