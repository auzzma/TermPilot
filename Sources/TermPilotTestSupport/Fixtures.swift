import Foundation
import TermPilotDomain

public enum Fixtures {
    public static func host(
        id: UUID = UUID(),
        label: String = "Development",
        hostname: String = "dev.example.com",
        authentication: AuthenticationMethod = .agent
    ) -> TermPilotDomain.Host {
        TermPilotDomain.Host(
            id: id,
            label: label,
            hostname: hostname,
            username: "pilot",
            authentication: authentication
        )
    }

    public static func localSession(id: UUID = UUID()) -> SessionDescriptor {
        SessionDescriptor(
            id: id,
            kind: .local,
            title: "zsh",
            shell: "/bin/zsh"
        )
    }
}
