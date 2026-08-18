import TermPilotDomain

enum PortForwardOpenSSHArguments {
    static func forwardingArguments(for rule: PortForwardRule) -> [String] {
        var arguments = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
        ]

        switch rule.kind {
        case .local:
            let remotePort = rule.remotePort ?? rule.localPort
            arguments += [
                "-L",
                "\(rule.bindAddress):\(rule.localPort):\(rule.remoteHost):\(remotePort)",
            ]
        case .remote:
            let remotePort = rule.remotePort ?? rule.localPort
            arguments += [
                "-R",
                "\(rule.remoteHost):\(remotePort):\(rule.bindAddress):\(rule.localPort)",
            ]
        case .dynamic:
            arguments += [
                "-D",
                "\(rule.bindAddress):\(rule.localPort)",
            ]
        }

        return arguments
    }
}
