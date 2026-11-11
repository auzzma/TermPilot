import BackgroundTasks
import UIKit

/// Uses a finite continued-processing task on iOS 26+, with UIKit's finite
/// background allowance on older systems. No automatic shell/transfer replay.
@MainActor final class TransferBackground {
  static let shared = TransferBackground()
  private var jobs: [String: BGTask] = [:]
  private var cancellations: [String: () -> Void] = [:]
  private var registered = false
  private let prefix = "com.termpilot.app.transfer."
  private init() {
    #if !targetEnvironment(simulator)
      if #available(iOS 26.0, *) {
        registered = BGTaskScheduler.shared.register(
          forTaskWithIdentifier: prefix + "*", using: .main
        ) { [weak self] task in
          Task { @MainActor in
            guard let self else {
              task.setTaskCompleted(success: false)
              return
            }
            let id = String(task.identifier.dropFirst(self.prefix.count))
            guard self.cancellations[id] != nil else {
              task.setTaskCompleted(success: false)
              return
            }
            self.jobs[id] = task
            if let processing = task as? BGContinuedProcessingTask {
              processing.progress.totalUnitCount = 100
              processing.progress.completedUnitCount = 0
            }
            task.expirationHandler = {
              Task { @MainActor in
                self.cancellations[id]?()
                self.end(id, success: false)
              }
            }
          }
        }
      }
    #endif
  }
  func begin(_ id: String, title: String, cancel: @escaping () -> Void) {
    guard registered else { return }
    cancellations[id] = cancel
    if #available(iOS 26.0, *) {
      let request = BGContinuedProcessingTaskRequest(
        identifier: prefix + id, title: "TermPilot · 文件传输", subtitle: title)
      request.strategy = .fail
      // Falling back retains only the finite UIKit allowance, never permanent background access.
      do { try BGTaskScheduler.shared.submit(request) } catch {
        cancellations.removeValue(forKey: id)
      }
    }
  }
  func update(_ id: String, done: Int64, total: Int64) {
    if #available(iOS 26.0, *), let task = jobs[id] as? BGContinuedProcessingTask {
      task.progress.totalUnitCount = max(1, total)
      task.progress.completedUnitCount = min(done, max(1, total))
    }
  }
  func end(_ id: String, success: Bool) {
    if let task = jobs.removeValue(forKey: id) { task.setTaskCompleted(success: success) }
    cancellations.removeValue(forKey: id)
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: prefix + id)
  }
  var hasActiveTask: Bool { !jobs.isEmpty }
}
