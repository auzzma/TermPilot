import SwiftUI

/// The durable Rust checkpoint is the authority; closing the process never
/// rolls back a cloud cutover. This view prevents accidental dismissal only.
struct SyncPasswordProgress: View {
    let progress: [String: Any]
    let running: Bool
    let retry: () -> Void
    let done: () -> Void
    let credentials: () -> Void
    private var complete: Bool { progress["phase"] as? String == "completed" }
    private var percent: Double { Double(progress["percent"] as? Int ?? 0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(complete ? "同步 Key 已修改" : "正在修改同步 Key", systemImage: complete ? "checkmark.shield" : "lock.shield")
                .font(.title2.weight(.semibold))
            Text(Self.phases[progress["phase"] as? String ?? ""] ?? "准备迁移")
            ProgressView(value: percent, total: 100).accessibilityLabel("Key 修改进度")
            HStack {
                Text("\(Int(percent))%").monospacedDigit()
                Spacer()
                if let total = progress["total"] as? Int, total > 0 {
                    Text("\(progress["completed"] as? Int ?? 0) / \(total) 个对象").monospacedDigit()
                }
            }.font(.caption).foregroundStyle(.secondary)
            if let message = progress["error"] as? String, !message.isEmpty {
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            }
            Text(complete
                 ? "其它设备下次同步时需输入新 Key，未上传的修改会继续合并。"
                 : "请保持应用和此页面打开，完成前无法关闭。断网或意外退出后，可在本设备继续；已完成的步骤会保留。")
                .font(.callout).foregroundStyle(.secondary)
            if complete { Button("完成", action: done).buttonStyle(.borderedProminent) }
            else if !running {
                HStack {
                    Button("继续修改 Key", action: retry).buttonStyle(.borderedProminent)
                    Button("更新云端认证", action: credentials)
                }
            }
        }
        .padding(28).frame(idealWidth: 500).frame(maxWidth: 600)
        .interactiveDismissDisabled(!complete)
        .accessibilityIdentifier("sync-password-progress")
    }
    static let phases = ["preparing":"准备本机备份", "locking":"等待同步库空闲", "synchronizing":"合并本机待同步修改", "downloading":"下载并校验全部旧密文", "reencrypting":"使用新 Key 重新加密", "uploading":"上传并回读校验新密文", "verifying":"核对完整性", "switching":"切换同步库版本", "finishing":"更新本机同步状态", "completed":"所有数据已完成切换"]
}
