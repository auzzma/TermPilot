import AppKit
import SwiftUI

struct AIChatComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        let view = Editor(); view.isRichText = false; view.drawsBackground = false
        view.font = .systemFont(ofSize: 13); view.textColor = .labelColor; view.insertionPointColor = .labelColor
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 7, height: 8); view.delegate = context.coordinator
        view.submit = submit; scroll.documentView = view; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? Editor else { return }
        view.submit = submit
        if view.string != text, !view.hasMarkedText() { view.string = text }
        context.coordinator.resize(view)
    }
    final class Editor: NSTextView {
        var submit: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if !hasMarkedText(), [36, 76].contains(event.keyCode), !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option) {
                submit?(); return
            }
            super.keyDown(with: event)
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIChatComposer
        init(_ parent: AIChatComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string; resize(view)
        }
        func resize(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let next = min(150, max(58, layout.usedRect(for: container).height + 18))
            if abs(parent.height - next) > 1 { DispatchQueue.main.async { [weak self] in self?.parent.height = next } }
        }
    }
}

/// Only user scrolling changes follow mode. Growing content does not disable it.
struct AIChatScrollObserver: NSViewRepresentable {
    var onScroll: (Bool) -> Void
    func makeNSView(context: Context) -> Marker { let v = Marker(); v.onScroll = onScroll; return v }
    func updateNSView(_ view: Marker, context: Context) { view.onScroll = onScroll }
    final class Marker: NSView {
        var onScroll: ((Bool) -> Void)?
        private weak var trackedScroll: NSScrollView?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard window != nil else { return }
            var parent = superview
            while let current = parent {
                if let scroll = current as? NSScrollView {
                    trackedScroll = scroll
                    NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSScrollView.didLiveScrollNotification, object: scroll)
                    break
                }; parent = current.superview
            }
        }
        @objc private func didScroll() {
            guard let scroll = trackedScroll, let doc = scroll.documentView else { return }
            onScroll?(scroll.documentVisibleRect.maxY >= doc.bounds.maxY - 48)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
