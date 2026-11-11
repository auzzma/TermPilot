import SwiftTerm
import SwiftUI
import UIKit

@MainActor final class TerminalAdapter: NSObject, TerminalViewDelegate {
  weak var session: MobileSession?
  weak var model: AppModel?
  init(session: MobileSession, model: AppModel) {
    self.session = session
    self.model = model
  }
  func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    guard let model, let s = session else { return }
    model.attempt {
      try await model.send(s.id, ["type": "resize", "cols": newCols, "rows": newRows])
      _ = try await model.call([
        "method": "terminal.resize", "id": s.terminalID, "columns": newCols, "rows": newRows,
      ])
    }
  }
  func send(source: TerminalView, data: ArraySlice<UInt8>) {
    guard let model, let s = session else { return }
    var bytes = Data(data)
    if bytes.count == 1, let byte = bytes.first, byte >= 32, byte <= 127 {
      if s.controlKey {
        bytes = Data([byte & 31])
        s.controlKey = false
      }
      if s.altKey {
        bytes.insert(27, at: 0)
        s.altKey = false
      }
    }
    let encoded = bytes.base64EncodedString()
    model.attempt {
      try await model.send(s.id, ["type": "data", "data": encoded])
    }
  }
  func setTerminalTitle(source: TerminalView, title: String) {}
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  func scrolled(source: TerminalView, position: Double) {}
  func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
  func bell(source: TerminalView) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
  func clipboardCopy(source: TerminalView, content: Data) {
    UIPasteboard.general.string = String(data: content, encoding: .utf8)
  }
  func clipboardRead(source: TerminalView) -> Data? { nil }  // Clipboard reads require the visible Paste action.
  func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
  func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
struct TerminalSurface: UIViewRepresentable {
  @ObservedObject var session: MobileSession
  @AppStorage("TermPilot.fontSize") private var fontSize = 14.0
  func makeUIView(context: Context) -> TerminalContainer {
    TerminalContainer()
  }
  func updateUIView(_ container: TerminalContainer, context: Context) {
    // SwiftUI may reuse the representable when switching sessions. Always mount
    // the current session's terminal so toolbar focus and displayed output agree.
    let view = session.terminalView
    container.mount(view)
    if view.font.pointSize != fontSize {
      view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
  }
}
final class TerminalContainer: UIView {
  private weak var terminal: TerminalView?
  func mount(_ view: TerminalView) {
    guard terminal !== view || view.superview !== self else { return }
    terminal?.removeFromSuperview()
    terminal = view
    view.accessibilityIdentifier = "terminal-surface"
    view.frame = bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(view)
  }
}
struct KeyBar: View {
  @EnvironmentObject var model: AppModel
  @ObservedObject var session: MobileSession
  @AppStorage("TermPilot.keyOrder") private var keyOrder = TerminalKey.defaultOrder
  @State private var search = false
  var body: some View {
    Group {
      if session.protocolKind == "ssh" { terminalBar }
      else {
        remoteBar.background(alignment: .topLeading) {
          RemoteKeyboard(session: session).frame(width: 1, height: 1)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
      }
    }
    .disabled(session.isClosing)
    .sheet(isPresented: $search) { TerminalSearch(session: session) }
    .onDisappear { session.dismissKeyboard() }
  }
  private var terminalBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        Button(tr("键盘")) { session.toggleKeyboard() }.accessibilityIdentifier("terminal-keyboard-toggle")
        Button(tr("搜索/选择")) { search = true }
        Button("Ctrl") { session.controlKey.toggle() }.tint(session.controlKey ? .orange : .accentColor)
        Button("Alt") { session.altKey.toggle() }.tint(session.altKey ? .orange : .accentColor)
        ForEach(TerminalKey.ordered(keyOrder), id: \.name) { item in
          Button(item.name) { key(item.text, item.code, modifier: item.modifier) }
        }
        Menu(tr("功能键")) {
          ForEach(1...12, id: \.self) { number in
            Button("F\(number)") {
              let codes = ["\u{1b}OP", "\u{1b}OQ", "\u{1b}OR", "\u{1b}OS", "\u{1b}[15~", "\u{1b}[17~", "\u{1b}[18~", "\u{1b}[19~", "\u{1b}[20~", "\u{1b}[21~", "\u{1b}[23~", "\u{1b}[24~"]
              model.sendText(session, codes[number - 1])
            }
          }
        }
        PasteButton(payloadType: String.self, onPaste: paste).labelStyle(.iconOnly)
      }.buttonStyle(.bordered).controlSize(.small).padding(8)
    }
  }
  private var remoteBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        action("触控板", id: "touchpad", active: session.touchpad) {
          session.touchpad.toggle()
          model.attempt { try await model.send(session.id, ["kind": "release"]) }
        }
        action("键盘", id: "keyboard", active: session.keyboardVisible) {
          session.toggleKeyboard()
        }
        PasteButton(payloadType: String.self, onPaste: paste)
          .labelStyle(.titleOnly).buttonBorderShape(.capsule).tint(.secondary)
          .frame(minHeight: 44).accessibilityIdentifier("remote-action-paste")
        action("复制远端", id: "copy") { UIPasteboard.general.string = session.remoteClipboard }
        separator
        action("拖动锁定", id: "drag", active: session.dragLocked) {
          session.dragLocked.toggle()
          if !session.dragLocked { model.attempt { try await model.send(session.id, ["kind": "release"]) } }
        }
        action("滚动↑", id: "scroll-up") {
          model.attempt { try await model.send(session.id, ["kind": "scroll", "dy": -1]) }
        }
        action("滚动↓", id: "scroll-down") {
          model.attempt { try await model.send(session.id, ["kind": "scroll", "dy": 1]) }
        }
        separator
        action("Win/⌘", id: "system-key") { key("", 0xffeb) }
        ForEach(TerminalKey.ordered(keyOrder), id: \.name) { item in
          action(item.name, id: "shortcut-" + item.name) { key(item.text, item.code, modifier: item.modifier) }
        }
        Menu(tr("组合键")) {
          Button("Ctrl-V") { key("", 118, modifier: 0xffe3) }
          Button("⌘-C") { key("", 99, modifier: 0xffeb) }
          Button("⌘-V") { key("", 118, modifier: 0xffeb) }
          Button("Alt-Tab") { key("", 0xff09, modifier: 0xffe9) }
          Button("Win-R") { key("", 114, modifier: 0xffeb) }
          if session.protocolKind == "rdp" {
            Button("Ctrl-Alt-Delete") {
              model.attempt { try await model.send(session.id, ["kind": "secureAttention"]) }
            }
          }
        }.buttonStyle(RemoteActionStyle()).accessibilityIdentifier("remote-action-combinations")
        separator
        action("声音", id: "audio", active: session.audioEnabled) {
          session.audioEnabled.toggle()
          model.attempt { try await model.send(session.id, ["kind": "audio", "enabled": session.audioEnabled]) }
          if !session.audioEnabled { session.remoteAudio.stop() }
        }
      }.padding(6)
    }.accessibilityIdentifier("remote-action-bar")
  }
  private var separator: some View { Divider().frame(height: 22).padding(.horizontal, 4) }
  private func action(_ title: String, id: String, active: Bool? = nil, perform: @escaping () -> Void) -> some View {
    Button(tr(title), action: perform)
      .buttonStyle(RemoteActionStyle(active: active == true))
      .accessibilityIdentifier("remote-action-" + id)
      .accessibilityAddTraits(active == true ? .isSelected : [])
  }
  private func paste(_ values: [String]) {
    guard let text = values.first else { return }
    model.attempt {
      if session.protocolKind == "ssh" {
        let snapshot = try await model.call(["method": "terminal.snapshot", "id": session.terminalID])
        model.sendText(session, snapshot["bracketedPaste"] as? Bool == true
          ? "\u{1b}[200~" + text + "\u{1b}[201~" : text)
      } else {
        try await model.send(session.id, ["kind": "clipboardSend", "text": text, "offerId": UUID().uuidString])
      }
    }
  }
  private func key(_ text: String, _ code: Int, modifier: Int? = nil) {
    if session.protocolKind == "ssh" { model.sendText(session, text); return }
    model.attempt {
      if let modifier { try await model.send(session.id, ["kind": "key", "key": modifier, "down": true]) }
      try await model.send(session.id, ["kind": "key", "key": code, "down": true])
      try await model.send(session.id, ["kind": "key", "key": code, "down": false])
      if let modifier { try await model.send(session.id, ["kind": "key", "key": modifier, "down": false]) }
    }
  }
}
private struct RemoteActionStyle: ButtonStyle {
  var active = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.subheadline).lineLimit(1)
      .padding(.horizontal, 12).frame(minHeight: 44)
      .foregroundStyle(active ? Color.accentColor : Color.primary)
      .background(active ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(configuration.isPressed ? 0.18 : 0.06), in: Capsule())
      .overlay(Capsule().strokeBorder(active ? Color.accentColor : Color(uiColor: .separator), lineWidth: 1))
      .contentShape(Capsule())
  }
}
