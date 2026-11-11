import {useEffect,useRef,useState} from 'react';
import {createPortal} from 'react-dom';
import {invoke} from '@tauri-apps/api/core';
import {protectSyncMigrationClose} from '../syncWindowClose';
import {useAppStore,flushPendingWrites,hasPendingWrites} from '../store';
import {hasPendingBatchDrafts,flushBatchDrafts} from '../batchPersistence';

type Progress={active?:boolean;phase?:string;percent?:number;completed?:number;total?:number;error?:string};
type Status={passwordChange?:Progress;provider?:Record<string,string>};
const request=<T=Status,>(value:Record<string,unknown>)=>invoke<T>('sync_request',{request:value});
const phases:Record<string,string>={preparing:'准备本机备份',locking:'等待同步库空闲',synchronizing:'合并本机待同步修改',downloading:'下载并校验全部旧密文',reencrypting:'使用新 Key 重新加密',uploading:'上传并回读校验新密文',verifying:'核对完整性',switching:'切换同步库版本',finishing:'更新本机同步状态',completed:'所有数据已完成切换'};
export function openPasswordMigration(stage:'preparing'|'started'|'rejected'='started'){window.dispatchEvent(new Event(`sync-password-${stage}`))}

/** Mounted above all workspaces, so switching tabs cannot dismiss a migration. */
export function SyncPasswordMigration(){
  const [status,setStatus]=useState<Status>({});const [visible,setVisible]=useState(false);const [running,setRunning]=useState(false);
  const [error,setError]=useState('');const [editing,setEditing]=useState(false);const [fields,setFields]=useState<Record<string,string>>({});
  const [definitions,setDefinitions]=useState<[string,string,boolean][]>([]);
  const active=useRef(false);const executing=useRef(false);const preparing=useRef(false);const dialog=useRef<HTMLDialogElement>(null);
  const progress=status.passwordChange||{};const complete=progress.phase==='completed';
  const refresh=async()=>{const value=await request({method:'sync.status'});if(!preparing.current){setStatus(value);active.current=!!value.passwordChange?.active;if(active.current)setVisible(true)}return value};
  const resume=async()=>{if(executing.current)return;executing.current=true;setRunning(true);setError('');try{await request({method:'sync.password.resume'});await useAppStore.getState().refreshPersistentData()}catch(e){setError(String(e))}finally{try{const s=await refresh();if(!s.passwordChange?.active&&s.passwordChange?.phase!=='completed')setVisible(false)}catch(e){setError(String(e))}executing.current=false;setRunning(false);window.dispatchEvent(new Event('sync-password-updated'))}};
  useEffect(()=>{
    let stopped=false;let timer:number;
    const poll=async()=>{try{if(!stopped)await refresh()}catch{/* Keep the checkpoint until status is available. */}if(!stopped)timer=window.setTimeout(()=>void poll(),active.current?800:5000)};
    void poll();
    const prepare=()=>{preparing.current=true;active.current=true;setRunning(true);setStatus({passwordChange:{active:true,phase:'preparing',percent:0}});setVisible(true)};
    const start=()=>{preparing.current=false;setVisible(true);active.current=true;void resume()};
    const rejected=()=>{preparing.current=false;setRunning(false);void refresh().then(s=>setVisible(!!s.passwordChange?.active)).catch(()=>setVisible(false))};
    window.addEventListener('sync-password-preparing',prepare);window.addEventListener('sync-password-rejected',rejected);window.addEventListener('sync-password-started',start);
    const closing=protectSyncMigrationClose(()=>active.current||executing.current,()=>setVisible(true),{dirty:()=>hasPendingWrites()||hasPendingBatchDrafts(),flush:async()=>{await Promise.all([flushPendingWrites(),flushBatchDrafts()])},failed:e=>useAppStore.setState({persistenceError:`保存失败，窗口未关闭：${String(e)}`})});
    return()=>{stopped=true;clearTimeout(timer);window.removeEventListener('sync-password-started',start);window.removeEventListener('sync-password-preparing',prepare);window.removeEventListener('sync-password-rejected',rejected);void closing.then(f=>f())};
  },[]);
  useEffect(()=>{if(visible&&!dialog.current?.open)dialog.current?.showModal();else if(!visible)dialog.current?.close()},[visible]);
  const edit=async()=>{try{const s=await refresh();const meta=await request<{providers:{id:string;fields:[string,string,boolean][]}[]}>({method:'sync.describe'});setFields(s.provider||{});setDefinitions(meta.providers.find(p=>p.id===s.provider?.kind)?.fields.filter(([key,,secret])=>secret||key==='username')||[]);setEditing(true)}catch(e){setError(String(e))}};
  const save=async()=>{try{await request({method:'sync.provider',provider:fields,confirmed:true});setEditing(false);setError('')}catch(e){setError(String(e))}};
  return createPortal(<dialog ref={dialog} className="sync-password-dialog" aria-labelledby="sync-password-title" onCancel={e=>e.preventDefault()} onKeyDown={e=>e.stopPropagation()}>
    <h2 id="sync-password-title">{complete?'同步 Key 已修改':'正在修改同步 Key'}</h2>
    <p>{phases[progress.phase||'']||'准备迁移'}</p>
    <progress value={progress.percent||0} max={100} aria-label="Key 修改进度"/>
    <p className="sync-password-count">{progress.percent||0}%<span>{!!progress.total&&`${progress.completed||0} / ${progress.total} 个对象`}</span></p>
    {(error||progress.error)&&<p role="alert" className="sync-password-error">{error||progress.error}</p>}
    <p>{complete?'其它设备下次同步时需输入新 Key，未上传的修改会继续合并。':'请保持应用和此页面打开，完成前无法关闭。断网或意外退出后，请在本设备继续；已完成的步骤会保留。'}</p>
    {editing?<section><h3>更新原位置的云端认证</h3>{definitions.map(([key,label,secret])=><label key={key}>{label}<input type={secret?'password':'text'} autoComplete="off" value={fields[key]||''} onChange={e=>setFields({...fields,[key]:e.target.value})}/></label>)}<div className="sync-actions"><button onClick={()=>setEditing(false)}>返回</button><button onClick={()=>void save()}>保存认证信息</button></div></section>:
      <div className="sync-actions">{complete?<button className="primary-button" onClick={()=>setVisible(false)}>完成</button>:!running&&<><button className="primary-button" onClick={()=>void resume()}>继续修改 Key</button><button onClick={()=>void edit()}>更新云端认证</button></>}</div>}
  </dialog>,document.body)
}
