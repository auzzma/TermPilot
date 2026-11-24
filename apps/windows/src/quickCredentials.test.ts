import { afterEach, beforeEach, expect, it, vi } from "vitest";
import type { Credential } from "./types";
import { configureQuickCredential, finishQuickCredential, quickCredentialProtocol, readQuickCredential, selectedQuickCredential, supportsQuickCredential, trackQuickCredential } from "./quickCredentials";

const saved: Credential = { id: "password-id", label: "Fixture", username: "test-user", kind: "password", password: "test-secret", savesPassphrase: false, createdAt: "", updatedAt: "" };
let storage: Map<string, string>;
beforeEach(() => {
  storage = new Map();
  vi.stubGlobal("localStorage", { getItem: (key: string) => storage.get(key) ?? null, setItem: (key: string, value: string) => storage.set(key, value) });
});
afterEach(() => vi.unstubAllGlobals());

it("keeps fixed choices and separate protocol histories after successful connection", () => {
  configureQuickCredential("ssh", "fixed", "ssh-key");
  configureQuickCredential("standardVNC", "recent", "");
  configureQuickCredential("highPerformance", "fixed", "mac-account");
  configureQuickCredential("rdp", "recent", "");
  trackQuickCredential("ssh-session", "ssh", saved.id);
  trackQuickCredential("rdp-session", "rdp", saved.id);
  expect(selectedQuickCredential("rdp")).toBe("");
  finishQuickCredential("rdp-session", "connecting", [saved]);
  expect(selectedQuickCredential("rdp")).toBe("");
  finishQuickCredential("rdp-session", "connected", [saved]);
  finishQuickCredential("ssh-session", "connected", [saved]);
  expect(selectedQuickCredential("rdp")).toBe(saved.id);
  expect(selectedQuickCredential("ssh")).toBe("ssh-key");
  expect(selectedQuickCredential("standardVNC")).toBe("");
  expect(selectedQuickCredential("highPerformance")).toBe("mac-account");
  expect([...storage.values()].join()).not.toContain(saved.password);
  expect([...storage.values()].join()).not.toContain(saved.username);
});

it("does not remember failed, cancelled, deleted, or incompatible credentials", () => {
  configureQuickCredential("rdp", "recent", "");
  for (const outcome of ["failed", "disconnected"] as const) {
    trackQuickCredential(outcome, "rdp", saved.id);
    finishQuickCredential(outcome, outcome, [saved]);
    finishQuickCredential(outcome, "connected", [saved]);
    expect(selectedQuickCredential("rdp")).toBe("");
  }
  trackQuickCredential("deleted", "rdp", saved.id);
  finishQuickCredential("deleted", "connected", []);
  trackQuickCredential("key", "rdp", saved.id);
  finishQuickCredential("key", "connected", [{ ...saved, kind: "identityKey" }]);
  expect(selectedQuickCredential("rdp")).toBe("");
});

it("uses the protocol captured by each attempt and records it only once", () => {
  configureQuickCredential("ssh", "recent", "");
  configureQuickCredential("rdp", "recent", "");
  trackQuickCredential("old", "ssh", "first");
  trackQuickCredential("new", "ssh", "second");
  const records = [{ ...saved, id: "first" }, { ...saved, id: "second" }];
  finishQuickCredential("old", "connected", records);
  finishQuickCredential("new", "connected", records);
  finishQuickCredential("old", "connected", records);
  expect(selectedQuickCredential("ssh")).toBe("second");
  expect(selectedQuickCredential("rdp")).toBe("");
});

it("handles missing and malformed preferences and filters incompatible types", () => {
  expect(readQuickCredential("ssh").strategy).toBe("manual");
  storage.set("TermPilot.quickCredential.ssh", "null");
  expect(selectedQuickCredential("ssh")).toBe("");
  expect(quickCredentialProtocol("screenSharing", "highPerformance")).toBe("highPerformance");
  expect(quickCredentialProtocol("screenSharing", "standardVNC")).toBe("standardVNC");
  expect(quickCredentialProtocol("rdp", "highPerformance")).toBe("rdp");
  expect(supportsQuickCredential("rdp", { ...saved, kind: "identityKey" })).toBe(false);
  expect(supportsQuickCredential("ssh", { ...saved, kind: "identityKey" })).toBe(true);
});
