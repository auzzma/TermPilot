import { invoke } from "@tauri-apps/api/core";
import type { AutomationScript } from "./types";

export type SavedScriptAction = "insert" | "run";
export interface SavedScriptPlan {
  bracketedInput: string;
  plainInput?: string;
}

export function savedScriptPlan(script: Pick<AutomationScript, "body">, action: SavedScriptAction) {
  return invoke<SavedScriptPlan>("saved_script_plan", { body: script.body, action });
}

export async function writeSavedScriptPlan(
  plan: SavedScriptPlan,
  pasteMode: () => boolean | undefined,
  write: (input: string) => Promise<void>,
  waitForPrompt = false,
) {
  const deadline = performance.now() + 5000;
  let mode = pasteMode();
  // xterm may parse the shell's first mode change after SSH reports connected.
  while (waitForPrompt && mode === false && plan.plainInput === undefined && performance.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 25));
    mode = pasteMode();
  }
  if (mode === undefined) throw new Error("Wait for a connected shell prompt.");
  const input = mode ? plan.bracketedInput : plan.plainInput;
  if (input === undefined) throw new Error("Enable bracketed paste in the current shell to use this script.");
  await write(input);
}
