import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { listen } from "@tauri-apps/api/event";
import { ArrowDownToLine, ArrowUpFromLine, ArrowUpDown, Inbox, RotateCcw, Pause, Play, X } from "lucide-react";
import { useTranslation } from "../i18n";
import { useAppStore } from "../store";
import { useWindowVisible } from "../windowActivity";
import { clearFinishedTransfers, controlFileTransfer, hasTransferControl, isTransferActive, retryTransfers, updateTransferProgress, useTransferStore, transferStateTitle, type TransferProgress, type TransferRecord } from "./SftpPanel";

function bytes(n: number) {
  if (!Number.isFinite(n) || n <= 0) return "0 B";
  const unit = Math.min(3, Math.floor(Math.log(n) / Math.log(1024)));
  return `${(n / 1024 ** unit).toFixed(unit ? 1 : 0)} ${["B", "KiB", "MiB", "GiB"][unit]}`;
}
function speedLabel(n: number) { return `${(Math.max(0,n)/1048576).toFixed(2)} MiB/s`; }
export function transferSpeed(item: TransferRecord, now: number) {
  return item.state === "running" && now - item.sampledAt < 2000 ? Math.max(0, item.bytesPerSecond) : 0;
}

const filters = ["All", "Running", "Queued", "Paused", "Needs attention", "Completed"] as const;
export function inTransferFilter(item:TransferRecord, filter:typeof filters[number]) {
  switch (filter) {
    case "Running":return item.state==="running";
    case "Queued":return item.state==="waiting";
    case "Paused":return item.state==="paused";
    case "Needs attention":return item.state==="failed" || item.state==="conflict";
    case "Completed":return !isTransferActive(item.state);
    default:return true;
  }
}
export function TransferToolbar() {
  const visible=useWindowVisible(), t=useTranslation(), items=useTransferStore(s=>s.transfers);
  const [open,setOpen]=useState(false), [filter,setFilter]=useState<typeof filters[number]>("All");
  const [error,setError]=useState(""), [pending,setPending]=useState<string[]>([]), [now,setNow]=useState(Date.now());
  const trigger=useRef<HTMLButtonElement>(null), panel=useRef<HTMLElement>(null);
  const [top,setTop]=useState(48);
  useEffect(()=>{
    const off=listen<TransferProgress>("sftp-progress",({payload})=>{
      useTransferStore.getState().setTransfers(rows=>rows.map(r=>r.transferKey===payload.transferKey && ["running","paused"].includes(r.state)
        ? updateTransferProgress(r,payload,Date.now()):r));
    });
    const unsubscribe=useAppStore.subscribe((next,previous)=>{
      if(next.workspace.sessions===previous.workspace.sessions)return;
      const removed=new Set(previous.workspace.sessions.map(session=>session.id));
      for(const session of next.workspace.sessions)removed.delete(session.id);
      for(const item of useTransferStore.getState().transfers){
        if(!item.owner || !removed.has(item.owner))continue;
        retryTransfers.delete(item.id);
        if(item.state==="waiting" && ["SFTP","SCP"].includes(item.protocol??""))void controlFileTransfer(item.id,"cancel").catch(()=>{});
      }
    });
    return ()=>{unsubscribe();void off.then(f=>f());};
  },[]);
  useEffect(()=>{
    if(!open)return;
    const place=()=>setTop(Math.max(4,(trigger.current?.getBoundingClientRect().bottom??36)+6));
    const outside=(e:PointerEvent)=>{if(!panel.current?.contains(e.target as Node)&&!trigger.current?.contains(e.target as Node))setOpen(false);};
    const key=(e:KeyboardEvent)=>{if(e.key==="Escape"){setOpen(false);trigger.current?.focus();}};
    place();window.addEventListener("resize",place);document.addEventListener("pointerdown",outside);document.addEventListener("keydown",key);
    return ()=>{window.removeEventListener("resize",place);document.removeEventListener("pointerdown",outside);document.removeEventListener("keydown",key);};
  },[open]);
  const running=items.some(i=>i.state==="running");
  useEffect(()=>{if(!open||!visible||!running)return;setNow(Date.now());const timer=setInterval(()=>setNow(Date.now()),500);return()=>clearInterval(timer);},[open,visible,running]);
  const count=items.filter(i=>isTransferActive(i.state)).length;
  const attention=items.some(i=>inTransferFilter(i,"Needs attention"));
  const rows=items.filter(i=>inTransferFilter(i,filter)).reverse();
  const rate=(dir:string)=>speedLabel(items.filter(i=>i.direction===dir).reduce((n,i)=>n+transferSpeed(i,now),0));
  async function act(id:string,action:"retry"|"pause"|"resume"|"cancel") {
    setError("");setPending(v=>[...v,id]);
    try {if(action==="retry")await retryTransfers.get(id)?.();else await controlFileTransfer(id,action);}
    catch(e){setError(String(e));}finally{setPending(v=>v.filter(key=>key!==id));}
  }
  return <><button type="button" ref={trigger} className="icon-button transfer-trigger" title={t("Transfers")} aria-label={t("Transfers")} aria-expanded={open} onClick={()=>setOpen(v=>!v)}>
    <ArrowUpDown size={14}/>{count>0 && <small>{count}</small>}{attention && <i/>}</button>
    {open && createPortal(<section ref={panel} role="dialog" aria-label={t("File transfers")} className="file-transfer-activity" style={{top,maxHeight:"calc(100dvh - "+(top+10)+"px)"}}>
      <header><strong>{t("File transfers")}<small>SFTP · {t("Remote desktop")}</small></strong>
        <button disabled={!items.some(i=>!isTransferActive(i.state))} onClick={clearFinishedTransfers}>{t("Clear Finished")}</button>
        <button aria-label={t("Close")} onClick={()=>setOpen(false)}><X size={15}/></button></header>
      <div className="transfer-filters">{filters.map(f=><button key={f} aria-pressed={filter===f} onClick={()=>setFilter(f)}>{t(f)}<b>{items.filter(i=>inTransferFilter(i,f)).length}</b></button>)}</div>
      <div className="file-transfer-activity-list">{!rows.length && <div className="transfer-empty"><Inbox size={28}/><strong>{t("No transfers")}</strong><small>{t("Uploads and downloads appear here.")}</small></div>}
      {rows.map(item=><article key={item.id}><div className="file-transfer-name">
        {item.direction==="upload"?<ArrowUpFromLine size={16}/>:<ArrowDownToLine size={16}/>}<strong title={item.name}>{item.name}</strong>
        {["running","paused"].includes(item.state) && item.supportsPause!==false && <button disabled={pending.includes(item.id)} title={t(item.state==="paused"?"Resume Transfer":"Pause Transfer")} onClick={()=>void act(item.id,item.state==="paused"?"resume":"pause")}>{item.state==="paused"?<Play size={14}/>:<Pause size={14}/>}</button>}
        {isTransferActive(item.state) && hasTransferControl(item.id) && <button disabled={pending.includes(item.id)} title={t("Cancel Transfer")} onClick={()=>void act(item.id,"cancel")}><X size={14}/></button>}
        {item.state==="failed" && retryTransfers.has(item.id) && <button disabled={pending.includes(item.id)} title={t("Retry")} onClick={()=>void act(item.id,"retry")}><RotateCcw size={14}/></button>}
        </div><progress max={item.total||1} value={item.state==="completed"?(item.total||1):item.total?Math.min(item.transferred,item.total):undefined}/>
        <div className="file-transfer-detail"><span>{item.protocol??"SFTP"} · {t(transferStateTitle(item.state))}{item.source && " · "+item.source}</span><span>{bytes(item.transferred)} / {item.total==null?"—":bytes(item.total)}</span></div>
        <div className="file-transfer-detail"><span>{item.total?Math.min(100,Math.floor(item.transferred/item.total*100))+"%":""}</span><span>{speedLabel(transferSpeed(item,now))}</span></div>
        {item.error && <p className="file-transfer-error">{item.error}</p>}</article>)}</div>
      {error && <p role="alert" className="file-transfer-error">{error}</p>}
      <footer className="file-transfer-summary">{t("Active")} {count}<span>↑ {rate("upload")}　↓ {rate("download")}</span></footer>
    </section>,document.body)}</>;
}
