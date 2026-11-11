import AppKit
import SwiftUI

struct TabInfoPopoverModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String?

    func body(content: Content) -> some View {
        content
            .overlay(
                TabInfoPopoverAnchor(
                    title: title,
                    subtitle: subtitle,
                    colorScheme: colorScheme
                )
            )
    }
}

private struct TabInfoPopoverAnchor: NSViewRepresentable {
    let title: String
    let subtitle: String?
    let colorScheme: ColorScheme

    func makeNSView(context _: Context) -> TabInfoPopoverAnchorView {
        let view = TabInfoPopoverAnchorView()
        view.update(
            title: title,
            subtitle: subtitle,
            colorScheme: colorScheme
        )
        return view
    }

    func updateNSView(
        _ nsView: TabInfoPopoverAnchorView,
        context _: Context
    ) {
        nsView.update(
            title: title,
            subtitle: subtitle,
            colorScheme: colorScheme
        )
    }

    static func dismantleNSView(
        _ nsView: TabInfoPopoverAnchorView,
        coordinator _: ()
    ) {
        nsView.hidePopover()
    }
}

private final class TabInfoPopoverAnchorView: NSView {
    private var title = ""
    private var subtitle: String?
    private var colorScheme = ColorScheme.light
    private var trackingArea: NSTrackingArea?
    private var popoverPanel: NSPanel?
    private var dismissalEventMonitor: Any?

    func update(
        title: String,
        subtitle: String?,
        colorScheme: ColorScheme
    ) {
        self.title = title
        self.subtitle = subtitle
        self.colorScheme = colorScheme
        updatePanelAppearance()
        if popoverPanel?.isVisible == true {
            updatePanelContent()
            positionPanel()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
            ],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hidePopover()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        showPopover()
    }

    override func mouseMoved(with event: NSEvent) {
        positionPanel()
    }

    override func mouseExited(with event: NSEvent) {
        hidePopover()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func hidePopover() {
        popoverPanel?.orderOut(nil)
        removeDismissalEventMonitor()
    }

    private func showPopover() {
        guard window != nil else {
            return
        }
        if popoverPanel == nil {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            panel.level = .popUpMenu
            panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = true
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            popoverPanel = panel
        }
        updatePanelAppearance()
        updatePanelContent()
        positionPanel()
        popoverPanel?.orderFrontRegardless()
        installDismissalEventMonitor()
    }

    private func installDismissalEventMonitor() {
        guard dismissalEventMonitor == nil else {
            return
        }
        dismissalEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            if TabInfoPopoverEventPolicy.dismissesPopover(for: event) {
                self?.hidePopover()
            }
            return event
        }
    }

    private func removeDismissalEventMonitor() {
        guard let dismissalEventMonitor else {
            return
        }
        NSEvent.removeMonitor(dismissalEventMonitor)
        self.dismissalEventMonitor = nil
    }

    private func updatePanelAppearance() {
        let name: NSAppearance.Name = colorScheme == .dark
            ? .darkAqua
            : .aqua
        popoverPanel?.appearance = NSAppearance(named: name)
    }

    private func updatePanelContent() {
        guard let popoverPanel else {
            return
        }
        let hostingView = NSHostingView(
            rootView: TabInfoPopoverContent(
                title: title,
                subtitle: subtitle,
                colorScheme: colorScheme
            )
        )
        hostingView.appearance = popoverPanel.appearance
        let size = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: size)
        popoverPanel.contentView = hostingView
        popoverPanel.setContentSize(size)
    }

    private func positionPanel() {
        guard let window,
              let popoverPanel,
              popoverPanel.contentView != nil
        else {
            return
        }
        let anchorRect = window.convertToScreen(convert(bounds, to: nil))
        let panelSize = popoverPanel.frame.size
        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        var origin = NSPoint(
            x: anchorRect.midX - panelSize.width / 2,
            y: anchorRect.minY - panelSize.height - 6
        )
        if origin.y < visibleFrame.minY {
            origin.y = anchorRect.maxY + 6
        }
        origin.x = min(
            max(origin.x, visibleFrame.minX + 6),
            visibleFrame.maxX - panelSize.width - 6
        )
        popoverPanel.setFrameOrigin(origin)
    }
}

enum TabInfoPopoverEventPolicy {
    static func dismissesPopover(for event: NSEvent) -> Bool {
        event.type == .rightMouseDown
            || (
                event.type == .leftMouseDown
                    && event.modifierFlags.contains(.control)
            )
    }
}

private struct TabInfoPopoverContent: View {
    let title: String
    let subtitle: String?
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .environment(\.colorScheme, colorScheme)
    }
}

struct PointingHandCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(CursorTrackingView(cursor: .pointingHand))
    }
}

extension View {
    func tabInfoPopover(
        title: String,
        subtitle: String? = nil
    ) -> some View {
        modifier(
            TabInfoPopoverModifier(
                title: title,
                subtitle: subtitle
            )
        )
    }

    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

struct CursorTrackingView: NSViewRepresentable {
    var cursor: NSCursor

    func makeNSView(context _: Context) -> CursorTrackingNSView {
        let view = CursorTrackingNSView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: CursorTrackingNSView, context _: Context) {
        nsView.cursor = cursor
    }
}

final class CursorTrackingNSView: NSView {
    var cursor: NSCursor = .arrow
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
                .cursorUpdate,
            ],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        cursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        cursor.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
