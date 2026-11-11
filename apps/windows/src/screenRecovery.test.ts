import { afterEach, describe, expect, it, vi } from "vitest";
import { ScreenRecovery } from "./screenRecovery";

afterEach(() => vi.useRealTimers());
describe("independent high-performance screen recovery", () => {
  it("retries missing video once without restarting a healthy second tab", () => {
    vi.useFakeTimers();
    const a = new ScreenRecovery(), b = new ScreenRecovery();
    const retryA = vi.fn(), retryB = vi.fn(), failed = vi.fn();
    let first = a.attempt(true, retryA, failed);
    const second = b.attempt(true, retryB, failed);
    first.connected(); second.connected(); second.frame();
    vi.advanceTimersByTime(15_300);
    expect(retryA).toHaveBeenCalledExactlyOnceWith("firstFrame");
    expect(retryB).not.toHaveBeenCalled();
    first.dispose(); first = a.attempt(true, retryA, failed); first.connected();
    vi.advanceTimersByTime(15_300);
    expect(failed).toHaveBeenCalledTimes(1);
    expect(retryA).toHaveBeenCalledTimes(1);
    a.reset(); first.dispose(); first = a.attempt(true, retryA, failed); first.connected();
    vi.advanceTimersByTime(15_300);
    expect(retryA).toHaveBeenCalledTimes(2);
  });
  it("limits broker recovery and coalesces error plus disconnected events", () => {
    vi.useFakeTimers();
    const recovery = new ScreenRecovery(), retry = vi.fn();
    for (let n = 0; n < 3; n++) {
      const attempt = recovery.attempt(true, retry, vi.fn());
      expect(attempt.failed("mediaBrokerDisconnected")).toBe(n < 2);
      if (n < 2) expect(attempt.failed()).toBe(true);
      vi.advanceTimersByTime(300); attempt.dispose();
    }
    expect(retry).toHaveBeenCalledTimes(2);
    vi.advanceTimersByTime(60_000);
    expect(recovery.attempt(true, retry, vi.fn()).failed("mediaBrokerDisconnected")).toBe(true);
  });
  it("cancels watchdogs and pending recovery when the user disconnects", () => {
    vi.useFakeTimers();
    const retry = vi.fn(), failed = vi.fn(), recovery = new ScreenRecovery();
    const a = recovery.attempt(true, retry, failed); a.connected(); a.dispose();
    const b = recovery.attempt(true, retry, failed); b.failed("mediaBrokerDisconnected"); b.dispose();
    vi.advanceTimersByTime(30_000);
    expect(retry).not.toHaveBeenCalled(); expect(failed).not.toHaveBeenCalled();
  });
  it("does not retry authentication, duplicate targets, VNC or RDP", () => {
    vi.useFakeTimers();
    const retry = vi.fn(), failed = vi.fn(), recovery = new ScreenRecovery();
    const a = recovery.attempt(true, retry, failed);
    for (const code of ["authenticationRejected", "screenSessionAlreadyActive", "udpPortsInUse"]) expect(a.failed(code)).toBe(false);
    const b = recovery.attempt(false, retry, failed); b.connected();
    expect(b.failed("mediaBrokerDisconnected")).toBe(false);
    vi.advanceTimersByTime(30_000);
    expect(retry).not.toHaveBeenCalled(); expect(failed).not.toHaveBeenCalled();
  });
  it("accepts a background tab's first-frame event before the connected event", () => {
    vi.useFakeTimers();
    const retry = vi.fn(), failed = vi.fn();
    const a = new ScreenRecovery().attempt(true, retry, failed);
    a.frame(); a.connected(); vi.advanceTimersByTime(30_000);
    expect(retry).not.toHaveBeenCalled(); expect(failed).not.toHaveBeenCalled();
  });
});
