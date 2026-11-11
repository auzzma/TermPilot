import { useState } from "react";
import { ai, type AIValue } from "../ai";

export function AIModelPicker({providers, providerId, model, pins, choose, changePins, disabled}: {
  providers:AIValue[]; providerId:string; model:string; pins:string[]; disabled:boolean;
  choose:(provider:string, model:string)=>void;
  changePins:(pins:string[])=>Promise<void>;
}) {
  const [open,setOpen]=useState(false), [search,setSearch]=useState("");
  const [catalog,setCatalog]=useState<Record<string,string[]>>({});
  const [loading,setLoading]=useState<string[]>([]), [saving,setSaving]=useState(false), [error,setError]=useState("");
  const active=providers.find(provider=>provider.id===providerId);
  async function discover(provider:AIValue) {
    setError("");setLoading(items=>[...items,provider.id]);
    try {
      const {modelIds}=await ai("provider.models",{provider});
      setCatalog(items=>({...items,[provider.id]:modelIds ?? []}));
    } catch(e){setError(String(e));}
    finally{setLoading(items=>items.filter(id=>id!==provider.id));}
  }
  async function pin(key:string) {
    setSaving(true);setError("");
    try{await changePins(pins.includes(key)?pins.filter(k=>k!==key):[...pins,key]);}
    catch(e){setError(String(e));}finally{setSaving(false);}
  }
  function pick(provider:string, name:string) {choose(provider,name);setOpen(false);setSearch("");}
  return <div className="ai-model-picker">
    <button type="button" disabled={disabled} aria-expanded={open} onClick={()=>setOpen(!open)}>
      {[active?.name ?? "选择提供商",model || active?.model].filter(Boolean).join(" · ")} ▾
    </button>
    {open && !disabled && <section aria-label="选择提供商和模型" onKeyDown={e=>{if(e.key==="Escape")setOpen(false);}}>
      <input autoFocus aria-label="搜索模型" placeholder="搜索或输入模型" value={search} onChange={e=>setSearch(e.target.value)}/>
      {providers.map(provider=>{
        const pinned=(name:string)=>pins.includes(provider.id+":"+name);
        const names=[...new Set<string>([provider.model,...(catalog[provider.id] ?? []),provider.id===providerId ? model : ""].filter(Boolean))]
          .filter(name=>name.toLowerCase().includes(search.toLowerCase()))
          .sort((a,b)=>Number(pinned(b))-Number(pinned(a)) || a.localeCompare(b));
        return <div key={provider.id}><header><strong>{provider.name}</strong>
          <button type="button" disabled={loading.includes(provider.id)} onClick={()=>void discover(provider)}>刷新模型</button></header>
          {names.map(name=><div className="ai-model-option" key={name}>
            <button type="button" onClick={()=>pick(provider.id,name)}>{name}</button>
            <button type="button" aria-label="固定模型" aria-pressed={pinned(name)} disabled={saving} onClick={()=>void pin(provider.id+":"+name)}>{pinned(name)?"★":"☆"}</button>
          </div>)}
          {search.trim() && !names.includes(search.trim()) && <button type="button" onClick={()=>pick(provider.id,search.trim())}>使用 {search.trim()}</button>}
        </div>;
      })}
      {!providers.length && <p>请在设置中添加提供商。</p>}
      {error && <small role="alert">{error}</small>}
    </section>}
  </div>;
}
