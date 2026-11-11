import { describe, expect, it, vi } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { createBatchStore, emptyJob, restoreBackgroundTargets, type BatchEvent, type BatchTarget } from "./batch";
import { batchResultsCSV } from "./batchCSV";
import { hostResults } from "./batchResults";
import { closeBatchTab, moveBatchTab, newBatchTab, openBatchHistory, renameBatchTab, useBatchWorkspace } from "./batchWorkspace";
import { useAppStore } from "./store";

vi.mock("@tauri-apps/api/core", () => ({invoke:vi.fn().mockResolvedValue(undefined)}));
vi.mock("@tauri-apps/api/event", () => ({listen:vi.fn().mockResolvedValue(()=>{})}));
const target: BatchTarget = {host:{id:"a",hostname:"127.0.0.1",port:22} as BatchTarget["host"],elevation:"none"};
const phase=(id:number,stage:string,status:string):BatchEvent=>({type:"batchHost",targetId:String(id),ip:`2001:db8::${id}`,stage,status});

describe("Windows batch parity",()=>{
  it("routes simultaneous workers independently and cancels only the chosen run, even during startup",async()=>{
    const first=createBatchStore(), second=createBatchStore();
    for(const store of [first,second]) store.setState({targets:[target]});
    let release!:()=>void;
    vi.mocked(invoke).mockImplementationOnce(()=>new Promise<void>(resolve=>{release=resolve;}));
    const prefs=useAppStore.getState().preferences;
    useAppStore.setState({preferences:{...prefs,autoAcceptSshHostKeys:false}});
    const pending=first.getState().start("check");
    await vi.waitFor(()=>expect(release).toBeTypeOf("function"));
    await first.getState().start("check");
    await first.getState().cancel();
    useAppStore.setState({preferences:{...prefs,autoAcceptSshHostKeys:true}});
    await second.getState().start("check");
    const a=first.getState().runId!, b=second.getState().runId!;
    expect(a).not.toBe(b);
    expect(invoke).toHaveBeenCalledWith("batch_start",expect.objectContaining({runId:a,autoAcceptHostKeys:false}));
    expect(invoke).toHaveBeenCalledWith("batch_start",expect.objectContaining({runId:b,autoAcceptHostKeys:true}));
    expect(vi.mocked(invoke).mock.calls.filter(([cmd])=>cmd==="batch_start")).toHaveLength(2);
    release(); await pending;
    expect(invoke).toHaveBeenCalledWith("batch_cancel",{runId:a});
    const consumer=vi.mocked(listen).mock.calls[0][1] as (event:{payload:BatchEvent})=>void;
    consumer({payload:{runId:a,type:"batchFinished",jobId:"report-a"}});consumer({payload:{runId:a,type:"exit"}});
    expect(first.getState()).toMatchObject({running:false,historyJobId:"report-a",error:""});
    expect(second.getState()).toMatchObject({running:true,events:[]});
    consumer({payload:{runId:b,type:"batchFinished",jobId:"report-b"}});consumer({payload:{runId:b,type:"exit"}});
    expect(second.getState().historyJobId).toBe("report-b");
    useAppStore.setState({preferences:prefs});
  });

  it("keeps config, status, and history bound to tab IDs through rename, reorder and duplicate",async()=>{
    const source=newBatchTab();
    source.store.setState({targets:[target],job:{...emptyJob(),remoteWorkDirectory:"/previous"},running:true});
    const copy=newBatchTab(source);
    expect(copy.store.getState().job.remoteWorkDirectory).toBe("");
    expect(copy.store.getState().targets).toEqual([target]);
    expect(copy.store.getState().targets[0]).not.toBe(target);
    renameBatchTab(copy.id,"  发布  ");renameBatchTab(copy.id,"  ");moveBatchTab(copy.id,source.id);
    closeBatchTab(source.id);
    expect(useBatchWorkspace.getState().tabs.slice(-2).map(t=>t.id)).toEqual([copy.id,source.id]);
    expect(useBatchWorkspace.getState().tabs.find(t=>t.id===copy.id)?.name).toBe("发布");
    vi.mocked(invoke).mockResolvedValueOnce({events:[phase(1,"finished","failed")],conflicts:[],reportDirectory:"history-dir"});
    await openBatchHistory("previous");
    const size=useBatchWorkspace.getState().tabs.length;
    const report=useBatchWorkspace.getState().tabs.at(-1)!;
    expect(report.store.getState().targets[0].host.hostname).toBe("2001:db8::1");
    expect(report.store.getState().job.script.body).toBe("");
    await openBatchHistory("previous");
    expect(useBatchWorkspace.getState().tabs.length).toBe(size);
    expect(source.store.getState().running).toBe(true);
  });

  it("does not reuse a different endpoint's current credentials when reopening a background job",()=>{
    const saved={...target.host,hostname:"other.invalid",password:"different endpoint secret"};
    const [restored]=restoreBackgroundTargets([{targetId:"a",remoteTaskId:"job",hostname:"127.0.0.1",port:22,username:"fixture",elevation:"none"}],[{host:saved,elevation:"su",elevationPassword:"another secret"}],[saved]);
    expect(restored.host.hostname).toBe("127.0.0.1");
    expect(restored.host.password).toBeUndefined();expect(restored.elevationPassword).toBeUndefined();
  });

  it("exports one row per final host and preserves the actual failure details",()=>{
    const events:BatchEvent[]=[];
    for(let i=0;i<159;i++){
      if(i>=109)events.push({...phase(i,"authenticate","failed"),message:'认证失败, "remote"',stderr:"连接超时\n20 s"});
      events.push(phase(i,"finished",i<109?"success":"failed"));
    }
    const rows=hostResults(events,false), tr=(s:string)=>s;
    const failed=batchResultsCSV(rows,"failed",tr), success=batchResultsCSV(rows,"success",tr), all=batchResultsCSV(rows,"all",tr);
    expect(all.charCodeAt(0)).toBe(0xfeff);
    expect(all.match(/"2001:db8::/g)).toHaveLength(159);
    expect(failed.match(/"2001:db8::/g)).toHaveLength(50);
    expect(success.match(/"2001:db8::/g)).toHaveLength(109);
    expect(failed).toContain('认证失败, ""remote""');expect(failed).toContain('连接超时\n20 s');
    expect(success).not.toContain("Failure reason");
    const unfinished=hostResults([phase(1,"authenticate","pending"),phase(2,"finished","cancelled")],true);
    expect(batchResultsCSV(unfinished,"failed",tr)).not.toContain("2001:db8");
  });
});
