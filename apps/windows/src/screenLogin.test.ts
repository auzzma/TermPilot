import { afterEach, describe, expect, it, vi } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import { ScreenLoginAction } from "./screenLogin";
vi.mock("@tauri-apps/api/core", () => ({invoke:vi.fn()}));
afterEach(() => vi.mocked(invoke).mockReset());
function fixture() {
  const action = new ScreenLoginAction(); action.available = () => true; action.changed = vi.fn();
  return action;
}
describe("credential login action", () => {
  it("sends only session identifiers, waits for input release, and prevents duplicate clicks", async () => {
    const action = fixture(); let release!: () => void;
    action.prepare = () => new Promise<void>(resolve => {release=resolve;});
    vi.mocked(invoke).mockResolvedValue("已输入密码并回车，请查看远端登录结果。");
    const first = action.start("session", "attempt"); await action.start("session", "attempt");
    expect(invoke).not.toHaveBeenCalled(); release(); await first;
    expect(invoke).toHaveBeenCalledTimes(1);
    expect(invoke).toHaveBeenCalledWith("screen_enter_login_password", {sessionId:"session",attemptId:"attempt",requestId:expect.any(String)});
    expect(action.changed).toHaveBeenLastCalledWith({busy:false,message:"已输入密码并回车，请查看远端登录结果。"});
  });
  it("cancels during preparation without starting native input", async () => {
    const action = fixture(); let release!: () => void;
    action.prepare = () => new Promise<void>(resolve => {release=resolve;});
    const run = action.start("session", "attempt"); action.cancel(); release(); await run;
    expect(invoke).not.toHaveBeenCalled(); expect(action.busy).toBe(false);
    expect(action.changed).toHaveBeenLastCalledWith({busy:false,message:"已取消密码输入。"});
  });
  it("cancels the matching operation and ignores replies from a disconnected attempt", async () => {
    const action = fixture(); let finish!: (value: unknown) => void;
    vi.mocked(invoke).mockImplementation(cmd => cmd === "screen_enter_login_password" ? new Promise(resolve => {finish=resolve;}) : Promise.resolve());
    const run = action.start("session", "old"); await vi.waitFor(() => expect(invoke).toHaveBeenCalledTimes(1));
    const args = vi.mocked(invoke).mock.calls[0][1]; action.cancel(); action.cancel();
    expect(invoke).toHaveBeenLastCalledWith("screen_cancel_login_password",args);
    expect(invoke).toHaveBeenCalledTimes(2); action.reset(); finish("late success"); await run;
    expect(action.changed).toHaveBeenLastCalledWith({busy:false,message:""});
  });
  it("does not start for an unavailable surface and displays native credential errors", async () => {
    const action = fixture(); action.available = () => false; await action.start("session","attempt");
    expect(invoke).not.toHaveBeenCalled(); action.available = () => true;
    vi.mocked(invoke).mockRejectedValue("已保存的远程桌面地址或账号已更改或删除，请从主机列表重新打开。");
    await action.start("session","attempt"); expect(action.changed).toHaveBeenLastCalledWith({busy:false,message:expect.stringContaining("重新打开")});
  });
});
