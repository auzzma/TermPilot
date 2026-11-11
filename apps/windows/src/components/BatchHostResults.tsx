import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import type { BatchEvent } from "../batch";
import { checkGroups } from "../batchPresentation";
import { workspaceCleanupLabel, filterHostResults, stepKey, transferProgress, type BatchHostResult } from "../batchResults";
import { useTranslation } from "../i18n";

const indicatorLabels: Record<string, string> = { success: "All succeeded", failed: "All failed", mixed: "Partially succeeded", running: "Checks in progress", neutral: "Not all checks completed" };
export function BatchHostResults({hosts, running, conflicts = [], progress = {}}: {hosts: BatchHostResult[]; running: boolean; conflicts?: BatchEvent[]; progress?: Record<string, BatchEvent>}) {
  const t = useTranslation();
  const [status, setStatus] = useState("all"), [phase, setPhase] = useState(""), [host, setHost] = useState("");
  const [expanded, setExpanded] = useState(new Set<string>()), [showConflicts, setShowConflicts] = useState(false);
  if (!hosts.length) return <p className="batch-muted">{t("Run a task or load history to view results.")}</p>;
  const groups = checkGroups(hosts.flatMap(h => [h.authentication, h.elevation]), running).slice(0, 2);
  const visible = filterHostResults(hosts, status, phase, host);
  const finished = hosts.filter(h => !["pending", "running", "unknown"].includes(h.status)).length;
  const changeExpanded = (id: string, open: boolean) => setExpanded(current => {
    if (current.has(id) === open) return current;
    const next = new Set(current); if (open) next.add(id); else next.delete(id); return next;
  });
  return <div className="batch-host-results">
    <div className="batch-overview"><strong>{t("Hosts")} {hosts.length}</strong><span>{t("Completed")} {finished} / {hosts.length}</span>{["success", "failed", "running", "pending", "cancelled", "skipped", "unknown"].map(s => {
      const count = hosts.filter(h => h.status === s).length;
      return count ? <span key={s} className={`batch-status-${s}`}>{t(s === "failed" ? "Failed" : s)} {count}</span> : null;
    })}</div>
    {running && <progress aria-label={t("Completed")} value={finished} max={hosts.length}/>}
    <div className="batch-phase-tags">{groups.map(g => <button key={g.stage} aria-pressed={phase === g.stage} title={t("Show hosts that failed this check")} onClick={() => {setPhase(phase === g.stage ? "" : g.stage); setStatus("all"); setHost("");}}>
      {t(g.stage)}<span className={`batch-check-dot ${g.indicator}`} role="img" aria-label={t(indicatorLabels[g.indicator])}/><small>{t("success")} {g.counts.success} · {t("Failed")} {g.counts.failed}{g.counts.skipped ? ` · ${t("skipped")} ${g.counts.skipped}` : ""}</small>
    </button>)}</div>
    <div className="batch-actions batch-result-filters"><div role="group" aria-label={t("Result filter")}>{[["all", "All"], ["failed", "Failed only"], ["running", "In progress"]].map(([value, label]) => <button key={value} aria-pressed={status === value && !phase} onClick={() => {setStatus(value); setPhase("");}}>{t(label)}</button>)}</div>
      <select aria-label={t("Host")} value={host} onChange={e => setHost(e.target.value)}><option value="">{t("All hosts")}</option>{hosts.map(h => <option key={h.id} value={h.id}>{h.endpoint}</option>)}</select>
      {phase && <span className="batch-muted">{t(phase === "authenticate" ? "Authentication failed" : "Elevation failed")}</span>}
      {(host || phase || status !== "all") && <button onClick={() => {setStatus("all"); setPhase(""); setHost("");}}>{t("Clear filters")}</button>}
    </div>
    {conflicts.length > 0 && <details className="batch-conflict-details" open={showConflicts} onToggle={e => setShowConflicts(e.currentTarget.open)}><summary>{t("Upload conflicts")} · {new Set(conflicts.map(e => e.targetId)).size} {t("Hosts")}</summary><ConflictList events={conflicts} onSelect={id => {setHost(id); setPhase(""); setStatus("all"); changeExpanded(id, true); setShowConflicts(false);}}/></details>}
    <div className="batch-host-table" role="group" aria-label={t("Host results")}><div className="batch-host-columns batch-muted" aria-hidden="true"><span>{t("Host")}</span><span>{t("Task status")}</span><span>{t("Elapsed")}</span></div>
      {visible.map(h => <HostRow key={h.id} host={h} progress={progress[h.id]} open={expanded.has(h.id)} onToggle={open => changeExpanded(h.id, open)}/>)}
      {!visible.length && <p className="batch-empty">{t("No hosts match these filters.")}</p>}
    </div>
  </div>;
}
function Status({value, label}: {value?: string; label?: string}) {
  const t = useTranslation();
  return <span className={`batch-status-${value}`}>{t(label ?? (value === "failed" ? "Failed" : value ?? "unknown"))}</span>;
}
function HostRow({host: h, progress, open, onToggle}: {host: BatchHostResult; progress?: BatchEvent; open: boolean; onToggle: (open: boolean) => void}) {
  const t = useTranslation(), transfer = transferProgress(h, progress);
  const finalMessage = h.final?.message;
  return <details className="batch-host-row" open={open} onToggle={e => onToggle(e.currentTarget.open)}>
    <summary className="batch-host-columns"><code><span className="batch-disclosure" aria-hidden="true">{open ? "⌄" : "›"}</span>{h.endpoint}</code><span><Status value={h.status} label={h.label}/>{transfer && <small> · {Math.min(100, Math.round(transfer.transferred / transfer.total * 100))}%</small>}</span><span className="batch-muted">{h.final?.elapsedMs !== undefined ? `${(h.final.elapsedMs / 1000).toFixed(1)} s` : "—"}</span></summary>
    <div className="batch-host-steps">{transfer && <div className="batch-transfer"><progress value={transfer.transferred} max={transfer.total}/><span>{Math.min(100, Math.round(transfer.transferred / transfer.total * 100))}% · {transfer.transferred} / {transfer.total} bytes</span></div>}
      {h.information.filter(e => e.status === "failed").map(e => <p key={stepKey(e)} className="batch-error">{t(e.message || "Workspace failed")}</p>)}
      {h.steps.map(e => <StepDetails key={stepKey(e)} event={e}/>)}
      {finalMessage && ![...h.steps, ...h.information].some(e => e.message === finalMessage) && <p className={h.status === "failed" ? "batch-error" : "batch-muted"}>{t(finalMessage)}</p>}
      {h.final?.remoteStateUnknown && <p className="batch-status-unknown">{t("Remote process state is unknown. Verify the host before rerunning.")}</p>}
      {h.information.length > 0 && <details className="batch-run-info"><summary>{t("Remote temporary directory")} · {t(workspaceCleanupLabel(h.information[0]))}</summary>{h.information.map(e => <EventOutput key={stepKey(e)} event={e}/>)}</details>}
    </div>
  </details>;
}
function StepDetails({event}: {event: BatchEvent}) {
  const t = useTranslation();
  return <details className="batch-step"><summary><strong>{t(event.stage ?? "")}</strong><Status value={event.status}/>{event.remotePath && <code title={event.remotePath}>{event.remotePath}</code>}</summary><EventOutput event={event}/></details>;
}
function EventOutput({event}: {event: BatchEvent}) {
  const t = useTranslation(), [error, setError] = useState("");
  return <div className="batch-step-output">{event.message && <pre>{t(event.message)}</pre>}{event.stdout && <><small>stdout</small><pre>{event.stdout}</pre></>}{event.stderr && <><small>stderr</small><pre>{event.stderr}</pre></>}{(event.stdoutTruncated || event.stderrTruncated) && <small>{t("Showing the latest 64 KiB per stream. Download complete logs for earlier output.")}</small>}{event.remoteLogDirectory && <><small>{t("Remote log directory")}</small><code>{event.remoteLogDirectory}</code></>}{event.exitCode !== undefined && <small>Exit: {event.exitCode}</small>}{event.remoteWorkDirectory && <><small>{t("Remote temporary directory")}</small><code>{event.remoteWorkDirectory}</code></>}{event.localPath && <button onClick={() => void invoke("local_reveal", {path:event.localPath}).catch(e => setError(String(e)))}>{event.localPath}</button>}{error && <p role="alert">{error}</p>}</div>;
}
function ConflictList({events, onSelect}: {events: BatchEvent[]; onSelect:(id:string)=>void}) {
  const t = useTranslation();
  return <div className="batch-conflict-list"><p className="batch-muted">{t("Hosts remain listed even when the conflict was handled successfully.")}</p><table><thead><tr><th>{t("Host")}</th><th>{t("Remote path")}</th><th>{t("Policy")}</th><th>{t("Result")}</th></tr></thead><tbody>{events.map(e => <tr key={stepKey(e)}><td><button title={t("Locate host")} onClick={() => onSelect(e.targetId!)}>{e.ip?.includes(":") ? `[${e.ip}]` : e.ip}{e.port ? `:${e.port}` : ""}</button></td><td>{e.remotePath}{e.backupPath && <small>{e.backupPath}</small>}</td><td>{t(e.policy ?? "")}</td><td><Status value={e.status}/></td></tr>)}</tbody></table></div>;
}
