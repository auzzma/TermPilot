import AppKit
import SwiftUI
import TermPilotDomain
@testable import TermPilotScreenSharing
import XCTest

@MainActor
final class ScreenSharingDragTests: XCTestCase {
    func testHostedDesktopRetainsFileDropRegistration() async throws {
        let runtime = ScreenSharingSessionRuntime(descriptor: SessionDescriptor(id: UUID(), kind: .screenSharing, title: "Drag fixture"))
        let host = NSHostingView(rootView: ScreenSharingSurface(runtime: runtime, isActive: true, onFocus: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func find(_ view: NSView) -> ScreenSharingMetalView? {
            if let metal = view as? ScreenSharingMetalView { return metal }
            return view.subviews.compactMap(find).first
        }
        let metal = try XCTUnwrap(find(host))
        XCTAssertTrue(metal.registeredDraggedTypes.contains(.fileURL))
        window.contentView = nil
        XCTAssertFalse(metal.registeredDraggedTypes.contains(.fileURL))
    }
    func testInactiveTabsAndRDPDoNotRemainNativeFileDropTargets() async throws {
        var rdp = SessionDescriptor(id: UUID(), kind: .screenSharing, title: "RDP")
        rdp.screenSharingMode = .rdp
        let runtimes = [ScreenSharingSessionRuntime(descriptor: rdp),
            ScreenSharingSessionRuntime(descriptor: SessionDescriptor(id: UUID(), kind: .screenSharing, title: "Mac A")),
            ScreenSharingSessionRuntime(descriptor: SessionDescriptor(id: UUID(), kind: .screenSharing, title: "Mac B"))]
        let host = NSHostingView(rootView: DragTabsFixture(runtimes: runtimes, active: 1))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        func surfaces(_ view: NSView) -> [ScreenSharingMetalView] {
            if let view = view as? ScreenSharingMetalView { return [view] }
            return view.subviews.flatMap(surfaces)
        }
        for active in [1, 0, 2, 1] {
            host.rootView = DragTabsFixture(runtimes: runtimes, active: active)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let views = surfaces(host); XCTAssertEqual(views.count, 3)
            for view in views {
                let expected = view.runtime === runtimes[active] && view.runtime.supportsFileTransfer
                XCTAssertEqual(view.isHidden, view.runtime !== runtimes[active])
                XCTAssertEqual(view.registeredDraggedTypes.contains(.fileURL), expected,
                               "Native drop registration must follow tab visibility and protocol: \(view.runtime.descriptor.title)")
            }
        }
    }

}

private struct DragTabsFixture: View {
    let runtimes: [ScreenSharingSessionRuntime]
    let active: Int
    var body: some View {
        ZStack {
            ForEach(runtimes.indices, id: \.self) { index in
                ScreenSharingSurface(runtime: runtimes[index], isActive: index == active)
                    .opacity(index == active ? 1 : 0).allowsHitTesting(index == active)
                    .accessibilityHidden(index != active).zIndex(index == active ? 1 : 0)
            }
        }
    }
}
