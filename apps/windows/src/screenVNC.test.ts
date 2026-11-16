import {describe,it,expect,vi} from "vitest";
import {VNCDesktopControl} from "./screenVNC";
describe("VNC resolution negotiation",()=>{
  it("does not send unsupported requests or change dimensions before server confirmation",async()=>{
    const c=new VNCDesktopControl();const sent:Record<string,unknown>[]=[];c.send=async v=>{sent.push(v);};
    c.event({kind:"connected",width:1280,height:720});await c.resize(1920,1080);expect(sent).toHaveLength(0);
    c.event({kind:"vncCapabilities",canResize:true});await c.resize(1920,1080);await c.resize(2560,1440);
    expect(sent).toHaveLength(1);expect(c.state.width).toBe(1280);
    c.event({kind:"vncResizeResult",requestID:"stale",accepted:true});expect(c.state.busy).toBe(true);
    c.event({kind:"vncResizeResult",requestID:sent[0].requestID,accepted:false,code:"vncResizeProhibited"});
    expect(c.state.busy).toBe(false);expect(c.state.width).toBe(1280);expect(c.state.message).toContain("不允许");
    await c.resize(1920,1080);c.event({kind:"desktopSize",width:1920,height:1080});
    c.event({kind:"vncResizeResult",requestID:sent[1].requestID,accepted:true});expect(c.state.width).toBe(1920);c.reset();
  });
  it("times out without claiming success and requires reconnect before another request",async()=>{
    vi.useFakeTimers();try{
      const c=new VNCDesktopControl();c.event({kind:"vncCapabilities",canResize:true});const send=vi.fn(async()=>{});c.send=send;
      await c.resize(1920,1080);await vi.advanceTimersByTimeAsync(15001);expect(c.state.blocked).toBe(true);
      await c.resize(1280,720);expect(send).toHaveBeenCalledTimes(1);c.reset();expect(c.state.blocked).toBe(false);expect(c.state.supported).toBe(false);
    }finally{vi.useRealTimers();}
  });
});
