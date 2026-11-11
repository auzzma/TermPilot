import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { open, save } from "@tauri-apps/plugin-dialog";
import { useAppStore } from "../store";
import { useTranslation } from "../i18n";
import { downloadRetryError, emptyScript, restoreBackgroundTargets, mergeTargets, type BatchScript, type BatchTarget, type Elevation } from "../batch";
import { BatchSaveControls } from "./BatchLibrary";
import { BatchDialog } from "./BatchDialog";
import { BatchHostPicker } from "./BatchHostPicker";
import { BatchHostResults } from "./BatchHostResults";
import { hostResults } from "../batchResults";
import { openBatchHistory, type BatchTab } from "../batchWorkspace";
import { batchResultsCSV, type CSVScope } from "../batchCSV";
import type { Host } from "../types";
export function BatchPanel({tab}: {tab:BatchTab}) {
    const t = useTranslation();
    const batch = tab.store();
    const { job, targets, running } = batch;
    const retryError = downloadRetryError(job, [...batch.events, ...Object.values(batch.steps), ...Object.values(batch.hostStates)], targets);
    const hosts = useAppStore(s => s.hosts);
    const credentials = useAppStore(s => s.credentials);
    const groups = useAppStore(s => s.groups);
    const {ips,port,credential,elevation,password} = batch.defaults;
    function setDefault<K extends keyof typeof batch.defaults>(key:K, value:typeof batch.defaults[K]) {
        tab.store.setState(s => ({defaults:{...s.defaults,[key]:value}}));
    }
    const [error, setError] = useState("");
    const [history, setHistory] = useState<Array<{
        id: string;
        time: number;
        background?: boolean;
    }>>([]);
    const section = batch.section;
    const setSection = (value:string) => tab.store.setState({section:value === "results" ? "results" : "configuration"});
    const [showingTargets, setShowingTargets] = useState(false);
    const [showingHistory, setShowingHistory] = useState(false);
    const [loadingHistory, setLoadingHistory] = useState(false);
    const [showingHostPicker, setShowingHostPicker] = useState(false);
    const update = (patch: Partial<typeof job>) => batch.setJob({ ...job, ...patch, ...(patch.kind && patch.kind !== "execute" ? {executionMode: "foreground" as const} : {}) });
    const attempt = async (f: () => Promise<unknown>) => { try {
        setError("");
        await f();
    }
    catch (e) {
        setError(String(e));
    } };
    async function addIPs() {
        const parsed = await invoke<Array<{
            hostname: string;
            port: number;
        }>>("batch_parse_targets", { text: ips, port });
        if (!credential)
            throw new Error(t("Select a credential for temporary IPs."));
        const c = credentials.find(c => c.id === credential);
        if (!c)
            throw new Error("Credential missing");
        const incoming = parsed.map(p => ({ host: { id: crypto.randomUUID(), label: p.hostname, ...p, username: "", credentialId: c.id, authentication: "password", sortOrder: 0, distroMode: "auto", iconMode: "auto", iconColorMode: "auto", sftpFileProtocol: "sftp", sftpFilenameEncoding: "auto", sftpUsesSudo: false, serverToolsUseRoot: false, serverToolsElevationMethod: "sudo", createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() } as Host, elevation, elevationPassword: password || undefined }));
        batch.setTargets(mergeTargets(targets, incoming));
        setDefault("ips","");
    }
    function addSaved(selected: Host[]) { batch.setTargets(mergeTargets(targets, selected.filter(h => !h.connectionKind || h.connectionKind === "ssh").map(h => ({ host: h, elevation, elevationPassword: password || undefined, savedHostId: h.id })))); }
    function editTarget(index: number, patch: Partial<BatchTarget>) { batch.setTargets(targets.map((target, i) => i === index ? { ...target, ...patch } : target)); }
    async function chooseUploads(directory: boolean) { const value = await open({ multiple: true, directory }); if (value)
        update({ localPaths: [...new Set([...job.localPaths, ...(Array.isArray(value) ? value : [value])])] }); }
    const resultRows = hostResults([...Object.values(batch.steps),...Object.values(batch.checks)],running);
    async function exportCSV(scope:CSVScope) {
        const text=batchResultsCSV(resultRows,scope,t);
        const path=await save({defaultPath:["TermPilot",batch.historyJobId,scope].filter(Boolean).join("-")+".csv",filters:[{name:"CSV",extensions:["csv"]}]});
        if(path) await invoke("batch_save_csv",{path,text});
    }
    const methods = new Set(targets.map(x => x.elevation));
    const credentialIds = new Set(targets.map(x => x.host.credentialId ?? ""));
    const targetSummary = !targets.length ? t("Add saved hosts or enter IP addresses to get started.") :
        `${credentialIds.size === 1 && !credentialIds.has("") ? credentials.find(c => c.id === targets[0].host.credentialId)?.label ?? t("Credentials") : t("Per-host credentials")} · ${methods.size === 1 ? (targets[0].elevation === "none" ? t("No elevation") : targets[0].elevation) : t("Per-host elevation")}`;
    const runtimeSummary = `${t(job.executionMode === "background" ? "Submission concurrency" : "Concurrency")} ${job.concurrency} · ${job.stepTimeout === 0 ? t("No execution time limit") : `${t("Execution timeout")} ${job.stepTimeout} s`}${job.stopOnFailure ? ` · ${t("Stop on failure")}` : ""}`;
    const hasRetryableResults = [...Object.values(batch.steps), ...Object.values(batch.checks)].some(e => e.stage === "finished" && ["failed", "cancelled"].includes(e.status ?? ""));
    async function openHistory() {
        setShowingHistory(true); setLoadingHistory(true);
        await attempt(async () => setHistory((await invoke<{jobs: typeof history}>("batch_history")).jobs));
        setLoadingHistory(false);
    }
    return <div className="batch-panel batch-workbench">
      <header className="batch-toolbar">
        <div><h2>{t("Batch Jobs")}</h2><p>{t("Configure once. Run across your hosts.")}</p></div>
        <div className="batch-actions">
          <BatchSaveControls tab={tab}/>
          <button onClick={() => void openHistory()}>{t("Job history")}</button>
          {running ? <button onClick={() => void attempt(batch.cancel)}>{t(batch.backgroundTasks.length || job.executionMode === "background" ? "Stop submitting or querying" : "Cancel")}</button> :
            <button className="batch-primary" disabled={!targets.length} onClick={() => void attempt(async () => { batch.setJob({...job, remotePaths: job.remotePaths.map(s => s.trim()).filter(Boolean)}); await batch.start(); })}>{t("Run batch")}</button>}
        </div>
      </header>
      <div className="batch-navigation">
        <div className="batch-segments" role="tablist" aria-label={t("Batch workspace")}>
          {[["configuration", "Task configuration"], ["results", "Execution results"]].map(([value, label]) => <button key={value} id={`batch-tab-${value}`} role="tab" aria-selected={section === value} aria-controls={`batch-pane-${value}`} tabIndex={section === value ? 0 : -1} onClick={() => setSection(value)} onKeyDown={e => { if (["ArrowLeft", "ArrowRight", "Home", "End"].includes(e.key)) { e.preventDefault(); const next = e.key === "Home" ? "configuration" : e.key === "End" ? "results" : section === "configuration" ? "results" : "configuration"; setSection(next); document.getElementById(`batch-tab-${next}`)?.focus(); } }}>{t(label)}</button>)}
        </div>
        {running && <span className="batch-muted" role="status">{t("Configuration is read-only while running.")}</span>}
      </div>
      {(error || batch.error) && <p role="alert" className="batch-error">{error || batch.error}</p>}
      <div className="batch-workbench-body">
        <section role="tabpanel" id="batch-pane-configuration" aria-labelledby="batch-tab-configuration" hidden={section !== "configuration"}>
          <div className="batch-target-summary"><div><h3>{t("Target hosts")} · {targets.length}</h3><p>{targetSummary}</p></div><button disabled={running} onClick={() => setShowingTargets(true)}>{t("Manage hosts")}</button></div>
          <fieldset disabled={running} className="batch-task-form"><legend className="sr-only">{t("Task")}</legend>
            <div className="batch-segments batch-task-kinds" role="group" aria-label={t("Task")}>{(["execute", "upload", "collect"] as const).map(kind => <button aria-pressed={job.kind === kind} key={kind} onClick={() => update({kind})}>{t({execute:"Batch execution", upload:"Batch upload", collect:"File collection"}[kind])}</button>)}</div>
            <div hidden={job.kind !== "execute"}>
              <label>{t("Execution mode")}<select value={job.executionMode} onChange={e => update({executionMode:e.target.value as "foreground" | "background"})}><option value="foreground">{t("Foreground execution")}</option><option value="background">{t("Background execution")}</option></select></label>
              {job.executionMode === "background" && <p className="batch-muted">{t("Submitted tasks continue after disconnect, sleep or app exit. Remote Python 3.8+ is required. View logs and results from job history.")}</p>}
              <ScriptEditor value={job.script} onChange={script => update({script})} label="Command or script"/></div>
            <div hidden={job.kind !== "upload"} className="batch-task-content">
              <div className="batch-file-heading"><strong>{t("Files to upload")} · {job.localPaths.length}</strong><div className="batch-actions"><button onClick={() => void attempt(() => chooseUploads(false))}>{t("Add files")}</button><button onClick={() => void attempt(() => chooseUploads(true))}>{t("Add directory")}</button>{job.localPaths.length > 0 && <button onClick={() => update({localPaths: []})}>{t("Clear")}</button>}</div></div>
              <div className="batch-upload-files">{!job.localPaths.length && <p className="batch-muted">{t("Choose files or directories to upload.")}</p>}{job.localPaths.map(path => <div key={path}><code>{path}</code><button aria-label={`${t("Remove")} ${path}`} onClick={() => update({localPaths: job.localPaths.filter(p => p !== path)})}>×</button></div>)}</div>
              <div className="batch-grid"><label>{t("Remote directory")}<input value={job.remoteDirectory} onChange={e => update({remoteDirectory:e.target.value})} placeholder="/opt/app"/></label><label>{t("Existing destination")}<select value={job.overwrite} onChange={e => update({overwrite:e.target.value})}><option value="skip">{t("Skip")}</option><option value="overwrite">{t("Overwrite")}</option><option value="backup">{t("Backup then replace")}</option></select></label></div>
              <small>{t("Conflict policies apply to each selected file or directory. Replacing a directory replaces its entire contents.")}</small>
              <details className="batch-option"><summary><span>{t("Permissions & ownership")}</span><small>{[job.fileMode, job.directoryMode, job.owner, job.group, job.recursivePermissions ? t("Recursive") : ""].filter(Boolean).join(" · ")}</small></summary><div className="batch-grid"><label>{t("File permissions")}<input value={job.fileMode} onChange={e => update({fileMode:e.target.value})}/></label><label>{t("Directory permissions")}<input value={job.directoryMode} onChange={e => update({directoryMode:e.target.value})}/></label><label>{t("Owner (optional)")}<input value={job.owner} onChange={e => update({owner:e.target.value})}/></label><label>{t("Group (optional)")}<input value={job.group} onChange={e => update({group:e.target.value})}/></label></div><label><input type="checkbox" checked={job.recursivePermissions} onChange={e => update({recursivePermissions:e.target.checked})}/>{t("Apply permissions recursively")}</label></details>
            </div>
            <div hidden={job.kind !== "collect"} className="batch-task-content">
              <label>{t("Remote files · one absolute path per line")}<textarea rows={5} value={job.remotePaths.join("\n")} onChange={e => update({remotePaths:e.target.value.split("\n")})} placeholder={'/var/log/syslog\n${REMOTE_WORK_DIR}/diagnostics.tar.gz'}/></label>
              <label>{t("Collection directory")}<div className="batch-actions"><input value={job.localDirectory} onChange={e => update({localDirectory:e.target.value})}/><button onClick={() => void attempt(async () => { const v = await open({directory:true}); if (typeof v === "string") update({localDirectory:v}); })}>{t("Browse")}</button></div></label>
              <small>{t("Files use IP-UTC time-filename; collisions receive a suffix. SHA-256 is verified before cleanup.")}</small>
              <details className="batch-option"><summary><span>{t("Preparation script")}</span><small>{t(job.before.body.trim() ? "Configured" : "Not configured")}</small></summary><ScriptEditor value={job.before} onChange={before => update({before})} label="Preparation (optional)"/></details>
              <details className="batch-option"><summary><span>{t("Cleanup script")}</span><small>{t(job.after.body.trim() ? "Configured" : "Not configured")}</small></summary><ScriptEditor value={job.after} onChange={after => update({after})} label="Cleanup (optional)"/><label>{t("Run cleanup")}<select value={job.cleanupPolicy} onChange={e => update({cleanupPolicy:e.target.value})}><option value="success">{t("Only after successful collection")}</option><option value="failure">{t("Only after failure")}</option><option value="always">{t("After success or failure")}</option></select></label><small>{t("Cancellation skips the cleanup script. The remote temporary directory is always cleaned up after the task.")}</small></details>
            </div>
            <details className="batch-option batch-runtime"><summary><span>{t("Run options")}</span><small>{runtimeSummary}</small></summary><div className="batch-grid"><label>{t(job.executionMode === "background" ? "Submission concurrency" : "Concurrency")}<input type="number" min={1} max={32} value={job.concurrency} onChange={e => update({concurrency:Number(e.target.value)})}/></label><label>{t("Connection timeout (s)")}<input type="number" min={10} max={600} value={job.connectTimeout} onChange={e => update({connectTimeout:Number(e.target.value)})}/></label><label>{t("Execution timeout (s)")}<input type="number" min={0} max={86400} value={job.stepTimeout} onChange={e => update({stepTimeout:Number(e.target.value)})}/><small>{t("0 means no time limit. You can still cancel the task.")}</small></label></div><label><input type="checkbox" checked={job.stopOnFailure} onChange={e => update({stopOnFailure:e.target.checked})}/>{t(job.executionMode === "background" ? "Stop submitting hosts after a submission failure" : "Stop scheduling new hosts after a failure")}</label></details>
          </fieldset>
          <div className="batch-actions batch-check-action"><button disabled={running || !targets.length} onClick={() => void attempt(() => batch.start("check"))}>{t("Check connections & elevation")}</button><small>{t("Verify authentication and elevation before running.")}</small></div>
        </section>
        <section role="tabpanel" id="batch-pane-results" aria-labelledby="batch-tab-results" hidden={section !== "results"}>
          <div className="batch-results-heading"><h3>{t("Execution results")}</h3><details className="batch-result-actions"><summary>{t("Export CSV")}</summary><div>{(["all","failed","success"] as const).map((scope,i)=><button key={scope} disabled={!resultRows.some(r=>scope==="all" || r.status===scope)} onClick={e=>{e.currentTarget.closest("details")!.open=false;void attempt(()=>exportCSV(scope));}}>{t(["Export all hosts","Export failed hosts","Export successful hosts"][i])}</button>)}</div></details><details className="batch-result-actions"><summary>{t("Result actions")}</summary><div><button disabled={!batch.reportDirectory} onClick={() => void attempt(() => invoke("local_open", {path:batch.reportDirectory}))}>{t("Open report folder")}</button><button disabled={!job.localDirectory} onClick={() => void attempt(() => invoke("local_open", {path:job.localDirectory}))}>{t("Open collection folder")}</button></div></details></div>
          {batch.backgroundTasks.length > 0 && <div className="batch-background-controls"><p className="batch-muted">{t("Background tasks are independent of this window. Refresh to reconnect; failed queries do not stop or rerun remote tasks.")}</p><div className="batch-actions">
            <button disabled={running} onClick={() => void attempt(() => batch.start(undefined,undefined,"status"))}>{t("Refresh background tasks")}</button>
            <button disabled={running} onClick={() => void attempt(() => batch.start(undefined,undefined,"logs"))}>{t("Download complete logs")}</button>
            <button disabled={running} onClick={() => {batch.setTargets(restoreBackgroundTargets(batch.backgroundTasks,targets,hosts));setShowingTargets(true);}}>{t("Reconnect credentials")}</button>
            <button disabled={running} onClick={() => void attempt(() => batch.start(undefined,undefined,"cancel"))}>{t("Stop background tasks")}</button>
          </div></div>}
          <BatchHostResults key={batch.reportDirectory || batch.runId} hosts={resultRows} running={running} conflicts={batch.conflicts} progress={batch.progress}/>
          {!running && !batch.backgroundTasks.length && hasRetryableResults && <div className="batch-actions batch-retry-actions">{batch.isHistory && <small>{t("History contains results only. Review the task and credentials before retrying.")}</small>}<button disabled={batch.isHistory && job.kind==="execute" && !job.script.body.trim()} onClick={() => void attempt(() => batch.start(undefined,"failed"))}>{t("Rerun failed hosts")}</button>{job.kind === "collect" && <button disabled={!!retryError} title={retryError ? t(retryError) : undefined} onClick={() => void attempt(() => batch.start(undefined,"download"))}>{t("Retry download only (one failed host)")}</button>}</div>}
        </section>
      </div>
      {showingTargets && <BatchDialog title={t("Manage hosts")} onClose={() => setShowingTargets(false)} className="batch-target-manager">
        <p className="batch-muted">{t("Defaults apply to newly added hosts. Each host can use its own settings.")}</p>
        {(error || batch.error) && <p role="alert" className="batch-error">{error || batch.error}</p>}
        <fieldset disabled={running}><legend>{t("Add hosts")}</legend>
   <textarea aria-label={t("IP list")} value={ips} onChange={e => setDefault("ips",e.target.value)} placeholder={'192.168.1.10\n192.168.1.11:2222\n[::1]:22'} rows={3}/>
   <div className="batch-grid"><label>{t("Port")}<input type="number" min={1} max={65535} value={port} onChange={e => setDefault("port",Number(e.target.value))}/></label>
    <label>{t("Credentials")}<select value={credential} onChange={e => setDefault("credential",e.target.value)}><option value="">{t("Select credential")}</option>{credentials.map(c => <option key={c.id} value={c.id}>{c.label} · {c.username}</option>)}</select></label>
    <label>{t("Elevation")}<select value={elevation} onChange={e => setDefault("elevation",e.target.value as Elevation)}><option value="none">{t("No elevation")}</option><option>sudo</option><option>su</option></select></label>
    <label>{t("Elevation password override")}<input type="password" autoComplete="off" value={password} onChange={e => setDefault("password",e.target.value)} placeholder={t("Use credential password")}/></label></div>
   <div className="batch-actions"><button onClick={() => void attempt(addIPs)}>{t("Add IPs")}</button><button onClick={() => setShowingHostPicker(true)}>{t("Add saved host")}</button><button onClick={() => batch.setTargets(targets.map(x => ({ ...x, elevation, elevationPassword: password || undefined, ...(credential ? { host: { ...x.host, credentialId: credential, username: "", elevationPassword: undefined } } : {}) })))}>{t("Apply defaults to all")}</button></div>
   <div className="batch-results-heading"><h3>{t("Selected hosts")} · {targets.length}</h3><button disabled={running || !targets.length} onClick={()=>batch.setTargets([])}>{t("Clear selected hosts")}</button></div>
   <div className="batch-targets">{targets.map((target, i) => <div className="batch-target" key={target.host.id}><code>{target.host.hostname.includes(":") ? `[${target.host.hostname}]` : target.host.hostname}:{target.host.port}</code><select aria-label={t("Credentials")} value={target.host.credentialId ?? ""} onChange={e => editTarget(i, { host: { ...target.host, credentialId: e.target.value || undefined, username: e.target.value ? "" : target.host.username, elevationPassword: undefined } })}><option value="">{t("Host credentials")}</option>{credentials.map(c => <option key={c.id} value={c.id}>{c.label}</option>)}</select><select aria-label={t("Elevation")} value={target.elevation} onChange={e => editTarget(i, { elevation: e.target.value as Elevation })}><option value="none">{t("No elevation")}</option><option>sudo</option><option>su</option></select><input aria-label={t("Elevation password override")} type="password" autoComplete="off" placeholder={t("Use credential password")} value={target.elevationPassword ?? ""} onChange={e => editTarget(i, { elevationPassword: e.target.value || undefined })}/><button aria-label={t("Remove")} onClick={() => batch.setTargets(targets.filter((_, n) => n !== i))}>×</button></div>)}</div>
   <small>{targets.length} {t("hosts selected · temporary IPs stay in this job")}</small>

        </fieldset>
        {showingHostPicker && <BatchHostPicker hosts={hosts} groups={groups} added={targets.map(t => t.host)} onAdd={addSaved} onClose={() => setShowingHostPicker(false)}/>}
      </BatchDialog>}
      {showingHistory && <BatchDialog title={t("Job history")} onClose={() => setShowingHistory(false)} className="batch-history-dialog">
        {loadingHistory ? <p role="status">{t("Loading…")}</p> : <>{error && <p role="alert" className="batch-error">{error}</p>}{!history.length ? <p className="batch-empty">{t("No previous jobs.")}</p> : <div className="batch-history-list">{history.map(h => <button key={h.id} onClick={() => void attempt(async () => {await openBatchHistory(h.id); setShowingHistory(false);})}><span>{new Date(h.time * 1000).toLocaleString()} {h.background && ` · ${t("Background execution")}`}</span><code>{h.id.slice(0,8)} ›</code></button>)}</div>}</>}
      </BatchDialog>}
    </div>;
}

function ScriptEditor({ value, onChange, label }: {
    value: BatchScript;
    onChange: (v: BatchScript) => void;
    label: string;
}) {
    const t = useTranslation();
    const scripts = useAppStore(s => s.scripts);
    const [advanced, setAdvanced] = useState(false);
    const [envError, setEnvError] = useState("");
    const [environmentText, setEnvironmentText] = useState(() => value.environment[""] ?? Object.entries(value.environment).map(([k, v]) => `${k}=${v}`).join("\n"));
    return <div className="batch-script"><label>{t(label)}<textarea rows={9} value={value.body} onChange={e => onChange({ ...value, body: e.target.value })}/></label><div className="batch-actions"><select value="" onChange={e => { const s = scripts.find(x => x.id === e.target.value); if (s)
        onChange({ ...value, body: s.body, shell: s.shell }); }}><option value="">{t("Choose saved script")}</option>{scripts.map(s => <option key={s.id} value={s.id}>{s.title}</option>)}</select><button onClick={() => void (async () => { const p = await open({ multiple: false }); if (typeof p === "string") {
        const r = await invoke<string>("batch_read_script", { path: p });
        onChange({ ...value, body: r });
    } })().catch(e => setEnvError(String(e)))}>{t("Import script")}</button><button onClick={() => setAdvanced(!advanced)}>{t("Script options")}</button><button onClick={() => { onChange(emptyScript()); setEnvironmentText(""); setEnvError(""); }}>{t("Clear")}</button></div>{advanced && <div className="batch-grid"><label>{t("Interpreter")}<input value={value.shell} onChange={e => onChange({ ...value, shell: e.target.value })}/></label><label>{t("Working directory")}<input value={value.cwd} onChange={e => onChange({ ...value, cwd: e.target.value })}/></label><label>{t("Step elevation")}<select value={value.elevation} onChange={e => onChange({ ...value, elevation: e.target.value })}><option value="">{t("Inherit host setting")}</option><option value="none">{t("No elevation")}</option><option>sudo</option><option>su</option></select></label><label>{t("Arguments · one per line")}<textarea value={value.args.join("\n")} onChange={e => onChange({ ...value, args: e.target.value ? e.target.value.split("\n") : [] })}/></label><label>{t("Environment · KEY=value per line")}<textarea value={environmentText} onChange={e => { const raw = e.target.value; setEnvironmentText(raw); try {
        const env: Record<string, string> = {};
        for (const l of raw.split("\n").filter(Boolean)) {
            const i = l.indexOf("=");
            if (i < 1)
                throw Error("Use KEY=value");
            env[l.slice(0, i)] = l.slice(i + 1);
        }
        onChange({ ...value, environment: env });
        setEnvError("");
    }
    catch (e) {
        onChange({ ...value, environment: { "": raw } }); // Shared validation blocks execution until this input is repaired.
        setEnvError(String(e));
    } }}/></label></div>}{envError && <p role="alert">{envError}</p>}<small>{t("Available variables: TASK_ID, HOST_IP, REMOTE_WORK_DIR")}</small></div>;
}
