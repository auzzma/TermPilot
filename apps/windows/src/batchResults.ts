import type { BatchEvent } from "./batch";
import { checkGroups } from "./batchPresentation";

export function stepKey(event: BatchEvent) {
  return JSON.stringify([event.targetId, event.stage, event.stepId || event.remotePath || ""]);
}
export function updateSteps(steps: Record<string, BatchEvent>, event: BatchEvent) {
  if (event.type !== "batchHost" || !event.targetId || !event.stage) return steps;
  const key = stepKey(event);
  return { ...steps, [key]: { ...steps[key], ...event } };
}
const order = ["authenticate", "elevation", "workspace", "prepare", "execute", "upload", "collect", "collection", "cleanup"];
const failures: Record<string, string> = { authenticate: "Authentication failed", elevation: "Elevation failed", workspace: "Workspace failed", prepare: "Preparation failed", execute: "Execution failed", upload: "Upload failed", collect: "Collection failed", collection: "Collection failed", cleanup: "Cleanup failed" };
export interface BatchHostResult {
  ip: string; failedSteps: BatchEvent[];
  id: string; endpoint: string; status: string; label: string; authentication: BatchEvent; elevation: BatchEvent;
  steps: BatchEvent[]; information: BatchEvent[]; final?: BatchEvent; hasFailure: boolean;
}
export function hostResults(events: BatchEvent[], running: boolean): BatchHostResult[] {
  const latest = Object.values(events.reduce(updateSteps, {}));
  const checks = checkGroups(latest, running);
  const hosts = new Map<string, BatchEvent[]>();
  for (const event of latest) hosts.set(event.targetId!, [...(hosts.get(event.targetId!) ?? []), event]);
  return [...hosts.entries()].map(([id, records]) => {
    const final = records.find(e => e.stage === "finished");
    const base = records.find(e => e.ip) ?? records[0];
    const normalize = (event: BatchEvent): BatchEvent => {
      if (final?.background && ["running", "unknown"].includes(final.status ?? "")) return event;
      if ((!running || final) && ["pending", "running"].includes(event.cleanupStatus ?? "")) event = { ...event, cleanupStatus: "unknown" };
      if (!["running", "pending"].includes(event.status ?? "") || (running && !final)) return event;
      const status = final && ["cancelled", "skipped"].includes(final.status ?? "") ? final.status
        : final?.status === "failed" && event.status === "running" ? "failed" : "unknown";
      return { ...event, status, message: event.message || final?.message };
    };
    const authentication = normalize(checks[0].rows.find(e => e.targetId === id) ?? { ...base, stage: "authenticate", status: "unknown" });
    const elevation = normalize(checks[1].rows.find(e => e.targetId === id) ?? { ...base, stage: "elevation", status: "unknown" });
    let steps = records.filter(e => !["connect", "authenticate", "elevation", "finished", "conflict"].includes(e.stage!)).map(normalize);
    steps = steps.filter(e => e.stage !== "collection" || (e.status === "failed" && !steps.some(s => ["prepare", "collect"].includes(s.stage!) && s.status === "failed")));
    steps = [authentication, elevation, ...steps].sort((a, b) => order.indexOf(a.stage!) - order.indexOf(b.stage!) || (a.stepId ?? a.remotePath ?? "").localeCompare(b.stepId ?? b.remotePath ?? "", undefined, {numeric:true}));
    const failed = steps.find(e => e.status === "failed");
    const active = [...steps].reverse().find(e => e.status === "running");
    const status = final?.status ?? (running ? (active || authentication.status !== "pending" ? "running" : "pending") : "unknown");
    const label = failed && status === "failed" ? failed.cleanupStatus === "failed" ? "Temporary directory cleanup failed" : failures[failed.stage!] ?? "Failed"
      : status === "running" && final?.background ? "Background running" : status === "running" && active ? active.cleanupStatus === "running" ? "Cleaning temporary directory" : active.stage! : status === "failed" ? "Failed" : status;
    const failedSteps = records.filter(e => e.stage !== "finished" && e.status === "failed")
      .sort((a,b) => order.indexOf(a.stage!) - order.indexOf(b.stage!) || (a.stepId ?? a.remotePath ?? "").localeCompare(b.stepId ?? b.remotePath ?? "", undefined, {numeric:true}));
    return { id, ip:base.ip ?? "", failedSteps, endpoint: `${base.ip?.includes(":") ? `[${base.ip}]` : base.ip ?? id}${base.port ? `:${base.port}` : ""}`, status, label, authentication, elevation,
      steps: steps.filter(e => e.stage !== "workspace"), information: steps.filter(e => e.stage === "workspace"), final, hasFailure: !!failed || status === "failed" };
  }).sort((a, b) => Number(b.hasFailure) - Number(a.hasFailure) || a.endpoint.localeCompare(b.endpoint) || a.id.localeCompare(b.id));
}
export function filterHostResults(hosts: BatchHostResult[], status: string, phase: string, host: string) {
  return hosts.filter(h => (!host || h.id === host) && (status !== "failed" || h.hasFailure) && (status !== "running" || ["pending", "running"].includes(h.status))
    && (phase !== "authenticate" || h.authentication.status === "failed") && (phase !== "elevation" || h.elevation.status === "failed"));
}
export function transferProgress(host: BatchHostResult, event?: BatchEvent) {
  const message = event?.event?.message;
  if (host.final || !message?.id || !message.total) return undefined;
  return host.steps.some(s => s.status === "running" && s.stepId === message.id && ["upload", "collect"].includes(s.stage!)) ? message : undefined;
}

export function workspaceCleanupLabel(event: BatchEvent) {
  const labels: Record<string, string> = { pending: "Cleanup pending", running: "Cleaning temporary directory", success: "Temporary directory removed", failed: "Temporary directory cleanup failed" };
  return labels[event.cleanupStatus ?? ""] ?? "Cleanup status unknown";
}
