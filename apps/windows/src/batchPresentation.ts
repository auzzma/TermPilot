import type { BatchEvent } from "./batch";
import type { Host, HostGroup } from "./types";
import { buildHostGroupTree } from "./components/Sidebar";

export const checkStages = ["authenticate", "elevation", "finished"] as const;
export const checkEventStages = ["connect", ...checkStages];
export function updateChecks(checks: Record<string, BatchEvent>, event: BatchEvent) {
  if (event.type !== "batchHost" || !event.targetId || !checkEventStages.includes(event.stage ?? "")) return checks;
  return { ...checks, [`${event.targetId}:${event.stage}`]: event };
}
export function checkGroups(events: BatchEvent[], running: boolean) {
  const hosts = new Map<string, Record<string, BatchEvent>>();
  for (const event of events) {
    if (event.type !== "batchHost" || !event.targetId || !checkEventStages.includes(event.stage ?? "")) continue;
    const stages = hosts.get(event.targetId) ?? {};
    stages[event.stage!] = event;
    hosts.set(event.targetId, stages);
  }
  const priority = ["failed", "unknown", "cancelled", "running", "pending", "skipped", "success"];
  return checkStages.map(stage => {
    const rows = [...hosts.entries()].map(([targetId, stages]) => {
      const last = stages.finished;
      const base = stages.authenticate ?? stages.connect ?? last;
      let result = stages[stage] ?? (stage === "authenticate" ? stages.connect : undefined);
      if (stage === "authenticate" && (!result || ["pending", "running"].includes(result.status ?? "")) && last) {
        result = { ...last, status: last.status === "success" ? "success" : last.status };
      }
      if (stage === "elevation" && !result && last) {
        const authenticated = stages.authenticate?.status === "success" || last.status === "success";
        result = { ...last, status: !authenticated ? "skipped" : last.status === "failed" ? "failed" : last.status };
        if (!authenticated) result.message = "Authentication did not succeed; elevation was not checked.";
      }
      let status = result?.status ?? "pending";
      if (!running && ["pending", "running"].includes(status)) status = "unknown";
      return { ...base, ...result, type: "batchHost", targetId, stage, status } as BatchEvent;
    }).sort((a, b) => priority.indexOf(a.status ?? "") - priority.indexOf(b.status ?? "") || (a.ip ?? "").localeCompare(b.ip ?? "") || a.targetId!.localeCompare(b.targetId!));
    const counts = Object.fromEntries(priority.map(status => [status, rows.filter(r => r.status === status).length]));
    const indicator = rows.length && counts.success === rows.length ? "success"
      : rows.length && counts.failed === rows.length ? "failed"
      : counts.success && counts.failed ? "mixed"
      : counts.running || counts.pending ? "running" : "neutral";
    return { stage, rows, counts, indicator };
  });
}

export function hostEndpoint(host: Host) { return `${host.hostname.toLowerCase()}:${host.port}`; }
export function selectableHosts(hosts: Host[]) {
  const seen = new Set<string>();
  return hosts.filter(host => {
    if (host.connectionKind && host.connectionKind !== "ssh") return false;
    const endpoint = hostEndpoint(host);
    if (seen.has(endpoint)) return false;
    seen.add(endpoint);
    return true;
  });
}
export function groupHostIds(groupId: string | undefined, hosts: Host[], groups: HostGroup[]) {
  if (!groupId) return hosts.filter(h => !h.groupId || !groups.some(g => g.id === h.groupId)).map(h => h.id);
  const ids = new Set([groupId]);
  let previous = -1;
  while (previous !== ids.size) {
    previous = ids.size;
    for (const group of groups) if (group.parentGroupId && ids.has(group.parentGroupId)) ids.add(group.id);
  }
  return hosts.filter(h => h.groupId && ids.has(h.groupId)).map(h => h.id);
}
export function groupPath(id: string | undefined, groups: HostGroup[]) {
  const names: string[] = [], seen = new Set<string>();
  while (id && !seen.has(id)) {
    seen.add(id);
    const group = groups.find(g => g.id === id);
    if (!group) break;
    names.unshift(group.name); id = group.parentGroupId;
  }
  return names.join(" / ");
}
export function toggleSelection(selected: Set<string>, ids: string[], alreadyAdded: Set<string>) {
  const available = ids.filter(id => !alreadyAdded.has(id));
  const remove = available.length > 0 && available.every(id => selected.has(id));
  const next = new Set(selected);
  available.forEach(id => remove ? next.delete(id) : next.add(id));
  return next;
}

export interface BatchHostTreeRow {
  id: string; depth: number; group?: HostGroup; host?: Host; hostIds: string[]; expanded?: boolean;
}
export function matchingHosts(hosts: Host[], groups: HostGroup[], query: string) {
  const q = query.trim().toLocaleLowerCase();
  return hosts.filter(h => `${h.label} ${h.hostname} ${h.username} ${groupPath(h.groupId, groups)}`.toLocaleLowerCase().includes(q));
}
export function hostTreeRows(hosts: Host[], groups: HostGroup[], query: string, expanded: Set<string>) {
  const matching = new Set(matchingHosts(hosts, groups, query).map(h => h.id));
  const rows: BatchHostTreeRow[] = [], visited = new Set<string>();
  function appendHosts(direct: Host[], depth: number) {
    for (const host of direct) if (matching.has(host.id)) rows.push({id:`host:${host.id}`,depth,host,hostIds:[host.id]});
  }
  function append(node: ReturnType<typeof buildHostGroupTree>[number], depth: number) {
    if (visited.has(node.group.id)) return;
    visited.add(node.group.id);
    const ids = groupHostIds(node.group.id, hosts, groups);
    if (!ids.some(id => matching.has(id))) return;
    const open = expanded.has(node.group.id);
    rows.push({id:node.group.id,depth,group:node.group,hostIds:ids,expanded:open});
    if (!open) return;
    appendHosts(hosts.filter(h => h.groupId === node.group.id), depth + 1);
    node.children.forEach(child => append(child, depth + 1));
  }
  buildHostGroupTree(groups).forEach(node => append(node, 0));
  const ungrouped = groupHostIds(undefined, hosts, groups);
  if (ungrouped.some(id => matching.has(id))) {
    rows.push({id:'ungrouped',depth:0,hostIds:ungrouped,expanded:expanded.has('ungrouped')});
    if (expanded.has('ungrouped')) appendHosts(hosts.filter(h => ungrouped.includes(h.id)), 1);
  }
  return rows;
}
