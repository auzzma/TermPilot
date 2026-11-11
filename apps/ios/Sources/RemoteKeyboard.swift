import SwiftUI
import UIKit

/// An inline first responder. Committed text goes to the remote desktop without
/// presenting a local editor or covering the desktop with a sheet.
struct RemoteKeyboard: UIViewRepresentable {
  @EnvironmentObject var model: AppModel
  @ObservedObject var session: MobileSession
  func makeUIView(context: Context) -> InputView {
    let view = InputView()
    session.remoteKeyboard = view
    view.sendText = { model.sendText(session, $0) }
    view.sendKey = { code in
      model.attempt {
        try await model.send(session.id, ["kind": "key", "key": code, "down": true])
        try await model.send(session.id, ["kind": "key", "key": code, "down": false])
      }
    }
    view.onDismiss = { session.keyboardVisible = false }
    view.setRequested(session.keyboardVisible)
    return view
  }
  func updateUIView(_ view: InputView, context: Context) {
    view.setRequested(session.keyboardVisible && !session.isClosing)
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: InputView, context: Context) -> CGSize? {
    CGSize(width: 1, height: 1)
  }
  static func dismantleUIView(_ view: InputView, coordinator: ()) {
    view.onDismiss = nil
    view.sendText = nil
    view.sendKey = nil
    view.hideKeyboard()
  }
  final class InputView: UITextView, UITextViewDelegate {
    var sendText: ((String) -> Void)?
    var sendKey: ((Int) -> Void)?
    var onDismiss: (() -> Void)?
    private var requested = false
    init() {
      super.init(frame: .zero, textContainer: nil)
      delegate = self
      backgroundColor = .clear
      textColor = .clear
      tintColor = .clear
      autocorrectionType = .no
      autocapitalizationType = .none
      smartQuotesType = .no
      smartDashesType = .no
      smartInsertDeleteType = .no
      spellCheckingType = .no
      isScrollEnabled = false
      isAccessibilityElement = false
      accessibilityElementsHidden = true
      accessibilityIdentifier = "remote-keyboard-input"
      inputAssistantItem.leadingBarButtonGroups = []
      inputAssistantItem.trailingBarButtonGroups = []
    }
    required init?(coder: NSCoder) { fatalError() }
    func setRequested(_ value: Bool) {
      guard requested != value else { return }
      requested = value
      scheduleFocus()
    }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window != nil { scheduleFocus() }
    }
    private func scheduleFocus() {
      // Focus changes may trigger SwiftUI bindings; perform them outside updateUIView.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if self.requested && self.window != nil {
          if !self.isFirstResponder { self.becomeFirstResponder() }
        } else if self.isFirstResponder { self.resignFirstResponder() }
      }
    }
    @objc func hideKeyboard() {
      requested = false
      // Do not commit an unfinished IME composition when closing the keyboard.
      text = ""
      onDismiss?()
      resignFirstResponder()
    }
    func textViewDidEndEditing(_ textView: UITextView) {
      text = ""
      if requested { requested = false; onDismiss?() }
    }
    override func resignFirstResponder() -> Bool {
      // UIKit can end focus while handling an outside touch. Synchronize the
      // toggle here as well as in the delegate, before a later tap can reopen.
      let wasRequested = requested
      requested = false
      text = ""
      let resigned = super.resignFirstResponder()
      if resigned {
        if wasRequested { onDismiss?() }
      } else { requested = wasRequested }
      return resigned
    }
    override var hasText: Bool { true }
    override func deleteBackward() {
      if markedTextRange != nil || !text.isEmpty { super.deleteBackward() }
      else { sendKey?(0xff08) }
    }
    override func insertText(_ value: String) {
      if markedTextRange == nil && (value == "\n" || value == "\r" || value == "\t") {
        sendKey?(value == "\t" ? 0xff09 : 0xff0d)
      } else {
        super.insertText(value)
        flushCommittedText()
      }
    }
    override func unmarkText() {
      super.unmarkText()
      flushCommittedText()
    }
    func textViewDidChange(_ textView: UITextView) { flushCommittedText() }
    private func flushCommittedText() {
      guard requested, markedTextRange == nil, !text.isEmpty else { return }
      let committed = text ?? ""
      text = ""
      sendText?(committed)
    }
  }
}
