# TermPilot Phase 5-7 Acceptance Notes

Date: 2026-07-30

## Scope

This delivery implements the local, non-cloud portions of phases 5, 6, and 7
from the TermPilot native roadmap.

Explicitly excluded by request:

- Local encrypted backup
- Restore workflows
- Cloud synchronization providers
- OAuth/token handling for sync
- Sync conflict resolution

## Delivered

### Phase 5: Advanced SSH and Transfer Workflows

- Added persisted port forwarding rules.
- Added a Workflows UI section for local, remote, and dynamic forwarding.
- Port forwarding rules launch as managed terminal sessions using system `ssh -N`.
- Existing SFTP work retained: dual-pane workspace, remote sidebar, transfer center, pause/resume, conflict handling, SCP fallback, external editing, and file operations.

### Phase 6: Productivity Tools

- Added persisted snippets with grouping and paste-to-focused-terminal action.
- Added persisted scripts with shell selection and run-as-terminal-session execution.
- Added persisted host notes with Markdown-capable text storage.
- Added Workflows UI sections for snippets, scripts, and notes.
- Existing connection history remains available in persistence.

### Phase 7: Extended Protocols and System Management

- Added persisted external protocol profiles.
- Profiles launch commands such as `mosh`, `et`, `telnet`, or serial tools as managed terminal sessions.
- Added basic remote system command launchers for system status and Docker container listing.
- External protocol binaries are not bundled in this phase; users install required tools separately.

## Verification

- `swift test` passed with 46 tests.
- `./scripts/build-app.sh` passed and produced `dist/TermPilot.app`.

## Known Limits

- Port forwarding uses system `ssh` and does not yet expose live byte counters.
- Password authentication for forwarding and remote command helper sessions relies on the system terminal prompt path.
- Mosh, EternalTerminal, Telnet, serial tools, and Docker commands require matching command-line tools on the user system.
- No backup or cloud synchronization functionality is included.
