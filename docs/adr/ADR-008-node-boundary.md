# ADR-008: Node Runtime Boundary

Status: Accepted

## Decision

TermPilot embeds a minimal Node.js runtime and a locked, locally patched `ssh2`
dependency tree for SSH sessions. The runtime is packaged inside
`TermPilot.app/Contents/Resources/ssh2-bridge-runtime` and is launched only by
the Swift terminal runtime for SSH bridge sessions.

The compatibility patch is versioned inside this repository at
`patches/ssh2+1.17.0.patch`. Runtime preparation must fail when that patch is
missing and must never read build inputs from a sibling repository.

TermPilot still does not embed Electron. The Node process is a narrow bridge:
it receives one connection config, opens one SSH shell channel through `ssh2`,
streams terminal data over stdio, and emits explicit `[ssh2:*]` connection logs.

The bridge must not access the Vault database or credential key directly.
Swift decrypts saved host fields and passes only the per-session secret needed
for that connection through the bridge environment.
