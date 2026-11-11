import { beforeEach, describe, expect, it, vi } from "vitest";
const memory = vi.hoisted(() => ({jobs: new Map<string, any>(), drafts: new Map<string, any>(), fail: false, next: 0}));
vi.mock("@tauri-apps/api/core", () => ({invoke: vi.fn(async (command: string, args?: any) => {
  if (command !== "batch_storage") return;
  const r = args.request;
  if (r.operation === "workspace") return {workspace: "windows-0"};
  if (r.operation === "loadDraft") return memory.drafts.get(r.workspace) ?? {payload: null, revision: 0};
  if (r.operation === "saveDraft") {
    if (memory.fail) throw new Error("disk full");
    if (r.revision !== (memory.drafts.get(r.workspace)?.revision ?? 0)) throw new Error("revision conflict");
    memory.drafts.set(r.workspace, {payload: r.payload, revision: r.revision + 1});return {revision: r.revision + 1};
  }
  if (r.operation === "list") return {items: [...memory.jobs.values()]};
  if (r.operation === "save") {
    const old = r.item.id ? memory.jobs.get(r.item.id) : undefined;
    if (r.item.id && (!old || old.revision !== r.item.revision)) throw new Error("revision conflict");
    const item = {...r.item, id: r.item.id ?? `saved-${++memory.next}`, revision: (old?.revision ?? 0) + 1, createdMs: 1, updatedMs: 2};
    memory.jobs.set(item.id, item);return {item};
  }
  if (r.operation === "delete") {memory.jobs.delete(r.id);return {};}
})}));
vi.mock("@tauri-apps/api/event", () => ({listen: vi.fn().mockResolvedValue(() => {})}));
async function modules() {
  return {p:await import("./batchPersistence"),w:await import("./batchWorkspace"),app:await import("./store")};
}
beforeEach(() => {vi.resetModules();memory.jobs.clear();memory.drafts.clear();memory.fail=false;memory.next=0;});
describe("saved batch jobs and drafts", () => {
  it("restores tab order, selection, full configuration and references in a fresh client", async () => {
    const {p,w,app}=await modules();await p.initializeBatchPersistence();
    const host={id:crypto.randomUUID(),label:"生产",hostname:"192.0.2.1",port:22,username:"ops",password:"login-secret",identityKey:"private-key"} as any;
    app.useAppStore.setState({hosts:[host]});
    const a=w.newBatchTab(),b=w.newBatchTab();w.renameBatchTab(a.id,"巡检");w.renameBatchTab(b.id,"收集日志");
    a.store.setState(s=>({job:{...s.job,script:{...s.job.script,body:"echo hello",environment:{TOKEN:"script-value"}},concurrency:9,remoteWorkDirectory:"/old",sourceTaskId:"old"},
      targets:[{host,elevation:"sudo",elevationPassword:"sudo-secret",savedHostId:host.id}],defaults:{ips:"192.0.2.2",port:2222,credential:"",elevation:"su",password:"default-secret"},running:true}));
    w.moveBatchTab(b.id,a.id);w.selectBatchTab(a.id);await p.flushBatchDrafts();
    const raw=memory.drafts.get("windows-0").payload;
    for(const secret of ["login-secret","private-key","sudo-secret","default-secret"])expect(raw).not.toContain(secret);
    const order=w.useBatchWorkspace.getState().tabs.map(t=>t.id);
    vi.resetModules();const next=await modules();next.app.useAppStore.setState({hosts:[{...host,password:"latest-secret"}]});await next.p.initializeBatchPersistence();
    const state=next.w.useBatchWorkspace.getState(),tab=state.tabs.find(t=>t.id===a.id)!;
    expect(state.tabs.map(t=>t.id)).toEqual(order);expect(state.selected).toBe(a.id);expect(tab.name).toBe("巡检");expect(tab.store.getState().running).toBe(false);
    expect(tab.store.getState().job).toMatchObject({concurrency:9,remoteWorkDirectory:"",sourceTaskId:"",script:{body:"echo hello",environment:{TOKEN:"script-value"}}});
    expect(tab.store.getState().targets[0]).toMatchObject({savedHostId:host.id,host:{password:"latest-secret"}});
    expect(tab.store.getState().targets[0].elevationPassword).toBeUndefined();expect(tab.store.getState().defaults.password).toBe("");
  });
  it("isolates saved versions, drafts and save-as copies, and focuses existing tabs",async()=>{
    const {p,w}=await modules();await p.initializeBatchPersistence();const tab=w.newBatchTab();
    tab.store.setState(s=>({job:{...s.job,script:{...s.job.script,body:"original"}}}));const original=await p.saveBatchJob(tab,"Original");
    const active=()=>w.useBatchWorkspace.getState().tabs.find(t=>t.id===tab.id)!;
    tab.store.setState(s=>({job:{...s.job,script:{...s.job.script,body:"temporary"}}}));await p.flushBatchDrafts();
    expect(JSON.parse(memory.jobs.get(original.id).configuration).job.script.body).toBe("original");
    const copy=await p.saveBatchJob(active(),"Copy",true);expect(copy.id).not.toBe(original.id);expect(memory.jobs.size).toBe(2);
    const count=w.useBatchWorkspace.getState().tabs.length;p.openSavedBatchJob(copy);expect(w.useBatchWorkspace.getState().tabs.length).toBe(count);
    p.openSavedBatchJob(original);expect(w.useBatchWorkspace.getState().tabs.at(-1)?.store.getState().job.script.body).toBe("original");
    await p.deleteSavedBatchJob(copy);expect(active().savedId).toBeUndefined();expect(active().store.getState().job.script.body).toBe("temporary");await p.flushBatchDrafts();
  });
  it("retains failed writes for retry and never overwrites an unreadable startup snapshot",async()=>{
    const {p,w}=await modules();memory.drafts.set("windows-0",{payload:'{"version":99,"tabs":[]}',revision:7});
    await p.initializeBatchPersistence();expect(p.useBatchLibrary.getState().ready).toBe(false);expect(memory.drafts.get("windows-0").revision).toBe(7);
    memory.drafts.delete("windows-0");await p.initializeBatchPersistence();const tab=w.newBatchTab();memory.fail=true;
    await expect(p.flushBatchDrafts()).rejects.toThrow("disk full");expect(p.hasPendingBatchDrafts()).toBe(true);expect(p.useBatchLibrary.getState().draftStatus).toBe("Draft not saved");
    tab.store.setState(s=>({job:{...s.job,script:{...s.job.script,body:"latest edit"}}}));memory.fail=false;await p.flushBatchDrafts();
    expect(p.hasPendingBatchDrafts()).toBe(false);expect(memory.drafts.get("windows-0").payload).toContain("latest edit");
  });
  it("blocks deleted or changed saved hosts before starting a worker",async()=>{
    const {w,app}=await modules();const tab=w.newBatchTab(),host={id:crypto.randomUUID(),label:"old",hostname:"192.0.2.1",port:22} as any;
    tab.store.setState({targets:[{host,savedHostId:host.id,elevation:"none"}]});app.useAppStore.setState({hosts:[]});
    await expect(tab.store.getState().start("check")).rejects.toThrow("A saved host is missing");
    app.useAppStore.setState({hosts:[{...host,hostname:"192.0.2.2"}]});await expect(tab.store.getState().start("check")).rejects.toThrow("A saved host is missing");expect(tab.store.getState().running).toBe(false);
  });
});
