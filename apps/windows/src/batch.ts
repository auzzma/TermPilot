import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useAppStore } from "./store";
import type { Host } from "./types";
import { updateChecks } from "./batchPresentation";
import { updateSteps } from "./batchResults";
export type Elevation = "none" | "sudo" | "su";
export interface BatchScript {
    body: string;
    shell: string;
    cwd: string;
    args: string[];
    environment: Record<string, string>;
    elevation: string;
}
export interface BatchJob {
    kind: "execute" | "upload" | "collect" | "check";
    executionMode: "foreground" | "background";
    concurrency: number;
    connectTimeout: number;
    stepTimeout: number;
    stopOnFailure: boolean;
    script: BatchScript;
    before: BatchScript;
    after: BatchScript;
    cleanupPolicy: string;
    localPaths: string[];
    remoteDirectory: string;
    overwrite: string;
    fileMode: string;
    directoryMode: string;
    recursivePermissions: boolean;
    owner: string;
    group: string;
    remotePaths: string[];
    localDirectory: string;
    remoteWorkDirectory: string;
    sourceTaskId: string;
}
export const emptyScript = (): BatchScript => ({ body: "", shell: "/bin/bash", cwd: "", args: [], environment: {}, elevation: "" });
export const emptyJob = (): BatchJob => ({ kind: "execute", executionMode: "foreground", concurrency: 5, connectTimeout: 120, stepTimeout: 600, stopOnFailure: false, script: emptyScript(), before: emptyScript(), after: emptyScript(), cleanupPolicy: "success", localPaths: [], remoteDirectory: "", overwrite: "skip", fileMode: "0644", directoryMode: "0755", recursivePermissions: false, owner: "", group: "", remotePaths: [], localDirectory: "", remoteWorkDirectory: "", sourceTaskId: "" });
export interface BatchTarget {
    host: Host;
    elevation: Elevation;
    elevationPassword?: string;
    savedHostId?: string;
}
export interface BackgroundTask {
    targetId: string; remoteTaskId: string; hostname: string; port: number; username: string;
    credentialId?: string; proxyProfileId?: string; elevation: Elevation;
}
export type BackgroundAction = "status" | "logs" | "cancel";
export function restoreBackgroundTargets(tasks: BackgroundTask[], current: BatchTarget[], saved: Host[]): BatchTarget[] {
    return tasks.map(task => {
        const matches = (host:Host) => host.id===task.targetId && host.hostname.toLowerCase()===task.hostname.toLowerCase() && host.port===task.port;
        const existing = current.find(t => matches(t.host));
        const host = existing?.host ?? saved.find(matches) ?? {
            id: task.targetId, label: task.hostname, authentication: "password", credentialId: task.credentialId,
            proxyProfileId: task.proxyProfileId, sortOrder: 0, distroMode: "auto", iconMode: "auto", iconColorMode: "auto",
            sftpFileProtocol: "sftp", sftpFilenameEncoding: "auto", sftpUsesSudo: false, serverToolsUseRoot: false,
            serverToolsElevationMethod: "sudo", createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
        } as Host;
        return { host: { ...host, hostname: task.hostname, port: task.port, username: task.username }, elevation: task.elevation, elevationPassword: existing?.elevationPassword };
    });
}
export interface BatchEvent {
    type: string;
    background?: boolean;
    backgroundTasks?: BackgroundTask[];
    remoteTaskId?: string;
    remoteLogDirectory?: string;
    stdoutTruncated?: boolean;
    stderrTruncated?: boolean;
    runId?: string;
    jobId?: string;
    targetId?: string;
    ip?: string;
    port?: number;
    stage?: string;
    stepId?: string;
    status?: string;
    message?: string;
    error?: string;
    stdout?: string;
    stderr?: string;
    exitCode?: number;
    localPath?: string;
    remotePath?: string;
    remoteWorkDirectory?: string;
    cleanupStatus?: string;
    sourceTaskId?: string;
    policy?: string;
    backupPath?: string;
    reportDirectory?: string;
    elapsedMs?: number;
    remoteStateUnknown?: boolean;
    event?: {
        type: string;
        message?: {
            id?: string;
            event?: string;
            transferred: number;
            total: number;
        };
    };
    time?: string;
}
export function targetKey(t: BatchTarget) { return `${t.host.hostname.toLowerCase()}:${t.host.port}`; }
export function mergeTargets(current: BatchTarget[], incoming: BatchTarget[]) { const keys = new Set(current.map(targetKey)); return [...current, ...incoming.filter(t => { const key = targetKey(t); if (keys.has(key))
        return false; keys.add(key); return true; })]; }
export function failedTargetIds(events: BatchEvent[]) { return new Set(events.filter(e => e.type === "batchHost" && e.stage === "finished" && ["failed", "cancelled"].includes(e.status ?? "")).map(e => e.targetId)); }
export function downloadRetryPlan(job: BatchJob, events: BatchEvent[], targets: BatchTarget[]) {
    const failed = failedTargetIds(events);
    const selected = targets.filter(t => failed.has(t.host.id));
    if (selected.length !== 1) throw new Error("Select one failed host for download-only retry.");
    const records = events.filter(e => e.targetId === selected[0].host.id);
    const workspace = records.find(e => e.remoteWorkDirectory)?.remoteWorkDirectory;
    if (!workspace) throw new Error("No remote workspace is available for this host.");
    const managed = records.some(e => !!e.cleanupStatus);
    if (managed && job.remotePaths.some(p => p.includes("${REMOTE_WORK_DIR}") || p.includes(workspace)))
        throw new Error("Temporary collection files cannot be reused. Rerun collection to recreate them.");
    return { remoteWorkDirectory: managed ? "" : workspace, sourceTaskId: records.find(e => e.sourceTaskId)?.sourceTaskId ?? "" };
}
export function downloadRetryError(job: BatchJob, events: BatchEvent[], targets: BatchTarget[]) {
    try { downloadRetryPlan(job, events, targets); return ""; }
    catch (error) { return error instanceof Error ? error.message : String(error); }
}
export function updateConflicts(conflicts: BatchEvent[], event: BatchEvent) {
    const key = (v: BatchEvent) => v.targetId === event.targetId && v.remotePath === event.remotePath;
    if (event.stage === "conflict")
        return conflicts.some(key) ? conflicts : [...conflicts, event];
    if (event.stage === "upload" && event.status !== "running")
        return conflicts.map(c => key(c) ? { ...c, status: event.status, backupPath: event.backupPath } : c);
    return conflicts;
}
export interface BatchState {
    section: "configuration" | "results";
    defaults: { ips: string; port: number; credential: string; elevation: Elevation; password: string };
    isHistory: boolean;
    waitingPrompt: boolean;
    backgroundTasks: BackgroundTask[];
    historyJobId: string;
    steps: Record<string, BatchEvent>;
    checks: Record<string, BatchEvent>;
    conflicts: BatchEvent[];
    hostStates: Record<string, BatchEvent>;
    progress: Record<string, BatchEvent>;
    job: BatchJob;
    targets: BatchTarget[];
    events: BatchEvent[];
    runId?: string;
    running: boolean;
    reportDirectory: string;
    error: string;
    cancel: () => Promise<void>;
    setJob: (job: BatchJob) => void;
    setTargets: (targets: BatchTarget[]) => void;
    start: (kind?: BatchJob["kind"], retry?: "failed" | "download", backgroundAction?: BackgroundAction) => Promise<void>;
}
type EventConsumer = (event: BatchEvent) => void;
const activeRuns = new Map<string, EventConsumer>();
let monitoring: Promise<unknown> | undefined;
export function monitorBatch() {
    return monitoring ??= listen<BatchEvent>("batch-event", ({payload}) => {
        if (payload.runId) activeRuns.get(payload.runId)?.(payload);
    }).catch(error => { monitoring = undefined; throw error; });
}
export function createBatchStore() {
    let starting: string | undefined;
    let pendingCancel: string | undefined;
    return create<BatchState>((set, get) => ({
        section: "configuration", defaults: {ips:"", port:22, credential:"", elevation:"none", password:""}, isHistory:false, waitingPrompt:false,
        backgroundTasks: [], historyJobId: "", steps: {}, checks: {}, job: emptyJob(), targets: [], events: [],
        conflicts: [], hostStates: {}, progress: {}, running: false, reportDirectory: "", error: "",
        cancel: async () => {
            const {runId, running} = get();
            if (!running || !runId) return;
            if (starting === runId) { pendingCancel = runId; return; }
            await invoke("batch_cancel", {runId});
        },
        setJob: job => set({job}), setTargets: targets => set({targets}), start: async (kind, retry, backgroundAction) => {
        const state = get();
        if (state.running) return;
        let targets = backgroundAction ? restoreBackgroundTargets(state.backgroundTasks, state.targets, useAppStore.getState().hosts) : state.targets;
        if (!backgroundAction) targets = targets.map(target => {
            if (!target.savedHostId) return target;
            const latest = useAppStore.getState().hosts.find(h => h.id.toLowerCase() === target.savedHostId!.toLowerCase());
            if (!latest || (latest.connectionKind && latest.connectionKind !== "ssh") || latest.hostname.toLowerCase() !== target.host.hostname.toLowerCase() || latest.port !== target.host.port)
                throw new Error("A saved host is missing or its address changed. Remove it and add the intended host again.");
            return {...target, host: {...latest, id: target.host.id, credentialId: target.host.credentialId ?? latest.credentialId,
                username: target.host.credentialId ? "" : latest.username}};
        });
        let job = backgroundAction ? { ...emptyJob(), script: { ...emptyScript(), body: ":" } } : { ...state.job, kind: kind ?? state.job.kind, executionMode: kind ? "foreground" as const : state.job.executionMode };
        const retryEvents = [...state.events, ...Object.values(state.steps), ...Object.values(state.hostStates)];
        if (retry) {
            const ids = failedTargetIds(retryEvents);
            targets = targets.filter(t => ids.has(t.host.id));
        }
        if (!targets.length)
            throw new Error("Select at least one target host.");
        if (retry === "download") {
            const plan = downloadRetryPlan(job, retryEvents, targets);
            job = { ...job, kind: "collect", before: emptyScript(), ...plan };
        }
        const runId = crypto.randomUUID();
        starting = runId;
        set({ ...(backgroundAction ? {} : {backgroundTasks: [], historyJobId: "", steps: {}, events: [], conflicts: [], hostStates: {}, reportDirectory: ""}), checks: Object.fromEntries(targets.map(t => [`${t.host.id}:authenticate`, { type: "batchHost", targetId: t.host.id, ip: t.host.hostname, port: t.host.port, stage: "authenticate", status: "pending" }])), running: true, runId, progress: {}, error: "" });
        activeRuns.set(runId, payload => {
            if (get().runId !== runId) { activeRuns.delete(runId); return; }
            const exit = payload.type === "exit";
            set(s => ({
                backgroundTasks: payload.backgroundTasks ?? s.backgroundTasks,
                historyJobId: payload.jobId ?? s.historyJobId, steps: updateSteps(s.steps, payload), checks: updateChecks(s.checks, payload),
                events: payload.type === "batchEvent" ? s.events : [...s.events, payload].slice(-3000),
                conflicts: updateConflicts(s.conflicts, payload),
                hostStates: payload.targetId && ["finished", "workspace"].includes(payload.stage ?? "")
                    ? {...s.hostStates, [payload.targetId]: {...s.hostStates[payload.targetId], ...payload}} : s.hostStates,
                progress: payload.event?.type === "sftpResponse" && payload.targetId ? {...s.progress, [payload.targetId]:payload} : s.progress,
                reportDirectory: payload.reportDirectory ?? s.reportDirectory, running: !exit,
                error: payload.error ?? (exit && !s.events.some(e => e.type === "batchFinished")
                    ? "Batch process ended unexpectedly. Check history; remote state may be unknown." : s.error),
            }));
            if (exit) activeRuns.delete(runId);
        });
        try {
            await monitorBatch();
            set({section:"results",isHistory:false});
            await invoke("batch_start", {runId, job, targets, historyJobId: backgroundAction ? state.historyJobId : undefined, backgroundAction,
                autoAcceptHostKeys: useAppStore.getState().preferences.autoAcceptSshHostKeys});
        } catch (e) {
            activeRuns.delete(runId);
            if (get().runId === runId) set({steps: backgroundAction ? state.steps : {}, checks: backgroundAction ? state.checks : {}, running:false, error:String(e)});
            throw e;
        } finally {
            if (starting === runId) starting = undefined;
        }
        if (pendingCancel === runId) {
            pendingCancel = undefined;
            if (get().running && get().runId === runId) await invoke("batch_cancel", {runId});
        }
    }}));
}
export const useBatchStore = createBatchStore();
