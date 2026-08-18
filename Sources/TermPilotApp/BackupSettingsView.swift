import AppKit
import SwiftUI
import TermPilotPersistence
import UniformTypeIdentifiers

struct BackupSettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var operation: BackupOperation?
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section("Encrypted Backup") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Full Data Backup",
                        systemImage: "lock.shield"
                    )
                    .font(.headline)
                    Text(
                        "Backups include hosts, groups, credentials, proxies, port forwards, scripts, and notes. Known hosts are excluded."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                HStack(spacing: 12) {
                    Button {
                        chooseExportDestination()
                    } label: {
                        Label(
                            "Export Backup",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        chooseImportSource()
                    } label: {
                        Label(
                            "Import Backup",
                            systemImage: "square.and.arrow.down"
                        )
                    }
                    .buttonStyle(.bordered)
                }

                Text(
                    "Import merges with existing data. Hosts are deduplicated by normalized IP address or hostname."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let statusMessage {
                Section("Last Result") {
                    Label(
                        statusMessage,
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $operation) { operation in
            BackupPasswordSheet(
                operation: operation
            ) { message in
                statusMessage = message
                self.operation = nil
            } onCancel: {
                self.operation = nil
            }
            .environmentObject(state)
        }
    }

    private func chooseExportDestination() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [backupContentType]
        panel.nameFieldStringValue =
            "TermPilot-\(backupDateString()).\(EncryptedBackupCodec.fileExtension)"
        panel.title = AppLocalization.string("Export Backup")
        guard panel.runModal() == .OK,
              let url = panel.url
        else {
            return
        }
        statusMessage = nil
        operation = .export(url)
    }

    private func chooseImportSource() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [backupContentType]
        panel.title = AppLocalization.string("Import Backup")
        guard panel.runModal() == .OK,
              let url = panel.url
        else {
            return
        }
        statusMessage = nil
        operation = .restore(url)
    }

    private func backupDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

private struct BackupPasswordSheet: View {
    @EnvironmentObject private var state: AppState
    let operation: BackupOperation
    let onComplete: (String) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(operation.title)
                        .font(.title3.weight(.semibold))
                    Text(operation.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SecureField("Backup Password", text: $password)
                .textFieldStyle(.roundedBorder)
            if operation.requiresConfirmation {
                SecureField(
                    "Confirm Backup Password",
                    text: $confirmation
                )
                .textFieldStyle(.roundedBorder)
            }
            Text("Use at least 8 characters. The password cannot be recovered.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .disabled(isWorking)
                Button(operation.actionTitle) {
                    performOperation()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || isWorking)
            }
        }
        .padding(22)
        .frame(width: 440)
        .overlay {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .padding(12)
                    .background(.regularMaterial)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 10)
                    )
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    private var canSubmit: Bool {
        password.count >= 8
            && (!operation.requiresConfirmation
                || password == confirmation)
    }

    private func performOperation() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let message: String
                switch operation {
                case .export(let url):
                    try await state.exportEncryptedBackup(
                        to: url,
                        password: password
                    )
                    message = String(
                        format: AppLocalization.string(
                            "Backup exported to %@."
                        ),
                        url.lastPathComponent
                    )
                case .restore(let url):
                    let summary = try await state.importEncryptedBackup(
                        from: url,
                        password: password
                    )
                    message = String(
                        format: AppLocalization.string(
                            "Imported %@ hosts (%@ deduplicated), %@ groups, %@ credentials, %@ proxies, %@ port forwards, %@ scripts, and %@ notes."
                        ),
                        String(summary.hosts),
                        String(summary.deduplicatedHosts),
                        String(summary.groups),
                        String(summary.credentials),
                        String(summary.proxyProfiles),
                        String(summary.portForwardRules),
                        String(summary.automationScripts),
                        String(summary.hostNotes)
                    )
                }
                isWorking = false
                onComplete(message)
            } catch {
                isWorking = false
                errorMessage = AppLocalization.errorDescription(error)
            }
        }
    }
}

private enum BackupOperation: Identifiable {
    case export(URL)
    case restore(URL)

    var id: String {
        switch self {
        case .export(let url):
            "export:\(url.path)"
        case .restore(let url):
            "restore:\(url.path)"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .export:
            "Export Encrypted Backup"
        case .restore:
            "Import Encrypted Backup"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .export:
            "Set a password to encrypt this backup."
        case .restore:
            "Enter the password used when this backup was exported."
        }
    }

    var actionTitle: LocalizedStringKey {
        switch self {
        case .export:
            "Export"
        case .restore:
            "Import"
        }
    }

    var requiresConfirmation: Bool {
        switch self {
        case .export:
            true
        case .restore:
            false
        }
    }
}

private let backupContentType =
    UTType(
        filenameExtension: EncryptedBackupCodec.fileExtension,
        conformingTo: .data
    ) ?? .data
