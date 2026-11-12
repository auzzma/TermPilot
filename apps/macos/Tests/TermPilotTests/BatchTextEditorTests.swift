import AppKit
import SwiftUI
@testable import TermPilotApp
import XCTest

final class BatchTextEditorTests: XCTestCase {
    @MainActor
    func testEditableChangesAreDeferredAndRapidSwitchesUseLatestState() async {
        let coordinator = BatchTextEditor.Coordinator(text: .constant("中文脚本"))
        let editor = EditableObservationTextView()
        editor.string = "中文脚本"
        editor.delegate = coordinator
        editor.setSelectedRange(NSRange(location: 1, length: 2))
        var changes: [Bool] = []
        editor.onEditableChange = { changes.append($0) }

        coordinator.syncAfterLayout(editor, isEditable: false)
        coordinator.syncAfterLayout(editor, isEditable: true)
        XCTAssertTrue(editor.isEditable)
        await drainMainQueue()
        XCTAssertTrue(changes.isEmpty, "A stale disable must not interrupt the input method")

        coordinator.syncAfterLayout(editor, isEditable: false)
        XCTAssertTrue(editor.isEditable, "SwiftUI's update must not change the input context synchronously")
        await drainMainQueue()
        XCTAssertEqual(changes, [false])
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(editor.string, "中文脚本")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 2))
    }

    @MainActor
    func testUpdateDuringInputContextTransitionIsAppliedAfterTransition() async {
        let coordinator = BatchTextEditor.Coordinator(text: .constant("draft"))
        let editor = EditableObservationTextView()
        editor.string = "draft"
        editor.delegate = coordinator
        var changes: [Bool] = []
        editor.onEditableChange = { enabled in
            changes.append(enabled)
            if !enabled {
                // Simulate a SwiftUI update delivered by the input method's
                // nested run loop while setEditable is still on the stack.
                coordinator.syncAfterLayout(editor, isEditable: true)
                XCTAssertFalse(editor.isEditable)
            }
        }
        coordinator.syncAfterLayout(editor, isEditable: false)
        await drainMainQueue()
        await drainMainQueue()
        XCTAssertEqual(changes, [false, true])
        XCTAssertTrue(editor.isEditable)
    }

    @MainActor
    func testDisablingWithMarkedInputDoesNotReplaceTheComposition() async {
        var model = "draft"
        let coordinator = BatchTextEditor.Coordinator(text: Binding(get: { model }, set: { model = $0 }))
        let editor = NSTextView()
        editor.string = "draft"
        editor.delegate = coordinator
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let composition = editor.string
        coordinator.syncAfterLayout(editor, isEditable: false)
        XCTAssertTrue(editor.isEditable)
        await drainMainQueue()
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(editor.string, composition)
        XCTAssertEqual(model, composition)
    }

    @MainActor
    func testDismantlingCancelsPendingTextAndEditableChanges() async {
        let coordinator = BatchTextEditor.Coordinator(text: .constant("replacement"))
        let editor = NSTextView()
        editor.string = "draft"
        editor.delegate = coordinator
        let scroll = NSScrollView()
        scroll.documentView = editor
        coordinator.syncAfterLayout(editor, isEditable: false)
        BatchTextEditor.dismantleNSView(scroll, coordinator: coordinator)
        await drainMainQueue()
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.string, "draft")
    }

    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { done in
            DispatchQueue.main.async { done.resume() }
        }
    }
}

@MainActor
private final class EditableObservationTextView: NSTextView {
    var onEditableChange: ((Bool) -> Void)?

    override var isEditable: Bool {
        didSet { onEditableChange?(isEditable) }
    }
}
