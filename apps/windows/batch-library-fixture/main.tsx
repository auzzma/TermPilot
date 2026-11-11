// Development-only UI fixture; never part of the application build or real vault.
import React from "react";
import {createRoot} from "react-dom/client";
import {mockIPC, mockWindows} from "@tauri-apps/api/mocks";
import {BatchWorkspace} from "../src/components/BatchWorkspace";
import {initializeBatchPersistence} from "../src/batchPersistence";
import {useAppStore} from "../src/store";
import "../src/styles.css";
import "../src/windows-shell.css";

const key="termpilot-batch-library-synthetic-fixture";
const storage=JSON.parse(localStorage.getItem(key) ?? '{"jobs":[],"draft":null,"revision":0}');
const persist=()=>localStorage.setItem(key,JSON.stringify(storage));
mockWindows("main");
mockIPC((command,args:any)=>{
 if(command!=="batch_storage") return undefined;
 const r=args.request;
 switch(r.operation){
 case "workspace":return {workspace:"fixture"};
 case "loadDraft":return {payload:storage.draft,revision:storage.revision};
 case "saveDraft":storage.draft=r.payload;storage.revision++;persist();return {revision:storage.revision};
 case "list":return {items:storage.jobs};
 case "save":{
  const old=storage.jobs.find((x:any)=>x.id===r.item.id);
  if(r.item.id&&old?.revision!==r.item.revision)throw Error("revision conflict");
  const item={...r.item,id:r.item.id??crypto.randomUUID(),createdMs:old?.createdMs??Date.now(),updatedMs:Date.now(),revision:(old?.revision??0)+1};
  storage.jobs=storage.jobs.filter((x:any)=>x.id!==item.id).concat(item);persist();return {item};
 }
 case "delete":storage.jobs=storage.jobs.filter((x:any)=>x.id!==r.id);persist();return {};
 }
},{shouldMockEvents:true});
useAppStore.setState(s=>({loading:false,preferences:{...s.preferences,language:"zh-Hans",theme:"light"}}));
document.documentElement.dataset.theme="light";
await initializeBatchPersistence();
createRoot(document.getElementById("root")!).render(<div style={{height:"100vh",display:"flex",flexDirection:"column"}}>
 <div style={{fontSize:12,padding:"6px 18px",background:"#fff5d6",color:"#614500"}}>作业库测试 · 合成数据 · 可刷新页面验证草稿恢复</div>
 <div style={{flex:1,minHeight:0}}><BatchWorkspace/></div>
</div>);
