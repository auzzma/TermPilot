import {version as appVersion} from "../package.json";
type Media = Record<string, unknown>;
/** Session-local counters; only whitelisted statistics enter the copyable report. */
export class RemoteVideoDiagnostics {
  receivedFrames=0; renderedFrames=0;
  lastFrameAt?:number; lastRenderedAt?:number;
  renderer=""; videoError=""; media?:Media;
  receivedBytes?:number; sentBytes?:number; trafficAt?:number;
  received(count:number,now:number){this.receivedFrames+=count;this.lastFrameAt=now;}
  rendered(now:number){this.renderedFrames++;this.lastRenderedAt=now;}
  event(event:Media,now:number){
    if(event.kind==="mediaDiagnostics")this.media=event;
    if(event.kind==="performance"){
      this.receivedBytes=finite(event.receiveBytesPerSecond);this.sentBytes=finite(event.sendBytesPerSecond);this.trafficAt=now;
    }
  }
  report(mode:string,resolution:string,fps:number,now:number,version=appVersion){
    const age=(time?:number)=>time==null?"暂无":`${(Math.max(0,now-time)/1000).toFixed(1)} s`;
    const rate=(value?:number)=>value==null||this.trafficAt==null||now-this.trafficAt>=3000?"—":(value/1024).toFixed(1);
    const lines=[`TermPilot · ${version} · Windows`,`${mode} · ${resolution}`,
      `${fps.toFixed(1)} FPS · ↓ ${rate(this.receivedBytes)} KiB/s · ↑ ${rate(this.sentBytes)} KiB/s`,
      `接收画面: ${this.receivedFrames} · ${age(this.lastFrameAt)}`,`绘制画面: ${this.renderedFrames} · ${age(this.lastRenderedAt)}`,`画面错误: ${this.videoError||"无"}`];
    if(this.renderer)lines.push(this.renderer);
    if(this.media)lines.push(mediaReport(this.media));
    return lines.join("\n");
  }
}
function finite(value:unknown):number|undefined{return typeof value==="number"&&Number.isFinite(value)?value:undefined;}
export function mediaReport(m:Media){
  const number=(key:string)=>finite(m[key]),n=(key:string)=>number(key)??"—";
  const str=(key:string)=>typeof m[key]==="string"?m[key]:"—";
  const ms=(value?:number)=>value==null?"—":(value/1000).toFixed(2);
  const calls=number("decodeCalls"),time=number("decodeMicros"),errors=number("decodeErrors"),audio=number("audioDecodeErrors");
  const lines=[`Video codec: ${str("videoCodec")}`];
  if(typeof m.nativeDecoder==="string"&&m.nativeDecoder)lines.push(`Decoder: ${m.nativeDecoder} · Color: ${n("nativeColorFormat")}`,`Current decoder input/output: ${n("nativeSubmitted")} / ${n("nativeOutputs")}`);
  lines.push(`Video packets: ${n("videoPackets")}`,
    `Decoded: ${n("frames")} · Decode errors: ${n("decodeErrors")} · Dropped: ${n("dropped")}`,
    `Receive queue drops: ${n("receiveQueueDrops")} packets · Assembly queue drops: ${n("decodeQueueDrops")} packets`,
    `Oversized packets: ${n("oversizedPackets")}`,
    `Assembly expired: ${n("assemblyDrops")} units · Late units: ${n("lateUnits")} · Missing sequence: ${n("missingUnits")}`,
    `Codec queue drops: ${n("codecQueueDrops")} units · Recovery skips: ${n("recoverySkips")}`,
    `Overload recoveries: ${n("overloadRecoveries")} · Decoder resets: ${n("decoderResets")}`,
    `Decode time: ${ms(calls&&calls>0&&time!=null?time/calls:undefined)} ms avg · ${ms(number("maxDecodeMicros"))} ms max · Queue wait: ${ms(number("maxQueueMicros"))} ms max`,
    `Video errors: ${errors!=null&&audio!=null?Math.max(0,errors-audio):"—"} · Last code: ${n("lastVideoDecodeError")} · Audio errors: ${n("audioDecodeErrors")}`);
  return lines.join("\n");
}
