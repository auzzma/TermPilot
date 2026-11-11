import { describe, expect, it } from "vitest";

import {
  assistedPasswordCommand,
  isExplicitSudoPrompt,
  isSuPasswordPrompt,
  isSudoScopedPasswordPrompt,
  makePasswordPromptRequest,
  PasswordPromptDetector,
  passwordPromptCandidates,
  passwordPromptCommandKind,
  passwordPromptQuickFill,
} from "./passwordPromptAssist";
import type { Credential, Host } from "./types";

const host: Host = {
  id: "host",
  label: "Production",
  hostname: "example.com",
  port: 22,
  username: "alice",
  authentication: "password",
  password: "login-secret",
  elevationPassword: "host-secret",
  sortOrder: 0,
  distroMode: "auto",
  iconMode: "auto",
  iconColorMode: "auto",
  sftpFileProtocol: "auto",
  sftpFilenameEncoding: "auto",
  sftpUsesSudo: false,
  serverToolsUseRoot: true,
  serverToolsElevationMethod: "sudo",
  createdAt: "2026-01-01T00:00:00Z",
  updatedAt: "2026-01-01T00:00:00Z",
};

const rootCredential: Credential = {
  id: "root",
  label: "Root",
  username: "root",
  kind: "password",
  password: "root-secret",
  savesPassphrase: false,
  createdAt: "2026-01-01T00:00:00Z",
  updatedAt: "2026-01-01T00:00:00Z",
};

describe("Swift-compatible password prompt detection", () => {
  it("arms only direct sudo and su commands", () => {
    expect(passwordPromptCommandKind("sudo whoami")).toBe("sudo");
    expect(passwordPromptCommandKind("command su - root")).toBe("su");
    expect(passwordPromptCommandKind("sum values")).toBeUndefined();
    expect(
      passwordPromptCommandKind("echo '[sudo] password for alice:'"),
    ).toBeUndefined();
  });

  it("extracts recalled commands from rendered prompt lines", () => {
    expect(
      assistedPasswordCommand("alice@example:~$ sudo whoami"),
    ).toBe("sudo whoami");
    expect(assistedPasswordCommand("~/project ❯ su - root")).toBe(
      "su - root",
    );
    expect(
      assistedPasswordCommand("alice@example:~$ mysql -p"),
    ).toBeUndefined();
  });

  it("rejects concealed and child-program prompts", () => {
    expect(
      isExplicitSudoPrompt(
        "\u001b[8m[sudo] password for alice: \u001b[0m",
      ),
    ).toBe(false);
    expect(isSudoScopedPasswordPrompt("Enter password: ")).toBe(false);
    expect(isSuPasswordPrompt("bob@example.com's password: ")).toBe(false);
  });

  it("offers sudo picker for bare, localized and split prompts after a recalled command", () => {
    for (const prompt of ["Password: ", "密码：", "口令："]) {
      const detector = new PasswordPromptDetector();
      expect(detector.observe(prompt)).toBeUndefined();
      detector.arm(assistedPasswordCommand("alice@host:~$ sudo -i")!);
      detector.observe(prompt.slice(0, 1));
      expect(detector.observe(prompt.slice(1))).toBe("sudo");
      const request = makePasswordPromptRequest(detector, "picker", "sudo", passwordPromptCandidates(host, [rootCredential]), 0);
      expect(request?.presentation).toBe("picker");
      expect(request?.items).toHaveLength(2);
      detector.dismiss();
      expect(detector.reshowDismissedPrompt()).toBe("sudo");
      detector.markFilled();
      expect(detector.observe("Sorry, try again.\r\n" + prompt)).toBe("sudo");
    }
  });

  it("allows a real authentication retry after filling", () => {
    const detector = new PasswordPromptDetector();
    detector.arm("su -");
    expect(detector.observe("Password: ", 1)).toBe("su");
    detector.markFilled(2);
    expect(
      detector.observe(
        "su: Authentication failure\r\nPassword: ",
        3,
      ),
    ).toBe("su");
  });
});

describe("Swift-compatible password credential selection", () => {
  it("prefers the host elevation password and deduplicates secrets", () => {
    expect(passwordPromptQuickFill(host)).toBe("host-secret");
    const candidates = passwordPromptCandidates(host, [
      rootCredential,
      {
        ...rootCredential,
        id: "duplicate",
        password: "host-secret",
      },
      {
        ...rootCredential,
        id: "key",
        kind: "identityKey",
        password: "ignored",
      },
    ]);
    expect(candidates.map((item) => item.id)).toEqual([
      "host",
      "credential:root",
    ]);
  });

  it("uses host-only quick fill unless an armed picker is active", () => {
    const detector = new PasswordPromptDetector();
    const candidates = passwordPromptCandidates(host, [rootCredential]);

    const unarmed = makePasswordPromptRequest(
      detector,
      "picker",
      "sudo",
      candidates,
      0,
    );
    expect(unarmed?.presentation).toBe("hint");
    expect(unarmed?.items.map((item) => item.id)).toEqual(["host"]);

    detector.arm("su -");
    const armed = makePasswordPromptRequest(
      detector,
      "picker",
      "su",
      candidates,
      0,
    );
    expect(armed?.presentation).toBe("picker");
    expect(armed?.items.map((item) => item.id)).toEqual([
      "host",
      "credential:root",
    ]);
    expect(JSON.stringify(armed)).not.toContain("secret");
  });
});
