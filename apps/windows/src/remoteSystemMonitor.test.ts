import { beforeEach, describe, expect, it, vi } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import { remoteSystemMonitor } from "./remoteSystemMonitor";
import type { Host } from "./types";
vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
const host = { id: "windows-host", hostname: "example", username: "admin", serverToolsUseRoot: true } as Host;
beforeEach(() => vi.mocked(invoke).mockReset());
describe("remote system monitor", () => {
  it("detects the remote OS once per session, not from the local OS", async () => {
    vi.mocked(invoke).mockResolvedValue({ platform: "windows", username: "admin" });
    const first = remoteSystemMonitor(host, "session-1");
    expect((await first.info()).platform).toBe("windows");
    await first.info();
    expect(invoke).toHaveBeenCalledTimes(1);
    await remoteSystemMonitor(host, "session-2").info();
    expect(invoke).toHaveBeenCalledTimes(2);
    expect(invoke).toHaveBeenLastCalledWith("sftp_request", { host, sourceSessionId: "session-2", request: { action: "systemInfo" } });
  });
  it("retries discovery after a temporary connection failure", async () => {
    vi.mocked(invoke).mockRejectedValueOnce(new Error("disconnected")).mockResolvedValueOnce({ platform: "linux", username: "root" });
    const monitor = remoteSystemMonitor(host, "session");
    await expect(monitor.info()).rejects.toThrow("disconnected");
    expect((await monitor.info()).platform).toBe("linux");
  });
  it("routes structured metrics through the existing connection without Unix elevation", async () => {
    vi.mocked(invoke).mockResolvedValue({ processes: [] });
    const monitor = remoteSystemMonitor(host, "session");
    await expect(monitor.collect("processes")).resolves.toEqual({ processes: [] });
    expect(invoke).toHaveBeenCalledWith("sftp_request", { host, sourceSessionId: "session", request: { action: "systemMonitor", operation: "processes" } });
  });
});
