import { describe, expect, it } from "vitest";

import {
  indicatesMissingTmux,
  parseTmuxSessions,
  parseTmuxVersion,
  parseTmuxWindows,
  sanitizeTmuxName,
  shellQuote,
  tmuxAttachCommand,
  tmuxCapturePaneCommand,
  tmuxInstallHint,
  tmuxKillServerCommand,
  tmuxKillSessionCommand,
  tmuxListWindowsCommand,
  tmuxNewSessionCommand,
  tmuxRenameSessionCommand,
  tmuxSendKeysCommand,
} from "./TmuxPanel";

describe("Tmux session commands", () => {
  it("validates and quotes user-supplied names", () => {
    expect(tmuxNewSessionCommand("dev")).toBe(
      "tmux new-session -d -s 'dev'",
    );
    expect(tmuxNewSessionCommand(undefined)).toBe("tmux new-session -d");
    expect(tmuxNewSessionCommand("   ")).toBe("tmux new-session -d");
    // Injection characters are stripped before quoting (hyphens are kept).
    expect(tmuxNewSessionCommand("a; rm -rf /")).toBe(
      "tmux new-session -d -s 'arm-rf'",
    );
    expect(tmuxNewSessionCommand("@@@")).toBeUndefined();

    expect(tmuxKillSessionCommand("dev")).toBe(
      "tmux kill-session -t 'dev'",
    );
    expect(tmuxRenameSessionCommand("old", "new")).toBe(
      "tmux rename-session -t 'old' 'new'",
    );
    expect(tmuxRenameSessionCommand("old", "api; rm")).toBe(
      "tmux rename-session -t 'old' 'apirm'",
    );
    expect(tmuxRenameSessionCommand("old", "@@@")).toBeUndefined();
  });

  it("rejects control characters and escapes quotes in targets", () => {
    expect(tmuxKillSessionCommand("dev\nrm")).toBeUndefined();
    // Existing names keep their value but are shell-escaped.
    expect(tmuxKillSessionCommand("my'session")).toBe(
      "tmux kill-session -t 'my'\\''session'",
    );
    expect(shellQuote("a'b")).toBe("'a'\\''b'");
    expect(sanitizeTmuxName(" api-server_1 ")).toBe("api-server_1");
  });

  it("builds attach commands with optional takeover", () => {
    expect(tmuxAttachCommand("dev")).toBe(
      "tmux attach-session -t 'dev'",
    );
    expect(tmuxAttachCommand("dev", true)).toBe(
      "tmux attach-session -d -t 'dev'",
    );
    expect(tmuxKillServerCommand).toBe("tmux kill-server");
  });
});

describe("Tmux windows, send-keys, capture-pane", () => {
  it("builds and parses window listings", () => {
    expect(tmuxListWindowsCommand("dev")).toContain(
      "tmux list-windows -t 'dev' -F ",
    );
    expect(tmuxListWindowsCommand("  ")).toBeUndefined();

    const windows = parseTmuxWindows(
      "0\teditor\t1\t2\n1\tlogs\t0\t1\nbad",
      "dev",
    );
    expect(windows).toHaveLength(2);
    expect(windows[0]).toMatchObject({
      index: 0,
      name: "editor",
      active: true,
      panes: 2,
      session: "dev",
      target: "dev:0",
    });
    expect(windows[1].active).toBe(false);
  });

  it("sends literal keys followed by a separate Enter", () => {
    expect(tmuxSendKeysCommand("dev", "git pull && make")).toBe(
      "tmux send-keys -t 'dev' -l 'git pull && make'" +
        " && tmux send-keys -t 'dev' Enter",
    );
    expect(tmuxSendKeysCommand("dev", "echo 'hi'")).toContain(
      "-l 'echo '\\''hi'\\'''",
    );
    expect(tmuxSendKeysCommand("dev", "  ")).toBeUndefined();
    expect(tmuxSendKeysCommand("dev", "ls\nrm")).toBeUndefined();
  });

  it("clamps capture-pane history depth", () => {
    expect(tmuxCapturePaneCommand("dev", 200)).toBe(
      "tmux capture-pane -p -t 'dev' -S -200 2>/dev/null",
    );
    expect(tmuxCapturePaneCommand("dev", 0)).toBe(
      "tmux capture-pane -p -t 'dev' -S -1 2>/dev/null",
    );
    expect(tmuxCapturePaneCommand("dev", 999_999)).toBe(
      "tmux capture-pane -p -t 'dev' -S -5000 2>/dev/null",
    );
    expect(tmuxCapturePaneCommand("  ")).toBeUndefined();
  });
});

describe("Tmux session parsing and diagnostics", () => {
  it("parses formatted session output and skips malformed lines", () => {
    const sessions = parseTmuxSessions(
      "dev\t3\t1\t1700000000\t1700000500\nwork\t1\t0\t\t\nonlyname",
    );
    expect(sessions).toHaveLength(2);
    expect(sessions[0]).toMatchObject({
      name: "dev",
      windows: 3,
      attached: true,
      created: 1_700_000_000,
      lastActivity: 1_700_000_500,
    });
    expect(sessions[1]).toMatchObject({
      name: "work",
      windows: 1,
      attached: false,
    });
    expect(sessions[1].created).toBeUndefined();
  });

  it("detects a missing binary but not an idle server", () => {
    expect(indicatesMissingTmux("", 127)).toBe(true);
    expect(indicatesMissingTmux("bash: tmux: command not found", 1)).toBe(
      true,
    );
    expect(
      indicatesMissingTmux("no server running on /tmp/tmux-501/default", 1),
    ).toBe(false);
    expect(indicatesMissingTmux("", 0)).toBe(false);
  });

  it("parses the tmux version token", () => {
    expect(parseTmuxVersion("tmux 3.4")).toBe("3.4");
    expect(parseTmuxVersion("tmux next-3.5a\n")).toBe("next-3.5a");
    expect(parseTmuxVersion("command not found")).toBeUndefined();
    expect(parseTmuxVersion("")).toBeUndefined();
  });

  it("suggests a distro-appropriate install command", () => {
    expect(tmuxInstallHint("macos")).toBe("brew install tmux");
    expect(tmuxInstallHint("ubuntu")).toBe("sudo apt install tmux");
    expect(tmuxInstallHint("alpine")).toBe("sudo apk add tmux");
    expect(tmuxInstallHint("fedora")).toBe("sudo dnf install tmux");
    expect(tmuxInstallHint("arch")).toBe("sudo pacman -S tmux");
    expect(tmuxInstallHint(undefined)).toBe("sudo apt install tmux");
  });
});
