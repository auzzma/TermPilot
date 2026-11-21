import { describe, expect, it, vi } from "vitest";
import { writeSavedScriptPlan } from "./savedScript";

const script = { bracketedInput: "\x1b[200~echo 1\necho 2\x1b[201~\r" };

describe("saved script input", () => {
  it("writes the complete paste and its Return together", async () => {
    const write = vi.fn(async (_s: string) => {});
    await writeSavedScriptPlan(script, () => true, write);
    expect(write.mock.calls).toEqual([[script.bracketedInput]]);
  });
  it("sends no part of an unsafe plain paste", async () => {
    const write = vi.fn(async (_s: string) => {});
    await expect(writeSavedScriptPlan(script, () => false, write)).rejects.toThrow("Enable bracketed paste");
    expect(write).not.toHaveBeenCalled();
    await writeSavedScriptPlan({ ...script, plainInput: "pwd\r" }, () => false, write);
    expect(write.mock.calls).toEqual([["pwd\r"]]);
  });
  it("uses the newly connected terminal's live paste mode and stops if its session closes", async () => {
    vi.useFakeTimers();
    try {
      let mode: boolean | undefined = false;
      const write = vi.fn(async (_s: string) => {});
      const first = writeSavedScriptPlan(script, () => mode, write, true);
      expect(write).not.toHaveBeenCalled();
      mode = true;
      await vi.advanceTimersByTimeAsync(25);
      await first;
      mode = false;
      const closed = expect(writeSavedScriptPlan(script, () => mode, write, true)).rejects.toThrow("connected shell prompt");
      mode = undefined;
      await vi.advanceTimersByTimeAsync(25);
      await closed;
      expect(write.mock.calls).toEqual([[script.bracketedInput]]);
    } finally {
      vi.useRealTimers();
    }
  });
});
