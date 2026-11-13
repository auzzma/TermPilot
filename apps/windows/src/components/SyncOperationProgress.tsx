import {useEffect,useRef,useState} from 'react';
import {invoke} from '@tauri-apps/api/core';

export type SyncProgress={id?:string;active?:boolean;phase?:string;completed?:number;total?:number|null;percent?:number|null;downloadedBytes?:number;uploadedBytes?:number;verifiedBytes?:number;error?:string};
const phases:Record<string,string>={preparing:'准备同步',connecting:'连接并验证云端',listing:'读取云端目录',merging:'合并本机修改',downloading:'下载并合并云端数据',encrypting:'加密待上传数据',uploading:'上传数据',verifying:'回读校验上传数据',finalizing:'确认云端提交',applying:'更新本机数据',completed:'操作完成',failed:'同步未完成'};
function bytes(value=0){return value>=1048576?`${(value/1048576).toFixed(1)} MiB`:value>=1024?`${(value/1024).toFixed(1)} KiB`:`${value} B`}

export function SyncOperationProgress({busy}:{busy:boolean}){
  const [progress,setProgress]=useState<SyncProgress|null>(null);const latest=useRef<SyncProgress|null>(null);const previousID=useRef<string>();
  useEffect(()=>{
    if(busy)previousID.current=latest.current?.id;
    let stopped=false;let timer:number;
    const poll=async()=>{
      try{const result=await invoke<SyncProgress|null>('sync_request',{request:{method:'sync.progress'}});if(!stopped){latest.current=result;setProgress(result)}}catch{/* Keep visible progress until the next successful poll. */}
      if(!stopped)timer=window.setTimeout(()=>void poll(),busy?250:800);
    };
    void poll();return()=>{stopped=true;clearTimeout(timer)};
  },[busy]);
  if(!busy&&!progress)return null;
  const value=busy&&!progress?.active&&progress?.id===previousID.current?{}:progress||{};
  const phase=value.phase||'preparing';const label=phases[phase]||'正在处理';
  return <section className="sync-operation-progress" aria-label="同步进度" role="status">
    <div><strong>{label}</strong>{value.percent!=null&&<span>{value.percent}%</span>}</div>
    {phase!=='failed'&&<progress max={100} value={value.percent??undefined} aria-label={`${label}进度`}/>}
    {value.total!=null&&phase!=='completed'&&<small>当前阶段：{value.completed||0} / {value.total}</small>}
    <small>下载 {bytes(value.downloadedBytes)} · 上传 {bytes(value.uploadedBytes)} · 已校验 {bytes(value.verifiedBytes)}</small>
    {value.error&&<p className="backup-error">{value.error}</p>}
    {phase!=='completed'&&phase!=='failed'&&<small className="sync-help">百分比为当前阶段；传输量按已完成的加密分块统计。</small>}
  </section>;
}
