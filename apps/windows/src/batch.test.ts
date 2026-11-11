import { beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn().mockResolvedValue(undefined) }));
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn().mockResolvedValue(() => {}) }));
import { invoke } from "@tauri-apps/api/core";
import { downloadRetryPlan, emptyJob, restoreBackgroundTargets, mergeTargets, updateConflicts, useBatchStore, type BatchTarget } from "./batch";
const target = (id: string, hostname: string, port=22):BatchTarget => ({host:{id,hostname,port,credentialId:"vault-credential"} as BatchTarget["host"],elevation:"sudo"});
describe("batch jobs",()=>{
 beforeEach(()=>{vi.clearAllMocks();useBatchStore.setState({backgroundTasks:[],historyJobId:"",steps:{},checks:{},job:emptyJob(),targets:[],events:[],conflicts:[],hostStates:{},progress:{},running:false,error:""});});
 it("deduplicates targets by endpoint while preserving different SSH ports",()=>{
  const first=target("a","10.0.0.1");const merged=mergeTargets([first],[target("b","10.0.0.1"),target("c","10.0.0.1",2222)]);
  expect(merged).toEqual([first,target("c","10.0.0.1",2222)]);
 });
 it("retains successful and skipped conflicts independently of the bounded event log",()=>{
  let conflicts=updateConflicts([],{type:"batchHost",stage:"conflict",targetId:"a",ip:"10.0.0.1",remotePath:"/opt/file",policy:"backup",status:"detected"});
  conflicts=updateConflicts(conflicts,{type:"batchHost",stage:"upload",targetId:"a",remotePath:"/opt/file",status:"success",backupPath:"/opt/file.backup"});
  for(let i=0;i<4000;i++)conflicts=updateConflicts(conflicts,{type:"batchHost",stage:"connect",targetId:String(i)});
  expect(conflicts).toHaveLength(1);expect(conflicts[0]).toMatchObject({ip:"10.0.0.1",status:"success",policy:"backup",backupPath:"/opt/file.backup"});
 });
 it("download-only retry reuses workspace and task variables without replaying preparation",async()=>{
  const job=emptyJob();job.kind="collect";job.before.body="expensive preparation";job.after.body="cleanup";job.remotePaths=["${REMOTE_WORK_DIR}/${TASK_ID}.log"];job.localDirectory="/tmp/out";
  useBatchStore.setState({job,targets:[target("a","10.0.0.1")],events:[{type:"batchHost",targetId:"a",stage:"workspace",remoteWorkDirectory:"/tmp/termpilot-batch-a6e2a19e-6902-428d-bbcf-c50e9e85ace1",sourceTaskId:"2c74ada6-8d81-4b30-8e23-d8bf23244865"},{type:"batchHost",targetId:"a",stage:"finished",status:"failed"}]});
  await useBatchStore.getState().start(undefined,"download");
  expect(invoke).toHaveBeenCalledWith("batch_start",expect.objectContaining({job:expect.objectContaining({before:expect.objectContaining({body:""}),after:expect.objectContaining({body:"cleanup"}),remoteWorkDirectory:"/tmp/termpilot-batch-a6e2a19e-6902-428d-bbcf-c50e9e85ace1",sourceTaskId:"2c74ada6-8d81-4b30-8e23-d8bf23244865"})}));
 });
 it("blocks download-only reuse of finalized temporary files, but retries direct paths from persisted steps",async()=>{
  const job=emptyJob();job.kind="collect";job.before.body="prepare";job.remotePaths=["${REMOTE_WORK_DIR}/result.log"];
  const workspace="/tmp/ssh-batch-a6e2a19e-6902-428d-bbcf-c50e9e85ace1";
  const targets=[target("a","10.0.0.1")];
  for(const cleanupStatus of ["pending","running","success","failed"]) {
   const events:BatchEvent[]=[{type:"batchHost",targetId:"a",stage:"workspace",remoteWorkDirectory:workspace,cleanupStatus,sourceTaskId:"source"},{type:"batchHost",targetId:"a",stage:"finished",status:"failed"}];
   useBatchStore.setState({job,targets,events:[],hostStates:{},steps:events.reduce(updateSteps,{})});
   await expect(useBatchStore.getState().start(undefined,"download")).rejects.toThrow("Rerun collection");
   expect(()=>downloadRetryPlan({...job,remotePaths:[workspace+"/result.log"]},events,targets)).toThrow("Rerun collection");
  }
  expect(invoke).not.toHaveBeenCalled();
  useBatchStore.setState({job:{...job,remotePaths:["/var/log/app-${TASK_ID}.log"]}});
  await useBatchStore.getState().start(undefined,"download");
  expect(invoke).toHaveBeenCalledWith("batch_start",expect.objectContaining({job:expect.objectContaining({remoteWorkDirectory:"",sourceTaskId:"source",before:expect.objectContaining({body:""})}),targets}));
 });
 it("never dispatches an empty batch",async()=>{await expect(useBatchStore.getState().start()).rejects.toThrow("Select at least one");expect(invoke).not.toHaveBeenCalled();});
});

import { checkGroups, updateChecks, groupHostIds, groupPath, selectableHosts, toggleSelection, hostTreeRows } from "./batchPresentation";
import type { BatchEvent } from "./batch";
import type { Host, HostGroup } from "./types";
const phase = (targetId: string, stage: string, status: string): BatchEvent => ({ type: "batchHost", targetId, ip: `192.0.2.${targetId}`, stage, status });
describe("batch result categories", () => {
 it("uses green, red and yellow only for the corresponding completed outcomes", () => {
  for (const [statuses, indicator] of [[['success','success'],'success'],[['failed','failed'],'failed'],[['success','failed'],'mixed']] as const) {
   const events = statuses.flatMap((status,i) => ['authenticate','elevation','finished'].map(stage=>phase(String(i),stage,status)));
   expect(checkGroups(events,false).map(g=>g.indicator)).toEqual([indicator,indicator,indicator]);
  }
 });
 it("keeps queued hosts in totals and does not turn an incomplete check green", () => {
  const events=[phase('1','authenticate','success'),phase('1','finished','success'),phase('2','authenticate','pending')];
  const groups=checkGroups(events,true);
  expect(groups[0].indicator).toBe('running');expect(groups[0].counts).toMatchObject({success:1,pending:1});
  expect(checkGroups([phase('1','finished','success')],false).map(g=>g.indicator)).toEqual(['success','success','success']);
 });
 it("preserves authentication success when elevation fails, including older history", () => {
  const events=[phase('1','connect','running'),phase('1','authenticate','success'),{...phase('1','finished','failed'),message:'Elevation check failed'},phase('2','connect','running'),{...phase('2','finished','failed'),message:'Authentication denied'}];
  const groups=checkGroups(events,false);
  expect(groups[0].indicator).toBe('mixed');
  expect(groups[1].counts).toMatchObject({failed:1,skipped:1});
  expect(groups[2].indicator).toBe('failed');
  expect(groups[1].rows.find(e=>e.targetId==='2')?.message).toContain('not checked');
 });
 it("retains one latest row per phase and distinguishes cancellation from failure", () => {
  let checks:Record<string,BatchEvent>={};
  for(const event of [phase('1','authenticate','pending'),phase('1','authenticate','running'),phase('1','authenticate','success'),phase('1','elevation','cancelled'),phase('1','finished','cancelled')])checks=updateChecks(checks,event);
  expect(Object.values(checks)).toHaveLength(3);
  const groups=checkGroups(Object.values(checks),false);expect(groups[0].indicator).toBe('success');expect(groups[1].indicator).toBe('neutral');
  expect(checkGroups([phase('1','authenticate','running')],false)[0].rows[0].status).toBe('unknown');
 });
});
describe("saved-host multi selection",()=>{
 const groups:HostGroup[]=[{id:'parent',name:'Prod',sortOrder:0},{id:'child',name:'DB',parentGroupId:'parent',sortOrder:0}];
 const hosts=[{...target('a','192.0.2.1').host,groupId:'parent'},{...target('b','192.0.2.2').host,groupId:'child'},target('c','192.0.2.3').host,{...target('d','192.0.2.4').host,connectionKind:'rdp'}] as Host[];
 it("selects subgroups, excludes non-SSH endpoints and avoids duplicates",()=>{
  const available=selectableHosts([...hosts,{...hosts[0],id:'duplicate'}]);
  expect(available).toHaveLength(3);expect(groupHostIds('parent',available,groups)).toEqual(['a','b']);
  expect(groupHostIds(undefined,available,groups)).toEqual(['c']);expect(groupPath('child',groups)).toBe('Prod / DB');
  expect(hostTreeRows(available,groups,'',new Set()).map(r=>r.id)).toEqual(['parent','ungrouped']);
  const expanded=hostTreeRows(available,groups,'',new Set(['parent','child']));
  expect(expanded.map(r=>r.id)).toEqual(['parent','host:a','child','host:b','ungrouped']);
  expect(expanded.map(r=>r.depth)).toEqual([0,1,1,2,0]);
  expect(hostTreeRows(available,groups,'192.0.2.2',new Set(['parent','child'])).map(r=>r.id)).toEqual(['parent','child','host:b']);
 });
 it("supports mixed group selection without removing already-added hosts",()=>{
  let selected=toggleSelection(new Set(),['a','b'],new Set(['a']));expect([...selected]).toEqual(['b']);
  selected=toggleSelection(selected,['a','b'],new Set(['a']));expect(selected.size).toBe(0);
 });
});

import { workspaceCleanupLabel, filterHostResults, hostResults, stepKey, transferProgress, updateSteps } from "./batchResults";
describe("host result consolidation", () => {
 it("retains cleanup outcome in history and shows cleanup failure at host level",()=>{
  const workspace={...phase('1','workspace','success'),remoteWorkDirectory:'/tmp/ssh-batch-a6e2a19e-6902-428d-bbcf-c50e9e85ace1',cleanupStatus:'pending'};
  const events=[phase('1','authenticate','success'),phase('1','elevation','success'),workspace,phase('1','execute','success'),{...workspace,status:'running',cleanupStatus:'running'}];
  expect(hostResults(events,true)[0].label).toBe('Cleaning temporary directory');
  expect(workspaceCleanupLabel(hostResults(events,false)[0].information[0])).toBe('Cleanup status unknown');
  events.push({...workspace,status:'failed',cleanupStatus:'failed'},phase('1','finished','failed'));
  const row=hostResults(Object.values(events.reduce(updateSteps,{})),false)[0];
  expect(row.label).toBe('Temporary directory cleanup failed');expect(row.information).toHaveLength(1);expect(row.hasFailure).toBe(true);
  expect(workspaceCleanupLabel(row.information[0])).toBe('Temporary directory cleanup failed');
  expect(workspaceCleanupLabel({...workspace,cleanupStatus:undefined})).toBe('Cleanup status unknown');
 });
 it("updates each step in place, retains output and keeps repeated file collections distinct", () => {
  const events: BatchEvent[] = [phase('1','authenticate','success'),phase('1','elevation','success'),
   {...phase('1','collect','running'),stepId:'collect-0',remotePath:'/log',localPath:'/saved/log'},
   {...phase('1','collect','success'),stepId:'collect-0',remotePath:'/log'},
   {...phase('1','collect','success'),stepId:'collect-1',remotePath:'/log',localPath:'/saved/log-1'},phase('1','collection','success'),phase('1','finished','success')];
  const [row]=hostResults(events,false);
  expect(row.steps.filter(e=>e.stage==='collect')).toHaveLength(2);
  expect(row.steps.find(e=>e.stepId==='collect-0')).toMatchObject({status:'success',localPath:'/saved/log'});
  expect(row.steps.some(e=>e.status==='running'||e.stage==='collection'||e.stage==='finished')).toBe(false);
  const steps=events.reduce(updateSteps,{});expect(hostResults(Object.values(steps),false)).toEqual([row]);
  expect(stepKey(events[2])).toBe(stepKey(events[3]));
 });
 it("sorts failures first and filters on host and failed phase without hiding successful authentication", () => {
  const events=[phase('1','authenticate','success'),phase('1','elevation','success'),phase('1','execute','success'),phase('1','finished','success'),phase('2','authenticate','success'),phase('2','elevation','failed'),phase('2','finished','failed'),phase('3','authenticate','pending')];
  const rows=hostResults(events,true);expect(rows[0]).toMatchObject({id:'2',label:'Elevation failed',authentication:{status:'success'}});
  expect(filterHostResults(rows,'failed','','').map(h=>h.id)).toEqual(['2']);
  expect(filterHostResults(rows,'all','authenticate','')).toEqual([]);
  expect(filterHostResults(rows,'all','elevation','').map(h=>h.id)).toEqual(['2']);
  expect(filterHostResults(rows,'running','','').map(h=>h.id)).toEqual(['3']);
  expect(filterHostResults(rows,'all','','1').map(h=>h.id)).toEqual(['1']);
 });
 it("closes incomplete states after cancellation or exit, and hides stale transfer progress", () => {
  const events=[phase('1','authenticate','success'),phase('1','elevation','success'),{...phase('1','upload','running'),stepId:'upload-1',remotePath:'/new'}];
  let [row]=hostResults(events,true);const transfer={type:'batchEvent',event:{type:'sftpResponse',message:{id:'upload-1',total:100,transferred:40}}};
  expect(transferProgress(row,transfer)?.transferred).toBe(40);
  expect(transferProgress(row,{...transfer,event:{...transfer.event,message:{...transfer.event.message,id:'upload-0'}}})).toBeUndefined();
  [row]=hostResults([...events,phase('1','finished','cancelled')],false);
  expect(row.steps.find(e=>e.stage==='upload')?.status).toBe('cancelled');expect(transferProgress(row,transfer)).toBeUndefined();
  expect(hostResults(events,false)[0].steps.some(e=>e.status==='running')).toBe(false);
 });
 it("passes a zero timeout through to the shared backend", async () => {
  useBatchStore.setState({running:false,job:{...emptyJob(),stepTimeout:0,script:{...emptyJob().script,body:'sleep 2'}},targets:[target('zero','192.0.2.1')]});
  await useBatchStore.getState().start();expect(invoke).toHaveBeenLastCalledWith('batch_start',expect.objectContaining({job:expect.objectContaining({stepTimeout:0,connectTimeout:120})}));
 });
});

describe("background execution", () => {
 it("keeps detached tasks running after the local worker has exited", () => {
  const events=[phase('1','authenticate','success'),phase('1','elevation','success'),phase('1','execute','running'),
   {...phase('1','workspace','success'),cleanupStatus:'pending'}, {...phase('1','finished','running'),background:true}];
  const row=hostResults(events,false)[0];
  expect(row.status).toBe('running');expect(row.label).toBe('Background running');
  expect(row.steps.at(-1)?.status).toBe('running');expect(row.information[0].cleanupStatus).toBe('pending');
 });
 it("is opt in and restores references without recording passwords", () => {
  expect(emptyJob().executionMode).toBe("foreground");
  const job=emptyJob();
  expect([job.script.shell,job.before.shell,job.after.shell]).toEqual(["/bin/bash","/bin/bash","/bin/bash"]);
  const tasks=[{targetId:"original",remoteTaskId:"remote",hostname:"192.0.2.2",port:2222,username:"ops",credentialId:"vault",elevation:"su" as const}];
  const restored=restoreBackgroundTargets(tasks,[],[])[0];
  expect(restored.host).toMatchObject({id:"original",hostname:"192.0.2.2",port:2222,username:"ops",credentialId:"vault"});
  expect(restored.host.password).toBeUndefined();expect(restored.elevation).toBe("su");
 });
 it("queries an existing receipt and retains last output without resubmitting", async () => {
  useBatchStore.setState({running:false,historyJobId:"history-id",backgroundTasks:[{targetId:"original",remoteTaskId:"remote",hostname:"192.0.2.2",port:22,username:"ops",credentialId:"vault",elevation:"sudo"}],steps:{previous:{type:"batchHost",stage:"execute",targetId:"original",stdout:"last output"}}});
  await useBatchStore.getState().start(undefined,undefined,"status");
  expect(invoke).toHaveBeenCalledWith("batch_start",expect.objectContaining({historyJobId:"history-id",backgroundAction:"status"}));
  expect(useBatchStore.getState().steps.previous.stdout).toBe("last output");
 });
 it("preserves the last remote output when reconnect setup fails", async () => {
  useBatchStore.setState({running:false,historyJobId:"history-id",backgroundTasks:[{targetId:"original",remoteTaskId:"remote",hostname:"192.0.2.2",port:22,username:"ops",credentialId:"vault",elevation:"sudo"}],steps:{previous:{type:"batchHost",stage:"execute",targetId:"original",stdout:"last output"}}});
  vi.mocked(invoke).mockRejectedValueOnce(new Error("Credential unavailable"));
  await expect(useBatchStore.getState().start(undefined,undefined,"status")).rejects.toThrow("Credential unavailable");
  expect(useBatchStore.getState().steps.previous.stdout).toBe("last output");
 });
});
