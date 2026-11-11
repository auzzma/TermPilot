import Foundation
import TermPilotDomain

struct BatchSavedConfiguration: Codable {
    var version = 1
    var job: BatchJob
    var targets: [Target]
    var defaults: Defaults

    struct Defaults: Codable {
        var ips: String
        var port: Int
        var credential: String
        var elevation: String
    }
    struct Target: Codable {
        var id: UUID
        var savedHostId: UUID?
        var label: String
        var hostname: String
        var port: Int
        var username: String
        var credentialId: UUID?
        var proxyProfileId: UUID?
        var elevation: String
    }

    @MainActor init(_ controller: BatchJobController, hosts: [TermPilotDomain.Host]) {
        job = controller.job
        job.remoteWorkDirectory = ""
        job.sourceTaskId = ""
        targets = controller.targets.map { target in
            Target(id: target.id, savedHostId: target.savedHostID ?? hosts.first(where: { $0.id == target.id })?.id,
                label: target.host.label, hostname: target.host.hostname, port: target.host.port,
                username: target.host.username, credentialId: target.host.credentialID,
                proxyProfileId: target.host.proxyProfileID, elevation: target.elevation)
        }
        let d = controller.targetDefaults
        defaults = Defaults(ips: d.ipList, port: d.port, credential: d.credentialID?.uuidString ?? "", elevation: d.elevation)
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    @MainActor func apply(to controller: BatchJobController, hosts: [TermPilotDomain.Host]) {
        controller.job = job
        controller.job.remoteWorkDirectory = ""
        controller.job.sourceTaskId = ""
        controller.targets = targets.map { target in
            var host = target.savedHostId.flatMap { id in hosts.first { $0.id == id } }
                ?? TermPilotDomain.Host(id: target.id, label: target.label, hostname: target.hostname, port: target.port,
                        username: target.username, authentication: .password)
            // Keep the saved endpoint visible. A changed/deleted reference is checked before execution.
            host.id = target.id; host.hostname = target.hostname; host.port = target.port
            if target.credentialId != nil { host.username = "" }
            host.credentialID = target.credentialId
            host.proxyProfileID = target.proxyProfileId
            return BatchTarget(host: host, elevation: target.elevation, savedHostID: target.savedHostId)
        }
        controller.targetDefaults = BatchTargetDefaults(ipList: defaults.ips, port: defaults.port,
            credentialID: UUID(uuidString: defaults.credential), elevation: defaults.elevation)
        controller.section = "configuration"
    }
}

struct BatchDraftDocument: Codable {
    var version = 1
    var tabs: [Tab]
    var selected: UUID
    struct Tab: Codable {
        var id: UUID
        var name: String?
        var number: Int
        var savedId: UUID?
        var savedRevision: Int?
        var configuration: String
    }
}
