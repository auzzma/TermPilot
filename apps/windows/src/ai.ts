import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useAppStore, resolveHostConnection } from "./store";
// JSON is the versioned contract owned by the shared AI engine.
export type AIValue = Record<string, any>;
export const ai = <T = AIValue>(method: string, params: AIValue = {}) =>
  invoke<T>("ai_request", { method, params });
export const aiScope = (sessionId: string) => {
  const s = useAppStore
    .getState()
    .workspace.sessions.find((s) => s.id === sessionId);
  return s?.hostId ? `host:${s.hostId.toLowerCase()}` : sessionId;
};
export const aiInteractions = new Map<string, AIValue>();

export function context() {
  const state = useAppStore.getState();
  return {
    sessions: state.workspace.sessions
      .filter((s) => s.kind === "ssh" && s.lifecycle === "connected")
      .map((s) => {
        const h =
          state.sessionHosts[s.id] ??
          state.hosts.find((h) => h.id === s.hostId);
        return {
          sessionId: s.id,
          scope: aiScope(s.id),
          kind: "ssh",
          label: s.title,
          hostId: s.hostId,
          hostname: h?.hostname,
          username: h?.username,
        };
      }),
  };
}
export const terminalSelections = new Map<string, () => string>();
export const terminalContexts = new Map<string, () => AIValue>();
async function execute(payload: AIValue) {
  const state = useAppStore.getState();
  const a = payload.arguments ?? {};
  const name = payload.name;
  if (name === "host_open") {
    const host = state.hosts.find(
      (h) => h.id.toLowerCase() === String(a.hostId).toLowerCase(),
    );
    if (!host || (host.connectionKind === "screenSharing" || host.connectionKind === "rdp"))
      throw Error("目标 SSH 主机不可用");
    let session = state.workspace.sessions.find(
      (s) => s.hostId === host.id && s.lifecycle === "connected",
    );
    const created = !session;
    if (!session) session = state.openHostSession(host);
    const sid = session.id;
    for (let i = 0; i < 300; i++) {
      const s = useAppStore
        .getState()
        .workspace.sessions.find((s) => s.id === sid);
      if (!s || s.lifecycle === "failed" || s.lifecycle === "exited")
        throw Error("连接失败，请检查终端认证提示");
      if (s.lifecycle === "connected") {
        await ai("context.update", context());
        return { sessionId: sid, created };
      }
      await new Promise((r) => setTimeout(r, 200));
    }
    throw Error("等待 SSH 连接超时");
  }
  if (name.startsWith("portforward_")) {
    if (name === "portforward_tunnels_list")
      return state.forwards.filter((r) =>
        context().sessions.some(
          (s) =>
            s.hostId === r.hostId &&
            (payload.scope === "workspace" ||
              s.scope === payload.scope ||
              `host:${s.hostId?.toLowerCase()}` === payload.scope),
        ),
      );
    const rule = state.forwards.find((r) => r.id === a.ruleId);
    const host = state.hosts.find((h) => h.id === rule?.hostId);
    if (!rule || !host) throw Error("转发规则不可用");
    return invoke(
      name === "portforward_start" ? "forward_start" : "forward_stop",
      name === "portforward_start"
        ? {
            host: resolveHostConnection(state, host),
            rule,
            autoAcceptHostKeys: false,
          }
        : { id: rule.id },
    );
  }
  const session = state.workspace.sessions.find(
    (s) => s.id === a.sessionId && s.lifecycle === "connected",
  );
  if (!session) throw Error("目标终端已断开或重连");
  if (name === "session_close") {
    const workspace = state.workspace.workspaces.find((w) =>
      JSON.stringify(w.root).includes(session.id),
    );
    if (workspace) state.closeSession(workspace.id, session.id);
    await ai("context.update", context());
    return { closed: true };
  }
  if (name === "terminal_read_context")
    return terminalContexts.get(session.id)?.() ?? { text: "", lines: [] };
  if (name === "terminal_write") {
    const bytes = new TextEncoder().encode(a.text);
    let binary = "";
    bytes.forEach((b) => (binary += String.fromCharCode(b)));
    await invoke("terminal_write", {
      sessionId: session.id,
      data: btoa(binary),
    });
    return {};
  }
  const host =
    state.sessionHosts[session.id] ??
    state.hosts.find((h) => h.id === session.hostId);
  if (!host) throw Error("主机不可用");
  const actions: Record<string, string> = {
    sftp_list: "list",
    sftp_read_file: "readText",
    sftp_write_file: "writeText",
    sftp_download: "download",
    sftp_upload: "upload",
    sftp_stat: "stat",
    sftp_home: "realpath",
    sftp_mkdir: "mkdir",
    sftp_delete: "delete",
    sftp_rename: "rename",
    sftp_chmod: "chmod",
  };
  if (!actions[name]) throw Error("未支持的工具");
  const request = { ...a, action: actions[name] };
  delete request.sessionId;
  if (name === "sftp_home") request.path = ".";
  if (name === "sftp_chmod") {
    request.permissions = parseInt(a.mode, 8);
    delete request.mode;
  }
  if (name === "sftp_write_file") request.overwrite = true;
  if (name === "sftp_download" || name === "sftp_upload")
    request.overwrite = false;
  const call = (r: AIValue) =>
    invoke<AIValue>("sftp_request", {
      host,
      sourceSessionId: session.id,
      request: r,
    });
  if (name === "sftp_delete")
    request.kind = (await call({ action: "stat", path: a.path })).entry?.kind;
  return call(request);
}
export async function startAICoordinator() {
  let active = true;
  const off = await listen<AIValue>("ai-event", async ({ payload }) => {
    if (!active) return;
    if (["approval", "question", "form"].includes(payload.type))
      aiInteractions.set(payload.requestId, payload);
    if (payload.type === "interactionClosed")
      aiInteractions.delete(payload.requestId);
    if (payload.type !== "toolRequest") return;
    let value: AIValue;
    try {
      value = { ok: true, result: await execute(payload.payload) };
    } catch (e) {
      value = { ok: false, error: String(e) };
    }
    await ai("interaction.reply", { requestId: payload.requestId, value });
  });
  let previous = "";
  let sending = false;
  let dirty = false;
  let scheduled: ReturnType<typeof setTimeout> | undefined;
  const send = async () => {
    scheduled = undefined;
    if (!active || document.visibilityState === "hidden") return;
    if (sending) { dirty = true; return; }
    const c = context();
    const key = JSON.stringify(c);
    if (key === previous) return;
    sending = true;
    dirty = false;
    try { await ai("context.update", c); previous = key; }
    catch { /* Retry after the next change or the low-frequency fallback. */ }
    finally { sending = false; if (active && dirty) schedule(); }
  };
  const schedule = () => {
    if (!active || scheduled !== undefined) return;
    scheduled = setTimeout(() => void send(), 80);
  };
  const unsubscribe = useAppStore.subscribe((state, old) => {
    if (state.workspace.sessions !== old.workspace.sessions || state.sessionHosts !== old.sessionHosts || state.hosts !== old.hosts) schedule();
  });
  const timer = setInterval(schedule, 30000);
  document.addEventListener("visibilitychange", schedule);
  schedule();
  return () => {
    active = false;
    off(); unsubscribe();
    clearTimeout(scheduled); clearInterval(timer);
    document.removeEventListener("visibilitychange", schedule);
  };

}

export const aiSelectionDrafts = new Map<string, string>();
export function addSelectionToAI(sessionId: string, text: string) {
  aiSelectionDrafts.set(sessionId, text);
  window.dispatchEvent(
    new CustomEvent("termpilot:ai-selection", { detail: sessionId }),
  );
}
