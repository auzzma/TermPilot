import SwiftUI

/// Observe transfer activity locally so progress never redraws the workspace.
struct FileTransferToolbarButton: View {
    @ObservedObject var activity: FileTransferActivityModel
    @Binding var isPresented: Bool

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 5) {
                Label("Transfers", systemImage: "arrow.up.arrow.down")
                if activity.unfinishedCount > 0 {
                    Text(verbatim: "\(activity.unfinishedCount)")
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                if activity.attentionCount > 0 {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .help("Transfer Center")
        .accessibilityIdentifier("file-transfer-toolbar")
    }
}

/// Keep the panel inside the content area, including when the window is resized.
struct FileTransferPanelOverlay: View {
    @Binding var isPresented: Bool

    var body: some View {
        if isPresented {
            GeometryReader { viewport in
                ZStack(alignment: .topTrailing) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { isPresented = false }
                        .accessibilityHidden(true)
                    TransferCenterView(
                        maximumSize: CGSize(width: max(0, viewport.size.width - 24),
                                            height: max(0, viewport.size.height - 24)),
                        onClose: { isPresented = false }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.primary.opacity(0.12)))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                    .onTapGesture { } // Interior whitespace must not dismiss the panel.
                    .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                    .padding(12)
                }
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topTrailing)
                .clipped()
            }
            .onExitCommand { isPresented = false }
        }
    }
}

/// The single progress surface for SFTP and remote desktop file transfers.
struct TransferCenterView: View {
    @EnvironmentObject private var state: AppState
    var maximumSize = CGSize(width: 560, height: 640)
    var onClose: (() -> Void)?

    var body: some View {
        TransferCenterContent(state: state, activity: state.transferActivity,
                              maximumSize: maximumSize, onClose: onClose)
    }
}

private struct TransferCenterContent: View {
    let state: AppState
    @ObservedObject var activity: FileTransferActivityModel
    let maximumSize: CGSize
    let onClose: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @State private var bucket = FileTransferBucket.all

    private var visibleTransfers: [FileTransferRecord] {
        activity.records.filter { $0.belongs(to: bucket) }
    }
    // An opaque surface keeps remote pixels and window focus from washing out text.
    private var surface: Color { Color(white: colorScheme == .dark ? 0.13 : 0.97) }
    private var card: Color { Color(white: colorScheme == .dark ? 0.18 : 1) }
    private var primary: Color { Color(white: colorScheme == .dark ? 0.95 : 0.12) }
    private var secondary: Color { Color(white: colorScheme == .dark ? 0.68 : 0.40) }
    private var listHeight: CGFloat { min(440, max(180, CGFloat(visibleTransfers.count) * 140 + 24)) }
    private var localizationBundle: Bundle {
        AppResourceLocator.localizedBundle(for: locale.language.languageCode?.identifier == "zh" ? "zh-Hans" : "en")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                header.layoutPriority(1)
                filters.layoutPriority(1)
                Divider()
                if visibleTransfers.isEmpty {
                    emptyState.frame(maxWidth: .infinity)
                        .frame(minHeight: 0, idealHeight: listHeight, maxHeight: listHeight)
                        .clipped()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(visibleTransfers) { record in row(record, now: context.date) }
                        }
                        .padding(12)
                    }
                    .frame(minHeight: 0, idealHeight: listHeight, maxHeight: listHeight)
                }
                Divider()
                footer(now: context.date).layoutPriority(1)
            }
            .frame(width: min(560, max(0, maximumSize.width)))
            .frame(maxHeight: max(0, maximumSize.height))
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(primary)
            .background(surface)
        }
        .accessibilityLabel("Transfer Center")
        .accessibilityIdentifier("file-transfer-center")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.title3.weight(.semibold)).foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text("File Transfers", bundle: localizationBundle).font(.headline)
                Text("SFTP · Remote Desktop", bundle: localizationBundle).font(.caption).foregroundStyle(secondary)
            }
            Spacer()
            Button { state.clearFinishedFileTransfers() } label: {
                Text("Clear Finished", bundle: localizationBundle)
            }
                .buttonStyle(.borderless).font(.caption)
                .disabled(!activity.records.contains { !$0.isUnfinished })
                .opacity(activity.records.contains { !$0.isUnfinished } ? 1 : 0.45)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Close").accessibilityLabel("Close")
                .accessibilityIdentifier("close-transfer-center")
            }
        }
        .padding(16)
    }

    private var filters: some View {
        HStack(spacing: 4) {
            ForEach(FileTransferBucket.allCases) { item in
                Button { bucket = item } label: {
                    VStack(spacing: 4) {
                        Text(item.title, bundle: localizationBundle).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(verbatim: "\(activity.records.filter { $0.belongs(to: item) }.count)")
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    }
                    .foregroundStyle(bucket == item ? Color.white : secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(bucket == item ? Color.accentColor : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityValue("\(activity.records.filter { $0.belongs(to: item) }.count)")
                .accessibilityAddTraits(bucket == item ? .isSelected : [])
                .accessibilityIdentifier("transfer-filter-\(item.rawValue)")
            }
        }
        .padding(4)
        .background(primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: activity.records.isEmpty ? "tray" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 28, weight: .light)).foregroundStyle(secondary)
            Text(activity.records.isEmpty ? "No Transfers" : "No Matching Transfers", bundle: localizationBundle)
                .font(.headline)
            Text(activity.records.isEmpty
                 ? "SFTP and remote desktop file transfers appear here."
                 : "There are no transfers in this category.", bundle: localizationBundle)
                .font(.caption).foregroundStyle(secondary)
            if !activity.records.isEmpty {
                Button { bucket = .all } label: {
                    Text("Show All Transfers", bundle: localizationBundle)
                }.buttonStyle(.borderless)
            }
        }
        .padding(20)
        .multilineTextAlignment(.center)
    }

    private func footer(now: Date) -> some View {
        HStack(spacing: 6) {
            Circle().fill(activity.records.contains { $0.status == .running } ? Color.accentColor : secondary)
                .frame(width: 6, height: 6)
            Text("In Progress", bundle: localizationBundle).font(.caption)
            Text(verbatim: "\(activity.unfinishedCount)").font(.caption.weight(.semibold)).monospacedDigit()
            Spacer()
            Label(rate(activity.bytesPerSecond(for: .upload, at: now)), systemImage: "arrow.up")
                .help("Upload")
            Label(rate(activity.bytesPerSecond(for: .download, at: now)), systemImage: "arrow.down")
                .padding(.leading, 10).help("Download")
        }
        .font(.caption).foregroundStyle(secondary).monospacedDigit()
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityIdentifier("file-transfer-summary")
    }

    private func row(_ record: FileTransferRecord, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: record.kind == .upload ? "arrow.up.doc" : "arrow.down.doc")
                    .foregroundStyle(Color.accentColor)
                Text(verbatim: record.name).font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).help(record.name)
                Spacer(minLength: 4)
                controls(record)
            }
            HStack(spacing: 6) {
                Text(verbatim: record.protocolName)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                Text(record.kind == .upload ? "Upload" : "Download", bundle: localizationBundle)
                if let connection = record.connectionName, !connection.isEmpty {
                    Text(verbatim: "· \(connection)").lineLimit(1).truncationMode(.middle).help(connection)
                }
                Spacer(minLength: 4)
                Text(record.statusTitle, bundle: localizationBundle).foregroundStyle(statusColor(record.status)).lineLimit(1)
            }
            .font(.caption2).foregroundStyle(secondary)
            if let progress = record.progressFraction {
                ProgressView(value: progress).tint(statusColor(record.status))
            } else if record.status == .running {
                ProgressView().progressViewStyle(.linear).tint(Color.accentColor)
            } else if record.isUnfinished {
                ProgressView(value: 0).tint(secondary)
            }
            HStack(spacing: 6) {
                Text(verbatim: record.totalBytes.map { "\(bytes(record.bytesTransferred)) / \(bytes($0))" }
                     ?? bytes(record.bytesTransferred))
                if let progress = record.progressFraction {
                    Text(verbatim: "· \(Int(progress * 100))%")
                }
                Spacer(minLength: 4)
                if record.status == .running {
                    Text(verbatim: rate(record.currentBytesPerSecond(at: now))).help("File data rate")
                }
            }
            .font(.caption2).foregroundStyle(secondary).monospacedDigit()
            if let message = record.statusMessage {
                Text(verbatim: message).font(.caption2).foregroundStyle(statusColor(record.status))
                    .lineLimit(2).help(message).textSelection(.enabled)
            }
        }
        .padding(12)
        .background(card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(primary.opacity(0.06)))
        .help([record.sourcePath, record.destinationPath].filter { !$0.isEmpty }.joined(separator: " → "))
        .accessibilityIdentifier("file-transfer-\(record.id)")
    }

    @ViewBuilder
    private func controls(_ record: FileTransferRecord) -> some View {
        if record.status == .paused {
            control("play.fill", "Resume Transfer", record, .resume)
        } else if record.status == .running && record.supportsPause {
            control("pause.fill", "Pause Transfer", record, .pause)
        } else if record.canRetry && record.protocolName == "SFTP" {
            control("arrow.clockwise", "Retry Transfer", record, .retry)
        }
        if record.isUnfinished {
            control("xmark", "Cancel Transfer", record, .cancel)
        }
    }

    private func control(_ symbol: String, _ title: String, _ record: FileTransferRecord, _ action: FileTransferAction) -> some View {
        Button { state.controlFileTransfer(record.id, action: action) } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26).contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.borderless).foregroundStyle(primary)
        .background(primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .help(LocalizedStringKey(title)).accessibilityLabel(LocalizedStringKey(title))
    }

    private func statusColor(_ status: FileTransferStatus) -> Color {
        switch status {
        case .running: .accentColor
        case .succeeded: colorScheme == .dark ? .green : Color(red: 0.12, green: 0.45, blue: 0.23)
        case .failed: colorScheme == .dark ? Color(red: 1, green: 0.5, blue: 0.5) : .red
        case .paused, .attention: colorScheme == .dark ? .orange : Color(red: 0.55, green: 0.29, blue: 0)
        case .queued, .cancelled: secondary
        }
    }

    private func rate(_ value: Double) -> String { String(format: "%.2f MiB/s", value / 1_048_576) }
    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}
