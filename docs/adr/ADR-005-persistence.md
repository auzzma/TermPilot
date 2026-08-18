# ADR-005: Persistence

Status: Accepted

## Decision

Use SQLite through GRDB 7.11.1 with WAL, foreign keys, explicit migrations, and
transactional writes. Use actors as the repository ownership boundary.

SQLite stores host, group, history, workspace, and encrypted credential fields.
Saved SSH passwords are written as `enc:v1:` AES-GCM field ciphertext. The
local AES key is stored as `credential.key` in TermPilot's Application Support
directory with owner-only permissions. macOS Keychain is not used for TermPilot
SSH credentials.

Workspace persistence uses a versioned Codable allowlist. It excludes terminal
output, scrollback, command history, PIDs, runtime handles, passwords, private
keys, tokens, and process state.
