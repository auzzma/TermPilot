import Foundation

enum TransferState {
  static func active(_ status: String) -> Bool {
    ["传输中", "已暂停", "transferring", "paused", "queued", "preparing"].contains(status)
  }
  static func paused(_ status: String) -> Bool { ["paused", "已暂停"].contains(status) }
  static func label(_ status: String) -> String {
    [
      "transferring": "传输中", "paused": "已暂停", "queued": "等待中", "preparing": "准备中",
      "completed": "已完成", "cancelled": "已取消", "failed": "失败",
    ][status] ?? status
  }
}
@MainActor extension AppModel {
  func controlTransfer(_ session: MobileSession, id: String, action: String) async throws {
    guard let item = session.transfers[id], TransferState.active(item.text("status")) else {
      return
    }
    if session.protocolKind == "ssh" {
      if action == "cancel" { session.transfers[id]?["cancelRequested"] = true }
      _ = try await files(session, ["action": action, "targetID": id])
      guard let latest = session.transfers[id], TransferState.active(latest.text("status")) else {
        return
      }
      session.transfers[id]?["status"] =
        action == "pause" ? "已暂停" : action == "resume" ? "传输中" : "已取消"
      try await recordTransfer(
        session.transfers[id]!,
        status: action == "pause" ? "paused" : action == "resume" ? "active" : "cancelled")
    } else {
      let kind =
        session.protocolKind == "rdp"
        ? action + "Transfer"
        : action == "pause" ? "filePause" : action == "resume" ? "fileResume" : "fileCancel"
      try await send(session.id, ["kind": kind, "requestID": id])
      // Protocol state events acknowledge controls and own remote transfer history.
    }
  }
}
