import {useEffect,useRef,useState} from "react";
import {invoke} from "@tauri-apps/api/core";
/** Native modal focus isolation keeps shortcuts away from the remote desktop. */
export function RemoteVideoDiagnosticsDialog({report,close}:{report:()=>string;close:()=>void}){
  const dialog=useRef<HTMLDialogElement>(null);
  const[,refresh]=useState(0);
  const[copyStatus,setCopyStatus]=useState("");
  useEffect(()=>{dialog.current?.showModal();const timer=setInterval(()=>refresh(v=>v+1),500);return()=>clearInterval(timer);},[]);
  const text=report();
  return <dialog ref={dialog} className="remote-video-dialog" aria-label="画面诊断" onCancel={close} onClose={close}>
    <h2>画面诊断</h2><pre data-testid="remote-video-report">{text}</pre>
    <footer><button onClick={()=>{void invoke("clipboard_write",{text}).then(()=>setCopyStatus("已复制"),()=>setCopyStatus("复制失败，请选择文本复制"));}}>复制</button>
      <span role="status">{copyStatus}</span><button autoFocus onClick={close}>完成</button></footer>
  </dialog>;
}
