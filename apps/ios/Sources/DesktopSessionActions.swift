import SwiftUI

extension AppModel {
  func desktopAvailable(_ s: MobileSession) -> Bool {
    s.protocolKind == "screen" && s.connected && !s.isClosing && desktopForeground && selected == s.id && s.activePanel == "terminal" && sessions.contains { $0 === s }
  }
  func bindDesktopControls(_ s: MobileSession) {
    s.desktopControls.available = { [weak self, weak s] in
      guard let self, let s else { return false }; return self.desktopAvailable(s)
    }
    s.desktopControls.send = { [weak self, weak s] command in
      guard let self, let s, !s.isClosing else { throw CancellationError() }
      if command.text("kind") != "release", !self.desktopAvailable(s) { throw CancellationError() }
      try await self.send(s.id,command,desktopAction:true)
    }
  }
  // Re-resolve the vault on every action; never fall back to a deleted saved credential.
  func freshDesktopConnection(_ s: MobileSession) async throws -> (JSON, (JSON, JSON)) {
    var source = s.sourceHost.isEmpty ? s.host : s.sourceHost
    if s.savedHost {
      guard let item = try await call(["method":"vault.get","collection":"hosts","id":s.host.text("id")])["item"] as? JSON else {
        throw MobileError(message:"主机或凭证已变更，请重新连接后再试。")
      }
      source = item
    }
    if !s.host.text("credentialID").isEmpty && source.text("credentialID").isEmpty {
      throw MobileError(message:"主机或凭证已变更，请重新连接后再试。")
    }
    let pair: (JSON,JSON)
    do { pair = try await resolveDesktopConnection(source) }
    catch { throw MobileError(message:"没有可用的远程桌面凭证，请修改主机或重新打开快速连接。") }
    let (resolved,config) = pair
    guard resolved.text("connectionKind") == "screenSharing",
      resolved.text("hostname") == s.host.text("host",s.host.text("hostname")),
      resolved.number("port",5900) == s.host.number("port",5900),
      config.text("username") == s.host.text("username"),
      config.text("mode","standardVNC") == s.host.text("mode","standardVNC") else {
      throw MobileError(message:"主机或凭证已变更，请重新连接后再试。")
    }
    return (source,pair)
  }
  func enterDesktopPassword(_ s: MobileSession) async {
    s.dismissKeyboard(); s.dragLocked = false
    await s.desktopControls.login { try await self.freshDesktopConnection(s).1.1.text("password") }
  }
  func resizeDesktop(_ s: MobileSession, to value: DesktopResolution) async {
    guard DesktopResolution.presets.contains(value) else { return }
    if !s.highPerformance { await s.desktopControls.resizeVNC(value); return }
    await s.desktopControls.reconnectResolution {
      do {
        let (source,pair) = try await self.freshDesktopConnection(s)
        guard self.desktopAvailable(s) else { throw CancellationError() }
        try await self.close(s)
        try await self.connect(source,resolution:value,prepared:pair)
      } catch {
        self.error = "重新连接失败，请检查主机及凭证后重试。"
        throw error
      }
    }
  }
}
