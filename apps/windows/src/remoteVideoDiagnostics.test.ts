import {describe,it,expect} from "vitest";
import {RemoteVideoDiagnostics,mediaReport} from "./remoteVideoDiagnostics";
describe("video diagnostics",()=>{
  it("keeps reception separate from presentation and advances ages on stalled video",()=>{
    const d=new RemoteVideoDiagnostics();d.received(2,1000);d.rendered(2000);
    const report=d.report("VNC","1920 × 1080",0,6000);
    expect(report).toContain("接收画面: 2 · 5.0 s");expect(report).toContain("绘制画面: 1 · 4.0 s");expect(report).not.toContain("Decode errors");
  });
  it("shows decoder errors before the first frame without exposing unrelated fields",()=>{
    const d=new RemoteVideoDiagnostics();d.event({kind:"mediaDiagnostics",videoCodec:"H.264",videoPackets:1234,decodeErrors:40,audioDecodeErrors:3,lastVideoDecodeError:-1009,password:"secret",host:"private"},0);
    const report=d.report("Apple High Performance","—",0,6000);
    expect(report).toContain("Video packets: 1234");expect(report).toContain("Video errors: 37 · Last code: -1009");expect(report).toContain("接收画面: 0 · 暂无");expect(report).not.toContain("secret");expect(report).not.toContain("private");
  });
  it("does not fabricate zeros for unavailable statistics or divide by zero",()=>{
    expect(mediaReport({decodeCalls:0,decodeMicros:0})).toContain("Decode time: — ms avg");
    expect(mediaReport({})).toContain("Dropped: —");
    expect(mediaReport({decodeCalls:3,decodeMicros:18000,maxDecodeMicros:8000,maxQueueMicros:10000})).toContain("6.00 ms avg · 8.00 ms max · Queue wait: 10.00 ms max");
  });
  it("expires traffic and isolates a reconnected session",()=>{
    const d=new RemoteVideoDiagnostics();d.event({kind:"performance",receiveBytesPerSecond:2048,sendBytesPerSecond:1024},1000);
    expect(d.report("RDP","—",1,2000)).toContain("↓ 2.0 KiB/s · ↑ 1.0 KiB/s");expect(d.report("RDP","—",0,5000)).toContain("↓ — KiB/s");expect(new RemoteVideoDiagnostics().media).toBeUndefined();
  });
});
