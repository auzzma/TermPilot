import Compression
import Foundation

enum TerminalAutocompletePathRequirement: Equatable {
    case files
    case folders
}

struct TerminalAutocompleteSpecResult {
    var suggestions: [TerminalAutocompleteSuggestion] = []
    var pathRequirement: TerminalAutocompletePathRequirement?
}

enum TerminalAutocompleteSpecCatalog {
    private static let archive = Archive()

    static func suggestions(
        context: TerminalAutocompleteCommandLine
    ) -> TerminalAutocompleteSpecResult {
        if context.wordIndex == 0 {
            return commandSuggestions(context: context)
        }
        guard let spec = archive.spec(named: context.commandName) else {
            return TerminalAutocompleteSpecResult()
        }

        let consumed = Array(
            context.tokens.dropFirst().dropLast()
        )
        let resolved = resolve(spec: spec, consumedTokens: consumed)
        let currentToken = context.currentWord
        var result = TerminalAutocompleteSpecResult(
            pathRequirement: pathRequirement(in: resolved.arguments)
        )

        if !currentToken.isEmpty,
           let exact = resolved.node.subcommands?.first(where: {
               $0.name.values.contains(currentToken)
           })
        {
            appendPreviewSuggestions(
                node: exact,
                commandLine: context.input,
                to: &result.suggestions
            )
            result.pathRequirement = pathRequirement(in: exact.arguments)
            return result
        }

        for subcommand in resolved.node.subcommands ?? [] {
            for name in subcommand.name.values
            where name.hasPrefix(currentToken) && name != currentToken {
                result.suggestions.append(
                    TerminalAutocompleteSuggestion(
                        text: context.replacingCurrentWord(with: name),
                        displayText: name,
                        detail: subcommand.description,
                        source: .subcommand,
                        score: 800
                    )
                )
            }
        }

        let directOptionCount = result.suggestions.count
        appendOptionSuggestions(
            resolved.node.options,
            context: context,
            to: &result.suggestions
        )
        if result.suggestions.count == directOptionCount {
            appendOptionSuggestions(
                resolved.inheritedOptions,
                context: context,
                to: &result.suggestions
            )
        }
        appendArgumentSuggestions(
            resolved.arguments,
            context: context,
            to: &result.suggestions
        )
        return result
    }

    private static func commandSuggestions(
        context: TerminalAutocompleteCommandLine
    ) -> TerminalAutocompleteSpecResult {
        let typed = context.currentWord.lowercased()
        if archive.commandNames.contains(typed),
           let spec = archive.spec(named: typed)
        {
            var suggestions: [TerminalAutocompleteSuggestion] = []
            appendPreviewSuggestions(
                node: spec,
                commandLine: context.input,
                to: &suggestions
            )
            return TerminalAutocompleteSpecResult(
                suggestions: suggestions,
                pathRequirement: pathRequirement(in: spec.arguments)
            )
        }

        let suggestions = archive.commandNames
            .lazy
            .filter {
                $0.hasPrefix(typed) && $0 != typed
            }
            .prefix(10)
            .map {
                TerminalAutocompleteSuggestion(
                    text: context.replacingCurrentWord(with: $0),
                    displayText: $0,
                    source: .command,
                    score: 600
                )
            }
        return TerminalAutocompleteSpecResult(
            suggestions: Array(suggestions)
        )
    }

    private static func appendPreviewSuggestions(
        node: CommandNode,
        commandLine: String,
        to suggestions: inout [TerminalAutocompleteSuggestion]
    ) {
        for subcommand in node.subcommands ?? [] {
            guard let name = subcommand.name.values.first else {
                continue
            }
            suggestions.append(
                TerminalAutocompleteSuggestion(
                    text: "\(commandLine) \(name)",
                    displayText: name,
                    detail: subcommand.description,
                    source: .subcommand,
                    score: 800
                )
            )
            if suggestions.count >= 10 {
                return
            }
        }
        for option in node.options ?? [] {
            guard suggestions.count < 15,
                  let name = option.name.values.first
            else {
                return
            }
            suggestions.append(
                TerminalAutocompleteSuggestion(
                    text: "\(commandLine) \(name)",
                    displayText: name,
                    detail: option.description,
                    source: .option,
                    score: 700
                )
            )
        }
    }

    private static func appendOptionSuggestions(
        _ options: [OptionNode]?,
        context: TerminalAutocompleteCommandLine,
        to suggestions: inout [TerminalAutocompleteSuggestion]
    ) {
        guard let options else {
            return
        }
        for option in options {
            for name in option.name.values
            where name.hasPrefix(context.currentWord)
                && name != context.currentWord
            {
                suggestions.append(
                    TerminalAutocompleteSuggestion(
                        text: context.replacingCurrentWord(with: name),
                        displayText: name,
                        detail: option.description,
                        source: .option,
                        score: 700
                    )
                )
            }
        }
    }

    private static func appendArgumentSuggestions(
        _ arguments: [ArgumentNode]?,
        context: TerminalAutocompleteCommandLine,
        to suggestions: inout [TerminalAutocompleteSuggestion]
    ) {
        for argument in arguments ?? [] {
            for suggestion in argument.suggestions ?? [] {
                guard let name = suggestion.name.values.first,
                      name.hasPrefix(context.currentWord),
                      name != context.currentWord
                else {
                    continue
                }
                suggestions.append(
                    TerminalAutocompleteSuggestion(
                        text: context.replacingCurrentWord(with: name),
                        displayText: name,
                        detail: suggestion.description,
                        source: .argument,
                        score: 600
                    )
                )
            }
        }
    }

    private static func pathRequirement(
        in arguments: [ArgumentNode]?
    ) -> TerminalAutocompletePathRequirement? {
        let templates = (arguments ?? []).flatMap {
            $0.template?.values ?? []
        }
        if templates.contains("folders")
            && !templates.contains("filepaths")
        {
            return .folders
        }
        if templates.contains("folders")
            || templates.contains("filepaths")
        {
            return .files
        }
        return nil
    }

    private static func resolve(
        spec: CommandNode,
        consumedTokens: [String]
    ) -> ResolvedContext {
        var current = spec
        var inheritedOptions: [OptionNode] = []
        var skipsNext = false
        var optionArguments: [ArgumentNode]?

        for token in consumedTokens {
            if skipsNext {
                skipsNext = false
                optionArguments = nil
                continue
            }
            if token.hasPrefix("-") {
                let options = (current.options ?? []) + inheritedOptions
                if let option = options.first(where: {
                    $0.name.values.contains(token)
                }),
                   let arguments = option.arguments,
                   arguments.first?.isOptional != true
                {
                    skipsNext = true
                    optionArguments = arguments
                }
                continue
            }
            guard let subcommand = current.subcommands?.first(where: {
                $0.name.values.contains(token)
            }) else {
                break
            }
            inheritedOptions = mergeOptions(
                inheritedOptions,
                current.options ?? []
            )
            current = subcommand
        }

        return ResolvedContext(
            node: current,
            inheritedOptions: inheritedOptions,
            arguments: skipsNext ? optionArguments : current.arguments
        )
    }

    private static func mergeOptions(
        _ first: [OptionNode],
        _ second: [OptionNode]
    ) -> [OptionNode] {
        var seen = Set<String>()
        return (first + second).filter {
            seen.insert($0.name.values.sorted().joined(separator: "\0"))
                .inserted
        }
    }
}

private struct ResolvedContext {
    var node: CommandNode
    var inheritedOptions: [OptionNode]
    var arguments: [ArgumentNode]?
}

private struct CommandNode: Decodable {
    var name: StringList
    var description: String?
    var subcommands: [CommandNode]?
    var options: [OptionNode]?
    private var argumentValue: OneOrMany<ArgumentNode>?

    var arguments: [ArgumentNode]? {
        argumentValue?.values
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case subcommands
        case options
        case argumentValue = "args"
    }
}

private struct OptionNode: Decodable {
    var name: StringList
    var description: String?
    private var argumentValue: OneOrMany<ArgumentNode>?

    var arguments: [ArgumentNode]? {
        argumentValue?.values
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case argumentValue = "args"
    }
}

private struct ArgumentNode: Decodable {
    var name: StringList?
    var description: String?
    var template: StringList?
    var isOptional: Bool?
    var suggestions: [ArgumentSuggestion]?
}

private struct ArgumentSuggestion: Decodable {
    var name: StringList
    var description: String?

    init(from decoder: any Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            name = StringList(values: [value])
            description = nil
            return
        }
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        name = try container.decode(StringList.self, forKey: .name)
        description = try container.decodeIfPresent(
            String.self,
            forKey: .description
        )
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
    }
}

private struct StringList: Decodable {
    var values: [String]

    init(values: [String]) {
        self.values = values
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            values = [value]
        } else {
            values = try container.decode([String].self)
        }
    }
}

private struct OneOrMany<Value: Decodable>: Decodable {
    var values: [Value]

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Value.self) {
            values = [value]
        } else {
            values = try container.decode([Value].self)
        }
    }
}

private final class Archive: @unchecked Sendable {
    struct Entry: Decodable {
        var offset: Int
        var length: Int
    }

    struct Header: Decodable {
        var commands: [String]
        var entries: [String: Entry]
    }

    let commandNames: [String]

    private let data: Data
    private let payloadOffset: Int
    private let entries: [String: Entry]
    private let lock = NSLock()
    private var cache: [String: CommandNode] = [:]

    init() {
        guard let url = Self.resourceURL(),
              let data = try? Data(contentsOf: url),
              data.count >= 4
        else {
            commandNames = []
            self.data = Data()
            payloadOffset = 0
            entries = [:]
            return
        }

        let headerLength = data.prefix(4).reduce(0) {
            ($0 << 8) | Int($1)
        }
        let headerStart = 4
        let headerEnd = headerStart + headerLength
        guard headerEnd <= data.count,
              let header = try? JSONDecoder().decode(
                  Header.self,
                  from: data.subdata(in: headerStart ..< headerEnd)
              )
        else {
            commandNames = []
            self.data = Data()
            payloadOffset = 0
            entries = [:]
            return
        }

        commandNames = header.commands
        self.data = data
        payloadOffset = headerEnd
        entries = header.entries
    }

    private static func resourceURL() -> URL? {
        let filename = "AutocompleteSpecs.bundledata"
        let appResourceBundle = "TermPilot_TermPilotApp.bundle"
        var directories: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            directories.append(resourceURL)
        }
        directories.append(Bundle.main.bundleURL)
        directories.append(
            Bundle.main.bundleURL.deletingLastPathComponent()
        )
        if let executableURL = Bundle.main.executableURL {
            directories.append(executableURL.deletingLastPathComponent())
        }
        #if DEBUG
        directories.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("TermPilotApp/Resources")
        )
        #endif

        for directory in directories {
            let candidates = [
                directory.appendingPathComponent(filename),
                directory
                    .appendingPathComponent(appResourceBundle)
                    .appendingPathComponent(filename),
            ]
            if let match = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }) {
                return match
            }
        }
        return nil
    }

    func spec(named name: String) -> CommandNode? {
        lock.lock()
        if let cached = cache[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let entry = entries[name] else {
            return nil
        }
        let start = payloadOffset + entry.offset
        let end = start + entry.length
        guard start >= payloadOffset, end <= data.count else {
            return nil
        }

        let compressed = data.subdata(in: start ..< end)
        guard let expanded = Self.decompress(compressed),
              let spec = try? JSONDecoder().decode(
                CommandNode.self,
                from: expanded
            )
        else {
            return nil
        }

        lock.lock()
        cache[name] = spec
        lock.unlock()
        return spec
    }

    private static func decompress(_ compressed: Data) -> Data? {
        var capacity = max(4_096, compressed.count * 8)
        while capacity <= 64 * 1_024 * 1_024 {
            var output = Data(count: capacity)
            let decoded = output.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source in
                    guard let destinationAddress = destination
                        .bindMemory(to: UInt8.self)
                        .baseAddress,
                          let sourceAddress = source
                              .bindMemory(to: UInt8.self)
                              .baseAddress
                    else {
                        return 0
                    }
                    return compression_decode_buffer(
                        destinationAddress,
                        destination.count,
                        sourceAddress,
                        source.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if decoded > 0 {
                output.count = decoded
                return output
            }
            capacity *= 2
        }
        return nil
    }
}
