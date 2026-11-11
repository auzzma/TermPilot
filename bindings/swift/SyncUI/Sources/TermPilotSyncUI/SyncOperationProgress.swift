import Foundation
import SwiftUI

/// A pinned, live view shared by macOS and iOS. Polls an in-memory endpoint;
/// neither the UI thread nor progress reads wait for the sync transaction.
struct SyncOperationProgress: View {
    let call: @MainActor ([String: Any]) async throws -> [String: Any]
    let busy: Bool
    @State private var progress: [String: Any] = [:]
    @State private var previousID = ""
    private var current: [String: Any] {
        busy && progress["active"] as? Bool != true && progress["id"] as? String == previousID ? [:] : progress
    }
    private var phase: String { current["phase"] as? String ?? "preparing" }
    private var label: String {
        ["preparing":"准备同步", "connecting":"连接并验证云端", "listing":"读取云端目录",
         "merging":"合并本机修改", "downloading":"下载并合并云端数据", "encrypting":"加密待上传数据",
         "uploading":"上传数据", "verifying":"回读校验上传数据", "finalizing":"确认云端提交",
         "applying":"更新本机数据", "completed":"操作完成", "failed":"同步未完成"][phase] ?? "正在处理"
    }
    var body: some View {
        Group {
            if busy || !progress.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(label).font(.headline)
                        Spacer()
                        if let percent = current["percent"] as? Int { Text("\(percent)%").monospacedDigit() }
                    }
                    if let percent = current["percent"] as? Int {
                        ProgressView(value: Double(percent), total: 100).tint(phase == "failed" ? .orange : .accentColor)
                    } else { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
                    if let total = current["total"] as? Int, phase != "completed" {
                        Text("当前阶段：\(current["completed"] as? Int ?? 0) / \(total)").font(.caption).monospacedDigit()
                    }
                    Text("下载 \(size("downloadedBytes")) · 上传 \(size("uploadedBytes")) · 已校验 \(size("verifiedBytes"))")
                        .font(.caption).monospacedDigit()
                    if let error = current["error"] as? String { Text(error).font(.caption).foregroundStyle(.red) }
                    if phase != "completed" && phase != "failed" {
                        Text("百分比为当前阶段；传输量按已完成的加密分块统计。").font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("sync-operation-progress")
            }
        }
        .onChange(of: busy) { _, value in if value { previousID = progress["id"] as? String ?? "" } }
        .task(id: busy) {
            repeat {
                if let value = try? await call(["method":"sync.progress"]) { progress = value }
                try? await Task.sleep(for: .milliseconds(busy ? 250 : 800))
            } while !Task.isCancelled
        }
    }
    private func size(_ key: String) -> String {
        ByteCountFormatter.string(fromByteCount: (current[key] as? NSNumber)?.int64Value ?? 0, countStyle: .binary)
    }
}
