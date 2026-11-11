import AppKit
import SwiftUI

/// A plain-text field whose programmatic updates cannot re-enter SwiftUI layout through the input method.
struct BatchTextEditor: NSViewRepresentable {
    @Binding var text: String
    let label: String
    var monospaced = false

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = NSTextView(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.font = monospaced ? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize)
        editor.string = text // Seed the field before it belongs to a window or its input context.
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        if editor.isEditable != context.environment.isEnabled { editor.isEditable = context.environment.isEnabled }
        editor.setAccessibilityLabel(label)
        context.coordinator.syncAfterLayout(editor)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.documentView as? NSTextView)?.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        private var syncPending = false
        private var applyingModel = false

        init(text: Binding<String>) { self.text = text }

        func syncAfterLayout(_ editor: NSTextView) {
            guard !syncPending, !editor.hasMarkedText(), editor.string != text.wrappedValue else { return }
            syncPending = true
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self else { return }
                syncPending = false
                guard let editor, editor.delegate === self, !editor.hasMarkedText() else { return }
                let value = text.wrappedValue
                guard editor.string != value else { return }
                applyingModel = true
                defer { applyingModel = false }
                let selection = editor.selectedRange()
                let length = (value as NSString).length
                let start = min(selection.location, length)
                editor.string = value
                editor.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !applyingModel, let editor = notification.object as? NSTextView,
                  !editor.hasMarkedText(), text.wrappedValue != editor.string else { return }
            text.wrappedValue = editor.string
        }
    }
}
