# ADR-003: Interactive SSH Backend

Status: Accepted for Phases 1-3

## Decision

Use `/usr/bin/ssh` inside SwiftTerm's PTY. Build arguments as an array and place
`--` before the hostname. Use the user's SSH Agent and OpenSSH configuration,
while setting TermPilot-specific host-key and keepalive options explicitly.

Password and encrypted-key prompts use the signed TermPilot executable as
`SSH_ASKPASS`. Saved passwords are decrypted from the Vault before launch and
passed to the askpass helper as Base64 in `TERMPILOT_ASKPASS_SECRET_B64`.
Passwords are never placed in command arguments or logs, and they are not
stored in macOS Keychain.

## Consequences

This obtains OpenSSH algorithm, certificate, Agent, and config compatibility.
Structured SSH events and SFTP are separate adapters. Error diagnosis is based
on lifecycle and exit categories rather than parsing localized terminal text.
