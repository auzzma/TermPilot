import {useEffect,useState} from 'react';
export function SyncLeaseSettings({minutes,save}:{minutes:number;save:(minutes:number)=>void}) {
  const [draft,setDraft]=useState(String(minutes));
  useEffect(()=>setDraft(String(minutes)),[minutes]);
  const value=Number(draft);const valid=/^[0-9]+$/.test(draft)&&Number.isInteger(value)&&value>=1&&value<=1440;
  return <div className="sync-lease-settings">
    <label>锁超时时长（分钟）<input type="number" min={1} max={1440} step={1} value={draft} onChange={e=>setDraft(e.target.value)}/></label>
    <p className="sync-help">1–1440 分钟，默认 60 分钟。同步期间自动续期；超过此时长未续期，其他设备可在同步时接管。修改用于本机此配置的下一次同步。参与同步的设备需更新到同一新版客户端。</p>
    <button disabled={!valid||value===minutes} onClick={()=>{if(valid)save(value)}}>保存超时时长</button>
  </div>;
}

export function SyncHistorySettings({count,pending,save}:{count:number;pending?:number;save:(count:number)=>void}) {
  const [draft,setDraft]=useState(String(pending??count));
  useEffect(()=>setDraft(String(pending??count)),[pending,count]);
  const value=Number(draft);const valid=/^[0-9]+$/.test(draft)&&Number.isInteger(value)&&value>=1&&value<=100;
  return <div className="sync-lease-settings">
    <label>历史版本保留数量<input aria-label="历史版本保留数量" type="number" min={1} max={100} step={1} value={draft} onChange={e=>setDraft(e.target.value)}/></label>
    <p className="sync-help">1–100 份，默认 10 份，不包含当前版本。每个版本是独立完整的加密 TPS。设置在下次成功同步后对整个同步库生效，过期历史延迟清理。</p>
    {pending!=null&&<p className="sync-help">待同步设置：{pending} 份</p>}
    <button disabled={!valid||value===(pending??count)} onClick={()=>{if(valid)save(value)}}>保存历史数量</button>
  </div>;
}
