import { refreshInterval } from "../uiScheduling";
import {
  ArrowRightCircle,
  Pencil,
  Plus,
  RefreshCw,
  SplitSquareVertical,
  Trash2,
  X,
  XOctagon,
} from "lucide-react";
import { invoke } from "@tauri-apps/api/core";
import { useEffect, useMemo, useRef, useState } from "react";

import { useTranslation } from "../i18n";
import type { Host, SessionDescriptor, TmuxSession, TmuxWindow } from "../types";
import { useAppStore } from "../store";

interface TmuxDialog {
  type: "input" | "confirm";
  title: string;
  message?: string;
  label?: string;
  value?: string;
  confirmLabel?: string;
  destructive?: boolean;
  submit: (value?: string) => void | Promise<void>;
}

export function TmuxPanel({
  active = true,
  host,
  session,
}: {
  active?: boolean;
  host?: Host;
  session: SessionDescriptor;
}) {
  const t = useTranslation();
  const openSiblingTab = useAppStore((state) => state.openSiblingTab);
  const preferences = useAppStore((state) => state.preferences);

  const [sessions, setSessions] = useState<TmuxSession[]>([]);
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<string>();
  const [windows, setWindows] = useState<TmuxWindow[]>([]);
  const [windowsLoading, setWindowsLoading] = useState(false);
  const [preview, setPreview] = useState<string>();
  const [previewLoading, setPreviewLoading] = useState(false);
  const [loading, setLoading] = useState(false);
  const [missing, setMissing] = useState(false);
  const [error, setError] = useState<string>();
  const [dialog, setDialog] = useState<TmuxDialog>();
  const generationRef = useRef(0);
  const refreshInFlight = useRef(false);
  const versionProbedRef = useRef(false);
  const selectedRef = useRef<string>();
  selectedRef.current = selected;

  const filteredSessions = useMemo(() => {
    const value = query.trim().toLowerCase();
    if (!value) return sessions;
    return sessions.filter((item) =>
      item.name.toLowerCase().includes(value),
    );
  }, [sessions, query]);

  async function execute(command: string) {
    const result = host
      ? await invoke<{ stdout: string; stderr: string; code?: number }>(
          "sftp_request",
          {
            host,
            sourceSessionId: session.id,
            // tmux servers are per-user/socket-scoped; never elevate or the
            // panel would manage root's server instead of this session's.
            request: {
              action: "exec",
              command,
              timeoutMS: 15_000,
              elevated: false,
            },
          },
        )
      : await invoke<{ stdout: string; stderr: string; code?: number }>(
          "local_exec",
          {
            command,
            shell: session.shell,
            workingDirectory: session.workingDirectory,
            timeoutMs: 15_000,
          },
        );
    return result;
  }

  async function runManaged(command: string) {
    const result = await execute(command);
    if (indicatesMissingTmux(result.stderr, result.code)) {
      setMissing(true);
      throw new Error(t("tmux is not installed on this host."));
    }
    if (result.code && result.code !== 0) {
      const message = result.stderr.trim();
      throw new Error(
        message ||
          t("tmux exited with code {code}.").replace(
            "{code}",
            String(result.code),
          ),
      );
    }
    return result.stdout;
  }

  async function refresh() {
    if (!active || refreshInFlight.current) return;
    const generation = generationRef.current;
    refreshInFlight.current = true;
    setError(undefined);
    try {
      const result = await execute(tmuxListSessionsCommand);
      if (generation !== generationRef.current) return;
      // `tmux list-sessions` exits non-zero with no server running; that is
      // "no sessions", not a failure. Only a missing binary is an error.
      if (indicatesMissingTmux(result.stderr, result.code)) {
        setMissing(true);
        setSessions([]);
        return;
      }
      setMissing(false);
      const parsed = parseTmuxSessions(result.stdout);
      setSessions(parsed);
      if (!versionProbedRef.current) {
        versionProbedRef.current = true;
        void probeVersion();
      }
      const current = selectedRef.current;
      if (current && parsed.some((item) => item.name === current)) {
        await loadWindows(current);
      } else if (current) {
        resetSelection();
      }
    } catch (reason) {
      if (generation === generationRef.current) setError(reason instanceof Error ? reason.message : String(reason));
    } finally { refreshInFlight.current = false; }
  }

  async function probeVersion() {
    try {
      await execute(tmuxVersionCommand);
    } catch {
      // Version is advisory only; ignore probe failures.
    }
  }

  async function loadWindows(sessionName: string) {
    const command = tmuxListWindowsCommand(sessionName);
    if (!command) return;
    setWindowsLoading(true);
    try {
      const output = await runManaged(command);
      if (selectedRef.current !== sessionName) return;
      setWindows(parseTmuxWindows(output, sessionName));
    } catch (reason) {
      if (selectedRef.current !== sessionName) return;
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      if (selectedRef.current === sessionName) setWindowsLoading(false);
    }
  }

  async function loadPreview(sessionName: string) {
    const command = tmuxCapturePaneCommand(sessionName);
    if (!command) return;
    setPreviewLoading(true);
    try {
      const output = await runManaged(command);
      if (selectedRef.current !== sessionName) return;
      setPreview(output);
    } catch (reason) {
      if (selectedRef.current !== sessionName) return;
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      if (selectedRef.current === sessionName) setPreviewLoading(false);
    }
  }

  async function runAction(action: () => Promise<void>) {
    setLoading(true);
    setError(undefined);
    try {
      await action();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setLoading(false);
    }
  }

  function createSession(name?: string) {
    const command = tmuxNewSessionCommand(name);
    if (!command) {
      setError(t("The tmux session name is invalid."));
      return;
    }
    void runAction(async () => {
      await runManaged(command);
      await refresh();
    });
  }

  function renameSession(target: string, name?: string) {
    const command = tmuxRenameSessionCommand(target, name ?? "");
    if (!command) {
      setError(t("The tmux session name is invalid."));
      return;
    }
    void runAction(async () => {
      await runManaged(command);
      if (selectedRef.current === target) setSelected(name);
      await refresh();
    });
  }

  function killSession(target: string) {
    const command = tmuxKillSessionCommand(target);
    if (!command) return;
    void runAction(async () => {
      await runManaged(command);
      if (selectedRef.current === target) resetSelection();
      await refresh();
    });
  }

  function killServer() {
    void runAction(async () => {
      await runManaged(tmuxKillServerCommand);
      resetSelection();
      await refresh();
    });
  }

  function sendKeys(target: string, keys: string) {
    const command = tmuxSendKeysCommand(target, keys);
    if (!command) return;
    void runAction(async () => {
      await runManaged(command);
      await loadPreview(target);
    });
  }

  function attach(target: string, detachOthers: boolean) {
    const command = tmuxAttachCommand(target, detachOthers);
    if (!command) return;
    openSiblingTab(session.id, `tmux: ${target}`, `${command}\r`);
  }

  function toggleSelection(item: TmuxSession) {
    if (selectedRef.current === item.name) {
      resetSelection();
      return;
    }
    setSelected(item.name);
    setWindows([]);
    setPreview(undefined);
    void loadWindows(item.name);
    void loadPreview(item.name);
  }

  function resetSelection() {
    setSelected(undefined);
    setWindows([]);
    setWindowsLoading(false);
    setPreview(undefined);
    setPreviewLoading(false);
  }

  useEffect(() => {
    generationRef.current += 1;
    versionProbedRef.current = false;
    resetSelection();
    setError(undefined);
    if (!active || (host && session.lifecycle !== "connected")) return;
    void refresh();
    const timer = window.setInterval(() => { void refresh(); }, refreshInterval(preferences.tmuxRefreshInterval));
    return () => { window.clearInterval(timer); generationRef.current += 1; };
  }, [active, host?.id, session.id, session.lifecycle, preferences.tmuxRefreshInterval]);

  return (
    <div className="tmux-panel">
      <div className="tmux-toolbar">
        <input
          placeholder={t("Search sessions...")}
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
        <button
          type="button"
          title={t("New Session")}
          disabled={loading}
          onClick={() =>
            setDialog({
              type: "input",
              title: t("New Session"),
              label: t("Session Name"),
              confirmLabel: t("Create"),
              submit: (value) => createSession(value),
            })
          }
        >
          <Plus size={13} />
        </button>
        {sessions.length > 0 ? (
          <button
            type="button"
            className="is-destructive"
            title={t("Kill Server")}
            disabled={loading}
            onClick={() =>
              setDialog({
                type: "confirm",
                title: t("Kill Server"),
                message: t(
                  "Kill the tmux server and all of its sessions on this host?",
                ),
                confirmLabel: t("Kill Server"),
                destructive: true,
                submit: () => killServer(),
              })
            }
          >
            <XOctagon size={13} />
          </button>
        ) : null}
        <button
          type="button"
          title={t("Refresh")}
          disabled={loading}
          onClick={() => void refresh()}
        >
          <RefreshCw size={13} />
        </button>
      </div>

      <div className="tmux-count-bar">
        <strong>{filteredSessions.length}</strong>
        {t("Sessions")}
      </div>

      {error ? <div className="tmux-error">{error}</div> : null}

      {missing ? (
        <div className="tmux-empty">
          <p>{t("Install tmux on this host to manage sessions.")}</p>
          <code>{tmuxInstallHint(host?.distro)}</code>
        </div>
      ) : filteredSessions.length === 0 && !error ? (
        <div className="tmux-empty">
          <p>{t("No Sessions Found")}</p>
        </div>
      ) : null}

      <div className="tmux-list">
        {filteredSessions.map((item) => (
          <div
            className={`tmux-item ${selected === item.name ? "is-selected" : ""}`}
            key={item.name}
          >
            <div
              className="tmux-row"
              role="button"
              tabIndex={0}
              aria-expanded={selected === item.name}
              onClick={() => toggleSelection(item)}
              onKeyDown={(event) => {
                if (event.target !== event.currentTarget) return;
                if (event.key === "Enter" || event.key === " ") {
                  event.preventDefault();
                  toggleSelection(item);
                }
              }}
            >
              <span
                className={`tmux-state ${item.attached ? "is-attached" : ""}`}
              />
              <div>
                <strong>{item.name}</strong>
                <span>
                  {t("{count} windows").replace(
                    "{count}",
                    String(item.windows),
                  )}
                </span>
              </div>
              <span className="tmux-badge">
                {item.attached ? t("Attached") : t("Detached")}
              </span>
              <div className="tmux-actions">
                <button
                  type="button"
                  title={t("Attach in New Tab")}
                  disabled={loading}
                  onClick={(event) => {
                    event.stopPropagation();
                    attach(item.name, item.attached);
                  }}
                >
                  <ArrowRightCircle size={12} />
                </button>
                <button
                  type="button"
                  title={t("Rename")}
                  disabled={loading}
                  onClick={(event) => {
                    event.stopPropagation();
                    setDialog({
                      type: "input",
                      title: t("Rename Session"),
                      label: t("Session Name"),
                      value: item.name,
                      confirmLabel: t("Rename"),
                      submit: (value) => renameSession(item.name, value),
                    });
                  }}
                >
                  <Pencil size={12} />
                </button>
                <button
                  type="button"
                  className="is-destructive"
                  title={t("Kill")}
                  disabled={loading}
                  onClick={(event) => {
                    event.stopPropagation();
                    setDialog({
                      type: "confirm",
                      title: t("Kill Session"),
                      message: t('Kill tmux session "{name}"?').replace(
                        "{name}",
                        item.name,
                      ),
                      confirmLabel: t("Kill"),
                      destructive: true,
                      submit: () => killSession(item.name),
                    });
                  }}
                >
                  <Trash2 size={12} />
                </button>
              </div>
            </div>
            {selected === item.name ? (
              <TmuxSessionDetail
                windows={windows}
                windowsLoading={windowsLoading}
                preview={preview}
                previewLoading={previewLoading}
                busy={loading}
                onAttachWindow={(window) => attach(window.target, false)}
                onSend={(keys) => sendKeys(item.name, keys)}
                onRefreshPreview={() => void loadPreview(item.name)}
              />
            ) : null}
          </div>
        ))}
      </div>

      {dialog ? (
        <TmuxDialogView
          dialog={dialog}
          onCancel={() => setDialog(undefined)}
          onSubmit={async (value) => {
            const run = dialog.submit;
            setDialog(undefined);
            await run(value);
          }}
        />
      ) : null}
    </div>
  );
}

function TmuxSessionDetail({
  windows,
  windowsLoading,
  preview,
  previewLoading,
  busy,
  onAttachWindow,
  onSend,
  onRefreshPreview,
}: {
  windows: TmuxWindow[];
  windowsLoading: boolean;
  preview?: string;
  previewLoading: boolean;
  busy: boolean;
  onAttachWindow: (window: TmuxWindow) => void;
  onSend: (keys: string) => void;
  onRefreshPreview: () => void;
}) {
  const t = useTranslation();
  const [command, setCommand] = useState("");

  function send() {
    const trimmed = command.trim();
    if (!trimmed) return;
    onSend(trimmed);
    setCommand("");
  }

  return (
    <div className="tmux-detail">
      <div className="tmux-detail-section">
        <h4>{t("Windows")}</h4>
        {windowsLoading && windows.length === 0 ? (
          <p className="tmux-muted">{t("Loading windows...")}</p>
        ) : windows.length === 0 ? (
          <p className="tmux-muted">{t("No windows in this session.")}</p>
        ) : (
          <div className="tmux-window-list">
            {windows.map((window) => (
              <div className="tmux-window-row" key={window.target}>
                <span className="tmux-window-index">{window.index}</span>
                <span className="tmux-window-name">
                  {window.name || t("Window")}
                </span>
                {window.active ? (
                  <span className="tmux-window-active">{t("Active")}</span>
                ) : null}
                <span className="tmux-muted">
                  {t("{count} panes").replace(
                    "{count}",
                    String(window.panes),
                  )}
                </span>
                <button
                  type="button"
                  title={t("Attach in New Tab")}
                  disabled={busy}
                  onClick={() => onAttachWindow(window)}
                >
                  <ArrowRightCircle size={12} />
                </button>
              </div>
            ))}
          </div>
        )}
      </div>

      <div className="tmux-detail-section">
        <h4>{t("Send Command")}</h4>
        <div className="tmux-send-row">
          <input
            placeholder={t("Command to send...")}
            value={command}
            onChange={(event) => setCommand(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                event.preventDefault();
                send();
              }
            }}
          />
          <button
            type="button"
            disabled={busy || !command.trim()}
            onClick={send}
          >
            {t("Send")}
          </button>
        </div>
        <p className="tmux-muted">
          {t("Runs in the session's active window without attaching.")}
        </p>
      </div>

      <div className="tmux-detail-section">
        <div className="tmux-detail-header">
          <h4>{t("Pane Preview")}</h4>
          <button
            type="button"
            title={t("Refresh")}
            disabled={previewLoading}
            onClick={onRefreshPreview}
          >
            <RefreshCw size={11} />
          </button>
        </div>
        {preview ? (
          <pre className="tmux-preview">{preview}</pre>
        ) : previewLoading ? null : (
          <p className="tmux-muted">{t("No preview captured yet.")}</p>
        )}
      </div>
    </div>
  );
}

function TmuxDialogView({
  dialog,
  onCancel,
  onSubmit,
}: {
  dialog: TmuxDialog;
  onCancel: () => void;
  onSubmit: (value?: string) => void | Promise<void>;
}) {
  const t = useTranslation();
  const [value, setValue] = useState(dialog.value ?? "");

  return (
    <div className="tmux-dialog-backdrop" role="presentation" onClick={onCancel}>
      <div
        className="tmux-dialog"
        role="dialog"
        aria-modal="true"
        onClick={(event) => event.stopPropagation()}
      >
        <h3>{dialog.title}</h3>
        {dialog.message ? <p>{dialog.message}</p> : null}
        {dialog.type === "input" ? (
          <label>
            {dialog.label ? <span>{dialog.label}</span> : null}
            <input
              autoFocus
              value={value}
              onChange={(event) => setValue(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter") {
                  event.preventDefault();
                  void onSubmit(value);
                }
              }}
            />
          </label>
        ) : null}
        <div className="tmux-dialog-actions">
          <button type="button" onClick={onCancel}>
            {t("Cancel")}
          </button>
          <button
            type="button"
            className={dialog.destructive ? "is-destructive" : "is-primary"}
            onClick={() => void onSubmit(dialog.type === "input" ? value : undefined)}
          >
            {dialog.confirmLabel ?? t("OK")}
          </button>
        </div>
      </div>
    </div>
  );
}

// ---- Pure command builders and parsers (unit-tested) ----

export const tmuxListSessionsCommand =
  "tmux list-sessions -F '#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_created}\t#{session_activity}' 2>/dev/null";

export const tmuxVersionCommand = "tmux -V";

export const tmuxKillServerCommand = "tmux kill-server";

export function tmuxNewSessionCommand(name?: string) {
  const trimmed = (name ?? "").trim();
  if (!trimmed) return "tmux new-session -d";
  const safe = sanitizeTmuxName(trimmed);
  if (!safe) return undefined;
  return `tmux new-session -d -s ${shellQuote(safe)}`;
}

export function tmuxKillSessionCommand(name: string) {
  const target = tmuxSessionTarget(name);
  if (!target) return undefined;
  return `tmux kill-session -t ${target}`;
}

export function tmuxRenameSessionCommand(current: string, next: string) {
  const target = tmuxSessionTarget(current);
  const safe = sanitizeTmuxName(next);
  if (!target || !safe) return undefined;
  return `tmux rename-session -t ${target} ${shellQuote(safe)}`;
}

export function tmuxAttachCommand(name: string, detachOthers = false) {
  const target = tmuxSessionTarget(name);
  if (!target) return undefined;
  return `tmux attach-session${detachOthers ? " -d" : ""} -t ${target}`;
}

export function tmuxListWindowsCommand(session: string) {
  const target = tmuxSessionTarget(session);
  if (!target) return undefined;
  return (
    `tmux list-windows -t ${target} -F ` +
    "'#{window_index}\t#{window_name}\t#{window_active}\t#{window_panes}' " +
    "2>/dev/null"
  );
}

export function tmuxSendKeysCommand(target: string, keys: string) {
  const safeTarget = tmuxSessionTarget(target);
  const trimmed = keys.trim();
  if (
    !safeTarget ||
    !trimmed ||
    trimmed.length > 2_000 ||
    /[\u0000-\u001f\u007f]/.test(trimmed)
  ) {
    return undefined;
  }
  // Send the literal payload, then a separate Enter key. `-l` stops tmux
  // from interpreting the text as key names.
  return (
    `tmux send-keys -t ${safeTarget} -l ${shellQuote(trimmed)}` +
    ` && tmux send-keys -t ${safeTarget} Enter`
  );
}

export function tmuxCapturePaneCommand(target: string, lines = 200) {
  const safeTarget = tmuxSessionTarget(target);
  if (!safeTarget) return undefined;
  const clamped = Math.min(5_000, Math.max(1, Math.trunc(lines)));
  return `tmux capture-pane -p -t ${safeTarget} -S -${clamped} 2>/dev/null`;
}

export function parseTmuxSessions(output: string): TmuxSession[] {
  const sessions: TmuxSession[] = [];
  for (const line of output.split(/\r?\n/)) {
    const parts = line.split("\t");
    if (parts.length < 3 || !parts[0]) continue;
    sessions.push({
      name: parts[0],
      windows: Number.parseInt(parts[1], 10) || 0,
      attached: (Number.parseInt(parts[2], 10) || 0) > 0,
      created: parts[3] ? Number.parseInt(parts[3], 10) || undefined : undefined,
      lastActivity: parts[4]
        ? Number.parseInt(parts[4], 10) || undefined
        : undefined,
    });
  }
  return sessions;
}

export function parseTmuxWindows(
  output: string,
  session: string,
): TmuxWindow[] {
  const windows: TmuxWindow[] = [];
  for (const line of output.split(/\r?\n/)) {
    const parts = line.split("\t");
    if (parts.length < 4) continue;
    const index = Number.parseInt(parts[0], 10);
    if (!Number.isFinite(index)) continue;
    windows.push({
      session,
      index,
      name: parts[1],
      active: (Number.parseInt(parts[2], 10) || 0) > 0,
      panes: Number.parseInt(parts[3], 10) || 0,
      target: `${session}:${index}`,
    });
  }
  return windows;
}

export function indicatesMissingTmux(stderr: string, code?: number) {
  if (code === 127) return true;
  const normalized = stderr.toLowerCase();
  return (
    normalized.includes("command not found") ||
    normalized.includes("not found") ||
    normalized.includes("no such file")
  );
}

export function parseTmuxVersion(output: string) {
  const trimmed = output.trim();
  if (!trimmed.toLowerCase().startsWith("tmux ")) return undefined;
  const token = trimmed.slice(5).trim().split(/\s+/)[0];
  return token || undefined;
}

export function tmuxInstallHint(distro?: string) {
  switch (distro) {
    case "macos":
    case "freebsd":
      return "brew install tmux";
    case "alpine":
      return "sudo apk add tmux";
    case "arch":
      return "sudo pacman -S tmux";
    case "opensuse":
      return "sudo zypper install tmux";
    case "centos":
    case "rocky":
    case "fedora":
    case "redhat":
    case "almalinux":
    case "oracle":
    case "amazon":
    case "alinux":
    case "openeuler":
      return "sudo dnf install tmux";
    default:
      return "sudo apt install tmux";
  }
}

export function sanitizeTmuxName(value: string) {
  const safe = [...value.trim().slice(0, 128)]
    .filter((character) => /^[A-Za-z0-9_-]$/.test(character))
    .join("");
  return safe || undefined;
}

export function tmuxSessionTarget(value: string) {
  const trimmed = value.trim();
  if (
    !trimmed ||
    trimmed.length > 256 ||
    /[\u0000-\u001f\u007f]/.test(trimmed)
  ) {
    return undefined;
  }
  return shellQuote(trimmed);
}

export function shellQuote(value: string) {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}
