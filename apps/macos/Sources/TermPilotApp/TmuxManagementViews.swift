import SwiftUI

struct TmuxSessionManagementRow: View {
    let session: TmuxSessionRow
    let selected: Bool
    let busy: Bool
    var onSelect: () -> Void
    var onAttach: () -> Void
    var onRename: () -> Void
    var onKill: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            TmuxIconTile(attached: session.attached)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 48, maxWidth: .infinity, alignment: .leading)

            TmuxAttachedBadge(attached: session.attached)

            HStack(spacing: 4) {
                TmuxRoundActionButton(
                    systemImage: "arrow.right.circle",
                    title: "Attach in New Tab",
                    disabled: busy,
                    action: onAttach
                )
                TmuxRoundActionButton(
                    systemImage: "pencil",
                    title: "Rename",
                    disabled: busy,
                    action: onRename
                )
                TmuxRoundActionButton(
                    systemImage: "trash",
                    title: "Kill",
                    role: .destructive,
                    disabled: busy,
                    action: onKill
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            selected
                ? Color.accentColor.opacity(0.22)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var detail: String {
        var parts = [
            String(
                format: AppLocalization.string("%@ windows"),
                String(session.windows)
            ),
        ]
        if let created = session.created {
            parts.append(Self.formatter.string(from: created))
        }
        return parts.joined(separator: " · ")
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

struct TmuxSessionDetailView: View {
    let windows: [TmuxWindowRow]
    let windowsLoading: Bool
    let preview: String?
    let previewLoading: Bool
    let busy: Bool
    var onAttachWindow: (TmuxWindowRow) -> Void
    var onSendKeys: (String) -> Void
    var onRefreshPreview: () -> Void
    var onClose: () -> Void
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Windows")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Close", action: onClose)
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }

            if windowsLoading, windows.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading Windows")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if windows.isEmpty {
                Text("No windows in this session.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(windows) { window in
                        TmuxWindowManagementRow(
                            window: window,
                            busy: busy,
                            onAttach: { onAttachWindow(window) }
                        )
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Send Command")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 6) {
                    TextField(
                        AppLocalization.string("Command to send..."),
                        text: $command
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .onSubmit(send)
                    Button("Send", action: send)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(
                            busy
                                || command.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty
                        )
                }
                Text("Runs in the session's active window without attaching.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Pane Preview")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button(action: onRefreshPreview) {
                        if previewLoading {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .disabled(previewLoading)
                    .accessibilityLabel("Refresh")
                }
                if let preview, !preview.isEmpty {
                    ScrollView([.horizontal, .vertical]) {
                        Text(preview)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                } else if !previewLoading {
                    Text("No preview captured yet.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.secondary.opacity(0.06))
    }

    private func send() {
        let trimmed = command.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            return
        }
        onSendKeys(trimmed)
        command = ""
    }
}

struct TmuxWindowManagementRow: View {
    let window: TmuxWindowRow
    let busy: Bool
    var onAttach: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(window.index)")
                .font(.caption2.monospaced().weight(.semibold))
                .frame(minWidth: 18)
                .foregroundStyle(.secondary)
            Text(window.name.isEmpty
                ? AppLocalization.string("Window")
                : window.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            if window.active {
                Text("Active")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: Capsule())
            }
            Spacer(minLength: 6)
            Text(
                String(
                    format: AppLocalization.string("%@ panes"),
                    String(window.panes)
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            Button(action: onAttach) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help("Attach in New Tab")
            .accessibilityLabel("Attach in New Tab")
        }
        .padding(.vertical, 5)
    }
}

struct TmuxNameSheet: View {
    let title: LocalizedStringKey
    let fieldTitle: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    let initialName: String
    var onCancel: () -> Void
    var onSave: (String) -> Void
    @State private var name: String

    init(
        title: LocalizedStringKey,
        fieldTitle: LocalizedStringKey,
        confirmTitle: LocalizedStringKey,
        initialName: String,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.fieldTitle = fieldTitle
        self.confirmTitle = confirmTitle
        self.initialName = initialName
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            HStack {
                Text(fieldTitle)
                    .frame(width: 110, alignment: .leading)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    onSave(name)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

struct TmuxConfirmationSheet: View {
    let title: LocalizedStringKey
    let message: String
    let confirmTitle: LocalizedStringKey
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.headline)
            }
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive, action: onConfirm) {
                    Text(confirmTitle)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 380)
    }
}

private struct TmuxIconTile: View {
    let attached: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(attached ? Color.green : Color.secondary)
            .frame(width: 38, height: 38)
            .overlay {
                Image(systemName: "rectangle.split.2x2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

private struct TmuxAttachedBadge: View {
    let attached: Bool

    var body: some View {
        Text(attached ? "Attached" : "Detached")
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .foregroundStyle(attached ? .black : .white)
            .background(attached ? Color.green : Color.secondary, in: Capsule())
    }
}

private struct TmuxRoundActionButton: View {
    let systemImage: String
    let title: LocalizedStringKey
    var role: ButtonRole?
    var disabled = false
    var action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(
                    Color.secondary.opacity(0.13),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(title)
        .accessibilityLabel(Text(title))
    }
}
