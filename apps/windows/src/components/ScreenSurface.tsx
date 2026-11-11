import { screenAttempt, screenConnectionError } from "../screenConnection";
import { ScreenRecovery } from "../screenRecovery";
import { ScreenLoginAction, type ScreenLoginState } from "../screenLogin";
import { ScreenScroll } from "../screenScroll";
import { RemoteVideoDiagnostics } from "../remoteVideoDiagnostics";
import { RemoteVideoDiagnosticsDialog } from "./RemoteVideoDiagnosticsDialog";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { HighPerformanceRenderer, ScreenAudio, screenPackets, validateScreenDisplay, type ScreenDisplay } from "../screenMedia";
import { useTransferStore, finishRemoteTransfers, updateTransferProgress, registerTransferControl, type TransferRecord } from "./SftpPanel";
import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useAppStore } from "../store";
import type { SessionDescriptor } from "../types";
import type { AIValue } from "../ai";
const keys: Record<string, number> = {
  Backspace: 0xff08,
  Tab: 0xff09,
  Enter: 0xff0d,
  Escape: 0xff1b,
  Delete: 0xffff,
  Home: 0xff50,
  End: 0xff57,
  PageUp: 0xff55,
  PageDown: 0xff56,
  ArrowLeft: 0xff51,
  ArrowUp: 0xff52,
  ArrowRight: 0xff53,
  ArrowDown: 0xff54,
  Shift: 0xffe1,
  Control: 0xffe3,
  Alt: 0xffe9,
  Meta: 0xffeb,
  CapsLock: 0xffe5,
  Insert: 0xff63,
};
export function keySym(key: string) {
  if (keys[key]) return keys[key];
  if (/^F\d+$/.test(key)) return 0xffbd + Number(key.slice(1));
  const point = key.codePointAt(0);
  return [...key].length === 1 && point
    ? point > 255
      ? 0x1000000 + point
      : point
    : 0;
}
export function decodeScreenFrame(bytes: ArrayBuffer) {
  if (bytes.byteLength < 4) return null;
  const n = new DataView(bytes).getUint32(0);
  if (n < 2 || n > 65536 || n + 4 > bytes.byteLength)
    throw Error("Invalid frame header");
  const h = JSON.parse(new TextDecoder().decode(new Uint8Array(bytes, 4, n)));
  const { width: w, height: hgt } = h;
  if (
    !Number.isInteger(w) ||
    !Number.isInteger(hgt) ||
    w <= 0 ||
    hgt <= 0 ||
    w * hgt * 4 > 64 * 1024 * 1024 ||
    h.pixelFormat !== "bgrx" ||
    bytes.byteLength - 4 - n !== w * hgt * 4
  )
    throw Error("Invalid frame pixels");
  const source = new Uint8Array(bytes, 4 + n);
  const rgba = new Uint8ClampedArray(source.length);
  for (let i = 0; i < source.length; i += 4) {
    rgba[i] = source[i + 2];
    rgba[i + 1] = source[i + 1];
    rgba[i + 2] = source[i];
    rgba[i + 3] = 255;
  }
  return { width: w, height: hgt, rgba };
}
type ClipboardSnapshot = { sequence: number; paths: string[]; text?: string };
export function ScreenSurface({ session, active }: { session: SessionDescriptor; active: boolean }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const display = useRef<HTMLDivElement>(null);
  const input = useRef<HTMLTextAreaElement>(null);
  const host = useAppStore(s => s.sessionHosts[session.id] ?? s.hosts.find(h => h.id === session.hostId));
  const frameRate = useAppStore(s => s.preferences.remoteDesktopFrameRate === 30 ? 30 : 60);
  const videoCodec = useAppStore(s => s.preferences.remoteDesktopVideoCodec === "h265" ? "h265" : "h264");
  const videoCodecRef = useRef(videoCodec); videoCodecRef.current = videoCodec;
  const frameRateRef = useRef(frameRate); frameRateRef.current = frameRate;
  const rdp = host?.connectionKind === "rdp";
  const hp = !rdp && host?.screenSharingProfile?.mode === "highPerformance";
  const player = useRef<ScreenAudio>();
  const [status, setStatus] = useState("连接中…");
  const [sync, setSync] = useState(true);
  const [audio, setAudio] = useState(host?.screenSharingProfile?.audio !== false);
  const audioEnabled=useRef(audio);audioEnabled.current=audio;
  const [fps, setFps] = useState(0);
  const diagnostics = useRef(new RemoteVideoDiagnostics());
  const [showDiagnostics, setShowDiagnostics] = useState(false);
  useEffect(() => { if (!active) setShowDiagnostics(false); }, [active]);
  const [bandwidth, setBandwidth] = useState("");
  const [retry, setRetry] = useState(0);
  const recovery = useRef(new ScreenRecovery());
  const [hpResolution, setHPResolution] = useState("1920x1080");
  const [hasFrame, setHasFrame] = useState(false);
  const [loginState, setLoginState] = useState<ScreenLoginState>({busy:false,message:""});
  const login = useRef(new ScreenLoginAction());
  const attemptId = useRef<string>();
  const disconnectAttempt = useRef<() => void>();
  const [certificate, setCertificate] = useState<AIValue>();

  const connected = useRef(false);
  const lastClipboard = useRef("");
  const clipboardSequence = useRef(-1);
  const incoming = useRef<Promise<ClipboardSnapshot>>();
  const preparingFile = useRef<string>();
  function finishPreparation(error?: string) {
    const id = preparingFile.current;
    if (!id) return;
    preparingFile.current = undefined;
    useTransferStore.getState().setTransfers(items => error
      ? items.map(item => item.id === id ? {...item, state:"failed", error} : item)
      : items.filter(item => item.id !== id));
  }
  function prepareFiles() {
    finishPreparation();
    const id = session.id + ":" + crypto.randomUUID();
    preparingFile.current = id;
    useTransferStore.getState().setTransfers(items => [...items, {
      id, transferKey:id, name:"Clipboard files", direction:"download", state:"waiting", protocol:"RDP",
      source:host?.label, owner:session.id, supportsPause:false, bytesPerSecond:0,
      transferred:0, sampledBytes:0, sampledAt:Date.now(),
    }]);
  }
  const offerPromise = useRef<Promise<void>>();
  const offer = useRef<{ id: string; resolve: () => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> }>();
  const keyboardQueue = useRef(Promise.resolve());
  const hpReads=useRef(new Map<string,{resolve:(value:AIValue)=>void;reject:(error:Error)=>void;timer:ReturnType<typeof setTimeout>}>());
  const hpRemoteText=useRef<string>(),hpRemoteVersion=useRef(0);
  const hpReading=useRef<Promise<AIValue>>(),hpClipboardEpoch=useRef(0);
  const hpPublishing=useRef<Promise<void>>();
  const synchronize = useRef(sync); synchronize.current = sync;
  const isActive = useRef(active); isActive.current = active;
  const composing = useRef(false);
  const remoteDrag=useRef<string[]>([]), nativeDragging=useRef(false);
  const pointerStart=useRef<{pointerId:number;outside:boolean;requested:boolean}>();
  const send = (command: AIValue) => invoke("screen_send", { sessionId: session.id, command });
  login.current.available = () => hp && connected.current && hasFrame && isActive.current && document.hasFocus();
  login.current.prepare = async () => { await keyboardQueue.current; await send({kind:"release"}); };
  login.current.changed = setLoginState;
  useEffect(() => {
    const cancel = () => login.current.cancel();
    const visibility = () => { if (document.hidden) cancel(); };
    const escape = (event: KeyboardEvent) => {
      if (event.key === "Escape" && login.current.busy) { event.preventDefault(); event.stopImmediatePropagation(); cancel(); }
    };
    window.addEventListener("blur", cancel); document.addEventListener("visibilitychange", visibility);
    window.addEventListener("keydown", escape, true);
    return () => { cancel(); window.removeEventListener("blur", cancel); document.removeEventListener("visibilitychange", visibility); window.removeEventListener("keydown", escape, true); };
  }, []);
  function notify(command: AIValue) { void send(command).catch(e => { if (connected.current) setStatus(String(e)); }); }
  useEffect(()=>{
    const view=canvas.current;
    if(!active || !view)return;
    const scroll=new ScreenScroll();
    let disposed=false, queue=Promise.resolve();
    const reset=()=>scroll.reset();
    const wheel=(e:WheelEvent)=>{
      if(!connected.current || login.current.busy)return;
      e.preventDefault();
      const rect=view.getBoundingClientRect();
      if(!rect.width||!rect.height)return;
      const steps=hp ? scroll.consume(e.deltaY,e.deltaMode,e.timeStamp,rect.height) : [Math.sign(e.deltaY)].filter(Boolean);
      if(!steps.length)return;
      const pointer={kind:"pointer",buttons:e.buttons,x:Math.max(0,Math.min(view.width-1,Math.floor((e.clientX-rect.left)*view.width/rect.width))),
        y:Math.max(0,Math.min(view.height-1,Math.floor((e.clientY-rect.top)*view.height/rect.height)))};
      queue=queue.then(async()=>{if(disposed)return;await send(pointer);for(const dy of steps){if(disposed)return;await send({kind:"scroll",dy});}}).catch(e=>{if(!disposed)setStatus(String(e));});
    };
    view.addEventListener("wheel",wheel,{passive:false});window.addEventListener("blur",reset);view.addEventListener("pointerleave",reset);view.addEventListener("blur",reset);
    return ()=>{disposed=true;view.removeEventListener("wheel",wheel);window.removeEventListener("blur",reset);view.removeEventListener("pointerleave",reset);view.removeEventListener("blur",reset);};
  },[active,hp,session.id,retry]);
  function beginRemoteDrag(){
    const gesture=pointerStart.current,c=canvas.current;
    if(!hp||!connected.current||login.current.busy||!isActive.current||!gesture?.outside||!remoteDrag.current.length||nativeDragging.current)return;
    nativeDragging.current=true;pointerStart.current=undefined;
    if(c?.hasPointerCapture(gesture.pointerId))c.releasePointerCapture(gesture.pointerId);
    void invoke("screen_drag_out",{sessionId:session.id}).catch(error=>setStatus(String(error))).finally(()=>{nativeDragging.current=false;remoteDrag.current=[];notify({kind:"release"});});
  }
  function readHPClipboard():Promise<AIValue>{
    if(hpReading.current)return hpReading.current;
    const id=crypto.randomUUID();
    const result=new Promise<AIValue>((resolve,reject)=>{
      const timer=setTimeout(()=>{hpReads.current.delete(id);reject(Error("远端剪贴板读取超时"));},3000);
      hpReads.current.set(id,{resolve,reject,timer});
      void send({kind:"clipboardFetch",requestID:id}).catch(error=>{clearTimeout(timer);hpReads.current.delete(id);reject(Error(String(error)));});
    });
    const operation=result.finally(()=>{if(hpReading.current===operation)hpReading.current=undefined;});
    hpReading.current=operation;return operation;
  }
  async function synchronizeHPRemote(apply:boolean){
    const version=hpRemoteVersion.current,epoch=hpClipboardEpoch.current;
    const before=await invoke<ClipboardSnapshot>("rdp_clipboard_snapshot");
    // A local copy that has not been published wins over a delayed remote reply.
    if(apply&&clipboardSequence.current>=0&&before.sequence!==clipboardSequence.current)return;
    const remote=await readHPClipboard();
    if(epoch!==hpClipboardEpoch.current||!synchronize.current||!isActive.current||!connected.current||(!apply&&version!==hpRemoteVersion.current))return;
    if(!remote.hasText)return;
    const changed=remote.text!==hpRemoteText.current;
    if(apply&&changed){clipboardSequence.current=await invoke<number>("rdp_clipboard_write",{paths:[],text:remote.text,expected:before.sequence});lastClipboard.current=remote.text;}
    hpRemoteText.current=remote.text;
  }
  async function publishHPClipboard(){
    if(!hp||!synchronize.current||!isActive.current||!connected.current)return;
    if(hpPublishing.current)return hpPublishing.current;
    const epoch=hpClipboardEpoch.current;
    const operation=(async()=>{
      const snapshot=await invoke<ClipboardSnapshot>("rdp_clipboard_snapshot");
      if(epoch!==hpClipboardEpoch.current||!synchronize.current||!isActive.current||!connected.current)return;
      if(clipboardSequence.current<0){clipboardSequence.current=snapshot.sequence;return;}
      if(snapshot.sequence===clipboardSequence.current)return;
      if(snapshot.text==null){clipboardSequence.current=snapshot.sequence;return;}
      await send({kind:"clipboardSend",text:snapshot.text});
      // Wait for readback before releasing a paste shortcut. Never paste stale text.
      for(let attempt=0;attempt<4;attempt++){
        if(epoch!==hpClipboardEpoch.current||!synchronize.current||!isActive.current||!connected.current)throw Error("剪贴板同步已停止");
        const reply=await readHPClipboard();
        if(epoch!==hpClipboardEpoch.current)throw Error("剪贴板同步已停止");
        if(reply.hasText&&reply.text===snapshot.text){clipboardSequence.current=snapshot.sequence;lastClipboard.current=snapshot.text;hpRemoteText.current=snapshot.text;return;}
        await new Promise(resolve=>setTimeout(resolve,75));
      }
      throw Error("远端剪贴板尚未就绪，请重新粘贴");
    })();hpPublishing.current=operation;
    try{await operation;}finally{if(hpPublishing.current===operation)hpPublishing.current=undefined;}
  }
  function endOffer(error?: string) {
    const pending = offer.current; offer.current = undefined;
    if (pending) { clearTimeout(pending.timer); if (error) {clipboardSequence.current=-1; pending.reject(Error(error));} else pending.resolve(); }
  }
  async function publishClipboard(wait = false) {
    if (!rdp || !synchronize.current || !isActive.current || !connected.current) return;
    const snapshot = await invoke<ClipboardSnapshot>("rdp_clipboard_snapshot");
    if (snapshot.sequence === clipboardSequence.current) { if (wait && offerPromise.current) await offerPromise.current; return; }
    if (!snapshot.paths.length && snapshot.text == null) { if (wait) throw Error("剪贴板中没有可复制的文本或文件"); return; }
    incoming.current = undefined;
    endOffer("剪贴板已变化");
    clipboardSequence.current = snapshot.sequence;
    const offerId = crypto.randomUUID();
    const accepted = new Promise<void>((resolve, reject) => {
      offer.current = { id: offerId, resolve, reject, timer: setTimeout(() => endOffer("剪贴板准备超时，请重新复制"), 15000) };
    });
    offerPromise.current = accepted;
    // Attach immediately: a background clipboard offer must never produce an unhandled rejection.
    void accepted.catch(e => setStatus(String(e)));
    try { await send({kind:"clipboardOffer", offerId, paths:snapshot.paths, text:snapshot.text ?? ""}); }
    catch (error) { endOffer(String(error)); throw error; }
    if (wait) await accepted;
  }
  useEffect(() => {
    login.current.reset(); setHasFrame(false);
    if (!host) {
      setStatus("没有可用的远程桌面凭证，请修改已保存的主机或重新打开快速连接。");
      useAppStore.getState().setSessionLifecycle(session.id,"failed");
      disconnectAttempt.current = undefined;
      return;
    }
    const attempt = screenAttempt(session.id);
    attemptId.current = attempt.attemptId;
    let cancelled = false, hasConnectionError = false, polling = false;
    const recoveryAttempt = recovery.current.attempt(hp, reason => {
      if (cancelled) return;
      setStatus(reason === "broker" ? "正在恢复共享媒体连接…" : "正在重新获取远程画面…");
      setRetry(value => value + 1);
    }, () => {
      if (cancelled) return;
      disconnectAttempt.current?.();
      setStatus(screenConnectionError({code:"firstFrameTimeout"}));
      useAppStore.getState().setSessionLifecycle(session.id,"failed");
    });
    disconnectAttempt.current = () => {
      recoveryAttempt.dispose();
      login.current.cancel(); setHasFrame(false);
      cancelled = true; connected.current = false; setFps(0); setCertificate(undefined);
      finishRemoteTransfers(session.id); endOffer("连接已断开");
      setStatus("已断开"); useAppStore.getState().setSessionLifecycle(session.id,"disconnected");
      void attempt.close().catch(e => setStatus(String(e)));
    };
    useAppStore.getState().setSessionLifecycle(session.id,"connecting");
    let timer: ReturnType<typeof setTimeout>;
    let renderer:HighPerformanceRenderer|undefined;
    const [width,height] = hpResolution.split("x").map(Number);
    let desktop:ScreenDisplay = {width,height,tiles:4};
    if(hp && canvas.current){canvas.current.width=width;canvas.current.height=height;}
    player.current=new ScreenAudio();
    let frames = 0, since = performance.now();
    diagnostics.current = new RemoteVideoDiagnostics();
    setFps(0); setBandwidth("");
    connected.current = false; clipboardSequence.current = -1; setCertificate(undefined);
    hpClipboardEpoch.current++;
    setStatus("连接中…");
    const events = listen<AIValue>("screen-event", ({payload:e}) => {
      if (e.sessionId !== session.id || e.attemptId !== attempt.attemptId || cancelled) return;
      diagnostics.current.event(e, performance.now());
      if (recoveryAttempt.pending) return;
      if (e.kind === "firstFrame") recoveryAttempt.frame();
      if (e.kind === "connected") {
        recoveryAttempt.connected();
        if(hp){
          const size={width:Number(e.width),height:Number(e.height),tiles:Number(e.tiles)};
          try { validateScreenDisplay(size); desktop=size; }
          catch(error){disconnectAttempt.current?.();setStatus(String(error));return;}
        }
        endOffer("连接已更新"); offerPromise.current = undefined; clipboardSequence.current = -1; incoming.current = undefined;
        connected.current = true; setStatus(`已连接 · ${rdp ? "RDP" : hp ? "Apple 高性能" : "VNC"} · ${e.width} × ${e.height}`);
        useAppStore.getState().setSessionLifecycle(session.id,"connected");
        notify({kind:"clipboardSync",enabled:synchronize.current&&isActive.current});
        if(hp||rdp)notify({kind:"audio",enabled:audioEnabled.current&&isActive.current});
        if(hp){hpRemoteText.current=undefined;hpRemoteVersion.current=0;void invoke<ClipboardSnapshot>("rdp_clipboard_snapshot").then(snapshot=>{if(!cancelled)clipboardSequence.current=snapshot.sequence;}).catch(()=>{});if(synchronize.current&&isActive.current)void synchronizeHPRemote(false).catch(()=>{});}
        notify({kind:"frameRate",fps:frameRateRef.current});
        if (rdp) notify({kind:"clipboardActive",active:isActive.current});
      }
      if (e.kind === "remoteDrag") {remoteDrag.current=Array.isArray(e.paths)?e.paths:[];beginRemoteDrag();}
      if (e.kind === "status") setStatus(e.stage);
      if (e.kind === "certificate") setCertificate(e);
      if (e.kind === "error" || e.kind === "disconnected") {
        login.current.cancel(); setHasFrame(false);
        finishRemoteTransfers(session.id);
        preparingFile.current=undefined;
        connected.current = false; setFps(0); setCertificate(undefined); endOffer("连接已断开");
        if (e.kind === "error") { hasConnectionError = true; setStatus(screenConnectionError(e)); }
        else if (!hasConnectionError) setStatus(e.message ?? "连接结束");
        if (recoveryAttempt.failed(e.code)) {
          setStatus("正在恢复共享媒体连接…");
          useAppStore.getState().setSessionLifecycle(session.id,"connecting");
          return;
        }
        useAppStore.getState().setSessionLifecycle(session.id,"failed");
      }
      if (e.kind === "clipboardOfferAccepted" && e.offerId === offer.current?.id) endOffer(e.accepted ? undefined : "远端拒绝剪贴板");
      if (e.kind === "audioError") setStatus(e.message);
      if (e.kind === "clipboardError") { finishPreparation(e.message); endOffer(e.message); setStatus(e.message); }
      if (e.kind === "fileTransfer") {
        if (rdp && e.direction==="download" && e.stage==="queued") finishPreparation();
        const id = `${session.id}:${e.id ?? e.requestID}`;
        const state = e.stage === "queued" ? "waiting" : e.stage === "paused" ? "paused" : ["completed", "failed", "cancelled"].includes(e.stage) ? e.stage : "running";
        if (["waiting","running", "paused"].includes(state)) registerTransferControl(id, async action => {
          await send({kind: hp ? (action === "pause" ? "filePause" : action === "resume" ? "fileResume" : "fileCancel") : (action === "pause" ? "pauseTransfer" : action === "resume" ? "resumeTransfer" : "cancelTransfer"), requestID:e.id ?? e.requestID});
        }); else registerTransferControl(id);
        useTransferStore.getState().setTransfers(items => {
          const old = items.find(t => t.id === id);
          const initial: TransferRecord = old ?? {id,transferKey:id,name:e.name ?? "Clipboard files",direction:e.direction ?? "download",transferred:0,bytesPerSecond:0,sampledAt:Date.now(),sampledBytes:0,state:"running" as const,protocol:rdp ? "RDP" : hp ? "屏幕共享" : "VNC",owner:session.id,source:host.label,supportsPause:true};
          const updated = updateTransferProgress(initial, {transferred:e.completedBytes ?? initial.transferred,total:e.totalBytes ?? initial.total},Date.now());
          const next = {...updated,name:e.name ?? initial.name,state,error:e.error ?? e.code,
            bytesPerSecond:state === "running" ? updated.bytesPerSecond : 0,
            ...(initial.state === "paused" && state === "running" ? {sampledAt:Date.now(),sampledBytes:updated.transferred,bytesPerSecond:0} : {})};
          return old ? items.map(t => t.id === id ? next : t) : [...items,next];
        });
        if (e.stage === "failed") setStatus(e.error ?? "文件复制失败");
      }
      if (e.kind === "clipboardPreparing" && synchronize.current && isActive.current) {
        incoming.current = invoke<ClipboardSnapshot>("rdp_clipboard_snapshot");
        void incoming.current.catch(() => {});
        if (e.files) { prepareFiles(); setStatus("正在接收文件，完成后可在资源管理器中粘贴…"); }
        else finishPreparation();
      }
      if(hp&&e.kind==="clipboard") {const request=hpReads.current.get(e.requestID);if(request){clearTimeout(request.timer);hpReads.current.delete(e.requestID);request.resolve(e);}return;}
      if (e.kind === "clipboardChanged" && synchronize.current && isActive.current){if(hp){hpRemoteVersion.current++;if(!hpPublishing.current)void synchronizeHPRemote(true).catch(()=>{});}else notify({kind:"clipboardFetch",requestID:crypto.randomUUID()});}
      if ((e.kind === "clipboardFiles" || (e.kind === "clipboard" && e.hasText)) && synchronize.current && isActive.current) {
        if (rdp) {
          const snapshot = incoming.current;
          incoming.current = undefined;
          if (snapshot) void snapshot.then(async previous => {
            if (cancelled || !isActive.current || !synchronize.current) return;
            clipboardSequence.current = await invoke<number>("rdp_clipboard_write", {
              paths:e.paths ?? [],text:e.text ?? null,expected:previous.sequence,
            });
            if (e.kind === "clipboardFiles") setStatus("文件已接收，可以在资源管理器中粘贴");
          }).catch(error => {
            setStatus(String(error));
            if(e.kind==="clipboardFiles" && !cancelled) {prepareFiles();finishPreparation(String(error));}
          });
        } else { lastClipboard.current = e.text; void invoke("clipboard_write",{text:e.text}); }
      }
      if (e.kind === "clipboardUnsupported") setStatus("此 VNC 服务仅支持 Latin-1 剪贴板文本");
      if (e.kind === "performance") setBandwidth(`${(((e.receiveBytesPerSecond??0)*8)/1e6).toFixed(2)} Mbps ↓ · ${(((e.sendBytesPerSecond??0)*8)/1e6).toFixed(2)} Mbps ↑`);
    });
    async function poll() {
      if (cancelled) return;
      const started = performance.now();
      if (!polling && connected.current && isActive.current) {
        polling = true;
        try {
          const bytes=await invoke<ArrayBuffer>("screen_next",{sessionId:session.id});
          if(cancelled)return;
          if (hp && canvas.current) {
            const packets=screenPackets(bytes);
            if(packets.length){
              recoveryAttempt.frame();
              diagnostics.current.received(packets.length, performance.now());
              if(!renderer){renderer=new HighPerformanceRenderer(canvas.current,desktop);diagnostics.current.renderer=renderer.description();}
              for(const p of packets)renderer.update(p.header,p.data);
              renderer.present();frames++;diagnostics.current.rendered(performance.now());setHasFrame(true);
            }
            const pcm=await invoke<ArrayBuffer>("screen_audio_next",{sessionId:session.id});if(cancelled)return;if(audioEnabled.current)player.current?.push(pcm);
          } else {
            const frame = decodeScreenFrame(bytes);
            if (frame && canvas.current) {
              diagnostics.current.received(1, performance.now());
              const c=canvas.current;c.width=frame.width;c.height=frame.height;
              const context=c.getContext("2d");if(!context)throw Error("Canvas 2D unavailable");
              context.putImageData(new ImageData(frame.rgba,frame.width,frame.height),0,0);
              diagnostics.current.renderer="Canvas 2D · BGRX";
              frames++;diagnostics.current.rendered(performance.now());
            }
          }
          const elapsed = performance.now() - since;
          if (elapsed >= 1000) { setFps(Number((frames * 1000 / elapsed).toFixed(1))); frames=0; since=performance.now(); }
        } catch(e) { if (!cancelled) {diagnostics.current.videoError="Frame receive/render failed";setStatus(String(e));} } finally { polling=false; }
      }
      if(!cancelled)timer=setTimeout(poll,Math.max(0,1000/frameRateRef.current-(performance.now()-started)));
    }
    void events.then(() => attempt.start({host,savedHost:session.screenSharingSavedHost ?? false,frameRate:frameRateRef.current,videoCodec:videoCodecRef.current,displaySize:hp?[width,height]:undefined})).then(() => {
      if (!cancelled) void poll();
    }).catch(e => { if (!cancelled) { hasConnectionError=true;setStatus(String(e));useAppStore.getState().setSessionLifecycle(session.id,"failed"); } });
    return () => {recoveryAttempt.dispose();login.current.reset();hpClipboardEpoch.current++;connected.current=false;for(const request of hpReads.current.values()){clearTimeout(request.timer);request.reject(Error("会话已关闭"));}hpReads.current.clear();renderer?.close();player.current?.close();cancelled=true;finishRemoteTransfers(session.id);preparingFile.current=undefined;clearTimeout(timer);endOffer("会话已关闭");void events.then(f=>f());void attempt.close().catch(()=>{});};
  },[session.id,retry,hpResolution]);
  useEffect(() => {
    if (connected.current) notify({kind:"frameRate",fps:frameRate});
  },[frameRate]);
  useEffect(() => {
    hpClipboardEpoch.current++;
    if (connected.current) notify({kind:"clipboardSync",enabled:sync&&active});
    if (!sync) {finishPreparation();incoming.current=undefined;endOffer("剪贴板同步已关闭");}
    clipboardSequence.current=-1;offerPromise.current=undefined;
    if(hp&&sync&&active&&connected.current){hpRemoteText.current=undefined;void synchronizeHPRemote(false).catch(()=>{});}
  },[sync]);
  useEffect(() => {if ((rdp||hp) && connected.current) notify({kind:"audio",enabled:audio&&active});},[audio,active]);
  useEffect(() => {
    hpClipboardEpoch.current++;
    if (connected.current) {if(hp)notify({kind:"clipboardSync",enabled:sync&&active});if (rdp) notify({kind:"clipboardActive",active});if (!active) notify({kind:"release"});}
    if (!active) {login.current.cancel();finishPreparation();incoming.current=undefined;endOffer("会话已切换");if(!hp)clipboardSequence.current=-1;}
    else if(hp&&sync&&connected.current){void synchronizeHPRemote(false).catch(()=>{});}
  },[active]);
  useEffect(() => {
    let busy=false,lastRemotePoll=0;
    const timer=setInterval(async()=>{
      if (!sync||!active||!connected.current||!document.hasFocus()||busy) return;
      if (rdp && document.activeElement !== input.current && document.activeElement !== canvas.current) return;
      busy=true;
      try {
        if (rdp) await publishClipboard();
        else if(hp){await publishHPClipboard();if(performance.now()-lastRemotePoll>2000){lastRemotePoll=performance.now();await synchronizeHPRemote(true);}}
        else {const text=await invoke<string>("clipboard_read");if(text!==lastClipboard.current){lastClipboard.current=text;await send({kind:"clipboardSend",text});}}
      } catch {} finally {busy=false;}
    },750);
    return ()=>clearInterval(timer);
  },[sync,active,rdp]);
  useEffect(()=>{
    if(!hp||!active)return;
    let disposed=false,paths:string[]=[],entered=false,queue=Promise.resolve();
    const listener=getCurrentWindow().onDragDropEvent(({payload:p})=>{
      if(disposed||nativeDragging.current)return;
      if(p.type === "enter")paths=p.paths;
      queue=queue.then(async()=>{
        if(disposed||!connected.current||login.current.busy)return;
        const c=canvas.current,r=c?.getBoundingClientRect();
        const x=p.type==="leave"?0:p.position.x/window.devicePixelRatio,y=p.type==="leave"?0:p.position.y/window.devicePixelRatio;
        const inside=p.type!=="leave"&&c&&r&&x>=r.left&&x<r.right&&y>=r.top&&y<r.bottom;
        if(!inside){if(entered){await send({kind:"dragCancel"});await send({kind:"release"});entered=false;}return;}
        if(p.type==="drop")paths=p.paths;
        if(!paths.length)return;
        if(!entered){await send({kind:"dragEnter",paths});entered=true;}
        const point={kind:"pointer",x:Math.max(0,Math.min(c.width-1,Math.floor((x-r.left)*c.width/r.width))),y:Math.max(0,Math.min(c.height-1,Math.floor((y-r.top)*c.height/r.height)))};
        await send({...point,buttons:1});
        if(p.type==="drop"){await send({kind:"dragDrop"});await send({...point,buttons:0});entered=false;paths=[];}
      }).catch(error=>{entered=false;notify({kind:"dragCancel"});notify({kind:"release"});setStatus(String(error));});
    });
    return()=>{disposed=true;void listener.then(stop=>stop());if(entered){notify({kind:"dragCancel"});notify({kind:"release"});}};
  },[hp,active,session.id,retry,hpResolution]);
  function key(e:React.KeyboardEvent, down:boolean) {
    if (login.current.busy) { e.preventDefault(); return; }
    if (e.nativeEvent.isComposing || composing.current || e.key === "Process") return;
    const symbol=keySym(hp && e.key === "Control" ? "Meta" : e.key); if (!symbol) return;
    e.preventDefault();
    const paste=(rdp||hp) && down && (e.ctrlKey||(hp&&e.metaKey)) && e.key.toLowerCase()==="v";
    keyboardQueue.current=keyboardQueue.current.then(async()=>{
      if(paste){if(rdp)await publishClipboard(true);else if(synchronize.current)await publishHPClipboard();}
      await send({kind:"key",key:symbol,down});
    }).catch(error=>{setStatus(String(error));notify({kind:"release"});});
  }
  function pointer(e:React.PointerEvent<HTMLCanvasElement>){
    if (login.current.busy) { e.preventDefault(); return; }
    const c=e.currentTarget,r=c.getBoundingClientRect();
    if(hp&&nativeDragging.current)return;
    if(hp&&e.type==="pointerdown"&&(e.buttons&1)){pointerStart.current={pointerId:e.pointerId,outside:false,requested:false};remoteDrag.current=[];}
    const start=pointerStart.current;
    if(hp&&start&&(e.buttons&1)&&e.type==="pointermove"){
      start.outside=e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom;
      // Ask only after the pointer leaves the remote surface, when Finder has
      // established its drag. A reply may arrive while the pointer is stationary.
      if(start.outside){if(!start.requested){start.requested=true;notify({kind:"dragRequest"});}beginRemoteDrag();return;}
    }
    if(e.type==="pointerup")pointerStart.current=undefined;
    if(e.type==="pointerdown"){if(hp)e.preventDefault();if(hp && audio)player.current?.resume();if(rdp||hp)input.current?.focus();else c.focus();c.setPointerCapture(e.pointerId);}
    notify({kind:"pointer",x:Math.max(0,Math.min(c.width-1,Math.floor((e.clientX-r.left)*c.width/r.width))),y:Math.max(0,Math.min(c.height-1,Math.floor((e.clientY-r.top)*c.height/r.height))),buttons:e.buttons});
  }
  return <div className="vnc-surface">
    <header><span>{status}</span><button className="remote-video-stats" aria-label="画面诊断" title="画面诊断" onClick={()=>setShowDiagnostics(true)}>{fps} FPS · {bandwidth || "↓ — · ↑ —"} ⓘ</button>
      <label><input type="checkbox" checked={sync} onChange={e=>setSync(e.target.checked)}/>双向同步剪贴板</label>
      {(rdp||hp) && <label><input type="checkbox" checked={audio} onChange={e=>{setAudio(e.target.checked);if(e.target.checked&&hp)player.current?.resume();}}/>声音</label>}
      {hp && <>
        <button data-testid="screen-login-password" disabled={!active || !connected.current || !hasFrame || loginState.busy}
          title="请先点击远端对应账号的空密码框，再点击此按钮。将输入当前凭证密码并回车；按 Esc 可取消。"
          onClick={()=>{if(attemptId.current)void login.current.start(session.id,attemptId.current);}}>输入密码并登录</button>
        {loginState.busy && <button data-testid="screen-login-cancel" onClick={()=>login.current.cancel()}>取消</button>}
      </>}
      {hp && <button onClick={()=>void (document.fullscreenElement ? document.exitFullscreen() : display.current?.requestFullscreen())}>全屏</button>}
      {hp && <label title="切换分辨率会自动重新连接">分辨率（重连） <select aria-label="远端分辨率" value={hpResolution} onChange={e=>{recovery.current.reset();setHPResolution(e.target.value);}}>
        <option value="1280x720">1280 × 720</option><option value="1920x1080">1920 × 1080</option>
        <option value="2560x1440">2560 × 1440</option><option value="3840x2160">3840 × 2160</option>
      </select></label>}
      {rdp && <>
        <button onClick={()=>notify({kind:"secureAttention"})}>Ctrl+Alt+Del</button>
        <select aria-label="远端分辨率" defaultValue="1920x1080" onChange={e=>{const[w,h]=e.target.value.split("x").map(Number);notify({kind:"resize",width:w,height:h});}}>
          {["1280x720","1920x1080","2560x1440","3840x2160"].map(s=><option key={s}>{s}</option>)}
        </select><button onClick={()=>void (document.fullscreenElement ? document.exitFullscreen() : display.current?.requestFullscreen())}>全屏</button></>}
      <button onClick={()=>disconnectAttempt.current?.()}>断开</button>
      <button onClick={()=>{recovery.current.reset();setRetry(value=>value+1);}}>重新连接</button>
    </header>
    {hp && loginState.message && <div className="screen-login-status" role="status">{loginState.message}</div>}
    {showDiagnostics && <RemoteVideoDiagnosticsDialog close={()=>setShowDiagnostics(false)} report={()=>diagnostics.current.report(
      rdp ? "RDP" : hp ? "Apple High Performance" : "VNC",
      canvas.current?.width ? `${canvas.current.width} × ${canvas.current.height}` : "—",
      connected.current ? fps : 0, performance.now())}/>}
    {certificate && <div className="rdp-certificate" role="alertdialog" aria-label="验证 RDP 服务器证书">
      <strong>验证 RDP 服务器证书</strong><p>{certificate.endpoint}</p><p>{certificate.message}</p><code>SHA-256: {certificate.sha256}</code>
      <p>确认是目标电脑后继续，本次信任仅用于当前会话。</p>
      <button onClick={()=>{notify({kind:"certificateDecision",id:certificate.id,accept:false});setCertificate(undefined);}}>取消连接</button>
      <button onClick={()=>{notify({kind:"certificateDecision",id:certificate.id,accept:true});setCertificate(undefined);}}>本次继续</button>
    </div>}
    <div className="vnc-display" ref={display}>
      {(rdp||hp)&&<textarea className="rdp-ime" ref={input} aria-label="远端键盘输入" autoCapitalize="off" autoCorrect="off" spellCheck={false}
        onKeyDown={e=>key(e,true)} onKeyUp={e=>key(e,false)}
        onCompositionStart={()=>{composing.current=true;}}
        onCompositionEnd={e=>{composing.current=false;if(login.current.busy){e.currentTarget.value="";return;}if(hp){for(const ch of e.data){notify({kind:"key",key:keySym(ch),down:true});notify({kind:"key",key:keySym(ch),down:false});}}else notify({kind:"text",text:e.data});e.currentTarget.value="";}}
        onBlur={()=>notify({kind:"release"})}/>}
      <canvas ref={canvas} tabIndex={0} onContextMenu={e=>e.preventDefault()} onPointerDown={pointer} onPointerMove={pointer} onPointerUp={pointer}
        onBlur={()=>{if(!rdp)notify({kind:"release"});}} onKeyDown={e=>key(e,true)} onKeyUp={e=>key(e,false)}
        />
    </div>
  </div>;
}
