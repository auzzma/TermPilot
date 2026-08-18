# TermPilot Phase 1-3 Acceptance Report

Baseline date: 2026-07-29

Historical reference revision: predecessor Electron implementation `b77f0d97`

## Delivered

### Phase 1

- Independent Swift 6 repository and TermPilot identity.
- macOS 14 package with Domain, Persistence, Remote, Terminal, App, and
  TestSupport modules.
- SwiftTerm local PTY terminal with resize, input, selection, copy, paste,
  search, font sizing, links, OSC title/current-directory, and exit status.
- Citadel-backed structured SFTP prototype with typed directory entries,
  fixed-size streaming upload/download, cancellation, and bounded buffering.
- Independent encrypted Vault persistence with no cross-project source or
  database dependency.
- Debug/Release build, CI, Universal 2 bundle script, Hardened Runtime signing,
  dependency lock file, and ADR-001 through ADR-008.

### Phase 2

- Vault host list, groups, search, host editing, copy-ready model, deletion,
  sorting, last-connect time, double-click connection, and context actions.
- Quick Connect for `user@host`, IPv6, and `ssh://`.
- Password, private-key, encrypted-key prompt, and SSH Agent flows.
- Encrypted Vault credential fields, strict host-key confirmation, private
  `known_hosts`, host-key management, keepalive, cancellation, exit categories,
  and reconnect.

### Phase 3

- Multiple local and SSH tabs.
- Rename-ready workspace model, ordering, pinning, closing, horizontal and
  vertical splits, draggable split dividers, focus tracking, and shortcuts.
- Versioned safe workspace restore. Startup recreates disconnected entries and
  never restores terminal output or process state.
- Shared actor-owned session lifecycle and resource cleanup on close.

## Automated Verification

- Domain, persistence, workspace safety, SSH argument safety, and encrypted
  Vault credential tests are in `Tests/TermPilotTests`.
- A SwiftTerm headless integration test launches `/bin/sh` in a real PTY and
  verifies ordered output plus exit code.
- SFTP tests validate byte integrity, chunk bounds, structured listing, and
  cancellation cleanup.
- Latest local result: 22 tests, 22 passed, 0 failures.
- Debug test command: `swift test`.
- Release and Universal 2 command: `./scripts/build-app.sh`.

## Manual and External Gates

The following project-plan acceptance items require infrastructure or elapsed
time that is not available in a source-only implementation run:

- Real password/key/Agent servers and 1,000 connect/disconnect cycles.
- CJK/Emoji/IME plus `vim`, `tmux`, `htop`, `less`, and `fzf` manual matrix.
- 20 MB output, P95 input latency, 8/16 session RSS, 10,000-host search, and
  24-hour soak measurements.
- Developer ID signing, notarization, staple, Gatekeeper, Intel hardware, and
  clean-machine installation.
- Real-server SFTP interoperability and a 5 GB transfer with measured peak
  memory.

These entries are not marked as passed. They must be run before declaring the
original project plan's phase exit gates complete.
