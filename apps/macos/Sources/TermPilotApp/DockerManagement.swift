import Foundation
import TermPilotDomain

struct DockerContainerRow: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var image: String
    var status: String
    var state: String
    var ports: String

    var isPaused: Bool {
        state == "paused"
            || status.localizedCaseInsensitiveContains("paused")
    }

    var isRunning: Bool {
        !isPaused
            && (
                state == "running"
                    || status.localizedCaseInsensitiveContains("up")
            )
    }
}

struct DockerImageRow: Equatable, Identifiable, Sendable {
    var id: String { "\(imageID)\u{1f}\(repository)\u{1f}\(tag)" }
    var imageID: String
    var repository: String
    var tag: String
    var size: String
    var createdAt: String
    var name: String

    var displayName: String {
        if !repository.isEmpty, repository != "<none>",
           !tag.isEmpty, tag != "<none>"
        {
            return "\(repository):\(tag)"
        }
        return name.isEmpty ? String(imageID.prefix(12)) : name
    }

    var isDangling: Bool {
        repository == "<none>" || tag == "<none>"
    }
}

enum DockerContainerAction: String, Sendable {
    case start
    case stop
    case restart
    case pause
    case unpause
    case kill
    case remove
    case rename
}

enum DockerInspectKind: Sendable {
    case container
    case image
}

struct DockerInspectField: Equatable, Identifiable, Sendable {
    var id: String { label }
    var label: String
    var value: String
    var monospaced: Bool
}

struct DockerInspectList: Equatable, Identifiable, Sendable {
    var id: String { label }
    var label: String
    var values: [String]
}

struct DockerInspectDetails: Equatable, Sendable {
    var kind: DockerInspectKind
    var fields: [DockerInspectField]
    var lists: [DockerInspectList]
    var rawJSON: String
}

enum DockerManagement {
    static func sanitizeID(_ value: String) -> String? {
        let normalized = value.hasPrefix("sha256:")
            ? String(value.dropFirst(7))
            : value
        let safe = normalized
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            .prefix(64)
        return safe.isEmpty ? nil : String(safe)
    }

    static func containerCommand(
        id: String,
        action: DockerContainerAction,
        newName: String? = nil
    ) -> String? {
        guard let safeID = sanitizeID(id) else {
            return nil
        }
        switch action {
        case .start, .stop, .restart, .pause, .unpause, .kill:
            return "docker \(action.rawValue) \(safeID)"
        case .remove:
            return "docker rm -f \(safeID)"
        case .rename:
            guard let safeName = sanitizeContainerName(newName) else {
                return nil
            }
            return "docker rename \(safeID) \(shellQuote(safeName))"
        }
    }

    static func imageRemoveCommand(
        id: String,
        force: Bool
    ) -> String? {
        guard let safeID = sanitizeID(id) else {
            return nil
        }
        return "docker rmi\(force ? " -f" : "") \(safeID)"
    }

    static func imagePruneCommand(all: Bool) -> String {
        "docker image prune\(all ? " -a" : "") -f"
    }

    static func imageTagCommand(
        id: String,
        repository: String,
        tag: String
    ) -> String? {
        guard let safeID = sanitizeID(id) else {
            return nil
        }
        let repository = repository
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repository.isEmpty,
              repository.count <= 256,
              !repository.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        let trimmedTag = tag
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTag = trimmedTag.isEmpty ? "latest" : trimmedTag
        guard effectiveTag.count <= 128,
              !effectiveTag.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            return nil
        }
        return "docker tag \(safeID) \(shellQuote("\(repository):\(effectiveTag)"))"
    }

    static func interactiveShellCommand(
        containerID: String,
        elevationMethod: ServerToolsElevationMethod? = nil
    ) -> String? {
        guard let safeID = sanitizeID(containerID) else {
            return nil
        }
        let shellProbe =
            "command -v bash >/dev/null 2>&1 && exec bash || exec sh"
        return interactiveCommand(
            dockerArguments:
                "exec -it \(safeID) sh -c \(shellQuote(shellProbe))",
            elevationMethod: elevationMethod
        )
    }

    static func logsCommand(
        containerID: String,
        elevationMethod: ServerToolsElevationMethod? = nil
    ) -> String? {
        guard let safeID = sanitizeID(containerID) else {
            return nil
        }
        return interactiveCommand(
            dockerArguments: "logs -f --tail 200 \(safeID)",
            elevationMethod: elevationMethod
        )
    }

    static func inspectCommand(
        id: String,
        kind: DockerInspectKind
    ) -> String? {
        guard let safeID = sanitizeID(id) else {
            return nil
        }
        switch kind {
        case .container:
            return "docker inspect \(safeID)"
        case .image:
            return "docker image inspect \(safeID)"
        }
    }

    static func parseInspect(
        _ output: String,
        kind: DockerInspectKind
    ) -> DockerInspectDetails? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = inspectRoot(object)
        else {
            return nil
        }
        let rawData = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        let rawJSON = rawData.flatMap {
            String(data: $0, encoding: .utf8)
        } ?? output

        switch kind {
        case .container:
            return containerInspect(root, rawJSON: rawJSON)
        case .image:
            return imageInspect(root, rawJSON: rawJSON)
        }
    }

    private static func interactiveCommand(
        dockerArguments: String,
        elevationMethod: ServerToolsElevationMethod?
    ) -> String {
        let script = [
            "printf '\\033[H\\033[2J\\033[3J';",
            "exec docker \(dockerArguments)",
        ].joined(separator: " ")
        let command = "sh -c \(shellQuote(script))"
        switch elevationMethod {
        case .sudo:
            return "sudo -H -S -k -p '[sudo] Password:' \(command)"
        case .su:
            return "su - root -c \(shellQuote(command))"
        case nil:
            return command
        }
    }

    private static func sanitizeContainerName(
        _ value: String?
    ) -> String? {
        let trimmed = (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(128)
        let safe = trimmed.filter {
            $0.isASCII
                && ($0.isLetter || $0.isNumber || "_.-".contains($0))
        }
        return safe.isEmpty ? nil : String(safe)
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func inspectRoot(
        _ object: Any
    ) -> [String: Any]? {
        if let rows = object as? [[String: Any]] {
            return rows.first
        }
        return object as? [String: Any]
    }

    private static func containerInspect(
        _ root: [String: Any],
        rawJSON: String
    ) -> DockerInspectDetails {
        var fields: [DockerInspectField] = []
        appendField(
            "ID",
            shortID(string(root["Id"])),
            monospaced: true,
            to: &fields
        )
        appendField(
            "Status",
            string(at: ["State", "Status"], in: root),
            to: &fields
        )
        appendField(
            "Image",
            string(at: ["Config", "Image"], in: root),
            monospaced: true,
            to: &fields
        )
        appendField("Created", string(root["Created"]), to: &fields)
        appendField(
            "Started",
            string(at: ["State", "StartedAt"], in: root),
            to: &fields
        )
        appendField(
            "Restart Policy",
            string(at: ["HostConfig", "RestartPolicy", "Name"], in: root),
            to: &fields
        )
        let command = (
            [string(root["Path"])]
                + stringArray(root["Args"])
        )
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        appendField("Command", command, monospaced: true, to: &fields)

        return DockerInspectDetails(
            kind: .container,
            fields: fields,
            lists: [
                DockerInspectList(
                    label: "Ports",
                    values: containerPorts(root)
                ),
                DockerInspectList(
                    label: "Networks",
                    values: dictionaryKeys(
                        value(at: ["NetworkSettings", "Networks"], in: root)
                    )
                ),
                DockerInspectList(
                    label: "Mounts",
                    values: mounts(root["Mounts"])
                ),
                DockerInspectList(
                    label: "Environment",
                    values: stringArray(
                        value(at: ["Config", "Env"], in: root)
                    )
                ),
                DockerInspectList(
                    label: "Labels",
                    values: dictionaryEntries(
                        value(at: ["Config", "Labels"], in: root)
                    )
                ),
            ].filter { !$0.values.isEmpty },
            rawJSON: rawJSON
        )
    }

    private static func imageInspect(
        _ root: [String: Any],
        rawJSON: String
    ) -> DockerInspectDetails {
        var fields: [DockerInspectField] = []
        appendField(
            "ID",
            shortID(string(root["Id"])),
            monospaced: true,
            to: &fields
        )
        appendField(
            "Size",
            formattedByteCount(root["Size"]),
            to: &fields
        )
        let platform = [
            string(root["Os"]),
            string(root["Architecture"]),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "/")
        appendField("Platform", platform, monospaced: true, to: &fields)
        appendField("Created", string(root["Created"]), to: &fields)
        appendField(
            "Entrypoint",
            stringArray(value(at: ["Config", "Entrypoint"], in: root))
                .joined(separator: " "),
            monospaced: true,
            to: &fields
        )
        appendField(
            "CMD",
            stringArray(value(at: ["Config", "Cmd"], in: root))
                .joined(separator: " "),
            monospaced: true,
            to: &fields
        )
        appendField(
            "Working Directory",
            string(at: ["Config", "WorkingDir"], in: root),
            monospaced: true,
            to: &fields
        )

        return DockerInspectDetails(
            kind: .image,
            fields: fields,
            lists: [
                DockerInspectList(
                    label: "Tags",
                    values: stringArray(root["RepoTags"])
                ),
                DockerInspectList(
                    label: "Digests",
                    values: stringArray(root["RepoDigests"])
                ),
                DockerInspectList(
                    label: "Exposed Ports",
                    values: dictionaryKeys(
                        value(at: ["Config", "ExposedPorts"], in: root)
                    )
                ),
                DockerInspectList(
                    label: "Environment",
                    values: stringArray(
                        value(at: ["Config", "Env"], in: root)
                    )
                ),
                DockerInspectList(
                    label: "Labels",
                    values: dictionaryEntries(
                        value(at: ["Config", "Labels"], in: root)
                    )
                ),
            ].filter { !$0.values.isEmpty },
            rawJSON: rawJSON
        )
    }

    private static func appendField(
        _ label: String,
        _ value: String,
        monospaced: Bool = false,
        to fields: inout [DockerInspectField]
    ) {
        guard !value.isEmpty else {
            return
        }
        fields.append(
            DockerInspectField(
                label: label,
                value: value,
                monospaced: monospaced
            )
        )
    }

    private static func value(
        at path: [String],
        in root: [String: Any]
    ) -> Any? {
        var current: Any = root
        for key in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key]
            else {
                return nil
            }
            current = next
        }
        return current
    }

    private static func string(
        at path: [String],
        in root: [String: Any]
    ) -> String {
        string(value(at: path, in: root))
    }

    private static func string(_ value: Any?) -> String {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return ""
        }
    }

    private static func stringArray(_ value: Any?) -> [String] {
        guard let values = value as? [Any] else {
            let single = string(value)
            return single.isEmpty ? [] : [single]
        }
        return values.map(string).filter { !$0.isEmpty }
    }

    private static func dictionaryKeys(_ value: Any?) -> [String] {
        guard let dictionary = value as? [String: Any] else {
            return []
        }
        return dictionary.keys.sorted()
    }

    private static func dictionaryEntries(_ value: Any?) -> [String] {
        guard let dictionary = value as? [String: Any] else {
            return []
        }
        return dictionary.keys.sorted().map {
            "\($0)=\(string(dictionary[$0]))"
        }
    }

    private static func mounts(_ value: Any?) -> [String] {
        guard let values = value as? [[String: Any]] else {
            return []
        }
        return values.compactMap {
            let source = string($0["Source"])
            let destination = string($0["Destination"])
            guard !destination.isEmpty else {
                return nil
            }
            return source.isEmpty
                ? destination
                : "\(source) -> \(destination)"
        }
    }

    private static func containerPorts(
        _ root: [String: Any]
    ) -> [String] {
        guard let ports = value(
                  at: ["NetworkSettings", "Ports"],
                  in: root
              ) as? [String: Any]
        else {
            return []
        }
        return ports.keys.sorted().map { port in
            guard let bindings = ports[port] as? [[String: Any]],
                  !bindings.isEmpty
            else {
                return port
            }
            let targets: [String] = bindings.compactMap { binding -> String? in
                let hostPort = string(binding["HostPort"])
                guard !hostPort.isEmpty else {
                    return nil
                }
                let hostIP = string(binding["HostIp"])
                return hostIP.isEmpty
                    ? hostPort
                    : "\(hostIP):\(hostPort)"
            }
            return targets.isEmpty
                ? port
                : "\(port) -> \(targets.joined(separator: ", "))"
        }
    }

    private static func shortID(_ value: String) -> String {
        let normalized = value.hasPrefix("sha256:")
            ? String(value.dropFirst(7))
            : value
        return String(normalized.prefix(12))
    }

    private static func formattedByteCount(_ value: Any?) -> String {
        guard let number = value as? NSNumber else {
            return string(value)
        }
        return ByteCountFormatter.string(
            fromByteCount: number.int64Value,
            countStyle: .file
        )
    }
}
