import SwiftUI

struct DesktopResolution: Equatable, Identifiable {
  let width: Int, height: Int
  var id: String { "\(width)x\(height)" }
  var title: String { "\(width) × \(height)" }
  static let presets = [(1280,720),(1920,1080),(2560,1440),(3840,2160)].map { Self(width:$0.0,height:$0.1) }
}

/// Session-local actions. Transport acknowledgements never imply a successful login.
@MainActor final class MobileDesktopControls: ObservableObject {
  @Published var actionError: String?
  @Published private(set) var loginBusy = false
  @Published private(set) var loginMessage = "请先点选远端密码输入框；将使用当前连接的密码并回车。"
  @Published private(set) var resizeBusy = false
  @Published private(set) var resizeSupported = false
  @Published private(set) var resizeBlocked = false
  @Published private(set) var resizeMessage = "远端未提供分辨率调整能力，请在远端系统设置中修改。"
  var available: () -> Bool = { false }
  var send: (JSON) async throws -> Void = { _ in throw CancellationError() }
  var keyTimeout: Duration = .seconds(5)
  var resizeTimeout: Duration = .seconds(15)
  private var cancelled = false
  private var pending: (String, CheckedContinuation<Bool,Never>)?
  private var keyDeadline: Task<Void,Never>?
  private var resizeDeadline: Task<Void,Never>?
  private var resizeID: String?

  func cancelLogin() {
    guard loginBusy else { return }
    cancelled = true; loginMessage = "已取消密码输入。"
    finishKey(false)
  }
  func stop() {
    cancelLogin(); resizeDeadline?.cancel(); resizeDeadline = nil; resizeID = nil
    resizeBusy = false; resizeSupported = false; resizeBlocked = false
  }
  func receive(_ e: JSON) {
    switch e.text("kind") {
    case "credentialKeySent": if pending?.0 == e.text("requestID") { finishKey(true) }
    case "vncCapabilities":
      resizeSupported = e["canResize"] as? Bool == true
      if resizeID == nil { resizeMessage = resizeSupported ? "分辨率修改须由远端 VNC 服务确认。" : "当前显示器布局暂不支持调整，请在远端系统设置中修改。" }
    case "vncResizeResult":
      guard let id = resizeID, id == e.text("requestID") else { return }
      if e["pending"] as? Bool == true { resizeMessage = "正在等待远端系统应用分辨率…"; return }
      resizeDeadline?.cancel(); resizeDeadline = nil; resizeID = nil; resizeBusy = false; resizeBlocked = false
      if e["accepted"] as? Bool == true { resizeMessage = "远端已确认修改分辨率。" }
      else { resizeMessage = e.text("code") == "vncResizeProhibited" ? "远端服务不允许修改分辨率。" : "远端拒绝了此分辨率，请尝试其他尺寸。"; actionError = resizeMessage }
    default: break
    }
  }
  func login(password: () async throws -> String) async {
    guard available(), !loginBusy, !resizeBusy else { return }
    actionError = nil; loginBusy = true; cancelled = false; loginMessage = "正在输入密码…"
    do {
      let value = try await password()
      guard !value.isEmpty else { throw MobileError(message:"没有可用的远程桌面凭证，请修改主机或重新打开快速连接。") }
      guard value.unicodeScalars.count <= 1024, !value.unicodeScalars.contains(where:{[.control,.lineSeparator,.paragraphSeparator].contains($0.properties.generalCategory)}) else {
        throw MobileError(message:"此密码无法自动输入，请在远端手动输入。")
      }
      if !cancelled && available() {
        try await send(["kind":"release"])
        for scalar in value.unicodeScalars {
          guard await step(scalar.value <= 255 ? scalar.value : scalar.value | 0x01000000) else { break }
        }
        if !cancelled && available(), await step(0xff0d) { loginMessage = "已输入密码并回车，请查看远端登录结果。" }
      } else { cancelLogin() }
    } catch {
      if !cancelled { loginMessage = (error as? MobileError)?.message ?? "连接不可用，已停止输入密码。"; actionError = loginMessage }
    }
    finishKey(false)
    try? await send(["kind":"release"])
    loginBusy = false
  }
  private func step(_ key: UInt32) async -> Bool {
    guard !cancelled, available(), !Task.isCancelled else { cancelLogin(); return false }
    let id = UUID().uuidString
    return await withCheckedContinuation { continuation in
      pending = (id,continuation)
      keyDeadline = Task { [weak self,keyTimeout] in
        do { try await Task.sleep(for:keyTimeout) } catch { return }
        guard let self, self.pending?.0 == id else { return }
        self.cancelled = true; self.loginMessage = "密码输入超时，请检查远端输入框后再重试。"; self.actionError = self.loginMessage; self.finishKey(false)
      }
      Task { [weak self] in
        guard let self, self.pending?.0 == id, !self.cancelled, self.available() else { self?.cancelLogin(); return }
        do { try await self.send(["kind":"credentialKey","key":key,"requestID":id]) }
        catch { self.cancelled = true; self.loginMessage = "连接不可用，已停止输入密码。"; self.actionError = self.loginMessage; self.finishKey(false) }
      }
    }
  }
  private func finishKey(_ success: Bool) {
    let continuation = pending?.1; pending = nil
    keyDeadline?.cancel(); keyDeadline = nil; continuation?.resume(returning:success)
  }
  func resizeVNC(_ value: DesktopResolution) async {
    guard available(), resizeSupported, !resizeBlocked, !resizeBusy, !loginBusy, DesktopResolution.presets.contains(value) else { return }
    actionError = nil
    let id = UUID().uuidString; resizeID = id; resizeBusy = true; resizeMessage = "正在请求修改远端分辨率…"
    resizeDeadline = Task { [weak self,resizeTimeout] in
      do { try await Task.sleep(for:resizeTimeout) } catch { return }
      guard let self, self.resizeID == id else { return }
      self.resizeBusy = false; self.resizeBlocked = true; self.resizeMessage = "远端未确认分辨率，请重连后重试。"; self.actionError = self.resizeMessage
    }
    do { try await send(["kind":"resize","width":value.width,"height":value.height,"requestID":id]) }
    catch {
      if resizeID == id { resizeDeadline?.cancel(); resizeID = nil; resizeBusy = false; resizeMessage = "连接不可用，请重连后调整分辨率。"; actionError = resizeMessage }
    }
  }
  func reconnectResolution(_ operation: () async throws -> Void) async {
    guard available(), !loginBusy, !resizeBusy else { return }
    actionError = nil; resizeBusy = true; resizeMessage = "正在按所选分辨率重新连接…"
    do { try await operation() }
    catch { resizeMessage = "重新连接失败，请检查连接后重试。"; actionError = resizeMessage }
    resizeBusy = false
  }
}

struct MobileDesktopActions: View {
  @EnvironmentObject var model: AppModel
  @ObservedObject var session: MobileSession
  @ObservedObject var controls: MobileDesktopControls
  var body: some View {
    HStack(spacing:6) {
      Button(tr("输入密码并登录")) { Task { await model.enterDesktopPassword(session) } }
        .disabled(!model.desktopAvailable(session) || controls.loginBusy || controls.resizeBusy)
        .accessibilityIdentifier("remote-login-password")
      if controls.loginBusy { Button(tr("取消")) { controls.cancelLogin() }.accessibilityIdentifier("remote-login-cancel") }
      Menu {
        Text("\(Int(session.desktopSize.width)) × \(Int(session.desktopSize.height))")
        ForEach(DesktopResolution.presets) { value in
          Button { Task { await model.resizeDesktop(session,to:value) } } label: {
            if session.desktopSize == CGSize(width:value.width,height:value.height) { Label(value.title,systemImage:"checkmark") }
            else { Text(value.title) }
          }.disabled(!model.desktopAvailable(session) || controls.loginBusy || controls.resizeBusy || (!session.highPerformance && (!controls.resizeSupported || controls.resizeBlocked)))
        }
      } label: { Label(tr("分辨率"),systemImage:"display") }
      .accessibilityIdentifier("remote-resolution")
      .accessibilityValue(DesktopResolution(width:Int(session.desktopSize.width),height:Int(session.desktopSize.height)).title)
    }.buttonStyle(RemoteActionStyle())
      .alert(tr("操作失败"),isPresented:Binding(get:{controls.actionError != nil},set:{if !$0 {controls.actionError = nil}})) {
        Button(tr("关闭"),role:.cancel) { controls.actionError = nil }
      } message: { Text(tr(controls.actionError ?? "")) }
      .onDisappear { controls.cancelLogin() }
  }
}
