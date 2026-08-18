import AppKit
@testable import TermPilotApp
import XCTest

final class HostAppearanceResourceTests: XCTestCase {
    func testDebianIconUsesCoreSVGCompatibleArcSyntax() throws {
        let url = try XCTUnwrap(
            AppResourceLocator.url(
                forResource: "debian",
                withExtension: "svg",
                subdirectory: "distro"
            )
        )
        let svg = try String(contentsOf: url, encoding: .utf8)

        // CoreSVG requires separators between both arc flags and coordinates.
        XCTAssertFalse(svg.contains("0 01"))
        XCTAssertFalse(svg.contains("0 00"))

        let image = try XCTUnwrap(NSImage(contentsOf: url))
        var rect = CGRect(origin: .zero, size: image.size)
        XCTAssertNotNil(
            image.cgImage(
                forProposedRect: &rect,
                context: nil,
                hints: nil
            )
        )
    }
}
