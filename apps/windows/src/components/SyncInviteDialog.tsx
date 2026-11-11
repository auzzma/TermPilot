import {SyncOperationProgress} from './SyncOperationProgress';
import {useEffect,useRef,useState} from 'react';
import {syncRequest} from './DataSyncSettings';
import {useAppStore} from '../store';
type QR={width:number;modules:string};
type Preview={title:string;library:string;provider:Record<string,string>};
const scopesList=[['configuration','主机、分组、代理、脚本、笔记和 AI 配置'],['credentials','密码、私钥和凭证秘密'],['aiSecrets','AI API Key 与认证请求头'],['preferences','外观、语言和终端偏好'],['aiHistory','AI 对话历史']];
export function SyncInviteDialog({profileId,close,saved}:{profileId?:string;close:()=>void;saved:()=>Promise<void>}){
  const [key,setKey]=useState('');const [code,setCode]=useState('');const [qr,setQR]=useState<QR|null>(null);
  const [preview,setPreview]=useState<Preview|null>(null);const [scopes,setScopes]=useState(['configuration']);
  const [busy,setBusy]=useState(false);const [error,setError]=useState('');const [message,setMessage]=useState('');
  const [scanning,setScanning]=useState(false);const [installed,setInstalled]=useState(false);const [name,setName]=useState('Windows');
  const video=useRef<HTMLVideoElement>(null);
  const reset=()=>{setPreview(null);setQR(null);setMessage('');setError('')};
  useEffect(()=>{ const hidden=()=>{if(document.hidden)setScanning(false)};document.addEventListener("visibilitychange",hidden);return()=>document.removeEventListener("visibilitychange",hidden) },[]);
  useEffect(()=>{
    if(!scanning)return;
    let stopped=false;let stream:MediaStream|undefined;let timer:ReturnType<typeof setTimeout>;
    const scan=async()=>{
      try{
        const v=video.current;
        if(v&&v.readyState>=2&&v.videoWidth){
          const canvas=document.createElement('canvas');const scale=Math.min(1,800/Math.max(v.videoWidth,v.videoHeight));
          canvas.width=Math.floor(v.videoWidth*scale);canvas.height=Math.floor(v.videoHeight*scale);
          const ctx=canvas.getContext('2d',{willReadFrequently:true})!;ctx.drawImage(v,0,0,canvas.width,canvas.height);
          const rgba=ctx.getImageData(0,0,canvas.width,canvas.height).data;const parts:string[]=[];
          for(let start=0;start<rgba.length/4;start+=8192){let part='';for(let i=start;i<Math.min(start+8192,rgba.length/4);i++)part+=String.fromCharCode((rgba[i*4]*77+rgba[i*4+1]*150+rgba[i*4+2]*29)>>8);parts.push(part)}
          const result=await syncRequest<{code:string|null}>({method:'sync.qr.decode',width:canvas.width,height:canvas.height,pixels:btoa(parts.join(''))});
          if(!stopped&&result.code){setCode(result.code);setPreview(null);setScanning(false);setMessage('已识别配置码，点击解析以核对云服务。');return}
        }
      }catch(e){if(!stopped){setError(String(e));setScanning(false);return}}
      if(!stopped)timer=setTimeout(()=>void scan(),550);
    };
    void navigator.mediaDevices?.getUserMedia({video:{facingMode:'environment',width:{ideal:1280}},audio:false}).then(s=>{
      if(stopped){s.getTracks().forEach(t=>t.stop());return}stream=s;if(video.current){video.current.srcObject=s;void video.current.play()}void scan();
    }).catch(()=>{if(!stopped){setError('无法使用摄像头，请允许相机访问或改用粘贴配置码。');setScanning(false)}});
    if(!navigator.mediaDevices){setError('此设备无法使用摄像头，请粘贴配置码。');setScanning(false)}
    return()=>{stopped=true;clearTimeout(timer);stream?.getTracks().forEach(t=>t.stop())};
  },[scanning]);
  const perform=async(action:'export'|'preview'|'import')=>{
    setBusy(true);setScanning(false);setError('');setMessage('');
    try{
      if(action==='export'){
        const r=await syncRequest<{code:string;qr:QR|null}>({method:'sync.invite.export',id:profileId,passphrase:key});setCode(r.code);setQR(r.qr);setKey('');
      }else if(action==='preview')setPreview(await syncRequest<Preview>({method:'sync.invite.preview',passphrase:key,code}));
      else{
        const r=await syncRequest<{installed:boolean;synced:boolean;reused:boolean;error?:string}>({method:'sync.invite.import',passphrase:key,code,scopes,name,confirmed:true});
        if(r.installed){setInstalled(true);setKey('');setCode('');setPreview(null);await saved();await useAppStore.getState().refreshPersistentData();setMessage(r.synced?(r.reused?'已使用已有配置并完成同步；原同步范围已保留。':'已添加云服务并完成合并同步。'):`配置已保存，本机数据和待上传修改已保留。请在配置列表使用此配置并重试同步。${r.error||''}`)}
      }
    }catch(e){setError(String(e))}finally{setBusy(false)}
  };
  const path=qr?Array.from(qr.modules).flatMap((v,i)=>v==='1'?[`M${i%qr.width+4} ${Math.floor(i/qr.width)+4}h1v1h-1z`]:[]).join(''):'';
  return <div className="backup-dialog-backdrop"><section role="dialog" aria-modal="true" aria-labelledby="sync-invite-title" className="backup-dialog sync-profile-editor sync-invite-dialog">
    <h3 id="sync-invite-title">{profileId?'添加设备':'导入云服务'}</h3><div className="sync-profile-form"><fieldset disabled={busy}>
    {!installed&&<>
      <p className="sync-help">{profileId?'输入此同步库当前的 Key，生成加密配置码。新设备使用同一个 Key 扫码或粘贴即可加入。':'先输入原设备使用的同步 Key，再扫描或粘贴加密配置码。Key 不包含在配置码中。'}</p>
      {(!profileId||!code)&&<label>同步 Key<input autoFocus type="password" className="sync-key-input" placeholder="请输入当前同步 Key" autoComplete="off" value={key} onChange={e=>{setKey(e.target.value);reset()}}/></label>}
      {profileId?<>{!code?<button disabled={key.length<12} onClick={()=>void perform('export')}>生成配置码</button>:<>
        {qr?<svg className="sync-invite-qr" viewBox={`0 0 ${qr.width+8} ${qr.width+8}`} role="img" aria-label="加密云服务配置二维码" shapeRendering="crispEdges"><rect width="100%" height="100%" fill="white"/><path d={path} fill="black"/></svg>:<p>配置较长，请使用“复制配置码”，在新设备上粘贴。</p>}
        <textarea aria-label="加密配置码" readOnly value={code}/><button onClick={()=>void navigator.clipboard.writeText(code).then(()=>setMessage('已复制加密配置码。')).catch(()=>setError('复制失败，请选中配置码手动复制。'))}>复制配置码</button>
        <p className="sync-help">配置码包含加密的云服务访问凭证，请仅交给自己的设备。更换 Key 后应重新生成配置码。</p>
      </>}</>:<>
        <div className="sync-actions"><button disabled={key.length<12} onClick={()=>setScanning(v=>!v)}>{scanning?'停止扫码':'扫描二维码'}</button><button disabled={key.length<12} onClick={()=>void navigator.clipboard.readText().then(v=>{setCode(v);reset()}).catch(()=>setError('请在下方输入框使用 Ctrl+V 粘贴。'))}>粘贴配置码</button></div>
        {scanning&&<video ref={video} className="sync-invite-camera" muted playsInline/>}
        <textarea disabled={key.length<12} aria-label="加密配置码" placeholder="粘贴 TP-SYNC:1: 开头的配置码" maxLength={24000} value={code} onChange={e=>{setCode(e.target.value);reset()}}/>
        {!preview&&<button disabled={key.length<12||!code.trim()} onClick={()=>void perform('preview')}>解析配置码</button>}
        {preview&&<><h4>{preview.title}</h4><p className="sync-library">{preview.provider.endpoint}<br/>{preview.provider.bucket}<br/>库 ID：{preview.library}</p>
          <label>当前设备名称<input value={name} onChange={e=>setName(e.target.value)} maxLength={100}/></label>
          <h4>合并并同步的数据</h4>{scopesList.map(([id,label])=><label key={id}><input type="checkbox" disabled={id==='configuration'} checked={scopes.includes(id)} onChange={e=>setScopes(e.target.checked?[...scopes,id]:scopes.filter(s=>s!==id))}/>{label}</label>)}
          <p className="sync-help">导入后自动启用并同步；当前其它配置暂停。已有相同配置将继续使用，保留原同步范围及未上传修改。脚本和笔记中的手写秘密不会被自动过滤。</p>
          <button className="primary-button" onClick={()=>void perform('import')}>导入并合并同步</button>
        </>}
      </>}
    </>}
    </fieldset>{error&&<p className="backup-error" role="alert">{error}</p>}{message&&<p role="status">{message}</p>}</div>
    <SyncOperationProgress busy={busy}/>
    <div className="sync-actions"><button disabled={busy} onClick={close}>{installed?'完成':'关闭'}</button></div>
  </section></div>
}
