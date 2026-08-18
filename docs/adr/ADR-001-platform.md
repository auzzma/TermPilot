# ADR-001: Platform and Distribution Baseline

Status: Accepted

## Decision

- Product name: TermPilot.
- Minimum version: macOS 14.
- Language: Swift 6 with strict concurrency checks.
- Architectures: arm64 and x86_64 in a Universal 2 application.
- Distribution: signed and notarized ZIP/DMG outside the Mac App Store.
- App Sandbox: disabled because local shells and OpenSSH need normal access to
  user files, executables, `~/.ssh`, SSH Agent sockets, and development tools.

## Consequences

Hardened Runtime, least-privilege process arguments, encrypted Vault fields,
file permissions, and release verification are the primary security boundaries.
App Store distribution would require a separate architecture decision.
