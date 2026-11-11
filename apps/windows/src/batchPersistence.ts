import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import { DeferredWrite } from "./deferredWrite";
import { createBatchStore, emptyJob, type BatchJob, type BatchTarget, type Elevation } from "./batch";
import { useBatchWorkspace, selectBatchTab, type BatchTab } from "./batchWorkspace";
import { useAppStore } from "./store";
import type { Host } from "./types";

export interface SavedBatchJob {
  id: string; name: string; configuration: string; createdMs: number; updatedMs: number; revision: number;
}
interface TargetReference {
  id: string; savedHostId?: string; label: string; hostname: string; port: number; username: string;
  credentialId?: string; proxyProfileId?: string; elevation: Elevation;
}
export interface SavedBatchConfiguration {
  version: 1; job: BatchJob; targets: TargetReference[];
  defaults: {ips: string; port: number; credential: string; elevation: Elevation};
}
interface DraftTab {id: string; name?: string; number: number; savedId?: string; savedRevision?: number; configuration: string}
interface DraftDocument {version: 1; tabs: DraftTab[]; selected: string}
const request = <T>(value: Record<string, unknown>) => invoke<T>("batch_storage", {request: value});
export const useBatchLibrary = create<{items: SavedBatchJob[]; ready: boolean; error: string; draftError: string; draftStatus: string}>(() => ({items: [], ready: false, error: "", draftError: "", draftStatus: ""}));
const message = (e: unknown) => e instanceof Error ? e.message : String(e);
const sameID = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase();

export function savedConfiguration(tab: BatchTab): string {
  const {job, targets, defaults} = tab.store.getState();
  const hosts = useAppStore.getState().hosts;
  const configuration: SavedBatchConfiguration = {
    version: 1, job: {...job, remoteWorkDirectory: "", sourceTaskId: ""},
    targets: targets.map(({host, elevation, savedHostId}) => ({id: host.id, savedHostId: savedHostId ?? hosts.find(h => sameID(h.id, host.id))?.id,
      label: host.label ?? host.hostname, hostname: host.hostname, port: host.port, username: host.username ?? "",
      credentialId: host.credentialId || undefined, proxyProfileId: host.proxyProfileId || undefined, elevation})),
    defaults: {ips: defaults.ips, port: defaults.port, credential: defaults.credential, elevation: defaults.elevation},
  };
  return JSON.stringify(configuration);
}
export function parseConfiguration(text: string): SavedBatchConfiguration {
  const value = JSON.parse(text) as SavedBatchConfiguration;
  if (value.version !== 1 || !value.job || !Array.isArray(value.targets) || !value.defaults)
    throw new Error("Invalid or unsupported saved job.");
  return value;
}
function restoredStore(text: string) {
  const config = parseConfiguration(text), hosts = useAppStore.getState().hosts;
  const targets: BatchTarget[] = config.targets.map(target => {
    const saved = target.savedHostId ? hosts.find(h => sameID(h.id, target.savedHostId)) : undefined;
    const host: Host = {...(saved ?? {authentication: "password", sortOrder: 0, distroMode: "auto", iconMode: "auto", iconColorMode: "auto",
      sftpFileProtocol: "sftp", sftpFilenameEncoding: "auto", sftpUsesSudo: false, serverToolsUseRoot: false,
      serverToolsElevationMethod: "sudo", createdAt: new Date().toISOString(), updatedAt: new Date().toISOString()}),
      id: target.id, label: target.label, hostname: target.hostname, port: target.port,
      username: target.credentialId ? "" : (saved?.username ?? target.username),
      credentialId: target.credentialId, proxyProfileId: target.proxyProfileId};
    return {host, elevation: target.elevation, savedHostId: target.savedHostId};
  });
  const store = createBatchStore();
  store.setState({job: {...emptyJob(), ...config.job, remoteWorkDirectory: "", sourceTaskId: ""}, targets,
    defaults: {...config.defaults, password: ""}, section: "configuration"});
  return store;
}
let workspace = "", revision = 0, initializing: Promise<void> | undefined;
let subscriptions: (() => void)[] = [];
let workspaceSubscription: (() => void) | undefined;
const drafts = new DeferredWrite<string>(async payload => {
  const result = await request<{revision: number}>({operation: "saveDraft", workspace, payload, revision});
  revision = result.revision;
}, error => useBatchLibrary.setState(error === undefined
  ? {draftStatus: "Draft saved", draftError: ""} : {draftStatus: "Draft not saved", draftError: message(error)}), 650, 1500);

function snapshot(): string {
  const state = useBatchWorkspace.getState();
  return JSON.stringify({version: 1, selected: state.selected, tabs: state.tabs.map(tab => ({
    id: tab.id, name: tab.name, number: tab.number, savedId: tab.savedId, savedRevision: tab.savedRevision,
    configuration: savedConfiguration(tab),
  }))} satisfies DraftDocument);
}
function enqueueDraft() {
  if (!useBatchLibrary.getState().ready) return;
  try { drafts.enqueue(snapshot()); useBatchLibrary.setState({draftStatus: "Saving draft…"}); }
  catch (error) { useBatchLibrary.setState({draftError: message(error), draftStatus: "Draft not saved"}); }
}
function observeTabs() {
  subscriptions.forEach(stop => stop());
  subscriptions = useBatchWorkspace.getState().tabs.map(tab => tab.store.subscribe((next, previous) => {
    if (next.job !== previous.job || next.targets !== previous.targets || next.defaults !== previous.defaults) enqueueDraft();
  }));
}
export async function initializeBatchPersistence() {
  if (useBatchLibrary.getState().ready) return;
  if (initializing) return initializing;
  initializing = (async () => {
    if (!workspace) workspace = (await request<{workspace: string}>({operation: "workspace"})).workspace;
    const result = await request<{payload: string | null; revision: number}>({operation: "loadDraft", workspace});
    let tabs: BatchTab[] | undefined, selected: string | undefined;
    if (result.payload) {
      const doc = JSON.parse(result.payload) as DraftDocument;
      if (doc.version !== 1 || !Array.isArray(doc.tabs)) throw new Error("Invalid or unsupported saved job.");
      tabs = doc.tabs.map(tab => ({id: tab.id, number: tab.number, name: tab.name, savedId: tab.savedId,
        savedRevision: tab.savedRevision, store: restoredStore(tab.configuration)}));
      selected = doc.selected;
    }
    revision = result.revision;
    if (tabs?.length) useBatchWorkspace.setState({tabs, selected: tabs.find(t => t.id === selected)?.id ?? tabs[0].id, next: Math.max(...tabs.map(t => t.number)) + 1});
    useBatchLibrary.setState({ready: true, draftError: "", draftStatus: tabs?.length ? "Drafts restored" : ""});
    observeTabs();
    workspaceSubscription?.();
    workspaceSubscription = useBatchWorkspace.subscribe((next, previous) => {
      if (next.tabs !== previous.tabs) observeTabs();
      if (next.tabs !== previous.tabs || next.selected !== previous.selected) enqueueDraft();
    });
  })().catch(error => { useBatchLibrary.setState({draftError: message(error)}); }).finally(() => { initializing = undefined; });
  return initializing;
}
export function hasPendingBatchDrafts() { return drafts.dirty; }
export async function flushBatchDrafts() { await drafts.flush(); }
export async function retryBatchPersistence() {
  if (!useBatchLibrary.getState().ready) await initializeBatchPersistence();
  else { enqueueDraft(); await drafts.flush(); }
}
export async function loadBatchLibrary() {
  try {
    const result = await request<{items: SavedBatchJob[]}>({operation: "list"});
    useBatchLibrary.setState({items: result.items, error: ""});
  } catch (error) { useBatchLibrary.setState({error: message(error)}); throw error; }
}
export async function saveBatchJob(tab: BatchTab, name: string, asCopy = false) {
  try {
    const {item} = await request<{item: SavedBatchJob}>({operation: "save", item: {
      name, configuration: savedConfiguration(tab), ...(asCopy ? {} : {id: tab.savedId, revision: tab.savedRevision}),
    }});
    useBatchWorkspace.setState(s => ({tabs: s.tabs.map(t => t.id === tab.id ? {...t, name: item.name, savedId: item.id, savedRevision: item.revision} : t)}));
    await loadBatchLibrary(); await drafts.flush();
    return item;
  } catch (error) { useBatchLibrary.setState({error: message(error)}); throw error; }
}
export function openSavedBatchJob(item: SavedBatchJob, asCopy = false) {
  const current = useBatchWorkspace.getState();
  const existing = current.tabs.find(tab => sameID(tab.savedId, item.id));
  if (!asCopy && existing) { selectBatchTab(existing.id); return; }
  const store = restoredStore(item.configuration), id = crypto.randomUUID();
  const tab: BatchTab = {id, number: current.next, name: item.name, store,
    savedId: asCopy ? undefined : item.id, savedRevision: asCopy ? undefined : item.revision};
  useBatchWorkspace.setState({tabs: [...current.tabs, tab], selected: id, next: current.next + 1});
}
export async function renameSavedBatchJob(item: SavedBatchJob, name: string) {
  const result = await request<{item: SavedBatchJob}>({operation: "save", item: {...item, name}});
  useBatchWorkspace.setState(s => ({tabs: s.tabs.map(tab => sameID(tab.savedId, item.id) ? {...tab, name: result.item.name, savedRevision: tab.savedRevision === item.revision ? result.item.revision : tab.savedRevision} : tab)}));
  await loadBatchLibrary();
}
export async function deleteSavedBatchJob(item: SavedBatchJob) {
  await request({operation: "delete", id: item.id, revision: item.revision});
  useBatchWorkspace.setState(s => ({tabs: s.tabs.map(tab => sameID(tab.savedId, item.id) ? {...tab, savedId: undefined, savedRevision: undefined} : tab)}));
  await loadBatchLibrary();
}
