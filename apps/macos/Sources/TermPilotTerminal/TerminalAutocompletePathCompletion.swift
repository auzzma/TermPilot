import Foundation

public struct TerminalAutocompleteDirectoryEntry: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case file
        case directory
        case symlink
    }

    public var name: String
    public var kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

struct TerminalAutocompletePathRequest: Equatable, Sendable {
    var directoryToList: String
    var filterPrefix: String
    var insertionPrefix: String
    var quoteSuffix: String
    var foldersOnly: Bool
}

enum TerminalAutocompletePathCompletion {
    private static let pathCommands: Set<String> = [
        "cd", "pushd", "ls", "ll", "la", "dir", "tree", "exa", "eza",
        "lsd", "cat", "less", "more", "head", "tail", "bat", "tac",
        "nl", "tee", "vim", "vi", "nvim", "nano", "emacs", "code",
        "subl", "micro", "helix", "hx", "joe", "mcedit", "cp", "mv",
        "rm", "mkdir", "rmdir", "touch", "ln", "install", "shred",
        "chmod", "chown", "chgrp", "stat", "file", "lsattr", "chattr",
        "find", "rg", "grep", "egrep", "fgrep", "ag", "fd", "locate",
        "wc", "sort", "uniq", "cut", "awk", "sed", "tar", "zip",
        "unzip", "gzip", "gunzip", "bzip2", "bunzip2", "xz", "unxz",
        "zstd", "7z", "rar", "unrar", "scp", "rsync", "diff", "cmp",
        "patch", "source", ".", "bash", "sh", "zsh", "fish", "python",
        "python3", "node", "ruby", "perl", "php", "rustc", "gcc", "g++",
        "deno", "bun", "tsx", "ts-node", "du", "df", "chroot",
        "realpath", "readlink", "basename", "dirname", "md5sum",
        "sha256sum", "xxd", "hexdump", "xdg-open", "open", "start",
    ]

    private static let folderOnlyCommands: Set<String> = [
        "cd", "mkdir", "rmdir", "pushd",
    ]

    static func request(
        context: TerminalAutocompleteCommandLine,
        currentDirectory: String?,
        specRequirement: TerminalAutocompletePathRequirement?
    ) -> TerminalAutocompletePathRequest? {
        guard context.wordIndex >= 1 else {
            return nil
        }
        let token = stripWrappingQuotes(context.currentWord)
        let hasPathPrefix = token.hasPrefix("/")
            || token.hasPrefix("./")
            || token.hasPrefix("../")
            || token.hasPrefix("~/")
            || token == "."
            || token == ".."
            || token == "~"
        let usesPathCommand = pathCommands.contains(context.commandName)
            && !token.hasPrefix("-")
        guard hasPathPrefix
                || specRequirement != nil
                || usesPathCommand
        else {
            return nil
        }

        let foldersOnly = specRequirement == .folders
            || folderOnlyCommands.contains(context.commandName)
        return resolve(
            token: context.currentWord,
            currentDirectory: currentDirectory,
            foldersOnly: foldersOnly
        )
    }

    static func suggestions(
        context: TerminalAutocompleteCommandLine,
        request: TerminalAutocompletePathRequest,
        entries: [TerminalAutocompleteDirectoryEntry]
    ) -> [TerminalAutocompleteSuggestion] {
        entries
            .filter {
                !request.foldersOnly || $0.kind == .directory
            }
            .filter {
                request.filterPrefix.isEmpty
                    || $0.name.lowercased().hasPrefix(
                        request.filterPrefix.lowercased()
                    )
            }
            .sorted(by: compareEntries)
            .map { entry in
                let suffix = entry.kind == .directory ? "/" : ""
                let quoted = request.insertionPrefix.hasPrefix("\"")
                    || request.insertionPrefix.hasPrefix("'")
                let name = quoted ? entry.name : shellEscape(entry.name)
                let replacement = request.insertionPrefix
                    + name
                    + suffix
                    + request.quoteSuffix
                return TerminalAutocompleteSuggestion(
                    text: context.replacingCurrentWord(with: replacement),
                    displayText: entry.name + suffix,
                    detail: nil,
                    source: .path,
                    score: 750,
                    isDirectory: entry.kind == .directory,
                    pathKind: entry.kind
                )
            }
    }

    static func localEntries(
        request: TerminalAutocompletePathRequest,
        limit: Int
    ) -> [TerminalAutocompleteDirectoryEntry] {
        let path = (request.directoryToList as NSString)
            .expandingTildeInPath
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: []
        ) else {
            return []
        }

        return urls.lazy.compactMap { url in
            let name = url.lastPathComponent
            guard name != ".",
                  name != "..",
                  request.filterPrefix.isEmpty
                    || name.lowercased().hasPrefix(
                        request.filterPrefix.lowercased()
                    )
            else {
                return nil
            }
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            let kind: TerminalAutocompleteDirectoryEntry.Kind
            if values?.isSymbolicLink == true {
                kind = .symlink
            } else if values?.isDirectory == true {
                kind = .directory
            } else {
                kind = .file
            }
            if request.foldersOnly, kind != .directory {
                return nil
            }
            return TerminalAutocompleteDirectoryEntry(
                name: name,
                kind: kind
            )
        }
        .prefix(max(1, min(limit, 200)))
        .map { $0 }
        .sorted(by: compareEntries)
    }

    static func childDirectory(
        panelDirectory: String,
        entryName: String
    ) -> String {
        let separator = panelDirectory.hasSuffix("/") ? "" : "/"
        return normalizePath(
            panelDirectory + separator + entryName + "/"
        )
    }

    static func replacementPath(
        directory: String,
        entry: TerminalAutocompleteDirectoryEntry,
        currentToken: String
    ) -> String {
        let separator = directory.hasSuffix("/") ? "" : "/"
        let suffix = entry.kind == .directory ? "/" : ""
        let path = directory + separator + entry.name + suffix
        let quote = leadingQuote(currentToken)
        let closingQuote = trailingMatchingQuote(
            currentToken,
            quotePrefix: quote
        )
        if quote == "\"" {
            let escaped = path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "`", with: "\\`")
            return quote + escaped + closingQuote
        }
        if quote == "'", !path.contains("'") {
            return quote + path + closingQuote
        }
        return shellEscape(path)
    }

    private static func resolve(
        token: String,
        currentDirectory: String?,
        foldersOnly: Bool
    ) -> TerminalAutocompletePathRequest {
        let quotePrefix = leadingQuote(token)
        let quoteSuffix = trailingMatchingQuote(
            token,
            quotePrefix: quotePrefix
        )
        let unquoted = stripWrappingQuotes(token)

        if unquoted.isEmpty
            || unquoted == "."
            || unquoted == ".."
            || unquoted == "~"
        {
            let directory: String
            let visiblePrefix: String
            switch unquoted {
            case "~":
                directory = "~"
                visiblePrefix = "~/"
            case "..":
                directory = resolveDirectory(
                    "../",
                    currentDirectory: currentDirectory
                )
                visiblePrefix = "../"
            case ".":
                directory = resolveDirectory(
                    "",
                    currentDirectory: currentDirectory
                )
                visiblePrefix = "./"
            default:
                directory = resolveDirectory(
                    "",
                    currentDirectory: currentDirectory
                )
                visiblePrefix = ""
            }
            return TerminalAutocompletePathRequest(
                directoryToList: directory,
                filterPrefix: "",
                insertionPrefix: quotePrefix + visiblePrefix,
                quoteSuffix: quoteSuffix,
                foldersOnly: foldersOnly
            )
        }

        if let slash = unquoted.lastIndex(of: "/") {
            let afterSlash = unquoted.index(after: slash)
            let directoryPart = String(unquoted[...slash])
            let filter = decodeShellPath(
                String(unquoted[afterSlash...])
            )
            return TerminalAutocompletePathRequest(
                directoryToList: resolveDirectory(
                    decodeShellPath(directoryPart),
                    currentDirectory: currentDirectory
                ),
                filterPrefix: filter,
                insertionPrefix: quotePrefix + directoryPart,
                quoteSuffix: quoteSuffix,
                foldersOnly: foldersOnly
            )
        }

        return TerminalAutocompletePathRequest(
            directoryToList: resolveDirectory(
                "",
                currentDirectory: currentDirectory
            ),
            filterPrefix: decodeShellPath(unquoted),
            insertionPrefix: quotePrefix,
            quoteSuffix: quoteSuffix,
            foldersOnly: foldersOnly
        )
    }

    private static func resolveDirectory(
        _ token: String,
        currentDirectory: String?
    ) -> String {
        if token.hasPrefix("/") || token == "~" || token.hasPrefix("~/") {
            return normalizePath(token)
        }
        guard let currentDirectory,
              !currentDirectory.isEmpty
        else {
            return normalizePath(token.isEmpty ? "." : token)
        }
        let separator = currentDirectory.hasSuffix("/") ? "" : "/"
        return normalizePath(currentDirectory + separator + token)
    }

    private static func normalizePath(_ input: String) -> String {
        guard !input.isEmpty else {
            return "."
        }
        let leadingSlash = input.hasPrefix("/")
        let tildeRoot = input == "~" || input.hasPrefix("~/")
        let trailingSlash = input.count > 1 && input.hasSuffix("/")
        let fixedSegments = tildeRoot ? 1 : 0
        let raw: Substring
        if leadingSlash {
            raw = input.dropFirst()
        } else if tildeRoot {
            raw = input.dropFirst(2)
        } else {
            raw = Substring(input)
        }
        var segments = tildeRoot ? ["~"] : []
        for segment in raw.split(separator: "/") {
            if segment == "." {
                continue
            }
            if segment == ".." {
                if segments.count > fixedSegments,
                   segments.last != ".."
                {
                    segments.removeLast()
                } else if !leadingSlash || tildeRoot {
                    segments.append("..")
                }
            } else {
                segments.append(String(segment))
            }
        }

        var result: String
        if leadingSlash {
            result = "/" + segments.joined(separator: "/")
        } else if !segments.isEmpty {
            result = segments.joined(separator: "/")
        } else {
            result = tildeRoot ? "~" : "."
        }
        if trailingSlash,
           result != "/",
           result != ".",
           result != "~"
        {
            result += "/"
        } else if trailingSlash, result == "~" {
            result = "~/"
        }
        return result
    }

    private static func shellEscape(_ value: String) -> String {
        guard value.range(
            of: #"[\\$'"|!<>;#~` ]"#,
            options: .regularExpression
        ) != nil else {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func decodeShellPath(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped {
            result.append("\\")
        }
        return result
    }

    private static func leadingQuote(_ value: String) -> String {
        value.hasPrefix("\"") || value.hasPrefix("'")
            ? String(value.prefix(1))
            : ""
    }

    private static func trailingMatchingQuote(
        _ value: String,
        quotePrefix: String
    ) -> String {
        !quotePrefix.isEmpty && value.hasSuffix(quotePrefix)
            ? quotePrefix
            : ""
    }

    private static func stripWrappingQuotes(_ value: String) -> String {
        var result = value
        if result.hasPrefix("\"") || result.hasPrefix("'") {
            result.removeFirst()
        }
        if result.hasSuffix("\"") || result.hasSuffix("'") {
            result.removeLast()
        }
        return result
    }

    private static func compareEntries(
        _ first: TerminalAutocompleteDirectoryEntry,
        _ second: TerminalAutocompleteDirectoryEntry
    ) -> Bool {
        let firstRank = rank(first.kind)
        let secondRank = rank(second.kind)
        if firstRank != secondRank {
            return firstRank < secondRank
        }
        return first.name.localizedCaseInsensitiveCompare(second.name)
            == .orderedAscending
    }

    private static func rank(
        _ kind: TerminalAutocompleteDirectoryEntry.Kind
    ) -> Int {
        switch kind {
        case .directory:
            0
        case .symlink:
            1
        case .file:
            2
        }
    }
}
