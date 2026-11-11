import Foundation
import TermPilotDomain
import XCTest

final class RemoteDesktopPreferencesTests: XCTestCase {
    func testVideoCodecDefaultsAndPersists() throws {
        let name="TermPilot-codec-tests-\(UUID().uuidString)"
        let defaults=try XCTUnwrap(UserDefaults(suiteName:name));defer{defaults.removePersistentDomain(forName:name)}
        XCTAssertEqual(RemoteDesktopPreferences.videoCodec(defaults:defaults),"h264")
        defaults.set("h265",forKey:RemoteDesktopPreferences.videoCodecKey)
        XCTAssertEqual(RemoteDesktopPreferences.videoCodec(defaults:try XCTUnwrap(UserDefaults(suiteName:name))),"h265")
        defaults.set("unsupported",forKey:RemoteDesktopPreferences.videoCodecKey)
        XCTAssertEqual(RemoteDesktopPreferences.videoCodec(defaults:defaults),"h264")
    }
    func testMissingAndInvalidValuesDefaultTo60And30Persists() throws {
        let name = "TermPilot-fps-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(RemoteDesktopPreferences.frameRate(defaults: defaults), 60)
        defaults.set(30, forKey: RemoteDesktopPreferences.frameRateKey)
        XCTAssertEqual(RemoteDesktopPreferences.frameRate(defaults: try XCTUnwrap(UserDefaults(suiteName: name))), 30)
        defaults.set(120, forKey: RemoteDesktopPreferences.frameRateKey)
        XCTAssertEqual(RemoteDesktopPreferences.frameRate(defaults: defaults), 60)
    }
}
