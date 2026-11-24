import type { Credential, SessionLifecycle } from "./types";

export const quickCredentialProtocols = ["ssh", "standardVNC", "highPerformance", "rdp"] as const;
export type QuickCredentialProtocol = typeof quickCredentialProtocols[number];
export type QuickCredentialStrategy = "manual" | "recent" | "fixed";
export type QuickCredentialPreference = { strategy: QuickCredentialStrategy; fixed: string; recent: string };
const storageKey = (protocol: QuickCredentialProtocol) => `TermPilot.quickCredential.${protocol}`;

export function quickCredentialProtocol(kind: string, mode?: string): QuickCredentialProtocol {
  if (kind === "rdp") return "rdp";
  if (kind === "screenSharing") return mode === "highPerformance" ? "highPerformance" : "standardVNC";
  return "ssh";
}

export function supportsQuickCredential(protocol: QuickCredentialProtocol, credential: Credential) {
  return credential.kind === "password" || (protocol === "ssh" && credential.kind === "identityKey");
}

export function readQuickCredential(protocol: QuickCredentialProtocol): QuickCredentialPreference {
  try {
    const data = JSON.parse(localStorage.getItem(storageKey(protocol)) ?? "{}");
    return {
      strategy: ["manual", "recent", "fixed"].includes(data.strategy) ? data.strategy : "manual",
      fixed: typeof data.fixed === "string" ? data.fixed : "",
      recent: typeof data.recent === "string" ? data.recent : "",
    };
  } catch { return { strategy: "manual", fixed: "", recent: "" }; }
}

export function configureQuickCredential(protocol: QuickCredentialProtocol, strategy: QuickCredentialStrategy, fixed: string) {
  const current = readQuickCredential(protocol);
  localStorage.setItem(storageKey(protocol), JSON.stringify({ ...current, strategy, fixed }));
}

export function selectedQuickCredential(protocol: QuickCredentialProtocol) {
  const value = readQuickCredential(protocol);
  return value.strategy === "fixed" ? value.fixed : value.strategy === "recent" ? value.recent : "";
}

// Pending selections live only for a connection attempt and never enter workspace snapshots.
const pending = new Map<string, { protocol: QuickCredentialProtocol; id: string }>();
export function trackQuickCredential(session: string, protocol: QuickCredentialProtocol, id: string) {
  if (id) pending.set(session, { protocol, id });
}

export function finishQuickCredential(session: string, lifecycle: SessionLifecycle, credentials: Credential[]) {
  const selection = pending.get(session);
  if (!selection || lifecycle === "connecting") return;
  pending.delete(session);
  if (lifecycle !== "connected") return;
  const credential = credentials.find(item => item.id === selection.id);
  const value = readQuickCredential(selection.protocol);
  if (value.strategy === "recent" && credential && supportsQuickCredential(selection.protocol, credential)) {
    try { localStorage.setItem(storageKey(selection.protocol), JSON.stringify({ ...value, recent: credential.id })); }
    catch { /* A successful connection must survive unavailable preference storage. */ }
  }
}
