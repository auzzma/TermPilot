import SwiftUI

struct SyncLeaseSettings: View {
    let minutes: Int
    let save: (Int) -> Void
    @State private var draft = ""
    private var value: Int? { Int(draft).flatMap { (1...1440).contains($0) ? $0 : nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("锁超时时长（分钟）", text: $draft)
                .accessibilityIdentifier("sync-lock-timeout")
            Text("1–1440 分钟，默认 60 分钟。同步期间自动续期；超过此时长未续期，其他设备可在同步时接管。修改用于本机此配置的下一次同步。参与同步的设备需更新到同一新版客户端。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("保存超时时长") { if let value { save(value) } }
                .disabled(value == nil || value == minutes)
                .accessibilityIdentifier("sync-lock-timeout-save")
        }
        .onAppear { draft = String(minutes) }
        .onChange(of: minutes) { _, value in draft = String(value) }
    }
}

struct SyncHistorySettings: View {
    let count: Int
    let pending: Int?
    let save: (Int) -> Void
    @State private var draft = ""
    private var value: Int? { Int(draft).flatMap { (1...100).contains($0) ? $0 : nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("历史版本保留数量", text: $draft).accessibilityIdentifier("sync-history-count")
            Text("1–100 份，默认 10 份，不包含当前版本。每个版本是独立完整的加密 TPS。设置在下次成功同步后对整个同步库生效，过期历史延迟清理。")
                .font(.footnote).foregroundStyle(.secondary)
            if let pending { Text("待同步设置：\(pending) 份").font(.footnote).foregroundStyle(.secondary) }
            Button("保存历史数量") { if let value { save(value) } }
                .disabled(value == nil || value == (pending ?? count)).accessibilityIdentifier("sync-history-count-save")
        }
        .onAppear { draft = String(pending ?? count) }
        .onChange(of: pending ?? count) { _, value in draft = String(value) }
    }
}
