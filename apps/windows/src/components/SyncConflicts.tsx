import {useEffect,useRef,useState} from 'react';
type Dot={writer:string;seq:number};
type Source={name:string;at?:string|null;local:boolean;version:string};
type Candidate={dot:Dot;display:string;secret:boolean;source:Source};
type Field={key:string;label:string;hint:string;secret:boolean;candidates:Candidate[]};
export type SyncConflict={id:string;scope:string;title:string;subtitle:string;revision:string;deleted:boolean;details:Field[];deletions:Source[]};
type Request=(request:Record<string,unknown>)=>Promise<{display?:string}>;
type Confirm=(text:string,request:Record<string,unknown>)=>void;
export function SyncConflicts({conflicts,request,confirm}:{conflicts:SyncConflict[];request:Request;confirm:Confirm}){
  const [search,setSearch]=useState('');
  return <section className="sync-card"><h3>冲突</h3>{conflicts.length===0?<p>没有待处理冲突</p>:<>
    <p className="sync-help">{conflicts.length} 条记录需要确认。比较版本并保存选择，结果会同步到其他设备。</p>
    <input aria-label="搜索冲突" placeholder="搜索名称、地址或冲突字段" value={search} onChange={e=>setSearch(e.target.value)}/>
    {conflicts.filter(c=>[c.title,c.subtitle,...c.details.map(f=>f.label)].join(' ').toLowerCase().includes(search.toLowerCase())).map(c=><ConflictRecord key={c.revision} conflict={c} request={request} confirm={confirm}/>)}</>}
  </section>;
}
function ConflictRecord({conflict:c,request,confirm}:{conflict:SyncConflict;request:Request;confirm:Confirm}){
  const [choices,setChoices]=useState<Record<string,Dot>>({});
  const [expanded,setExpanded]=useState(false);
  const command={method:'sync.resolve',scope:c.scope,id:c.id,revision:c.revision,choices,confirmed:true};
  return <details className="sync-conflict-record" onToggle={e=>setExpanded(e.currentTarget.open)}><summary><strong>{c.title}</strong><small>{c.deleted?'删除与编辑冲突':c.details.map(f=>f.label).join('、')}</small></summary>
    <p>{c.subtitle}</p>{c.deleted&&<><p>有设备删除了记录，同时另一个版本仍有修改。原记录目前保持删除；需要恢复时可在回收站恢复为副本。</p>{c.deletions.map(s=><p key={s.version}>删除来源：{s.name} · {s.at?new Date(s.at).toLocaleString():'时间未记录'}</p>)}</>}
    {expanded&&c.details.map(field=><div className="sync-conflict-field" key={field.key}><h4>{field.label}</h4><p className="sync-help">{field.hint}</p><div className="sync-conflict-options">
      {field.candidates.map((candidate,i)=><ConflictCandidate key={`${candidate.dot.writer}:${candidate.dot.seq}`} candidate={candidate} number={i+1} field={field.key} conflict={c} request={request}
        selected={choices[field.key]?.writer===candidate.dot.writer&&choices[field.key]?.seq===candidate.dot.seq} choose={()=>setChoices({...choices,[field.key]:candidate.dot})}/>)}</div></div>)}
    {c.deleted?<button onClick={()=>confirm('确认保留删除？编辑内容会保留在同步历史和回收站中。',{...command,keepDeleted:true})}>保留删除</button>:
      <button className="primary-button" disabled={!c.details.length||c.details.some(f=>!choices[f.key])} onClick={()=>confirm(`将所选版本用于“${c.title}”的 ${c.details.length} 个冲突字段，其他字段保持不变。`,command)}>保存冲突选择</button>}
    <p className="sync-help">记录 ID：{c.id}</p>
  </details>;
}
function ConflictCandidate({candidate:c,number,field,conflict,request,selected,choose}:{candidate:Candidate;number:number;field:string;conflict:SyncConflict;request:Request;selected:boolean;choose:()=>void}){
  const [revealed,setRevealed]=useState<string|null>(null);const [error,setError]=useState('');const [loading,setLoading]=useState(false);
  const epoch=useRef(0);
  useEffect(()=>{const hide=()=>{if(document.hidden){epoch.current++;setRevealed(null)}};document.addEventListener('visibilitychange',hide);return()=>{epoch.current++;document.removeEventListener('visibilitychange',hide)}},[]);
  const reveal=async()=>{if(revealed!==null){setRevealed(null);return}setLoading(true);setError('');const pending=epoch.current;try{const value=await request({method:'sync.conflict.preview',scope:conflict.scope,id:conflict.id,revision:conflict.revision,field,dot:c.dot,reveal:true});if(pending===epoch.current&&!document.hidden)setRevealed(value.display??'')}catch(e){setError(String(e))}finally{setLoading(false)}};
  return <div className={`sync-conflict-option${selected?' selected':''}`}><strong>版本 {number} · {c.source.name}{c.source.local?' · 本设备':''}</strong>
    <small>{c.source.at?new Date(c.source.at).toLocaleString():'修改时间未记录'}</small><pre>{revealed??c.display}</pre>
    <div className="sync-actions">{c.secret&&<button disabled={loading} onClick={()=>void reveal()}>{revealed===null?'显示敏感内容':'隐藏内容'}</button>}
      {!conflict.deleted&&<button aria-pressed={selected} onClick={choose}>{selected?'✓ 已选择此版本':'选择此版本'}</button>}</div>{error&&<p role="alert">{error}</p>}
  </div>;
}
export type Maintenance={checkedAt?:number;deleted?:number;message?:string|null};
export function SyncMaintenanceStatus({status}:{status?:Maintenance}){
  return <section className="sync-card"><h3>云端历史自动清理</h3><p className="sync-help">同步成功后自动检查。按设置的数量保留历史完整版本，不包含当前版本；冲突、删除标记和可恢复的回收站内容完整保留。被淘汰的历史及迁移前的旧文件保护 7 天后分批清理。</p>
    {status?.checkedAt&&<p>上次检查：{new Date(status.checkedAt*1000).toLocaleString()} · 清理 {status.deleted??0} 个文件</p>}{status?.message&&<p role="status">{status.message}</p>}
  </section>;
}
