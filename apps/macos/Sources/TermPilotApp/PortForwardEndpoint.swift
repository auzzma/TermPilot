import Foundation

struct PortForwardEndpoint: Equatable {
    var host: String
    var port: Int

    var text: String {
        "\(host):\(port)"
    }

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    static func parse(_ value: String) -> PortForwardEndpoint? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.lastIndex(of: ":"),
              separator > trimmed.startIndex,
              separator < trimmed.index(before: trimmed.endIndex)
        else {
            return nil
        }

        let host = trimmed[..<separator]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = trimmed[trimmed.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")

        guard !host.isEmpty,
              let port = Int(portText),
              (1 ... 65_535).contains(port)
        else {
            return nil
        }

        return PortForwardEndpoint(host: host, port: port)
    }
}
