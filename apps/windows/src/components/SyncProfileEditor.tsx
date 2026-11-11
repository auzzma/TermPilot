import {SyncOperationProgress} from './SyncOperationProgress';
import {useState} from 'react';
import {syncRequest} from './DataSyncSettings';
export type SyncProvider={id:string;name:string;fields:[string,string,boolean][];help?:string};
export type SyncProfile={id:string;title:string;active:boolean;provider:Record<string,string>;library:string;name:string;auto:boolean;scopes:string[];pending:number};
export function SyncProfileEditor({profile,providers,scopeRows,close,saved}:{profile:Partial<SyncProfile>;providers:SyncProvider[];scopeRows:string[][];close:()=>void;saved:()=>Promise<void>}){
  const editing=!!profile.id;
  const [title,setTitle]=useState(profile.title||'');const [kind,setKind]=useState(profile.provider?.kind||'webdav');
  const [fields,setFields]=useState<Record<string,string>>(profile.provider||{});
  const [library,setLibrary]=useState(profile.library||'');const [name,setName]=useState(profile.name||'Windows');
  const [password,setPassword]=useState('');const [scopes,setScopes]=useState(profile.scopes||['configuration']);
  const [auto,setAuto]=useState(!!profile.auto);const [confirmed,setConfirmed]=useState(false);
  const [busy,setBusy]=useState(false);const [error,setError]=useState('');const provider=providers.find(p=>p.id===kind);
  const save=async()=>{setBusy(true);setError('');try{
    await syncRequest({method:editing?'sync.profile.update':'sync.profile.add',id:profile.id,title,provider:Object.fromEntries([['kind',kind],...(provider?.fields||[]).map(([key])=>[key,fields[key]||''])]),library,name,passphrase:password,scopes,auto,confirmed});
    setPassword('');await saved();close();
  }catch(e){setError(String(e))}finally{setBusy(false)}};
  return <div className="backup-dialog-backdrop"><section role="dialog" aria-modal="true" aria-labelledby="sync-profile-title" className="backup-dialog sync-profile-editor">
    <h3 id="sync-profile-title">{editing?'编辑云服务':'添加云服务'}</h3><div className="sync-profile-form"><fieldset disabled={busy}>
      <label>配置名称<input autoFocus value={title} maxLength={100} onChange={e=>setTitle(e.target.value)}/></label>
      <label>服务类型<select value={kind} onChange={e=>{setKind(e.target.value);setFields({})}}>{providers.map(p=><option key={p.id} value={p.id}>{p.name}</option>)}</select></label>
      {provider?.help&&<p className="sync-help">{provider.help}</p>}
      {provider?.fields.map(([key,label,secret])=><label key={key}>{label}{key==='auth_type'?<select value={fields[key]||''} onChange={e=>setFields({...fields,[key]:e.target.value})}><option value="">Basic</option><option value="digest">Digest</option><option value="token">Bearer Token</option></select>:<input type={secret?'password':'text'} autoComplete="off" placeholder={secret&&editing?'留空保留原值':''} value={fields[key]||''} onChange={e=>setFields({...fields,[key]:e.target.value})}/>}</label>)}
      {editing&&<p className="sync-help">同一地址和账号下，凭证留空保留原值。更换地址或账号时请重新填写凭证；原云端数据保留。</p>}
      <label>同步库 ID（新建库时留空）<input disabled={editing} value={library} onChange={e=>setLibrary(e.target.value)}/></label>
      {editing&&<p className="sync-help">库 ID 标识现有同步历史。连接其它同步库时，请新增一份配置。</p>}
      <label>当前设备名称<input value={name} onChange={e=>setName(e.target.value)}/></label>
      <label>{editing?'重新启用同步范围时填写当前 Key':'同步 Key（至少 12 个字符）'}<input type="password" className="sync-key-input" placeholder={editing?'请输入当前同步 Key':'至少 12 个字符'} autoComplete="off" value={password} onChange={e=>setPassword(e.target.value)}/></label>
      <p className="sync-help">同步 Key 用于数据加密，与云服务访问密钥不同。</p><h4>此配置的同步范围</h4>
      {scopeRows.map(([key,label])=><label key={key}><input type="checkbox" disabled={key==='configuration'} checked={scopes.includes(key)} onChange={e=>setScopes(e.target.checked?[...scopes,key]:scopes.filter(s=>s!==key))}/>{label}</label>)}
      <label><input type="checkbox" checked={auto} onChange={e=>setAuto(e.target.checked)}/>使用此配置时自动同步</label>
      <p className="sync-help">脚本和笔记中的手写秘密不会被自动过滤。其它配置的自动同步在未选用时暂停。</p>
      <label><input type="checkbox" checked={confirmed} onChange={e=>setConfirmed(e.target.checked)}/>确认保存配置及所选数据合并范围</label>
    </fieldset>{error&&<p role="alert" className="backup-error">{error}</p>}</div>
    <SyncOperationProgress busy={busy}/>
    <div className="sync-actions"><button disabled={busy} onClick={close}>取消</button><button className="primary-button" disabled={busy||!confirmed||!title.trim()||(!editing&&password.length<12)} onClick={()=>void save()}>{busy?'正在保存…':'保存'}</button></div>
  </section></div>
}
