import { afterEach, describe, expect, it, vi } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import { screenAttempt, screenConnectionError } from "./screenConnection";
vi.mock("@tauri-apps/api/core", () => ({invoke:vi.fn().mockResolvedValue(undefined)}));
afterEach(() => vi.mocked(invoke).mockReset().mockResolvedValue(undefined));
describe("remote desktop reconnect", () => {
  it("waits for old helper teardown before starting the next attempt", async () => {
    let release!: () => void;
    const calls: string[] = [];
    vi.mocked(invoke).mockImplementation(async cmd => {
      calls.push(cmd);
      if (cmd === "screen_close") await new Promise<void>(resolve => {release=resolve;});
    });
    const old = screenAttempt("same-tab");
    await old.start({host:{hostname:"127.0.0.1"}});
    const closed = old.close();
    const next = screenAttempt("same-tab");
    const started = next.start({});
    await vi.waitFor(() => expect(calls).toEqual(["screen_start","screen_close"]));
    release(); await closed; await started;
    expect(calls).toEqual(["screen_start","screen_close","screen_start"]);
    expect(old.attemptId).not.toBe(next.attemptId);
  });
  it("cancels a queued reconnect while allowing a different tab to connect", async () => {
    const attempt = screenAttempt("cancelled-tab");
    const start = attempt.start({});
    const close = attempt.close();
    await Promise.all([start,close,screenAttempt("other-tab").start({})]);
    expect(vi.mocked(invoke).mock.calls.filter(([cmd])=>cmd === "screen_start")).toHaveLength(1);
    expect(vi.mocked(invoke).mock.calls.find(([cmd])=>cmd === "screen_start")?.[1]).toMatchObject({sessionId:"other-tab"});
  });
  it("distinguishes authentication failures from local network and port failures", () => {
    expect(screenConnectionError({code:"authenticationRejected",message:"raw"})).toContain("认证失败");
    expect(screenConnectionError({code:"serverProof"})).toContain("认证校验失败");
    expect(screenConnectionError({code:"addressNotAvailable"})).toContain("网络或 VPN");
    expect(screenConnectionError({code:"udpPortsInUse"})).toContain("5900/5901");
    expect(screenConnectionError({code:"rdpFailure",message:"RDP authentication failed"})).toBe("RDP authentication failed");
  });
});
