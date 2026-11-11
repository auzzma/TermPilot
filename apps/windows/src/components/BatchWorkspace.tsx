import { useEffect, useRef, useState } from "react";
import { Plus, ChevronDown, X } from "lucide-react";
import { batchTabStatus, batchTabTitle, closeBatchTab, moveBatchTab, newBatchTab, renameBatchTab, selectBatchTab, useBatchWorkspace, type BatchTab } from "../batchWorkspace";
import { useTranslation } from "../i18n";
import { BatchLibraryButton } from "./BatchLibrary";
import { useBatchLibrary, retryBatchPersistence } from "../batchPersistence";
import { BatchPanel } from "./BatchPanel";

export function BatchWorkspace() {
  const {tabs, selected} = useBatchWorkspace();
  const storageReady = useBatchLibrary(s => s.ready);
  const storageError = useBatchLibrary(s => [s.error, s.draftError].filter(Boolean).join("\n"));
  const current = tabs.find(t => t.id === selected)!;
  const t = useTranslation();
  const strip = useRef<HTMLDivElement>(null);
  const drag = useRef<{id:string; x:number; moved:boolean}>();
  const [edge, setEdge] = useState<number>();
  const [editing, setEditing] = useState<string>();
  const [draft, setDraft] = useState("");
  const cancelEdit = useRef(false);
  const skipClick = useRef(false);
  useEffect(() => { strip.current?.querySelector<HTMLElement>('[aria-selected="true"]')?.scrollIntoView({block:"nearest",inline:"nearest"}); }, [selected]);
  function target(x:number) {
    const items = Array.from(strip.current!.querySelectorAll<HTMLElement>("[data-batch-id]"));
    const next = items.find(el => x < el.getBoundingClientRect().left + el.offsetWidth/2);
    return {before:next?.dataset.batchId, x:next?.getBoundingClientRect().left ?? items.at(-1)!.getBoundingClientRect().right};
  }
  function finishName(id:string) { if (!cancelEdit.current) renameBatchTab(id,draft); setEditing(undefined); }
  return <div className="batch-workspace">
    <div className="batch-job-toolbar"><div className="batch-job-strip" role="tablist" ref={strip}>
      {tabs.map(tab => <div key={tab.id} data-batch-id={tab.id} className={tab.id===selected?"is-active":""}>
        {editing === tab.id ? <input aria-label={t("Name")} value={draft} autoFocus onFocus={e=>e.currentTarget.select()}
          onChange={e=>setDraft(e.target.value)} onBlur={()=>finishName(tab.id)} onKeyDown={e=>{
            if(e.nativeEvent.isComposing) return;
            if(e.key==="Enter") e.currentTarget.blur();
            if(e.key==="Escape") {e.preventDefault();cancelEdit.current=true;e.currentTarget.blur();}
          }}/> : <button type="button" role="tab" aria-selected={tab.id===selected}
          title={batchTabTitle(tab,t)+"\n"+t("Double-click to rename. Drag to reorder.")}
          onClick={e=>{if(!skipClick.current || e.detail===0) selectBatchTab(tab.id);skipClick.current=false;}}
          onDoubleClick={()=>{cancelEdit.current=false;selectBatchTab(tab.id);setDraft(batchTabTitle(tab,t));setEditing(tab.id);}}
          onPointerDown={e=>{if(e.button!==0)return;skipClick.current=false;drag.current={id:tab.id,x:e.clientX,moved:false};e.currentTarget.setPointerCapture(e.pointerId);}}
          onPointerMove={e=>{
            const d=drag.current;if(!d||(!d.moved && Math.abs(e.clientX-d.x)<5))return;
            d.moved=true; const bounds=strip.current!.getBoundingClientRect();
            if(e.clientX<bounds.left+20) strip.current!.scrollLeft-=20;
            if(e.clientX>bounds.right-20) strip.current!.scrollLeft+=20;
            setEdge(target(e.clientX).x-bounds.left);
          }} onPointerUp={e=>{
            const d=drag.current;
            if(d?.moved){skipClick.current=true;const b=strip.current!.getBoundingClientRect();
              if(e.clientX>=b.left && e.clientX<=b.right && e.clientY>=b.top && e.clientY<=b.bottom)moveBatchTab(d.id,target(e.clientX).before);}
            drag.current=undefined;setEdge(undefined);
          }} onLostPointerCapture={()=>{drag.current=undefined;setEdge(undefined);}}>
          <span>{batchTabTitle(tab,t)}</span><TabStatus tab={tab}/></button>}
        {tabs.length>1 && <CloseTab tab={tab}/>}
      </div>)}
    </div>{edge!==undefined && <i className="batch-job-drop-line" style={{left:edge}}/>}
    <BatchLibraryButton/>
    <div className="batch-new-actions"><button disabled={!storageReady} onClick={()=>newBatchTab()}><Plus size={14}/>{t("New batch job")}</button>
      <details><summary aria-label={t("New job with current configuration")}><ChevronDown size={14}/></summary>
        <div><button disabled={!storageReady} onClick={e=>{e.currentTarget.closest("details")!.open=false;newBatchTab(current);}}>{t("New job with current configuration")}</button></div>
      </details></div></div>
    {storageError && <div className="batch-storage-error" role="alert">{t(storageError)} <button onClick={() => void retryBatchPersistence().catch(() => undefined)}>{t("Retry saving")}</button></div>}
    {storageReady ? <BatchPanel key={current.id} tab={current}/> : <p className="batch-muted" role="status">{t("Restoring drafts…")}</p>}
  </div>;
}
function TabStatus({tab}:{tab:BatchTab}) {
  const t=useTranslation(), status=tab.store(batchTabStatus);
  return <small>{t(status)}</small>;
}
function CloseTab({tab}:{tab:BatchTab}) {
  const t=useTranslation(), running=tab.store(s=>s.running);
  return running ? null : <button aria-label={t("Close job tab")} onClick={()=>closeBatchTab(tab.id)}><X size={12}/></button>;
}
