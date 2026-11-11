import SwiftUI
import SwiftTerm
import UIKit

extension MobileSession {
  func dismissKeyboard() {
    keyboardVisible = false
    remoteKeyboard?.hideKeyboard()
    _ = terminalView.resignFirstResponder()
    // SwiftTerm's stock keyboard icon switches to an alternate function-key
    // inputView. Never leave that alternate keyboard active after dismissal.
    terminalView.inputView = nil
    controlKey = false
    altKey = false
  }

  func toggleKeyboard() {
    if keyboardVisible { dismissKeyboard() }
    else if protocolKind == "ssh" {
      // A terminal may retain hardware-input focus after UIKit hides the soft
      // keyboard. An explicit open action must request the keyboard afresh.
      if terminalView.isFirstResponder { _ = terminalView.resignFirstResponder() }
      terminalView.inputView = nil
      _ = terminalView.becomeFirstResponder()
    } else { keyboardVisible = true }
  }
}

/// Track native terminal focus, including taps and system keyboard dismissal.
@MainActor final class MobileTerminalView: TerminalView {
  var focusChanged: ((Bool) -> Void)?
  override func becomeFirstResponder() -> Bool {
    let changed = super.becomeFirstResponder()
    if changed { focusChanged?(true) }
    return changed
  }
  override func resignFirstResponder() -> Bool {
    let changed = super.resignFirstResponder()
    if changed { focusChanged?(false) }
    return changed
  }
}

/// SSH already has a configurable shortcut bar. Replace SwiftTerm's duplicate
/// accessory, whose keyboard-down icon actually opens its function-key panel.
@MainActor final class TerminalKeyboardAccessory: UIToolbar {
  private weak var session: MobileSession?
  init(session: MobileSession) {
    self.session = session
    super.init(frame: .zero)
    sizeToFit()
    let dismiss = UIBarButtonItem(
      image: UIImage(systemName: "keyboard.chevron.compact.down"),
      style: .plain, target: self, action: #selector(hideKeyboard))
    dismiss.accessibilityLabel = tr("收起键盘")
    dismiss.accessibilityIdentifier = "terminal-keyboard-dismiss"
    items = [.flexibleSpace(), dismiss]
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc private func hideKeyboard() { session?.dismissKeyboard() }
}
