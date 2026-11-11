import XCTest
@testable import TermPilot

enum LiveTestFixture {
  // Device-specific selectors belong in the local, authorized fixture, never
  // in source code. Missing selectors skip live tests instead of picking a host.
  static func hostname(_ source: JSON, role: String) -> String {
    source.object("testTargets").text(role)
  }

  static func host(_ source: JSON, role: String) throws -> JSON {
    let name = hostname(source, role: role)
    guard !name.isEmpty else { throw XCTSkip("Set testTargets.\(role) in the authorized fixture") }
    return try XCTUnwrap(source.array("hosts").first { $0.text("hostname") == name })
  }
}
