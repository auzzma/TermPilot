import Foundation
import TermPilotDomain

let batchCheckStages = ["authenticate", "elevation", "finished"]
let batchCheckEventStages = ["connect"] + batchCheckStages

struct BatchCheckHost: Identifiable {
    var id: String
    var event: BatchEvent
}
struct BatchCheckGroup: Identifiable {
    var id: String
    var hosts: [BatchCheckHost]
    var counts: [String: Int]
    var indicator: String
}
func batchCheckGroups(_ events: [BatchEvent], running: Bool) -> [BatchCheckGroup] {
    var hosts: [String: [String: BatchEvent]] = [:]
    for event in events where event.text("type") == "batchHost" && !event.text("targetId").isEmpty && batchCheckEventStages.contains(event.text("stage")) {
        hosts[event.text("targetId"), default: [:]][event.text("stage")] = event
    }
    let priority = ["failed", "unknown", "cancelled", "running", "pending", "skipped", "success"]
    return batchCheckStages.map { stage in
        let rows = hosts.map { id, stages -> BatchCheckHost in
            let last = stages["finished"]
            let base = stages["authenticate"] ?? stages["connect"] ?? last
            var result = stages[stage] ?? (stage == "authenticate" ? stages["connect"] : nil)
            if stage == "authenticate", result == nil || ["pending", "running"].contains(result?.text("status") ?? ""), let last { result = last }
            if stage == "elevation", result == nil, let last {
                result = last
                if stages["authenticate"]?.text("status") != "success" && last.text("status") != "success" {
                    result?.value["status"] = "skipped"
                    result?.value["message"] = "Authentication did not succeed; elevation was not checked."
                }
            }
            var value = (base?.value ?? [:]).merging(result?.value ?? [:]) { _, new in new }
            var status = result?.text("status") ?? "pending"
            if !running && ["pending", "running"].contains(status) { status = "unknown" }
            value["type"] = "batchHost"; value["targetId"] = id; value["stage"] = stage; value["status"] = status
            return BatchCheckHost(id: id, event: BatchEvent(value: value))
        }.sorted { a, b in
            let lhs = priority.firstIndex(of: a.event.text("status")) ?? priority.count
            let rhs = priority.firstIndex(of: b.event.text("status")) ?? priority.count
            if lhs != rhs { return lhs < rhs }
            if a.event.text("ip") != b.event.text("ip") { return a.event.text("ip") < b.event.text("ip") }
            return a.id < b.id
        }
        let counts = Dictionary(uniqueKeysWithValues: priority.map { status in (status, rows.filter { $0.event.text("status") == status }.count) })
        let indicator: String
        if !rows.isEmpty && counts["success"] == rows.count { indicator = "success" }
        else if !rows.isEmpty && counts["failed"] == rows.count { indicator = "failed" }
        else if counts["success", default: 0] > 0 && counts["failed", default: 0] > 0 { indicator = "mixed" }
        else if counts["pending", default: 0] + counts["running", default: 0] > 0 { indicator = "running" }
        else { indicator = "neutral" }
        return BatchCheckGroup(id: stage, hosts: rows, counts: counts, indicator: indicator)
    }
}

func batchHostEndpoint(_ host: TermPilotDomain.Host) -> String { "\(host.hostname.lowercased()):\(host.port)" }
func batchSelectableHosts(_ hosts: [TermPilotDomain.Host]) -> [TermPilotDomain.Host] {
    var seen = Set<String>()
    return hosts.filter { $0.connectionKind == .ssh && seen.insert(batchHostEndpoint($0)).inserted }
}
func batchGroupHostIDs(_ id: UUID?, hosts: [TermPilotDomain.Host], groups: [HostGroup]) -> Set<UUID> {
    guard let id else { return Set(hosts.filter { host in !groups.contains { $0.id == host.groupID } }.map(\.id)) }
    var ids = Set([id]); var previous = -1
    while previous != ids.count {
        previous = ids.count
        for group in groups where group.parentGroupID.map({ ids.contains($0) }) == true { ids.insert(group.id) }
    }
    return Set(hosts.filter { $0.groupID.map { ids.contains($0) } == true }.map(\.id))
}
func batchGroupPath(_ id: UUID?, groups: [HostGroup]) -> String {
    var current = id; var names: [String] = []; var seen = Set<UUID>()
    while let id = current, seen.insert(id).inserted, let group = groups.first(where: { $0.id == id }) {
        names.insert(group.name, at: 0); current = group.parentGroupID
    }
    return names.joined(separator: " / ")
}
func batchToggleSelection(_ selected: Set<UUID>, ids: Set<UUID>, alreadyAdded: Set<UUID>) -> Set<UUID> {
    let available = ids.subtracting(alreadyAdded)
    return !available.isEmpty && available.isSubset(of: selected) ? selected.subtracting(available) : selected.union(available)
}

struct BatchHostTreeRow: Identifiable {
    var id: String
    var depth: Int
    var group: HostGroup?
    var host: TermPilotDomain.Host?
    var hostIDs: Set<UUID>
    var expanded = false
}

func batchMatchingHosts(_ hosts: [TermPilotDomain.Host], groups: [HostGroup], query: String) -> [TermPilotDomain.Host] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return hosts.filter { q.isEmpty || "\($0.label) \($0.hostname) \($0.username) \(batchGroupPath($0.groupID, groups: groups))".localizedCaseInsensitiveContains(q) }
}

func batchHostTreeRows(hosts: [TermPilotDomain.Host], groups: [HostGroup], query: String, expanded: Set<String>) -> [BatchHostTreeRow] {
    let matching = Set(batchMatchingHosts(hosts, groups: groups, query: query).map(\.id))
    var rows: [BatchHostTreeRow] = []
    var visited = Set<UUID>()
    func appendHosts(_ direct: [TermPilotDomain.Host], depth: Int) {
        for host in direct where matching.contains(host.id) {
            rows.append(BatchHostTreeRow(id: "host:\(host.id)", depth: depth, host: host, hostIDs: [host.id]))
        }
    }
    func append(_ node: HostGroupNode, depth: Int) {
        guard visited.insert(node.id).inserted else { return }
        let ids = batchGroupHostIDs(node.id, hosts: hosts, groups: groups)
        guard !ids.isDisjoint(with: matching) else { return }
        let key = node.id.uuidString
        rows.append(BatchHostTreeRow(id: key, depth: depth, group: node.group, hostIDs: ids, expanded: expanded.contains(key)))
        guard expanded.contains(key) else { return }
        appendHosts(hosts.filter { $0.groupID == node.id }, depth: depth + 1)
        for child in node.children { append(child, depth: depth + 1) }
    }
    for node in HostGroupHierarchy.roots(from: groups) { append(node, depth: 0) }
    let ungrouped = batchGroupHostIDs(nil, hosts: hosts, groups: groups)
    if !ungrouped.isDisjoint(with: matching) {
        rows.append(BatchHostTreeRow(id: "ungrouped", depth: 0, hostIDs: ungrouped, expanded: expanded.contains("ungrouped")))
        if expanded.contains("ungrouped") { appendHosts(hosts.filter { ungrouped.contains($0.id) }, depth: 1) }
    }
    return rows
}
