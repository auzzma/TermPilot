import Foundation

@MainActor extension AppModel {
  func noteRemoteTransfer(_ session: MobileSession, _ event: JSON) {
    let id = event.text("id", event.text("requestID"))
    guard !id.isEmpty else { return }
    let stage = event.text("stage")
    let taskID = "\(session.id)-\(id)"
    let finished = ["completed", "failed", "cancelled"].contains(stage)
    if session.transfers[id] == nil && !finished {
      TransferBackground.shared.begin(taskID, title: event.text("name", "文件")) { [weak self] in
        self?.attempt {
          try await self?.send(
            session.id,
            [
              "kind": session.protocolKind == "rdp" ? "cancelTransfer" : "fileCancel",
              "requestID": id,
            ])
        }
      }
    }
    TransferBackground.shared.update(
      taskID, done: Int64(event.number("completedBytes")), total: Int64(event.number("totalBytes")))
    if finished { TransferBackground.shared.end(taskID, success: stage == "completed") }
    // Record state transitions, not every network packet; credentials never enter the journal.
    if session.transfers[id]?.text("status") != stage {
      let local = session.remoteDownloads[id]?.path ?? ""
      let state =
        stage == "completed"
        ? (local.isEmpty ? "completed" : "downloaded")
        : stage == "paused" ? "paused" : finished ? "interrupted" : "active"
      let row: JSON = [
        "id": taskID, "hostID": session.host.text("id"), "label": session.label,
        "protocol": session.protocolKind, "name": event.text("name", "文件"), "status": state,
        "localPath": local, "upload": event.text("direction") == "upload",
        "total": event.number("totalBytes"), "transferred": event.number("completedBytes"),
      ]
      attempt {
        try await self.recordTransfer(
          row, status: state, error: event.text("error", event.text("code")))
      }
    }
  }
  func recordReceivedFiles(_ session: MobileSession, _ paths: [String]) {
    for path in paths {
      let row: JSON = [
        "id": UUID().uuidString, "hostID": session.host.text("id"), "label": session.label,
        "protocol": session.protocolKind, "name": URL(fileURLWithPath: path).lastPathComponent,
        "localPath": path, "upload": false,
      ]
      attempt { try await self.recordTransfer(row, status: "downloaded") }
    }
  }
  func endRemoteTransfers(_ session: MobileSession) {
    guard session.protocolKind != "ssh" else { return }
    for (id, task) in session.transfers {
      let key = "\(session.id)-\(id)"
      TransferBackground.shared.end(key, success: false)
      if !["completed", "failed", "cancelled"].contains(task.text("status")) {
        var row = task
        row["id"] = key
        row["protocol"] = session.protocolKind
        row["hostID"] = session.host.text("id")
        row["label"] = session.label
        attempt {
          try await self.recordTransfer(row, status: "interrupted", error: "会话已断开；请重新选择文件发起传输")
        }
      }
    }
  }
}
