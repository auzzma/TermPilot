import SwiftUI

struct DockerContainerManagementRow: View {
    let container: DockerContainerRow
    let selected: Bool
    let pendingAction: DockerContainerAction?
    var onSelect: () -> Void
    var onShell: () -> Void
    var onLogs: () -> Void
    var onAction: (DockerContainerAction) -> Void

    var body: some View {
        HStack(spacing: 9) {
            DockerIconTile()
            VStack(alignment: .leading, spacing: 3) {
                Text(container.name.isEmpty
                    ? String(container.id.prefix(12))
                    : container.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(container.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 48, maxWidth: .infinity, alignment: .leading)

            DockerStatusBadge(container: container)

            HStack(spacing: 4) {
                if container.isRunning {
                    DockerRoundActionButton(
                        systemImage: "terminal",
                        title: "Shell",
                        action: onShell
                    )
                }
                DockerRoundActionButton(
                    systemImage: "doc.text",
                    title: "Logs",
                    action: onLogs
                )
                if container.isRunning {
                    DockerRoundActionButton(
                        systemImage: "arrow.counterclockwise",
                        title: "Restart",
                        disabled: pendingAction != nil,
                        loading: pendingAction == .restart
                    ) {
                        onAction(.restart)
                    }
                    DockerRoundActionButton(
                        systemImage: "stop",
                        title: "Stop",
                        disabled: pendingAction != nil,
                        loading: pendingAction == .stop
                    ) {
                        onAction(.stop)
                    }
                } else if container.isPaused {
                    DockerRoundActionButton(
                        systemImage: "play",
                        title: "Resume",
                        disabled: pendingAction != nil,
                        loading: pendingAction == .unpause
                    ) {
                        onAction(.unpause)
                    }
                } else {
                    DockerRoundActionButton(
                        systemImage: "play",
                        title: "Start",
                        disabled: pendingAction != nil,
                        loading: pendingAction == .start
                    ) {
                        onAction(.start)
                    }
                }
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
}

struct DockerContainerDetailView: View {
    let container: DockerContainerRow
    let inspect: DockerInspectDetails?
    let inspectLoading: Bool
    let pendingAction: DockerContainerAction?
    var onRename: () -> Void
    var onAction: (DockerContainerAction) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !container.ports.isEmpty {
                Text(container.ports)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 5) {
                DockerActionChip(
                    title: "Rename",
                    systemImage: "pencil",
                    disabled: pendingAction != nil,
                    action: onRename
                )
                if container.isRunning {
                    DockerActionChip(
                        title: "Pause",
                        systemImage: "pause",
                        disabled: pendingAction != nil
                    ) {
                        onAction(.pause)
                    }
                } else if container.isPaused {
                    DockerActionChip(
                        title: "Resume",
                        systemImage: "play",
                        disabled: pendingAction != nil
                    ) {
                        onAction(.unpause)
                    }
                }
                if container.isRunning || container.isPaused {
                    DockerActionChip(
                        title: "Kill",
                        systemImage: "bolt.fill",
                        role: .destructive,
                        disabled: pendingAction != nil
                    ) {
                        onAction(.kill)
                    }
                }
                DockerActionChip(
                    title: "Remove",
                    systemImage: "trash",
                    role: .destructive,
                    disabled: pendingAction != nil
                ) {
                    onAction(.remove)
                }
                if pendingAction != nil {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.leading, 2)
                }
            }

            if inspectLoading, inspect == nil {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading Details")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let inspect {
                DockerInspectPanel(
                    details: inspect,
                    onClose: onClose
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.secondary.opacity(0.06))
    }
}

struct DockerImageManagementRow: View {
    let image: DockerImageRow
    let selected: Bool
    let busy: Bool
    var onSelect: () -> Void
    var onTag: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            DockerIconTile()
            VStack(alignment: .leading, spacing: 3) {
                Text(image.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(
                    [
                        String(image.imageID.prefix(12)),
                        image.size,
                        image.createdAt,
                    ]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(minWidth: 48, maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                DockerRoundActionButton(
                    systemImage: "tag",
                    title: "Tag",
                    disabled: busy,
                    action: onTag
                )
                DockerRoundActionButton(
                    systemImage: "trash",
                    title: "Remove",
                    role: .destructive,
                    disabled: busy,
                    action: onRemove
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
}

struct DockerImageDetailView: View {
    let inspect: DockerInspectDetails?
    let loading: Bool
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if loading, inspect == nil {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading Details")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let inspect {
                DockerInspectPanel(
                    details: inspect,
                    onClose: onClose
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.secondary.opacity(0.06))
    }
}

struct DockerInspectPanel: View {
    let details: DockerInspectDetails
    var onClose: () -> Void
    @State private var showsRawJSON = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(details.kind == .container
                    ? "Container Inspect"
                    : "Image Inspect")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(showsRawJSON ? "Details" : "JSON") {
                    showsRawJSON.toggle()
                }
                Button("Close", action: onClose)
            }
            .buttonStyle(.borderless)
            .font(.caption2)

            if showsRawJSON {
                ScrollView([.horizontal, .vertical]) {
                    Text(details.rawJSON)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(details.fields) { field in
                        HStack(alignment: .top, spacing: 8) {
                            Text(LocalizedStringKey(field.label))
                                .foregroundStyle(.secondary)
                                .frame(width: 92, alignment: .leading)
                            Text(field.value)
                                .font(
                                    field.monospaced
                                        ? .caption2.monospaced()
                                        : .caption2
                                )
                                .textSelection(.enabled)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .leading
                                )
                        }
                    }
                    ForEach(details.lists) { list in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(LocalizedStringKey(list.label))
                                .foregroundStyle(.secondary)
                            ForEach(
                                Array(list.values.enumerated()),
                                id: \.offset
                            ) { _, value in
                                Text(value)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    )
                            }
                        }
                    }
                }
                .font(.caption2)
            }
        }
    }
}

struct DockerConfirmationSheet: View {
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

struct DockerRenameSheet: View {
    let initialName: String
    var onCancel: () -> Void
    var onSave: (String) -> Void
    @State private var name: String

    init(
        initialName: String,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.initialName = initialName
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Container")
                .font(.headline)
            HStack {
                Text("Container Name")
                    .frame(width: 110, alignment: .leading)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    onSave(name)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

struct DockerTagSheet: View {
    let image: DockerImageRow
    var onCancel: () -> Void
    var onSave: (String, String) -> Void
    @State private var repository: String
    @State private var tag: String

    init(
        image: DockerImageRow,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, String) -> Void
    ) {
        self.image = image
        self.onCancel = onCancel
        self.onSave = onSave
        _repository = State(
            initialValue: image.repository == "<none>"
                ? ""
                : image.repository
        )
        _tag = State(
            initialValue: image.tag == "<none>" || image.tag.isEmpty
                ? "latest"
                : image.tag
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tag Image")
                .font(.headline)
            HStack {
                Text("Repository")
                    .frame(width: 90, alignment: .leading)
                TextField("", text: $repository)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            }
            HStack {
                Text("Tag Name")
                    .frame(width: 90, alignment: .leading)
                TextField("", text: $tag)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Tag") {
                    onSave(repository, tag)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    repository.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

private struct DockerIconTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.blue)
            .frame(width: 38, height: 38)
            .overlay {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

private struct DockerStatusBadge: View {
    let container: DockerContainerRow

    private var title: LocalizedStringKey {
        if container.isRunning {
            return "System Filter Running"
        }
        if container.isPaused {
            return "System Filter Paused"
        }
        return "System Filter Stopped"
    }

    private var color: Color {
        if container.isRunning {
            return .green
        }
        if container.isPaused {
            return .orange
        }
        return .secondary
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .foregroundStyle(container.isRunning ? .black : .white)
            .background(color, in: Capsule())
    }
}

private struct DockerRoundActionButton: View {
    let systemImage: String
    let title: LocalizedStringKey
    var role: ButtonRole?
    var disabled = false
    var loading = false
    var action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Group {
                if loading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: systemImage)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 28, height: 28)
            .background(
                Color.secondary.opacity(0.13),
                in: Circle()
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled || loading)
        .help(title)
        .accessibilityLabel(Text(title))
    }
}

private struct DockerActionChip: View {
    let title: LocalizedStringKey
    let systemImage: String
    var role: ButtonRole?
    var disabled = false
    var action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(
                    Color.secondary.opacity(0.1),
                    in: RoundedRectangle(
                        cornerRadius: 6,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
