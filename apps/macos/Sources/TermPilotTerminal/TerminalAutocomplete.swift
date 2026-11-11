import Foundation
import TermPilotDomain

public enum TerminalAutocompletePreferences {
    public static let enabledKey = "terminalAutocompleteEnabled"
    public static let ghostTextKey = "terminalAutocompleteGhostText"
    public static let popupMenuKey = "terminalAutocompletePopupMenu"

    public static let defaultEnabled = true
    public static let defaultGhostText = false
    public static let defaultPopupMenu = true
}

struct TerminalAutocompleteSettings: Equatable {
    var enabled = TerminalAutocompletePreferences.defaultEnabled
    var showsGhostText = TerminalAutocompletePreferences.defaultGhostText
    var showsPopupMenu = TerminalAutocompletePreferences.defaultPopupMenu
    var debounceMilliseconds = 100
    var minimumCharacters = 1
    var maximumSuggestions = 8

    var normalized: TerminalAutocompleteSettings {
        var copy = self
        if copy.showsPopupMenu {
            copy.showsGhostText = false
        }
        copy.debounceMilliseconds = max(0, copy.debounceMilliseconds)
        copy.minimumCharacters = max(1, copy.minimumCharacters)
        copy.maximumSuggestions = max(1, copy.maximumSuggestions)
        return copy
    }
}

enum TerminalAutocompleteSuggestionSource: String, Codable, Sendable {
    case history
    case command
    case subcommand
    case option
    case argument
    case path

    var badge: String {
        switch self {
        case .history:
            "h"
        case .command:
            "c"
        case .subcommand:
            "s"
        case .option:
            "o"
        case .argument:
            "a"
        case .path:
            "p"
        }
    }
}

struct TerminalAutocompleteSuggestion: Equatable, Identifiable, Sendable {
    var text: String
    var displayText: String
    var detail: String?
    var source: TerminalAutocompleteSuggestionSource
    var score: Double
    var frequency: Int?
    var isDirectory = false
    var pathKind: TerminalAutocompleteDirectoryEntry.Kind?

    var id: String {
        "\(source.rawValue):\(text)"
    }
}

struct TerminalAutocompleteSubdirectoryPanel: Equatable, Sendable {
    var entries: [TerminalAutocompleteDirectoryEntry]
    var selectedIndex = -1
    var directory: String
}

struct TerminalAutocompletePresentation: Equatable {
    var suggestions: [TerminalAutocompleteSuggestion] = []
    var selectedIndex = -1
    var ghostText = ""
    var showsPopupMenu = false
    var subdirectoryPanels: [TerminalAutocompleteSubdirectoryPanel] = []
    var subdirectoryFocusLevel = -1

    var popupVisible: Bool {
        showsPopupMenu && !suggestions.isEmpty
    }

    static let empty = TerminalAutocompletePresentation()
}

@MainActor
final class TerminalAutocompleteController {
    var onPresentationChange: ((TerminalAutocompletePresentation) -> Void)?
    var onWrite: ((String) -> Void)?
    var onInputLineReplace: ((String) -> Void)?
    var currentDirectory: (() -> String?)?
    var remoteDirectoryProvider: (
        @Sendable (
            _ path: String,
            _ foldersOnly: Bool,
            _ filterPrefix: String,
            _ limit: Int
        ) async -> [TerminalAutocompleteDirectoryEntry]
    )?
    var closeRemoteDirectoryProvider: (@Sendable () async -> Void)?

    private(set) var presentation = TerminalAutocompletePresentation.empty
    private(set) var typedInput = ""
    private(set) var typedInputIsReliable = true

    private let descriptor: SessionDescriptor
    private let historyStore: TerminalAutocompleteHistoryStore
    private var settings = TerminalAutocompleteSettings()
    private var promptConfirmed = false
    private var previewBaseline = ""
    private var previewActive = false
    private var suggestionGeneration = 0
    private var suggestionTask: Task<Void, Never>?
    private var subdirectoryTask: Task<Void, Never>?
    private var subdirectoryGeneration = 0
    private var lastKeystrokeAt = Date.distantPast

    init(
        descriptor: SessionDescriptor,
        historyStore: TerminalAutocompleteHistoryStore = .shared
    ) {
        self.descriptor = descriptor
        self.historyStore = historyStore
        if descriptor.kind == .local {
            historyStore.seedLocalShellHistoryIfNeeded(hostKey: historyKey)
        }
    }

    func configure(_ settings: TerminalAutocompleteSettings) {
        let normalized = settings.normalized
        guard self.settings != normalized else {
            return
        }
        self.settings = normalized
        if !normalized.enabled
            || (!normalized.showsGhostText && !normalized.showsPopupMenu)
        {
            clearSuggestions()
            invalidateRemoteDirectoryProvider()
        } else if !normalized.showsGhostText, !presentation.ghostText.isEmpty {
            presentation.ghostText = ""
            publish()
        } else if !normalized.showsPopupMenu, presentation.popupVisible {
            presentation.showsPopupMenu = false
            presentation.selectedIndex = -1
            publish()
        }
    }

    func invalidateRemoteDirectoryProvider() {
        subdirectoryTask?.cancel()
        subdirectoryTask = nil
        guard let closeRemoteDirectoryProvider else {
            return
        }
        Task {
            await closeRemoteDirectoryProvider()
        }
    }

    func process(
        bytes: [UInt8],
        renderedLine: String?
    ) -> Bool {
        guard settings.enabled, !bytes.isEmpty else {
            return false
        }

        if handleCompletionKey(bytes) {
            return true
        }

        if Self.isEnter(bytes) {
            recordSubmittedCommand(renderedLine: renderedLine)
            resetInputState()
            return false
        }

        if bytes == [0x03] || bytes == [0x15] {
            resetInputState()
            return false
        }

        if !promptConfirmed {
            promptConfirmed = TerminalAutocompletePromptDetector.isPrompt(
                renderedLine,
                trackedInput: typedInput
            )
        }

        if bytes == [0x7f] || bytes == [0x08] {
            if !typedInput.isEmpty {
                typedInput.removeLast()
            }
            previewActive = false
            previewBaseline = typedInput
            refreshPresentationDuringTyping()
            scheduleSuggestions()
            return false
        }

        if bytes == [0x17] {
            typedInput = typedInput.replacingOccurrences(
                of: #"\s*\S+\s*$"#,
                with: "",
                options: .regularExpression
            )
            previewActive = false
            previewBaseline = typedInput
            refreshPresentationDuringTyping()
            scheduleSuggestions()
            return false
        }

        let data = String(decoding: bytes, as: UTF8.self)
        if data.hasPrefix("\u{1B}[200~") {
            typedInput.append(contentsOf: Self.bracketedPasteContent(data))
            previewActive = false
            previewBaseline = typedInput
            clearSuggestions()
            scheduleSuggestions()
            return false
        }

        if data.hasPrefix("\u{1B}") {
            typedInput = ""
            typedInputIsReliable = false
            promptConfirmed = false
            clearSuggestions()
            return false
        }

        if bytes.count == 1, let byte = bytes.first, byte < 0x20 {
            typedInput = ""
            typedInputIsReliable = false
            promptConfirmed = false
            clearSuggestions()
            return false
        }

        let tail = Self.inputTail(afterLastLineBreakIn: data)
        if tail.didContainLineBreak {
            typedInput = tail.value
            typedInputIsReliable = true
            promptConfirmed = false
            clearSuggestions()
        } else {
            typedInput.append(contentsOf: tail.value)
            refreshPresentationDuringTyping()
        }
        previewActive = false
        previewBaseline = typedInput
        scheduleSuggestions()
        return false
    }

    func close() {
        if previewActive {
            replaceCurrentLine(with: previewBaseline)
            typedInput = previewBaseline
            typedInputIsReliable = true
        }
        previewActive = false
        clearSuggestions()
    }

    func clearForSensitiveInput() {
        resetInputState()
    }

    func selectSuggestion(at index: Int) {
        guard presentation.suggestions.indices.contains(index) else {
            return
        }
        accept(
            presentation.suggestions[index],
            executesImmediately: false
        )
    }

    private func handleCompletionKey(_ bytes: [UInt8]) -> Bool {
        if presentation.popupVisible {
            if presentation.subdirectoryFocusLevel >= 0 {
                return handleSubdirectoryKey(bytes)
            }
            if Self.isArrowUp(bytes) {
                navigatePopup(up: true)
                return true
            }
            if Self.isArrowDown(bytes) {
                navigatePopup(up: false)
                return true
            }
            if Self.isArrowRight(bytes),
               presentation.selectedIndex >= 0,
               presentation.suggestions[
                   presentation.selectedIndex
               ].isDirectory,
               !presentation.subdirectoryPanels.isEmpty
            {
                enterFirstSubdirectoryPanel()
                return true
            }
            if bytes == [0x1b] {
                close()
                return true
            }
            if bytes == [0x09] {
                clearSuggestions()
                previewActive = false
                return false
            }
            if Self.isEnter(bytes) {
                clearSuggestions()
                previewActive = false
                return false
            }
        }

        guard !presentation.ghostText.isEmpty,
              let suggestion = activeGhostSuggestion
        else {
            return false
        }
        if Self.isArrowRight(bytes) {
            accept(suggestion, executesImmediately: false)
            return true
        }
        if Self.isWordRight(bytes) {
            acceptNextWord(from: suggestion)
            return true
        }
        return false
    }

    private func handleSubdirectoryKey(_ bytes: [UInt8]) -> Bool {
        let level = presentation.subdirectoryFocusLevel
        guard presentation.subdirectoryPanels.indices.contains(level) else {
            presentation.subdirectoryFocusLevel = -1
            publish()
            return false
        }

        if Self.isArrowUp(bytes) || Self.isArrowDown(bytes) {
            navigateSubdirectory(
                level: level,
                up: Self.isArrowUp(bytes)
            )
            return true
        }
        if Self.isArrowLeft(bytes) {
            presentation.subdirectoryPanels = Array(
                presentation.subdirectoryPanels.prefix(level + 1)
            )
            presentation.subdirectoryFocusLevel = level - 1
            publish()
            return true
        }
        if Self.isArrowRight(bytes) {
            expandSelectedSubdirectory(level: level, movesFocus: true)
            return true
        }
        if Self.isEnter(bytes) || bytes == [0x09] {
            selectCurrentSubdirectoryEntry(level: level)
            return true
        }
        if bytes == [0x1b] {
            if level > 0 {
                presentation.subdirectoryPanels = Array(
                    presentation.subdirectoryPanels.prefix(level)
                )
                presentation.subdirectoryFocusLevel = level - 1
            } else {
                presentation.subdirectoryPanels = []
                presentation.subdirectoryFocusLevel = -1
            }
            publish()
            return true
        }
        return false
    }

    private func navigatePopup(up: Bool) {
        let count = presentation.suggestions.count
        guard count > 0 else {
            return
        }
        let current = presentation.selectedIndex
        let next: Int
        if up {
            next = current <= -1 ? count - 1 : current - 1
        } else {
            next = current >= count - 1 ? -1 : current + 1
        }
        presentation.selectedIndex = next
        let candidate = next >= 0
            ? presentation.suggestions[next].text
            : previewBaseline
        replaceCurrentLine(with: candidate)
        typedInput = candidate
        typedInputIsReliable = true
        previewActive = next >= 0 && candidate != previewBaseline
        publish()
        fetchSubdirectoryForMainSelection(next)
    }

    private func enterFirstSubdirectoryPanel() {
        guard !presentation.subdirectoryPanels.isEmpty,
              !presentation.subdirectoryPanels[0].entries.isEmpty
        else {
            return
        }
        presentation.subdirectoryPanels[0].selectedIndex = 0
        presentation.subdirectoryFocusLevel = 0
        publish()
        renderSubdirectoryPreview(level: 0)
        expandSelectedSubdirectory(level: 0, movesFocus: false)
    }

    private func navigateSubdirectory(level: Int, up: Bool) {
        let entries = presentation.subdirectoryPanels[level].entries
        guard !entries.isEmpty else {
            return
        }
        let current = presentation.subdirectoryPanels[level].selectedIndex
        let next = up
            ? (current <= 0 ? entries.count - 1 : current - 1)
            : (current >= entries.count - 1 ? 0 : current + 1)
        presentation.subdirectoryPanels[level].selectedIndex = next
        presentation.subdirectoryPanels = Array(
            presentation.subdirectoryPanels.prefix(level + 1)
        )
        publish()
        renderSubdirectoryPreview(level: level)
        expandSelectedSubdirectory(level: level, movesFocus: false)
    }

    private func renderSubdirectoryPreview(level: Int) {
        guard presentation.subdirectoryPanels.indices.contains(level),
              let entry = selectedEntry(inSubdirectoryLevel: level)
        else {
            return
        }
        let panel = presentation.subdirectoryPanels[level]
        let replacement = TerminalAutocompletePathCompletion
            .replacementPath(
                directory: panel.directory,
                entry: entry,
                currentToken: TerminalAutocompleteCommandLine
                    .parse(typedInput)
                    .currentWord
            )
        let command = TerminalAutocompleteCommandLine
            .parse(typedInput)
            .replacingCurrentWord(with: replacement)
        replaceCurrentLine(with: command)
        typedInput = command
        typedInputIsReliable = true
        previewActive = command != previewBaseline
    }

    private func selectCurrentSubdirectoryEntry(level: Int) {
        guard presentation.subdirectoryPanels.indices.contains(level),
              let entry = selectedEntry(inSubdirectoryLevel: level)
        else {
            return
        }
        let panel = presentation.subdirectoryPanels[level]
        let context = TerminalAutocompleteCommandLine.parse(typedInput)
        let replacement = TerminalAutocompletePathCompletion
            .replacementPath(
                directory: panel.directory,
                entry: entry,
                currentToken: context.currentWord
            )
        let command = context.replacingCurrentWord(with: replacement)
        replaceCurrentLine(with: command)
        typedInput = command
        typedInputIsReliable = true
        previewBaseline = command
        previewActive = false
        clearSuggestions()
        if entry.kind == .directory {
            scheduleSuggestions()
        }
    }

    private func selectedEntry(
        inSubdirectoryLevel level: Int
    ) -> TerminalAutocompleteDirectoryEntry? {
        let panel = presentation.subdirectoryPanels[level]
        guard panel.entries.indices.contains(panel.selectedIndex) else {
            return nil
        }
        return panel.entries[panel.selectedIndex]
    }

    private func fetchSubdirectoryForMainSelection(_ index: Int) {
        subdirectoryGeneration &+= 1
        let generation = subdirectoryGeneration
        subdirectoryTask?.cancel()
        presentation.subdirectoryPanels = []
        presentation.subdirectoryFocusLevel = -1

        guard presentation.suggestions.indices.contains(index),
              presentation.suggestions[index].isDirectory
        else {
            publish()
            return
        }
        let selected = presentation.suggestions[index]
        let context = TerminalAutocompleteCommandLine.parse(selected.text)
        guard let request = TerminalAutocompletePathCompletion.request(
            context: context,
            currentDirectory: currentDirectory?(),
            specRequirement: .folders
        ) else {
            publish()
            return
        }
        publish()
        subdirectoryTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let entries = await self.directoryEntries(
                request: request,
                limit: 50
            )
            guard !Task.isCancelled,
                  generation == self.subdirectoryGeneration,
                  self.presentation.selectedIndex == index
            else {
                return
            }
            self.presentation.subdirectoryPanels = entries.isEmpty
                ? []
                : [
                    TerminalAutocompleteSubdirectoryPanel(
                        entries: entries,
                        directory: request.directoryToList
                    ),
                ]
            self.presentation.subdirectoryFocusLevel = -1
            self.publish()
        }
    }

    private func expandSelectedSubdirectory(
        level: Int,
        movesFocus: Bool
    ) {
        guard presentation.subdirectoryPanels.indices.contains(level),
              let entry = selectedEntry(inSubdirectoryLevel: level),
              entry.kind == .directory
        else {
            return
        }
        let parent = presentation.subdirectoryPanels[level].directory
        let child = TerminalAutocompletePathCompletion.childDirectory(
            panelDirectory: parent,
            entryName: entry.name
        )
        subdirectoryGeneration &+= 1
        let generation = subdirectoryGeneration
        subdirectoryTask?.cancel()
        subdirectoryTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let request = TerminalAutocompletePathRequest(
                directoryToList: child,
                filterPrefix: "",
                insertionPrefix: "",
                quoteSuffix: "",
                foldersOnly: false
            )
            let entries = await self.directoryEntries(
                request: request,
                limit: 50
            )
            guard !Task.isCancelled,
                  generation == self.subdirectoryGeneration,
                  self.presentation.subdirectoryPanels.indices.contains(level)
            else {
                return
            }
            self.presentation.subdirectoryPanels = Array(
                self.presentation.subdirectoryPanels.prefix(level + 1)
            )
            guard !entries.isEmpty else {
                self.publish()
                return
            }
            self.presentation.subdirectoryPanels.append(
                TerminalAutocompleteSubdirectoryPanel(
                    entries: entries,
                    selectedIndex: movesFocus ? 0 : -1,
                    directory: child
                )
            )
            if movesFocus {
                self.presentation.subdirectoryFocusLevel = level + 1
            }
            self.publish()
        }
    }

    private var activeGhostSuggestion: TerminalAutocompleteSuggestion? {
        presentation.suggestions.first(where: {
            $0.source != .path || $0.text.hasPrefix(typedInput)
        })
    }

    private func accept(
        _ suggestion: TerminalAutocompleteSuggestion,
        executesImmediately: Bool
    ) {
        let payload: String
        if suggestion.text.hasPrefix(typedInput) {
            payload = String(suggestion.text.dropFirst(typedInput.count))
                + (executesImmediately ? "\r" : "")
        } else {
            payload = "\u{15}" + suggestion.text
                + (executesImmediately ? "\r" : "")
        }
        onWrite?(payload)
        if executesImmediately {
            historyStore.record(
                command: suggestion.text,
                hostKey: historyKey
            )
            typedInput = ""
            promptConfirmed = false
        } else {
            typedInput = suggestion.text
            onInputLineReplace?(typedInput)
        }
        typedInputIsReliable = true
        previewActive = false
        clearSuggestions()
    }

    private func acceptNextWord(
        from suggestion: TerminalAutocompleteSuggestion
    ) {
        guard suggestion.text.hasPrefix(typedInput) else {
            clearSuggestions()
            return
        }
        let suffix = String(suggestion.text.dropFirst(typedInput.count))
        var accepted = ""
        var foundNonWhitespace = false
        for character in suffix {
            accepted.append(character)
            if character.isWhitespace {
                if foundNonWhitespace {
                    break
                }
            } else {
                foundNonWhitespace = true
            }
        }
        guard !accepted.isEmpty else {
            return
        }
        onWrite?(accepted)
        typedInput.append(contentsOf: accepted)
        typedInputIsReliable = true
        onInputLineReplace?(typedInput)
        if suggestion.text.count > typedInput.count {
            presentation.ghostText = String(
                suggestion.text.dropFirst(typedInput.count)
            )
            publish()
        } else {
            clearSuggestions()
        }
    }

    private func replaceCurrentLine(with value: String) {
        onWrite?("\u{15}\(value)")
        onInputLineReplace?(value)
    }

    private func recordSubmittedCommand(renderedLine: String?) {
        let command: String?
        if promptConfirmed, typedInputIsReliable {
            command = typedInput
        } else {
            command = TerminalAutocompletePromptDetector.command(
                in: renderedLine
            )
        }
        guard let command else {
            return
        }
        historyStore.record(command: command, hostKey: historyKey)
    }

    private func scheduleSuggestions() {
        suggestionGeneration &+= 1
        let generation = suggestionGeneration
        suggestionTask?.cancel()

        guard promptConfirmed,
              typedInputIsReliable,
              typedInput.count >= settings.minimumCharacters,
              settings.showsGhostText || settings.showsPopupMenu
        else {
            return
        }

        let now = Date()
        let interval = now.timeIntervalSince(lastKeystrokeAt)
        lastKeystrokeAt = now
        let multiplier = interval < 0.04 ? 3 : 1
        let delay = settings.debounceMilliseconds * multiplier
        suggestionTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(delay) * 1_000_000
                )
            }
            guard !Task.isCancelled,
                  let self,
                  generation == self.suggestionGeneration
            else {
                return
            }
            await self.fetchSuggestions(generation: generation)
        }
    }

    private func fetchSuggestions(generation: Int) async {
        let input = typedInput
        let plan = TerminalAutocompleteEngine.plan(
            for: input,
            currentDirectory: currentDirectory?()
        )
        let history: [TerminalAutocompleteSuggestion]
        if plan.pathRequest != nil {
            history = historyStore.recentSuggestions(
                commandName: plan.context.commandName,
                argumentPrefix: plan.context.currentWord,
                excluding: input,
                hostKey: historyKey,
                limit: 5
            )
        } else {
            history = historyStore.suggestions(
                prefix: input,
                hostKey: historyKey,
                limit: 5
            )
        }
        let pathEntries: [TerminalAutocompleteDirectoryEntry]
        if let request = plan.pathRequest {
            pathEntries = await directoryEntries(
                request: request,
                limit: 100
            )
        } else {
            pathEntries = []
        }
        let suggestions = TerminalAutocompleteEngine.suggestions(
            plan: plan,
            history: history,
            pathEntries: pathEntries,
            maximum: settings.maximumSuggestions
        )
        guard !Task.isCancelled,
              generation == suggestionGeneration,
              input == typedInput
        else {
            return
        }

        previewBaseline = input
        previewActive = false
        presentation.suggestions = suggestions
        presentation.selectedIndex = -1
        presentation.showsPopupMenu = settings.showsPopupMenu
        if settings.showsGhostText,
           let first = suggestions.first,
           first.text.hasPrefix(input)
        {
            presentation.ghostText = String(
                first.text.dropFirst(input.count)
            )
        } else {
            presentation.ghostText = ""
        }
        publish()
    }

    private func directoryEntries(
        request: TerminalAutocompletePathRequest,
        limit: Int
    ) async -> [TerminalAutocompleteDirectoryEntry] {
        if descriptor.kind == .local {
            return TerminalAutocompletePathCompletion.localEntries(
                request: request,
                limit: limit
            )
        }
        guard let remoteDirectoryProvider else {
            return []
        }
        return await remoteDirectoryProvider(
            request.directoryToList,
            request.foldersOnly,
            request.filterPrefix,
            limit
        )
    }

    private func clearSuggestions() {
        suggestionGeneration &+= 1
        suggestionTask?.cancel()
        suggestionTask = nil
        subdirectoryGeneration &+= 1
        subdirectoryTask?.cancel()
        subdirectoryTask = nil
        guard presentation != .empty else {
            return
        }
        presentation = .empty
        publish()
    }

    private func refreshPresentationDuringTyping() {
        guard typedInput.count >= settings.minimumCharacters else {
            clearSuggestions()
            return
        }
        guard presentation != .empty else {
            return
        }
        presentation.selectedIndex = -1
        presentation.subdirectoryPanels = []
        presentation.subdirectoryFocusLevel = -1
        if settings.showsGhostText,
           let active = presentation.suggestions.first,
           active.text.hasPrefix(typedInput)
        {
            presentation.ghostText = String(
                active.text.dropFirst(typedInput.count)
            )
        } else {
            presentation.ghostText = ""
        }
        publish()
    }

    private func resetInputState() {
        typedInput = ""
        typedInputIsReliable = true
        promptConfirmed = false
        previewBaseline = ""
        previewActive = false
        clearSuggestions()
    }

    private func publish() {
        onPresentationChange?(presentation)
    }

    private var historyKey: String {
        if descriptor.kind == .local {
            return "local-shell"
        }
        if let hostID = descriptor.hostID {
            return hostID.uuidString
        }
        return [
            descriptor.username ?? "",
            descriptor.hostname ?? "",
            String(descriptor.port ?? 22),
        ].joined(separator: "@")
    }

    private static func isEnter(_ bytes: [UInt8]) -> Bool {
        bytes == [0x0d] || bytes == [0x0a]
    }

    private static func isArrowUp(_ bytes: [UInt8]) -> Bool {
        bytes == [0x1b, 0x5b, 0x41]
            || bytes == [0x1b, 0x4f, 0x41]
    }

    private static func isArrowDown(_ bytes: [UInt8]) -> Bool {
        bytes == [0x1b, 0x5b, 0x42]
            || bytes == [0x1b, 0x4f, 0x42]
    }

    private static func isArrowLeft(_ bytes: [UInt8]) -> Bool {
        bytes == [0x1b, 0x5b, 0x44]
            || bytes == [0x1b, 0x4f, 0x44]
    }

    private static func isArrowRight(_ bytes: [UInt8]) -> Bool {
        bytes == [0x1b, 0x5b, 0x43]
            || bytes == [0x1b, 0x4f, 0x43]
    }

    private static func isWordRight(_ bytes: [UInt8]) -> Bool {
        bytes == [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x43]
            || bytes == [0x1b, 0x5b, 0x31, 0x3b, 0x33, 0x43]
            || bytes == [0x1b, 0x66]
    }

    private static func bracketedPasteContent(_ value: String) -> String {
        let prefix = "\u{1B}[200~"
        let suffix = "\u{1B}[201~"
        var content = String(value.dropFirst(prefix.count))
        if content.hasSuffix(suffix) {
            content.removeLast(suffix.count)
        }
        return content
    }

    private static func inputTail(
        afterLastLineBreakIn value: String
    ) -> (value: String, didContainLineBreak: Bool) {
        guard let index = value.lastIndex(where: {
            $0 == "\r" || $0 == "\n"
        }) else {
            return (value, false)
        }
        return (String(value[value.index(after: index)...]), true)
    }
}

private enum TerminalAutocompletePromptDetector {
    private static let promptCharacters: Set<Character> = [
        "$", "#", "%", ">", "❯", "❮", "→", "➜", "➤", "⟩", "»", "›",
    ]
    private static let nonPromptPatterns = [
        #"^~$"#,
        #"(?i)^\s*--\s*more\s*--"#,
        #"^\s*\(END\)"#,
        #"^:\s*$"#,
        #"^>{1,3}\s"#,
        #"(?i)^(?:mysql|sqlite(?:3)?|redis(?:-cli)?|psql|mariadb)>\s*"#,
        #"(?i)^SQL>\s*"#,
        #"(?i)^(?:sftp|ftp|lftp|ghci|node|mongo|mongosh|deno|irb|pry|julia|scala|gdb|lldb|cqlsh|hive|spark-sql|jshell|ksql|trino|presto|duckdb)>\s*"#,
        #"(?i)^MariaDB\s+\[[^\]]+\]>\s*"#,
        #"^[\w.-]+=[#>]\s*"#,
        #"^[\w.-]+[-'"][#>]\s*"#,
    ]
    private static let sensitivePattern =
        #"(?i)(?:password|passphrase|verification\s+code|one[- ]time\s+(?:code|password)|otp|pin)\s*[:：]\s*$"#

    static func isPrompt(
        _ renderedLine: String?,
        trackedInput _: String
    ) -> Bool {
        guard let line = renderedLine?
            .trimmingCharacters(in: .newlines),
              !line.isEmpty
        else {
            return false
        }
        guard !isNonPrompt(line),
              !matches(sensitivePattern, in: line)
        else {
            return false
        }
        return promptBoundary(in: line) != nil
    }

    static func command(in renderedLine: String?) -> String? {
        guard let renderedLine else {
            return nil
        }
        let line = renderedLine.trimmingCharacters(
            in: .newlines
        )
        guard !isNonPrompt(line),
              !matches(sensitivePattern, in: line),
              let boundary = promptBoundary(in: line)
        else {
            return nil
        }
        let command = line[boundary...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    private static func promptBoundary(in line: String) -> String.Index? {
        var lastBoundary: String.Index?
        var scanned = 0
        var index = line.startIndex
        while index < line.endIndex, scanned < 200 {
            let character = line[index]
            guard promptCharacters.contains(character)
                    || isPrivateUse(character)
            else {
                index = line.index(after: index)
                scanned += 1
                continue
            }

            let afterMarker = line.index(after: index)
            let next = afterMarker < line.endIndex
                ? line[afterMarker]
                : nil
            guard next == nil || next == " " else {
                index = afterMarker
                scanned += 1
                continue
            }
            if character == "$", index > line.startIndex {
                let previous = line[line.index(before: index)]
                if previous == "=" || previous == "/" || previous == ":" {
                    index = afterMarker
                    scanned += 1
                    continue
                }
            }
            if character == ">" || character == "›" {
                let distance = line.distance(
                    from: line.startIndex,
                    to: index
                )
                let visibleLength = max(
                    1,
                    line.trimmingCharacters(in: .whitespaces).count
                )
                if distance >= max(40, visibleLength * 3 / 5) {
                    index = afterMarker
                    scanned += 1
                    continue
                }
            }
            lastBoundary = next == " "
                ? line.index(after: afterMarker)
                : afterMarker
            index = afterMarker
            scanned += 1
        }
        return lastBoundary
    }

    private static func isNonPrompt(_ value: String) -> Bool {
        let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return nonPromptPatterns.contains {
            matches($0, in: line)
        }
    }

    private static func matches(
        _ pattern: String,
        in value: String
    ) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isPrivateUse(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first
        else {
            return false
        }
        return (0xE000 ... 0xF8FF).contains(Int(scalar.value))
    }
}

@MainActor
final class TerminalAutocompleteHistoryStore {
    static let shared = TerminalAutocompleteHistoryStore()

    struct Entry: Codable, Equatable {
        var command: String
        var hostKey: String
        var frequency: Int
        var createdAt: Date
        var lastUsedAt: Date
    }

    private struct Store: Codable {
        var entries: [Entry]
        var seededLocalHostKeys: Set<String>
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var store: Store

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "terminalAutocompleteHistory"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(Store.self, from: data)
        {
            store = decoded
        } else {
            store = Store(entries: [], seededLocalHostKeys: [])
        }
    }

    func record(command: String, hostKey: String) {
        record(commands: [command], hostKey: hostKey)
    }

    func suggestions(
        prefix: String,
        hostKey: String,
        limit: Int
    ) -> [TerminalAutocompleteSuggestion] {
        guard limit > 0 else {
            return []
        }
        let normalizedPrefix = prefix.lowercased()
        let now = Date()
        let prefixMatches = store.entries
            .filter {
                $0.hostKey == hostKey
                    && $0.command.lowercased().hasPrefix(normalizedPrefix)
                    && $0.command != prefix
            }
            .sorted {
                score($0, now: now) > score($1, now: now)
            }

        var matches = Array(prefixMatches.prefix(limit))
        if matches.count < min(3, limit), prefix.count >= 2 {
            let existing = Set(matches.map(\.command))
            let fuzzy = store.entries
                .filter {
                    $0.hostKey == hostKey
                        && !existing.contains($0.command)
                        && Self.fuzzyMatches(
                            normalizedPrefix,
                            candidate: $0.command.lowercased()
                        )
                }
                .sorted {
                    score($0, now: now) > score($1, now: now)
                }
            matches.append(
                contentsOf: fuzzy.prefix(limit - matches.count)
            )
        }

        return matches.map {
            TerminalAutocompleteSuggestion(
                text: $0.command,
                displayText: $0.command,
                source: .history,
                score: 1_000 + score($0, now: now),
                frequency: $0.frequency
            )
        }
    }

    func recentSuggestions(
        commandName: String,
        argumentPrefix: String,
        excluding command: String,
        hostKey: String,
        limit: Int
    ) -> [TerminalAutocompleteSuggestion] {
        guard !commandName.isEmpty, limit > 0 else {
            return []
        }
        let commandPrefix = commandName.lowercased() + " "
        let normalizedArgument = Self.normalizeArgument(argumentPrefix)
        return store.entries
            .filter {
                guard $0.hostKey == hostKey,
                      $0.command != command
                else {
                    return false
                }
                let lowercased = $0.command.lowercased()
                guard lowercased == commandName.lowercased()
                        || lowercased.hasPrefix(commandPrefix)
                else {
                    return false
                }
                guard !normalizedArgument.isEmpty else {
                    return true
                }
                let token = TerminalAutocompleteCommandLine
                    .parse($0.command)
                    .currentWord
                return Self.normalizeArgument(token)
                    .hasPrefix(normalizedArgument)
            }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .prefix(limit)
            .enumerated()
            .map { index, entry in
                TerminalAutocompleteSuggestion(
                    text: entry.command,
                    displayText: entry.command,
                    source: .history,
                    score: 720 - Double(index),
                    frequency: entry.frequency
                )
            }
    }

    func seedLocalShellHistoryIfNeeded(hostKey: String) {
        guard !store.seededLocalHostKeys.contains(hostKey) else {
            return
        }
        store.seededLocalHostKeys.insert(hostKey)
        var commands: [String] = []
        commands.append(contentsOf: Self.readZshHistory())
        commands.append(contentsOf: Self.readPlainHistory(".bash_history"))
        commands.append(contentsOf: Self.readFishHistory())
        record(commands: commands.suffix(3_000), hostKey: hostKey)
        persist()
    }

    private func record<S: Sequence>(
        commands: S,
        hostKey: String
    ) where S.Element == String {
        let now = Date()
        for rawCommand in commands {
            let command = rawCommand.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !command.isEmpty, command.count <= 2_000 else {
                continue
            }
            if let index = store.entries.firstIndex(where: {
                $0.hostKey == hostKey && $0.command == command
            }) {
                store.entries[index].frequency += 1
                store.entries[index].lastUsedAt = now
            } else {
                store.entries.append(
                    Entry(
                        command: command,
                        hostKey: hostKey,
                        frequency: 1,
                        createdAt: now,
                        lastUsedAt: now
                    )
                )
            }
        }
        enforceLimits(now: now)
        persist()
    }

    private func enforceLimits(now: Date) {
        let hostGroups = Dictionary(grouping: store.entries, by: \.hostKey)
        let retainedPerHost = hostGroups.values.flatMap { entries in
            entries.sorted {
                score($0, now: now) > score($1, now: now)
            }
            .prefix(5_000)
        }
        store.entries = Array(
            retainedPerHost.sorted {
                score($0, now: now) > score($1, now: now)
            }
            .prefix(10_000)
        )
    }

    private func score(_ entry: Entry, now: Date) -> Double {
        let ageHours = now.timeIntervalSince(entry.lastUsedAt) / 3_600
        return Double(entry.frequency) * pow(0.5, ageHours / 24)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(store) else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    private static func fuzzyMatches(
        _ query: String,
        candidate: String
    ) -> Bool {
        var candidateIndex = candidate.startIndex
        for character in query {
            guard let match = candidate[candidateIndex...]
                .firstIndex(of: character)
            else {
                return false
            }
            candidateIndex = candidate.index(after: match)
        }
        return true
    }

    private static func normalizeArgument(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "'\"")
            )
            .replacingOccurrences(of: "\\ ", with: " ")
            .lowercased()
    }

    private static func readPlainHistory(_ filename: String) -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(filename)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("#") }
    }

    private static func readZshHistory() -> [String] {
        readPlainHistory(".zsh_history").map { line in
            guard line.hasPrefix(": "),
                  let separator = line.firstIndex(of: ";")
            else {
                return line
            }
            return String(line[line.index(after: separator)...])
        }
    }

    private static func readFishHistory() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(
                ".local/share/fish/fish_history"
            ),
            home.appendingPathComponent(
                ".config/fish/fish_history"
            ),
        ]
        guard let url = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return []
        }
        return text.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("- cmd:") else {
                return nil
            }
            return line.dropFirst(6)
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\n", with: "\n")
        }
    }
}

struct TerminalAutocompletePlan {
    var context: TerminalAutocompleteCommandLine
    var specSuggestions: [TerminalAutocompleteSuggestion]
    var pathRequest: TerminalAutocompletePathRequest?
}

enum TerminalAutocompleteEngine {
    static func plan(
        for input: String,
        currentDirectory: String?
    ) -> TerminalAutocompletePlan {
        let context = TerminalAutocompleteCommandLine.parse(input)
        let specResult = TerminalAutocompleteSpecCatalog.suggestions(
            context: context
        )
        return TerminalAutocompletePlan(
            context: context,
            specSuggestions: specResult.suggestions,
            pathRequest: TerminalAutocompletePathCompletion.request(
                context: context,
                currentDirectory: currentDirectory,
                specRequirement: specResult.pathRequirement
            )
        )
    }

    static func suggestions(
        plan: TerminalAutocompletePlan,
        history: [TerminalAutocompleteSuggestion],
        pathEntries: [TerminalAutocompleteDirectoryEntry],
        maximum: Int
    ) -> [TerminalAutocompleteSuggestion] {
        var suggestions = history + plan.specSuggestions
        if let request = plan.pathRequest {
            suggestions.append(
                contentsOf: TerminalAutocompletePathCompletion.suggestions(
                    context: plan.context,
                    request: request,
                    entries: pathEntries
                )
            )
        }
        suggestions.sort { $0.score > $1.score }

        var seen = Set<String>()
        return suggestions.filter {
            seen.insert($0.text).inserted
        }
        .prefix(plan.pathRequest == nil ? maximum : max(maximum, 24))
        .map { $0 }
    }

    static func suggestions(
        for input: String,
        history: [TerminalAutocompleteSuggestion],
        maximum: Int,
        localCurrentDirectory: String?
    ) -> [TerminalAutocompleteSuggestion] {
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else {
            return []
        }
        let plan = plan(
            for: input,
            currentDirectory: localCurrentDirectory
        )
        let entries = plan.pathRequest.map {
            TerminalAutocompletePathCompletion.localEntries(
                request: $0,
                limit: 100
            )
        } ?? []
        return suggestions(
            plan: plan,
            history: history,
            pathEntries: entries,
            maximum: maximum
        )
    }
}

struct TerminalAutocompleteCommandLine {
    var input: String
    var tokens: [String]
    var currentWord: String
    var wordIndex: Int
    var commandName: String

    static func parse(_ input: String) -> TerminalAutocompleteCommandLine {
        var tokens: [String] = []
        var current = ""
        var singleQuoted = false
        var doubleQuoted = false
        var escaped = false
        for character in input {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "'", !doubleQuoted {
                current.append(character)
                singleQuoted.toggle()
            } else if character == "\"", !singleQuoted {
                current.append(character)
                doubleQuoted.toggle()
            } else if character == " ", !singleQuoted, !doubleQuoted {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        tokens.append(current)
        let command = tokens.first?
            .split(separator: "/")
            .last
            .map(String.init)?
            .replacingOccurrences(
                of: #"\.(exe|cmd|bat|sh|bash|zsh|fish)$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .lowercased()
            ?? ""
        return TerminalAutocompleteCommandLine(
            input: input,
            tokens: tokens,
            currentWord: current,
            wordIndex: max(0, tokens.count - 1),
            commandName: command
        )
    }

    func replacingCurrentWord(with replacement: String) -> String {
        guard input.count >= currentWord.count else {
            return replacement
        }
        return String(input.dropLast(currentWord.count)) + replacement
    }
}
