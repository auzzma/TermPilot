import AppKit
import SwiftUI
import TermPilotDomain
import TermPilotRemote

struct CredentialDeleteConfirmationView: View {
    let credential: SSHCredential
    let affectedHosts: [TermPilotDomain.Host]
    let onCancel: () -> Void
    let onDelete: () async -> Bool
    @State private var isDeleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Delete Credential")
                        .font(.title3.weight(.semibold))
                    Text(credential.label)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(
                String(
                    format: AppLocalization.string(
                        "Deleting this credential will remove it from %lld saved hosts. Those hosts may require new login credentials."
                    ),
                    Int64(affectedHosts.count)
                )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !affectedHosts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Affected Hosts")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(affectedHosts) { host in
                                HStack(spacing: 12) {
                                    Image(systemName: "externaldrive")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(host.label)
                                            .font(.headline)
                                            .lineLimit(1)
                                        Text(
                                            "\(host.username)@\(host.hostname):\(host.port)"
                                        )
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 10)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 190)
                }
            }

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isDeleting)
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    isDeleting = true
                    Task {
                        if !(await onDelete()) {
                            isDeleting = false
                        }
                    }
                } label: {
                    Group {
                        if isDeleting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Delete")
                        }
                    }
                    .frame(minWidth: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(isDeleting)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(
            Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.3))
        )
        .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
    }
}

struct CredentialCreationEditor: View {
    @EnvironmentObject private var state: AppState
    @State private var label = ""
    @State private var username = ""
    @State private var keyType = SSHKeyType.ed25519
    @State private var ecdsaBits = 256
    @State private var rsaBits = 4_096
    @State private var protectsKey = false
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var isGenerating = false
    @State private var message: String?
    @State private var succeeded = false
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    textField(
                        title: "Label *",
                        placeholder: "Credential label",
                        text: $label
                    )
                    textField(
                        title: "Username *",
                        placeholder: "Username",
                        text: $username
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Key Type")
                            .font(.caption.weight(.semibold))
                        Picker("Key Type", selection: $keyType) {
                            Text("ED25519").tag(SSHKeyType.ed25519)
                            Text("ECDSA").tag(SSHKeyType.ecdsa)
                            Text("RSA").tag(SSHKeyType.rsa)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    if keyType == .ecdsa {
                        keyStrengthPicker(
                            title: "Curve",
                            selection: $ecdsaBits,
                            options: [
                                (256, "P-256"),
                                (384, "P-384"),
                                (521, "P-521"),
                            ]
                        )
                    } else if keyType == .rsa {
                        keyStrengthPicker(
                            title: "Key Size",
                            selection: $rsaBits,
                            options: [
                                (4_096, "4096 bits"),
                                (2_048, "2048 bits"),
                                (1_024, "1024 bits"),
                            ]
                        )
                    }
                    Toggle(
                        "Protect with passphrase",
                        isOn: $protectsKey
                    )
                    if protectsKey {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Passphrase")
                                .font(.caption.weight(.semibold))
                            RevealablePasswordField(
                                AppLocalization.string("Passphrase"),
                                text: $passphrase
                            )
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Confirm Passphrase")
                                .font(.caption.weight(.semibold))
                            RevealablePasswordField(
                                AppLocalization.string("Confirm Passphrase"),
                                text: $confirmPassphrase
                            )
                        }
                    }
                    if let message {
                        Label(
                            message,
                            systemImage: succeeded
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(succeeded ? Color.green : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Divider()
            footer
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Create Credential")
                    .font(.title2.weight(.semibold))
                Text("Generate a new SSH key pair.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Spacer()
            if succeeded {
                Button("Done", action: onCancel)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Cancel", action: onCancel)
                    .disabled(isGenerating)
                Button {
                    Task { await createCredential() }
                } label: {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isGenerating ? "Generating..." : "Create Credential")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating)
            }
        }
        .padding(12)
    }

    private func textField(
        title: LocalizedStringKey,
        placeholder: LocalizedStringKey,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            TextField(placeholder, text: text)
        }
    }

    private func keyStrengthPicker(
        title: LocalizedStringKey,
        selection: Binding<Int>,
        options: [(Int, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            Picker(title, selection: selection) {
                ForEach(options, id: \.0) { value, title in
                    Text(verbatim: title).tag(value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @MainActor
    private func createCredential() async {
        if protectsKey, passphrase.isEmpty {
            message = AppLocalization.string(
                "Enter a passphrase or turn off passphrase protection."
            )
            succeeded = false
            return
        }
        if protectsKey, passphrase != confirmPassphrase {
            message = AppLocalization.string("Passphrases do not match.")
            succeeded = false
            return
        }
        isGenerating = true
        message = nil
        do {
            _ = try await state.createGeneratedCredential(
                label: label,
                username: username,
                request: SSHKeyGenerationRequest(
                    keyType: keyType,
                    bits: keyType == .ecdsa
                        ? ecdsaBits
                        : keyType == .rsa ? rsaBits : nil,
                    passphrase: protectsKey ? passphrase : nil,
                    comment: label
                )
            )
            succeeded = true
            message = AppLocalization.string(
                "Credential created successfully."
            )
        } catch {
            succeeded = false
            message = AppLocalization.errorDescription(error)
        }
        isGenerating = false
    }
}

private enum CredentialHostExportStatus: Equatable {
    case working
    case success
    case failure(String)
}

private struct CredentialExportTreeItem: Identifiable {
    enum Kind {
        case group(HostGroup, hostIDs: Set<UUID>, canExpand: Bool)
        case ungrouped(hostIDs: Set<UUID>)
        case host(TermPilotDomain.Host)
    }

    var id: String
    var depth: Int
    var kind: Kind
}

struct CredentialExportEditor: View {
    @EnvironmentObject private var state: AppState
    let credential: SSHCredential
    let onCancel: () -> Void
    @State private var selectedHostIDs = Set<UUID>()
    @State private var expandedGroupIDs = Set<UUID>()
    @State private var isUngroupedExpanded = false
    @State private var statuses: [UUID: CredentialHostExportStatus] = [:]
    @State private var isExporting = false
    @State private var summary: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    selectionActions
                    if state.hosts.isEmpty {
                        Text("No saved hosts.")
                            .foregroundStyle(.secondary)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .padding(12)
                            .background(Color.secondary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        LazyVStack(spacing: 6) {
                            ForEach(treeItems) { item in
                                treeRow(item)
                            }
                        }
                    }
                    if let summary {
                        Label(
                            summary,
                            systemImage: statuses.values.contains {
                                if case .failure = $0 {
                                    true
                                } else {
                                    false
                                }
                            } ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            statuses.values.contains {
                                if case .failure = $0 {
                                    true
                                } else {
                                    false
                                }
                            } ? Color.orange : Color.green
                        )
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up.on.square")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Export to Hosts")
                    .font(.title2.weight(.semibold))
                Text(credential.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .disabled(isExporting)
        }
        .padding(16)
    }

    private var selectionActions: some View {
        HStack(spacing: 8) {
            Button("Select All") {
                selectedHostIDs = Set(state.hosts.map(\.id))
            }
            .disabled(isExporting || state.hosts.isEmpty)
            Button("Clear") {
                selectedHostIDs.removeAll()
            }
            .disabled(isExporting || selectedHostIDs.isEmpty)
            Spacer()
            Text(
                AppLocalization.string("{count} selected")
                    .replacingOccurrences(
                        of: "{count}",
                        with: String(selectedHostIDs.count)
                    )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var treeItems: [CredentialExportTreeItem] {
        var items: [CredentialExportTreeItem] = []

        func append(_ node: HostGroupNode, depth: Int) {
            let hostIDs = HostGroupHierarchy.hostIDs(
                includingDescendantsOf: node.group.id,
                groups: state.groups,
                hosts: state.hosts
            )
            let directHosts = state.hosts.filter {
                $0.groupID == node.group.id
            }
            items.append(
                CredentialExportTreeItem(
                    id: "group:\(node.group.id.uuidString)",
                    depth: depth,
                    kind: .group(
                        node.group,
                        hostIDs: hostIDs,
                        canExpand: !directHosts.isEmpty || !node.children.isEmpty
                    )
                )
            )
            guard expandedGroupIDs.contains(node.group.id) else {
                return
            }
            items.append(
                contentsOf: directHosts.map {
                    CredentialExportTreeItem(
                        id: "host:\($0.id.uuidString)",
                        depth: depth + 1,
                        kind: .host($0)
                    )
                }
            )
            for child in node.children {
                append(child, depth: depth + 1)
            }
        }

        for root in HostGroupHierarchy.roots(from: state.groups) {
            append(root, depth: 0)
        }

        let validGroupIDs = Set(state.groups.map(\.id))
        let ungroupedHosts = state.hosts.filter {
            guard let groupID = $0.groupID else {
                return true
            }
            return !validGroupIDs.contains(groupID)
        }
        if !ungroupedHosts.isEmpty {
            let hostIDs = Set(ungroupedHosts.map(\.id))
            items.append(
                CredentialExportTreeItem(
                    id: "group:ungrouped",
                    depth: 0,
                    kind: .ungrouped(hostIDs: hostIDs)
                )
            )
            if isUngroupedExpanded {
                items.append(
                    contentsOf: ungroupedHosts.map {
                        CredentialExportTreeItem(
                            id: "host:\($0.id.uuidString)",
                            depth: 1,
                            kind: .host($0)
                        )
                    }
                )
            }
        }
        return items
    }

    @ViewBuilder
    private func treeRow(_ item: CredentialExportTreeItem) -> some View {
        switch item.kind {
        case .group(let group, let hostIDs, let canExpand):
            groupRow(
                title: group.name,
                hostIDs: hostIDs,
                depth: item.depth,
                expanded: expandedGroupIDs.contains(group.id),
                canExpand: canExpand
            ) {
                if expandedGroupIDs.contains(group.id) {
                    expandedGroupIDs.remove(group.id)
                } else {
                    expandedGroupIDs.insert(group.id)
                }
            }
        case .ungrouped(let hostIDs):
            groupRow(
                title: AppLocalization.string("No Group"),
                hostIDs: hostIDs,
                depth: item.depth,
                expanded: isUngroupedExpanded,
                canExpand: true
            ) {
                isUngroupedExpanded.toggle()
            }
        case .host(let host):
            hostRow(host, depth: item.depth)
        }
    }

    private func groupRow(
        title: String,
        hostIDs: Set<UUID>,
        depth: Int,
        expanded: Bool,
        canExpand: Bool,
        toggleExpanded: @escaping () -> Void
    ) -> some View {
        let selectionState = HostGroupHierarchy.selectionState(
            hostIDs: hostIDs,
            selectedHostIDs: selectedHostIDs
        )
        return HStack(spacing: 8) {
            Button(action: toggleExpanded) {
                Image(
                    systemName: expanded
                        ? "chevron.down"
                        : "chevron.right"
                )
                .font(.caption.weight(.semibold))
                .frame(width: 14, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)
            .opacity(canExpand ? 1 : 0)
            .accessibilityLabel(Text(expanded ? "Collapse" : "Expand"))
            Button {
                toggleSelection(hostIDs)
            } label: {
                Image(systemName: selectionState.systemImage)
                    .foregroundStyle(
                        selectionState == .none
                            ? Color.secondary
                            : Color.accentColor
                    )
            }
            .buttonStyle(.plain)
            .disabled(isExporting || hostIDs.isEmpty)
            .accessibilityLabel(
                Text(
                    selectionState == .all
                        ? "Deselect Group Hosts"
                        : "Select Group Hosts"
                )
            )
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text("\(hostIDs.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 8 + CGFloat(depth) * 18)
        .padding(.trailing, 10)
        .frame(minHeight: 38)
        .background(
            selectionState == .none
                ? Color.secondary.opacity(0.07)
                : Color.accentColor.opacity(0.1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func toggleSelection(_ hostIDs: Set<UUID>) {
        let selectsAll = hostIDs.contains {
            !selectedHostIDs.contains($0)
        }
        if selectsAll {
            selectedHostIDs.formUnion(hostIDs)
        } else {
            selectedHostIDs.subtract(hostIDs)
        }
    }

    private func hostRow(
        _ host: TermPilotDomain.Host,
        depth: Int
    ) -> some View {
        HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { selectedHostIDs.contains(host.id) },
                    set: { selected in
                        if selected {
                            selectedHostIDs.insert(host.id)
                        } else {
                            selectedHostIDs.remove(host.id)
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(isExporting)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(host.username)@\(host.hostname):\(host.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if case .failure(let message) = statuses[host.id] {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            statusView(statuses[host.id])
        }
        .padding(.vertical, 10)
        .padding(.leading, 10 + CGFloat(depth) * 18)
        .padding(.trailing, 10)
        .background(
            selectedHostIDs.contains(host.id)
                ? Color.accentColor.opacity(0.1)
                : Color.secondary.opacity(0.06)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func statusView(_ status: CredentialHostExportStatus?) -> some View {
        switch status {
        case .working:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close", action: onCancel)
                .disabled(isExporting)
            Button {
                Task { await exportSelectedHosts() }
            } label: {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(isExporting ? "Exporting..." : "Export")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isExporting || selectedHostIDs.isEmpty)
        }
        .padding(12)
    }

    @MainActor
    private func exportSelectedHosts() async {
        guard !selectedHostIDs.isEmpty else {
            return
        }
        isExporting = true
        summary = nil
        var succeeded = 0
        var failed = 0
        let selectedHosts = state.hosts.filter {
            selectedHostIDs.contains($0.id)
        }
        for host in selectedHosts {
            statuses[host.id] = .working
            do {
                try await state.exportCredential(credential, to: host)
                statuses[host.id] = .success
                succeeded += 1
            } catch {
                statuses[host.id] = .failure(
                    AppLocalization.errorDescription(error)
                )
                failed += 1
            }
        }
        if failed == 0 {
            summary = AppLocalization.string(
                "Public key exported to {count} hosts."
            )
            .replacingOccurrences(of: "{count}", with: String(succeeded))
        } else {
            summary = AppLocalization.string(
                "{succeeded} hosts succeeded; {failed} hosts failed."
            )
            .replacingOccurrences(
                of: "{succeeded}",
                with: String(succeeded)
            )
            .replacingOccurrences(of: "{failed}", with: String(failed))
        }
        isExporting = false
    }
}

extension SSHCredential {
    var hasCompleteKeyPair: Bool {
        kind == .identityKey
            && privateKey?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty == false
            && publicKey?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty == false
    }
}
