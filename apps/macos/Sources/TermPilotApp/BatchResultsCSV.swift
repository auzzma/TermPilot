import SwiftUI
import UniformTypeIdentifiers

enum BatchCSVScope: String, CaseIterable {
    case all, failed, success

    var title: String {
        switch self {
        case .all: "Export all hosts"
        case .failed: "Export failed hosts"
        case .success: "Export successful hosts"
        }
    }

    func includes(_ host: BatchHostResult) -> Bool {
        self == .all || host.status == rawValue
    }
}

struct BatchResultsCSV: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    let data: Data

    init(hosts: [BatchHostResult], scope: BatchCSVScope, localize: (String) -> String = AppLocalization.string) {
        let headers = scope == .success ? ["Host IP", "Status"] : ["Host IP", "Status", "Failure reason"]
        var csv = Self.line(headers.map(localize))
        for host in hosts where scope.includes(host) {
            var fields = [host.ip, localize(host.status)]
            if scope != .success {
                fields.append(Self.failureReason(host, localize: localize))
            }
            csv += Self.line(fields)
        }
        data = Data(("\u{FEFF}" + csv).utf8)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    private static func failureReason(_ host: BatchHostResult, localize: (String) -> String) -> String {
        guard host.status == "failed" else { return "" }
        var lines: [String] = []
        var seen = Set<String>()
        for event in host.failedSteps + [host.final].compactMap({ $0 }) {
            var details = ["message", "error"].map { event.text($0) }.filter { !$0.isEmpty }.map(localize)
            details.append(event.text("stderr"))
            if let code = event.value["exitCode"] as? Int, code != 0 {
                details.append("\(localize("Exit code")) \(code)")
            }
            let stage = event.text("stage")
            details = details.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if stage == "finished" { details.removeAll(where: seen.contains) }
            seen.formUnion(details)
            if details.isEmpty { continue }
            let prefix = stage == "finished" ? "" : localize(stage) + " · "
            let line = prefix + details.joined(separator: "\n")
            if !lines.contains(line) { lines.append(line) }
        }
        if lines.isEmpty {
            let stages = host.failedSteps.map { localize($0.text("stage")) }
            return (stages + [localize("No failure details recorded.")]).joined(separator: " · ")
        }
        return lines.joined(separator: "\n")
    }

    private static func line(_ fields: [String]) -> String {
        fields.map { field in
            // Remote diagnostics and host names are spreadsheet text, even when they start with a formula.
            let first = field.trimmingCharacters(in: .whitespacesAndNewlines).first
            let value = first.map { "=+-@".contains($0) } == true ? "'" + field : field
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",") + "\r\n"
    }
}
