import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import { createBatchStore, useBatchStore, restoreBackgroundTargets, type BackgroundTask, type BatchEvent, type BatchTarget } from "./batch";
import { updateChecks } from "./batchPresentation";
import { updateSteps } from "./batchResults";
import { useAppStore } from "./store";
import type { Host } from "./types";

export interface BatchTab {
  id: string;
  number: number;
  name?: string;
  savedId?: string;
  savedRevision?: number;
  store: ReturnType<typeof createBatchStore>;
}
const first: BatchTab = {id: crypto.randomUUID(), number: 1, store: useBatchStore};
export const useBatchWorkspace = create<{tabs: BatchTab[]; selected: string; next: number}>(() => ({
  tabs: [first], selected: first.id, next: 2,
}));
export function selectBatchTab(id: string) { useBatchWorkspace.setState({selected:id}); }
function addBatchTab(store: BatchTab["store"]) {
  const tab: BatchTab = {id: crypto.randomUUID(), number: useBatchWorkspace.getState().next, store};
  useBatchWorkspace.setState(s => ({tabs:[...s.tabs, tab], selected:tab.id, next:tab.number+1}));
  return tab;
}
export function newBatchTab(copy?: BatchTab) {
  const store = createBatchStore();
  if (copy) {
    const {job, targets, defaults} = copy.store.getState();
    store.setState({job:{...structuredClone(job), remoteWorkDirectory:"", sourceTaskId:""}, targets:structuredClone(targets), defaults:{...defaults}});
  }
  return addBatchTab(store);
}
export function closeBatchTab(id: string) {
  const {tabs, selected} = useBatchWorkspace.getState();
  const index = tabs.findIndex(t => t.id === id);
  if (index < 0 || tabs.length === 1 || tabs[index].store.getState().running) return;
  useBatchWorkspace.setState({tabs:tabs.filter(t => t.id !== id), selected:selected === id ? tabs[index === 0 ? 1 : index-1].id : selected});
}
export function renameBatchTab(id: string, value: string) {
  const name = value.trim();
  if (name) useBatchWorkspace.setState(s => ({tabs:s.tabs.map(tab => tab.id === id ? {...tab, name} : tab)}));
}
export function moveBatchTab(id: string, before?: string) {
  const {tabs} = useBatchWorkspace.getState();
  const tab = tabs.find(t => t.id === id);
  if (!tab || id === before || (before && !tabs.some(t => t.id === before))) return;
  const rest = tabs.filter(t => t.id !== id);
  rest.splice(before ? rest.findIndex(t => t.id === before) : rest.length, 0, tab);
  useBatchWorkspace.setState({tabs:rest});
}
export function batchTabTitle(tab: BatchTab, t: (key:string) => string) { return tab.name ?? t("Job %lld").replace("%lld", String(tab.number)); }
export function batchTabStatus(state: ReturnType<BatchTab["store"]["getState"]>) {
  if (state.waitingPrompt && state.running) return "Waiting for confirmation";
  if (state.running) return "running";
  const final = Object.values(state.checks).filter(e => e.stage === "finished");
  for (const status of ["running","unknown","failed","cancelled"]) {
    if (final.some(e => e.status === status)) return status === "running" ? "Background running" : status;
  }
  return state.error ? "failed" : state.reportDirectory ? "Completed" : "Draft";
}
function selectReport(id: string) {
  const existing = useBatchWorkspace.getState().tabs.find(t => t.store.getState().historyJobId === id);
  if (!existing) return false;
  existing.store.setState({section:"results"}); selectBatchTab(existing.id); return true;
}
export async function openBatchHistory(id: string) {
  if (selectReport(id)) return;
  const result = await invoke<{events:BatchEvent[]; conflicts:BatchEvent[]; steps?:BatchEvent[]; checks?:BatchEvent[]; reportDirectory?:string; backgroundTasks?:BackgroundTask[]}>("batch_history",{jobId:id});
  if (selectReport(id)) return;
  const store = createBatchStore(), saved = useAppStore.getState().hosts;
  const steps = (result.steps ?? result.events).reduce(updateSteps,{});
  const backgroundTasks = result.backgroundTasks ?? [];
  const targets = new Map<string,BatchTarget>();
  for (const e of Object.values<BatchEvent>(steps)) {
    if (!e.targetId || !e.ip || targets.has(e.targetId)) continue;
    const port = e.port ?? 22;
    const host = saved.find(h => h.id === e.targetId && h.hostname === e.ip && h.port === port)
      ?? {id:e.targetId,label:e.ip,hostname:e.ip,port,username:"",authentication:"password",connectionKind:"ssh",sortOrder:0,distroMode:"auto",iconMode:"auto",iconColorMode:"auto",sftpFileProtocol:"sftp",sftpFilenameEncoding:"auto",sftpUsesSudo:false,serverToolsUseRoot:false,serverToolsElevationMethod:"sudo",createdAt:new Date().toISOString(),updatedAt:new Date().toISOString()} as Host;
    targets.set(e.targetId,{host,elevation:"none"});
  }
  store.setState({historyJobId:id,section:"results",isHistory:true,steps,checks:(result.checks??result.events).reduce(updateChecks,{}),
    events:result.events, conflicts:result.conflicts, reportDirectory:result.reportDirectory??"",backgroundTasks,
    targets:backgroundTasks.length ? restoreBackgroundTargets(backgroundTasks,[],saved) : [...targets.values()]});
  addBatchTab(store);
}
