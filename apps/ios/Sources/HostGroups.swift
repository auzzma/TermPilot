import Foundation

struct MobileHostGroupNode {
  let id: String
  let name: String
  let children: [MobileHostGroupNode]
  var descendants: Set<String> { children.reduce(into: Set([id])) { $0.formUnion($1.descendants) } }
}
struct MobileHostTreeRow: Identifiable {
  let id: String
  let depth: Int
  var group: MobileHostGroupNode? = nil
  var host: JSON? = nil
  var count = 0
  var expanded = false
}
enum MobileHostGroups {
  static func tree(_ records: [JSON]) -> [MobileHostGroupNode] {
    var seen = Set<String>()
    let sorted = records.enumerated().filter { !$0.element.text("id").isEmpty }
      .sorted { a, b in
        let left = a.element.number("sortOrder", a.offset)
        let right = b.element.number("sortOrder", b.offset)
        if left != right { return left < right }
        return a.element.text("name").localizedCaseInsensitiveCompare(b.element.text("name")) == .orderedAscending
      }.map(\.element)
    let known = Set(sorted.map { $0.text("id") })
    func node(_ group: JSON) -> MobileHostGroupNode {
      let id = group.text("id")
      seen.insert(id)
      var children = [MobileHostGroupNode]()
      for child in sorted where child.text("parentGroupID") == id && !seen.contains(child.text("id")) {
        children.append(node(child))
      }
      return MobileHostGroupNode(id: id, name: group.text("name"), children: children)
    }
    var roots = [MobileHostGroupNode]()
    for group in sorted where !known.contains(group.text("parentGroupID")) && !seen.contains(group.text("id")) { roots.append(node(group)) }
    for group in sorted where !seen.contains(group.text("id")) { roots.append(node(group)) }
    return roots
  }
  static func options(_ nodes: [MobileHostGroupNode], prefix: String = "") -> [(id: String, name: String)] {
    nodes.flatMap { node in
      let path = prefix.isEmpty ? node.name : prefix + " / " + node.name
      return [(node.id, path)] + options(node.children, prefix: path)
    }
  }
  static func excluded(_ id: String, in nodes: [MobileHostGroupNode]) -> Set<String> {
    nodes.reduce(into: Set<String>()) { result, node in
      result.formUnion(node.id == id ? node.descendants : excluded(id, in: node.children))
    }
  }
  static func rows(_ roots: [MobileHostGroupNode], hosts: [String: [JSON]], collapsed: Set<String>, search: String) -> [MobileHostTreeRow] {
    var rows = [MobileHostTreeRow]()
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    func contains(_ value: String) -> Bool { value.localizedCaseInsensitiveContains(query) }
    func hostMatches(_ host: JSON) -> Bool { contains(host.text("label") + " " + host.text("hostname")) }
    func count(_ node: MobileHostGroupNode) -> Int { (hosts[node.id]?.count ?? 0) + node.children.reduce(0) { $0 + count($1) } }
    func matches(_ node: MobileHostGroupNode) -> Bool { contains(node.name) || (hosts[node.id] ?? []).contains(where: hostMatches) || node.children.contains(where: matches) }
    func append(_ node: MobileHostGroupNode, _ depth: Int, _ parentMatches: Bool) {
      let all = parentMatches || (!query.isEmpty && contains(node.name))
      if !query.isEmpty && !all && !matches(node) { return }
      let expanded = !query.isEmpty || !collapsed.contains(node.id)
      rows.append(MobileHostTreeRow(id: "group-" + node.id, depth: depth, group: node, count: count(node), expanded: expanded))
      if expanded {
        node.children.forEach { append($0, depth + 1, all) }
        for host in hosts[node.id] ?? [] where query.isEmpty || all || hostMatches(host) {
          rows.append(MobileHostTreeRow(id: "host-" + host.text("id"), depth: depth + 1, host: host))
        }
      }
    }
    roots.forEach { append($0, 0, false) }
    return rows
  }
}
