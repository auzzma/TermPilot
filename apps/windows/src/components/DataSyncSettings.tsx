import {SyncConflicts,SyncMaintenanceStatus,type SyncConflict,type Maintenance} from './SyncConflicts';
import {SyncLeaseSettings,SyncHistorySettings} from './SyncLeaseSettings';
import {SyncOperationProgress} from './SyncOperationProgress';
import {SyncInviteDialog} from './SyncInviteDialog';
import {SyncProfileEditor,type SyncProfile} from './SyncProfileEditor';
import {openPasswordMigration} from './SyncPasswordMigration';
import {useEffect,useState} from 'react';
import {invoke} from '@tauri-apps/api/core';
import {open} from '@tauri-apps/plugin-dialog';
import {RefreshCw,Cloud,Trash2,RotateCcw} from 'lucide-react';
import {useAppStore} from '../store';

type Provider={id:string;name:string;fields:[string,string,boolean][];help?:string};
type SyncStatus={historyVersionCount?:number;pendingHistoryVersionCount?:number;maintenance?:Maintenance;lockTimeoutMinutes?:number;profiles?:SyncProfile[];activeProfile?:string;passwordRequired?:boolean;configured?:boolean;providerUnavailable?:boolean;library?:string;name?:string;auto?:boolean;pending?:number;gaps?:number;scopes?:string[];provider?:Record<string,string>;retentionDays?:number|null;lastCheck?:{at:string};lastError?:{message:string};
  recycle?:{id:string;scope:string;label:string;deletedAt:string;restored:boolean}[];
  conflicts?:SyncConflict[];
  snapshots?:{id:string;at:string;verified:boolean}[]};
export const syncRequest=<T=SyncStatus,>(request:Record<string,unknown>)=>invoke<T>('sync_request',{request});
export function startSyncCoordinator(){
  let stopped=false;let busy=false;
  const tick=async()=>{if(stopped||busy)return;busy=true;try{const result=await syncRequest<SyncStatus&{skipped?:boolean}>({method:'sync.tick'});if(!stopped&&!result.skipped)await useAppStore.getState().refreshPersistentData();}catch{/* Shared Rust persists status and exponential retry. */}finally{busy=false}};
  void tick();const timer=window.setInterval(()=>void tick(),5000);const focus=()=>void tick();window.addEventListener('focus',focus);
  return()=>{stopped=true;clearInterval(timer);window.removeEventListener('focus',focus)};
}
export function DataSyncSettings(){
  const [providers,setProviders]=useState<Provider[]>([]);const [scopeRows,setScopeRows]=useState<string[][]>([]);
  const [status,setStatus]=useState<SyncStatus>({});
  const [invite,setInvite]=useState<{profileId?:string}|null>(null);
  const [editor,setEditor]=useState<Partial<SyncProfile>|null>(null);
  const [recycleSearch,setRecycleSearch]=useState('');
  const [versionFile,setVersionFile]=useState<string|null>(null);const [versionKey,setVersionKey]=useState('');
  const [oldPassword,setOldPassword]=useState('');const [newPassword,setNewPassword]=useState('');const [repeatPassword,setRepeatPassword]=useState('');const [currentPassword,setCurrentPassword]=useState('');const [clientsUpdated,setClientsUpdated]=useState(false);
  const [busy,setBusy]=useState(false);const [error,setError]=useState('');const [confirmation,setConfirmation]=useState<{text:string;request:Record<string,unknown>}|null>(null);
  const load=async()=>{const meta=await syncRequest<{providers:Provider[];scopes:string[][]}>({method:'sync.describe'});setProviders(meta.providers);setScopeRows(meta.scopes);setStatus(await syncRequest({method:'sync.status'}))};
  useEffect(()=>{void load().catch(e=>setError(String(e)));const updated=()=>{void load().catch(e=>setError(String(e)))};window.addEventListener('sync-password-updated',updated);return()=>window.removeEventListener('sync-password-updated',updated)},[]);
  const run=async(request:Record<string,unknown>)=>{setBusy(true);setError('');try{await syncRequest(request);if(request.method==='sync.profile.use'||request.method==='sync.snapshot')await syncRequest({method:'sync.run'})}catch(e){setError(String(e))}finally{try{await load();await useAppStore.getState().refreshPersistentData()}catch(e){setError(String(e))}setBusy(false)}};
  const changePassword=async()=>{setBusy(true);setError('');openPasswordMigration('preparing');try{await syncRequest({method:'sync.password.begin',oldPassphrase:oldPassword,newPassphrase:newPassword,confirmPassphrase:repeatPassword,confirmed:true,clientsUpdated});setOldPassword('');setNewPassword('');setRepeatPassword('');openPasswordMigration()}catch(e){setError(String(e));openPasswordMigration('rejected')}finally{setBusy(false)}};
  const unlock=async()=>{setBusy(true);setError('');try{await syncRequest({method:'sync.password.unlock',passphrase:currentPassword});setCurrentPassword('');await syncRequest({method:'sync.run'});await load();await useAppStore.getState().refreshPersistentData()}catch(e){setError(String(e))}finally{setBusy(false)}};
  const inspectLegacyLock=async()=>{setBusy(true);setError('');try{const preview=await syncRequest<{message:string;expectedHead:string}>({method:'sync.lock.inspect'});setConfirmation({text:preview.message,request:{method:'sync.lock.recover',expectedHead:preview.expectedHead,confirmed:true,otherDevicesStopped:true}})}catch(e){setError(String(e))}finally{setBusy(false)}};
  const previewSnapshot=async(id:string)=>{setBusy(true);try{const value=await syncRequest<{copies:number}>({method:'sync.snapshot.preview',id});setConfirmation({text:`恢复 ${value.copies} 条记录为新副本。快照中的偏好及 AI 设置若已启用同步，会作为新的修改应用。`,request:{method:'sync.snapshot.restore',id,confirmed:true,actionId:crypto.randomUUID()}})}catch(e){setError(String(e))}finally{setBusy(false)}};
  const chooseVersion=async()=>{try{const path=await open({multiple:false,filters:[{name:'TermPilot',extensions:['tps']}]});if(typeof path==='string'){setVersionKey('');setVersionFile(path)}}catch(e){setError(String(e))}};
  const importVersion=async()=>{setBusy(true);setError('');const path=versionFile;const passphrase=versionKey;setVersionFile(null);setVersionKey('');try{const result=await syncRequest<{id:string}>({method:'sync.snapshot.import',path,passphrase});await load();await previewSnapshot(result.id)}catch(e){setError(String(e))}finally{setBusy(false)}};
  return <section className="data-sync-settings"><h2><Cloud size={20}/> 数据同步</h2>
    <p className="sync-help">使用相同同步库 ID 和 Key 连接设备。内容在本机加密，离线修改将在下次同步时合并。</p>
    <SyncOperationProgress busy={busy}/>
    <fieldset disabled={busy}>
      <section className="sync-card"><h3>云服务配置</h3>
        <p className="sync-help">可添加多份同类型服务。一次使用一份配置；切换时保留本机数据，并将期间的增删改与选定同步库合并。</p>
        {!status.profiles?.length&&<p>尚未添加云服务</p>}
        {status.profiles?.map(p=><div className="sync-profile-row" key={p.id}>
          <div><strong>{p.title}</strong>{p.active&&<span className="sync-profile-active">正在使用</span>}<small>{providers.find(provider=>provider.id===p.provider.kind)?.name||p.provider.kind} · {p.provider.bucket||p.provider.endpoint}</small><small className="sync-library">库 ID：{p.library}</small></div>
        <div className="sync-actions">{!p.active&&<button onClick={()=>setConfirmation({text:'切换到此云服务？本机数据保留，期间的新增、修改和删除将在此同步库中合并。其它配置暂停同步。',request:{method:'sync.profile.use',id:p.id,confirmed:true}})}>使用此配置</button>}<button onClick={()=>setInvite({profileId:p.id})}>添加设备</button><button onClick={()=>setEditor(p)}>编辑</button><button onClick={()=>setConfirmation({text:'删除此本机配置及其待上传队列？本机主机和云端数据保持不变；删除前会保存本机恢复备份。',request:{method:'sync.profile.delete',id:p.id,confirmed:true}})}>删除</button></div>
        </div>)}
        <button className="primary-button" onClick={()=>setEditor({})}>添加云服务</button> <button onClick={()=>setInvite({})}>导入云服务</button>
      </section>
    {status.configured&&<>
      <section className="sync-card"><h3>当前同步状态</h3><label>库 ID <code className="sync-library">{status.library}</code></label><label>当前设备 <span>{status.name}</span></label>
        <label><input type="checkbox" disabled={status.providerUnavailable} checked={!!status.auto} onChange={e=>void run({method:'sync.configure',auto:e.target.checked,confirmed:true})}/>自动同步</label>
        <SyncLeaseSettings minutes={status.lockTimeoutMinutes??60} save={minutes=>void run({method:'sync.configure',confirmed:true,lockTimeoutMinutes:minutes})}/>
        <p>待上传 {status.pending||0} · 待补齐依赖 {status.gaps||0}</p><p className="sync-help">上次检查：{status.lastCheck?.at||'尚未同步'}</p>
        <SyncHistorySettings count={status.historyVersionCount??10} pending={status.pendingHistoryVersionCount} save={count=>void run({method:'sync.configure',confirmed:true,historyVersionCount:count})}/>
        <div className="sync-actions"><button className="primary-button" disabled={status.providerUnavailable} onClick={()=>void run({method:'sync.run'})}><RefreshCw size={14}/>立即同步</button><button disabled={status.providerUnavailable} onClick={()=>void inspectLegacyLock()}>恢复旧锁并同步</button><button disabled={status.providerUnavailable} onClick={()=>void run({method:'sync.repair'})}>检查并修复缺失文件</button><button onClick={()=>void run({method:'sync.snapshot'})}>生成完整快照</button></div>
      </section>
      <SyncMaintenanceStatus status={status.maintenance}/>
      <section className="sync-card"><h3>同步 Key</h3>
        {status.passwordRequired&&<p role="alert">云端 Key 已更新。输入当前 Key 后，本机离线修改会继续合并。</p>}
        <details open={status.passwordRequired||undefined}><summary>输入当前同步 Key</summary><label>当前同步 Key<input type="password" className="sync-key-input" placeholder="请输入当前同步 Key" autoComplete="off" value={currentPassword} onChange={e=>setCurrentPassword(e.target.value)}/></label><button disabled={!currentPassword} onClick={()=>void unlock()}>解锁并同步</button></details>
        <details><summary>修改同步 Key</summary>
          <label>原同步 Key<input type="password" className="sync-key-input" placeholder="请输入原同步 Key" autoComplete="off" value={oldPassword} onChange={e=>setOldPassword(e.target.value)}/></label>
          <label>新同步 Key<input type="password" className="sync-key-input" placeholder="至少 12 个字符" autoComplete="new-password" value={newPassword} onChange={e=>setNewPassword(e.target.value)}/></label>
          <label>确认新 Key<input type="password" className="sync-key-input" placeholder="请再次输入新 Key" autoComplete="new-password" value={repeatPassword} onChange={e=>setRepeatPassword(e.target.value)}/></label>
          <p className="sync-help">先下载全部旧密文，再重新加密并上传，验证后切换。包含增量、历史快照及回收站，也包含已关闭同步范围的云端历史。请预留新旧两份密文和备份的本机空间。</p>
          <p className="sync-help">原云端密文暂时保留用于恢复，旧 Key 仍能解密这些历史副本。</p>
          <label><input type="checkbox" checked={clientsUpdated} onChange={e=>setClientsUpdated(e.target.checked)}/>所有参与同步的设备均已升级；完成前保持页面打开</label>
          <button className="primary-button" disabled={!clientsUpdated||!oldPassword||newPassword.length<12||newPassword!==repeatPassword||newPassword===oldPassword} onClick={()=>void changePassword()}>开始修改 Key</button>
        </details>
      </section>
      <section className="sync-card"><h3>回收站</h3><label>保留期限<select value={status.retentionDays??0} onChange={e=>setConfirmation({text:'新期限用于之后的删除。延长会保护当前条目，缩短不会提前清理已保护内容。',request:{method:'sync.retention',days:Number(e.target.value)||null}})}><option value={7}>7 天</option><option value={30}>30 天</option><option value={90}>90 天</option><option value={0}>长期保留</option></select></label><input placeholder="搜索已删除记录" value={recycleSearch} onChange={e=>setRecycleSearch(e.target.value)}/><p className="sync-help">默认保留 30 天；未上传的唯一副本会留在本机。恢复使用新记录 ID。</p>
        {!status.recycle?.length&&<p>回收站为空</p>}{status.recycle?.filter(item=>!recycleSearch||item.label.toLowerCase().includes(recycleSearch.toLowerCase())).map(item=><div className="sync-item" key={`${item.scope}/${item.id}`}><div><strong>{item.label}</strong><small>{item.deletedAt}{item.restored?' · 已恢复':''}</small></div><button title="恢复为新记录" onClick={()=>setConfirmation({text:'恢复为新记录。本机保留的密码可恢复，其它设备缺少的密码需补填；已有数据保持不变。',request:{method:'sync.restore',scope:item.scope,ids:[item.id],actionId:crypto.randomUUID(),confirmed:true}})}><RotateCcw size={16}/></button><button title="清理" onClick={()=>setConfirmation({text:'清理后不能再从回收站恢复。历史云端密文仍保留，不代表物理擦除。',request:{method:'sync.purge',scope:item.scope,ids:[item.id],confirmed:true}})}><Trash2 size={16}/></button></div>)}
      </section>
      <SyncConflicts conflicts={status.conflicts??[]} request={command=>syncRequest<{display?:string}>(command)} confirm={(text,request)=>setConfirmation({text,request})}/>
      <section className="sync-card"><h3>完整快照</h3><button onClick={()=>void chooseVersion()}>从 TPS 文件恢复</button>{!status.snapshots?.length&&<p>尚未生成快照</p>}{status.snapshots?.map(s=><div className="sync-item" key={s.id}>{s.at}<span>{s.verified?'已验证':'等待同步'}</span><button disabled={!s.verified} onClick={()=>void previewSnapshot(s.id)}>预览恢复</button></div>)}</section>
    </>}
    </fieldset>{(error||status.lastError?.message)&&<p className="backup-error" role="alert">{error||status.lastError?.message}</p>}
    {versionFile&&<div className="backup-dialog-backdrop"><section role="dialog" aria-modal="true" aria-label="从完整版本恢复" className="backup-dialog"><h3>从完整版本恢复</h3><p>输入创建此文件时的同步 Key。无需连接云端；先预览，再恢复已开启同步范围内的数据。</p><label>文件的同步 Key<input type="password" autoComplete="off" value={versionKey} onChange={e=>setVersionKey(e.target.value)}/></label><div className="sync-actions"><button onClick={()=>{setVersionFile(null);setVersionKey('')}}>取消</button><button className="primary-button" disabled={!versionKey} onClick={()=>void importVersion()}>校验并预览</button></div></section></div>}
    {invite&&<SyncInviteDialog {...invite} close={()=>setInvite(null)} saved={load}/>}
    {editor&&<SyncProfileEditor profile={editor} providers={providers} scopeRows={scopeRows} close={()=>setEditor(null)} saved={async()=>{await load();await useAppStore.getState().refreshPersistentData()}}/>}
    {confirmation&&<div className="backup-dialog-backdrop"><section role="dialog" aria-modal="true" className="backup-dialog"><h3>确认操作</h3><p>{confirmation.text}</p><div className="sync-actions"><button onClick={()=>setConfirmation(null)}>取消</button><button className="primary-button" onClick={()=>{void run(confirmation.request);setConfirmation(null)}}>确认</button></div></section></div>}
  </section>
}
