import SwiftUI
import TermPilotPersistence
import TermPilotTerminal

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedTab = "general"

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                
                sidebarItem(id: "general", title: "General", icon: "gear")
                sidebarItem(id: "groups", title: "Groups", icon: "folder")
                sidebarItem(id: "known_hosts", title: "Known Hosts", icon: "checkmark.shield")
                sidebarItem(id: "backup", title: "Backup", icon: "externaldrive.badge.timemachine")
                Spacer()
            }
            .padding(.top, 12)
            .padding(.horizontal, 8)
            .frame(width: 180)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            VStack {
                switch selectedTab {
                case "general":
                    SettingsGeneralView()
                case "groups":
                    HostGroupManagerView().environmentObject(state)
                case "known_hosts":
                    KnownHostsSettingsView().environmentObject(state)
                case "backup":
                    BackupSettingsView().environmentObject(state)
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 760, height: 540)
    }

    private func sidebarItem(id: String, title: String, icon: String) -> some View {
        Button {
            selectedTab = id
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selectedTab == id ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                .foregroundStyle(selectedTab == id ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct SettingsGeneralView: View {
    @AppStorage(AppPreferences.appearance) private var appearance = "system"
    @AppStorage(AppPreferences.language)
    private var language = AppPreferences.defaultLanguage
    @AppStorage(AppPreferences.passwordPromptAssistMode)
    private var passwordPromptAssistMode =
        AppPreferences.defaultPasswordPromptAssistMode
    @AppStorage(AppPreferences.autoOpenSystemOverviewOnSSHConnect)
    private var autoOpensSystemOverviewOnSSHConnect =
        AppPreferences.defaultAutoOpenSystemOverviewOnSSHConnect
    @AppStorage(AppPreferences.autoAcceptSSHHostKeys)
    private var autoAcceptsSSHHostKeys =
        AppPreferences.defaultAutoAcceptSSHHostKeys
    @AppStorage(AppPreferences.overviewRefreshInterval)
    private var overviewRefreshInterval =
        AppPreferences.defaultOverviewRefreshInterval
    @AppStorage(AppPreferences.processesRefreshInterval)
    private var processesRefreshInterval =
        AppPreferences.defaultProcessesRefreshInterval
    @AppStorage(AppPreferences.dockerRefreshInterval)
    private var dockerRefreshInterval =
        AppPreferences.defaultDockerRefreshInterval
    @AppStorage(TerminalFontPreferences.fontNameKey)
    private var terminalFontName = TerminalFontPreferences.automaticFontName
    @AppStorage(TerminalFontPreferences.fontSizeKey)
    private var terminalFontSize = TerminalFontPreferences.defaultFontSize
    @AppStorage(TerminalAutocompletePreferences.enabledKey)
    private var autocompleteEnabled =
        TerminalAutocompletePreferences.defaultEnabled
    @AppStorage(TerminalAutocompletePreferences.ghostTextKey)
    private var autocompleteGhostText =
        TerminalAutocompletePreferences.defaultGhostText
    @AppStorage(TerminalAutocompletePreferences.popupMenuKey)
    private var autocompletePopupMenu =
        TerminalAutocompletePreferences.defaultPopupMenu
    @AppStorage(SFTPPreferences.showsHiddenFilesKey)
    private var sftpShowsHiddenFiles =
        SFTPPreferences.defaultShowsHiddenFiles
    @AppStorage(SFTPPreferences.fileTransferConcurrencyKey)
    private var sftpFileTransferConcurrency =
        SFTPPreferences.defaultFileTransferConcurrency
    @AppStorage(SFTPPreferences.chunkConcurrencyKey)
    private var sftpChunkConcurrency =
        SFTPPreferences.defaultChunkConcurrency
    @AppStorage(SFTPPreferences.chunkSizeBytesKey)
    private var sftpChunkSizeBytes =
        SFTPPreferences.defaultChunkSizeBytes
    @AppStorage(SFTPPreferences.transferConnectionIdleSecondsKey)
    private var sftpTransferConnectionIdleSeconds =
        SFTPPreferences.defaultTransferConnectionIdleSeconds
    @State private var terminalFontFamilies: [String] = []

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Language", selection: $language) {
                    Text("Chinese").tag("zh-Hans")
                    Text("English").tag("en")
                }
                Picker("Theme", selection: $appearance) {
                    Text("System (Follow System)").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }

            Section("Terminal") {
                Picker("Terminal Font", selection: $terminalFontName) {
                    Text("Auto (Prefer Nerd Font)").tag(
                        TerminalFontPreferences.automaticFontName
                    )
                    if terminalFontName
                        != TerminalFontPreferences.automaticFontName,
                       !terminalFontFamilies.contains(terminalFontName)
                    {
                        Text(terminalFontName).tag(terminalFontName)
                    }
                    ForEach(terminalFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                Stepper(
                    value: $terminalFontSize,
                    in: terminalFontSizeRange,
                    step: 1
                ) {
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text("\(Int(terminalFontSize))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Use a Nerd Font to display Powerline and shell prompt icons correctly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Open System Overview after SSH connects",
                    isOn: $autoOpensSystemOverviewOnSSHConnect
                )
                Text("When an SSH session connects, automatically open the right panel to System > Overview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Automatically accept SSH fingerprints",
                    isOn: $autoAcceptsSSHHostKeys
                )
                Text("When enabled, SSH fingerprints are accepted automatically. Turn it off to confirm fingerprints manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                autocompleteToggleRow(
                    title: "Enable Autocomplete",
                    description: "Show command suggestions based on history and command specifications as you type.",
                    isOn: $autocompleteEnabled
                )
                autocompleteToggleRow(
                    title: "Inline Suggestions",
                    description: "Show gray suggestion text after the cursor (similar to fish shell).",
                    isOn: $autocompleteGhostText,
                    disabled: !autocompleteEnabled
                )
                autocompleteToggleRow(
                    title: "Popup Menu",
                    description: "Show a floating list containing multiple suggestions.",
                    isOn: $autocompletePopupMenu,
                    disabled: !autocompleteEnabled
                )
            } header: {
                Text(verbatim: AppLocalization.string("Autocomplete"))
            }

            Section("Password Prompt Assist") {
                Picker("Assist Mode", selection: $passwordPromptAssistMode) {
                    Text("Off").tag(PasswordPromptAssistMode.off.rawValue)
                    Text("Quick Fill (Enter)").tag(PasswordPromptAssistMode.hint.rawValue)
                    Text("Credential Picker").tag(PasswordPromptAssistMode.picker.rawValue)
                }
                Text("When sudo or su asks for a password, offer a saved credential. Never sends a password without confirmation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("SFTP") {
                autocompleteToggleRow(
                    title: "Show Hidden Files",
                    description: "Display hidden files when browsing local and remote filesystems.",
                    isOn: $sftpShowsHiddenFiles
                )
                integerSliderSetting(
                    title: "File Transfer Concurrency",
                    description: "Maximum files transferred concurrently for one SFTP target, including files inside folders.",
                    value: $sftpFileTransferConcurrency,
                    range: SFTPPreferences.fileTransferConcurrencyRange
                )
                integerSliderSetting(
                    title: "Single-File Chunk Concurrency",
                    description: "Maximum chunks transferred concurrently inside one file.",
                    value: $sftpChunkConcurrency,
                    range: SFTPPreferences.chunkConcurrencyRange
                )
                Picker("Chunk Size", selection: $sftpChunkSizeBytes) {
                    ForEach(
                        SFTPPreferences.chunkSizePresets,
                        id: \.self
                    ) { bytes in
                        Text(verbatim: SFTPPreferences.chunkSizeTitle(bytes))
                            .tag(bytes)
                    }
                }
                Picker(
                    "Transfer Connection Keep-Alive",
                    selection: $sftpTransferConnectionIdleSeconds
                ) {
                    Text("1 Minute").tag(60)
                    Text("5 Minutes").tag(5 * 60)
                    Text("15 Minutes").tag(15 * 60)
                    Text("30 Minutes").tag(30 * 60)
                    Text("Until App Quits").tag(0)
                }
                Text("Dedicated transfer connections close after this idle time. Active transfers are never closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("System Monitor") {
                refreshIntervalStepper(
                    "Overview",
                    value: $overviewRefreshInterval
                )
                refreshIntervalStepper(
                    "Processes",
                    value: $processesRefreshInterval
                )
                refreshIntervalStepper(
                    "Docker",
                    value: $dockerRefreshInterval
                )
                Text("Refresh and data collection intervals use the same value. Range: 1-10 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: ensureSupportedLanguage)
        .onAppear(perform: normalizePasswordPromptAssistMode)
        .onAppear(perform: normalizeSystemMonitorRefreshIntervals)
        .onAppear(perform: normalizeAutocompleteSettings)
        .onAppear(perform: normalizeSFTPSettings)
        .task {
            guard terminalFontFamilies.isEmpty else {
                return
            }
            let families =
                await TerminalFontPreferences.availableFontFamiliesAsync()
            guard !Task.isCancelled else {
                return
            }
            terminalFontFamilies = families
        }
        .onChange(of: language) { _, _ in
            ensureSupportedLanguage()
        }
        .onChange(of: terminalFontSize) { _, newValue in
            terminalFontSize = TerminalFontPreferences.clampedFontSize(newValue)
        }
        .onChange(of: passwordPromptAssistMode) { _, _ in
            normalizePasswordPromptAssistMode()
        }
        .onChange(of: autocompleteGhostText) { _, enabled in
            if enabled {
                autocompletePopupMenu = false
            }
        }
        .onChange(of: autocompletePopupMenu) { _, enabled in
            if enabled {
                autocompleteGhostText = false
            }
        }
        .onChange(of: overviewRefreshInterval) { _, _ in
            normalizeSystemMonitorRefreshIntervals()
        }
        .onChange(of: processesRefreshInterval) { _, _ in
            normalizeSystemMonitorRefreshIntervals()
        }
        .onChange(of: dockerRefreshInterval) { _, _ in
            normalizeSystemMonitorRefreshIntervals()
        }
        .onChange(of: sftpFileTransferConcurrency) { _, _ in
            normalizeSFTPSettings()
        }
        .onChange(of: sftpChunkConcurrency) { _, _ in
            normalizeSFTPSettings()
        }
        .onChange(of: sftpChunkSizeBytes) { _, _ in
            normalizeSFTPSettings()
        }
        .onChange(of: sftpTransferConnectionIdleSeconds) { _, _ in
            normalizeSFTPSettings()
        }
    }

    private var terminalFontSizeRange: ClosedRange<Double> {
        TerminalFontPreferences.minimumFontSize...TerminalFontPreferences.maximumFontSize
    }

    private func autocompleteToggleRow(
        title: String,
        description: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: AppLocalization.string(title))
                    .font(.body.weight(.medium))
                Text(verbatim: AppLocalization.string(description))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 24)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(disabled)
        }
        .padding(.vertical, 4)
    }

    private func normalizeAutocompleteSettings() {
        if autocompletePopupMenu {
            autocompleteGhostText = false
        }
    }

    private func integerSliderSetting(
        title: String,
        description: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: AppLocalization.string(title))
                    .font(.body.weight(.medium))
                Text(verbatim: AppLocalization.string(description))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound) ... Double(range.upperBound),
                step: 1
            )
            .frame(width: 150)
            Text("\(value.wrappedValue)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func normalizeSFTPSettings() {
        sftpFileTransferConcurrency =
            SFTPPreferences.clampedFileTransferConcurrency(
                sftpFileTransferConcurrency
            )
        sftpChunkConcurrency = SFTPPreferences.clampedChunkConcurrency(
            sftpChunkConcurrency
        )
        sftpChunkSizeBytes = SFTPPreferences.normalizedChunkSizeBytes(
            sftpChunkSizeBytes
        )
        sftpTransferConnectionIdleSeconds =
            SFTPPreferences.normalizedTransferConnectionIdleSeconds(
                sftpTransferConnectionIdleSeconds
            )
    }

    private func normalizePasswordPromptAssistMode() {
        guard PasswordPromptAssistMode(rawValue: passwordPromptAssistMode) == nil else {
            return
        }
        passwordPromptAssistMode = AppPreferences.defaultPasswordPromptAssistMode
    }

    private var systemMonitorRefreshIntervalRange: ClosedRange<Int> {
        AppPreferences.minimumSystemMonitorRefreshInterval...AppPreferences.maximumSystemMonitorRefreshInterval
    }

    private func refreshIntervalStepper(
        _ title: LocalizedStringKey,
        value: Binding<Int>
    ) -> some View {
        Stepper(
            value: value,
            in: systemMonitorRefreshIntervalRange,
            step: 1
        ) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue)s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func ensureSupportedLanguage() {
        let normalized = AppPreferences.normalizedLanguage(language)
        if normalized != language {
            language = normalized
        }
    }

    private func normalizeSystemMonitorRefreshIntervals() {
        overviewRefreshInterval =
            AppPreferences.clampedSystemMonitorRefreshInterval(
                overviewRefreshInterval
            )
        processesRefreshInterval =
            AppPreferences.clampedSystemMonitorRefreshInterval(
                processesRefreshInterval
            )
        dockerRefreshInterval =
            AppPreferences.clampedSystemMonitorRefreshInterval(
                dockerRefreshInterval
            )
    }
}

struct KnownHostsSettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedLineNumbers = Set<Int>()
    @State private var pendingDeleteRecords: [KnownHostRecord] = []
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Host keys accepted by TermPilot")
                    .font(.headline)
                Spacer()
                Button {
                    Task {
                        await state.refreshKnownHosts()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    pendingDeleteRecords = selectedKnownHosts
                    isDeleteConfirmationPresented = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selectedLineNumbers.isEmpty)
            }

            List(state.knownHosts) { record in
                HStack {
                    Toggle(
                        isOn: selectionBinding(for: record)
                    ) {
                        EmptyView()
                    }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Select known host")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.hostPattern)
                        Text("\(record.algorithm)  \(record.fingerprint)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        pendingDeleteRecords = [record]
                        isDeleteConfirmationPresented = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete known host")
                }
            }
            .overlay {
                if state.knownHosts.isEmpty {
                    ContentUnavailableView(
                        "No Known Hosts",
                        systemImage: "checkmark.shield",
                        description: Text("Accepted SSH host keys appear here.")
                    )
                }
            }
        }
        .padding(20)
        .confirmationDialog(
            "Delete Known Hosts",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let records = pendingDeleteRecords
                pendingDeleteRecords = []
                selectedLineNumbers.removeAll()
                Task {
                    await state.deleteKnownHosts(records)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteRecords = []
            }
        } message: {
            Text("Selected known host keys will be removed.")
        }
        .task {
            await state.refreshKnownHosts()
        }
        .onChange(of: state.knownHosts) { _, records in
            selectedLineNumbers.formIntersection(
                Set(records.map(\.lineNumber))
            )
        }
    }

    private var selectedKnownHosts: [KnownHostRecord] {
        state.knownHosts.filter {
            selectedLineNumbers.contains($0.lineNumber)
        }
    }

    private func selectionBinding(
        for record: KnownHostRecord
    ) -> Binding<Bool> {
        Binding {
            selectedLineNumbers.contains(record.lineNumber)
        } set: { isSelected in
            if isSelected {
                selectedLineNumbers.insert(record.lineNumber)
            } else {
                selectedLineNumbers.remove(record.lineNumber)
            }
        }
    }
}
