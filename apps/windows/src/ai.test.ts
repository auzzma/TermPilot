import { describe, expect, it, vi } from "vitest";

const { state } = vi.hoisted(() => ({ state: { workspace: { sessions: [] as any[] }, hosts: [] as any[], sessionHosts: {} as Record<string, any> } }));
vi.mock("./store", () => ({ useAppStore: { getState: () => state }, resolveHostConnection: vi.fn() }));
vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn() }));
import { automationWarningForSession, context } from "./ai";

describe("automatic script context and warnings", () => {
  it("keeps quick SSH connections usable without claiming local or offline sessions are connected SSH", () => {
    state.workspace.sessions = [
      { id: "local", kind: "local", lifecycle: "connected" },
      { id: "offline", kind: "ssh", lifecycle: "failed", hostId: "saved" },
      { id: "quick", kind: "ssh", lifecycle: "connected", hostId: "unsaved", title: "Quick connect" },
    ];
    state.sessionHosts = { quick: { id: "unsaved", hostname: "fixture.invalid", username: "fixture" } };
    expect(context().sessions).toEqual([{
      sessionId: "quick", scope: "host:unsaved", kind: "ssh", connected: true,
      label: "Quick connect", hostId: "unsaved", hostname: "fixture.invalid", username: "fixture",
    }]);
  });
  it("routes a background warning to its session independently of the open conversation", () => {
    const event = { type: "automationError", conversationId: "", sessionId: "A", message: "Fixture queue failure" };
    expect(automationWarningForSession(event, "A")).toBe("Fixture queue failure");
    expect(automationWarningForSession(event, "B")).toBeUndefined();
    expect(automationWarningForSession({ ...event, type: "error" }, "A")).toBeUndefined();
    expect(automationWarningForSession({ ...event, sessionId: undefined }, "A")).toBeUndefined();
  });
});
