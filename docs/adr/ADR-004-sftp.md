# ADR-004: Structured SFTP Backend

Status: Accepted for Phase 1 prototype

## Decision

Use Citadel 0.12.1 for the Phase 1 structured SFTP prototype. The app-facing
boundary is `SFTPBackend`, so directory entries and transfer operations do not
expose shell output or Citadel types.

`CitadelSFTPBackend` maps protocol-level directory metadata and opens remote
file handles for offset-based reads and writes. `SFTPStreamingPrototype`
transfers one fixed-size chunk at a time, checks structured-task cancellation
between I/O operations, and closes the remote handle on success, failure, or
cancellation. The default chunk is 1 MiB and callers cannot configure more
than 8 MiB; the Data/ByteBuffer conversion therefore remains well below the
64 MiB Phase 1 buffer budget.

SFTP product UI and transfer persistence remain outside Phases 1-3.

## Evidence

- Citadel is pinned in `Package.resolved`.
- `SFTPStreamingTests` verify byte-for-byte upload/download, structured
  directory entries, chunk bounds, and cancellation cleanup.
- Debug builds compile the Citadel adapter under Swift 6 strict concurrency.

## Remaining Risk

Citadel 0.12.1 currently depends on the `Wellz26/swift-nio-ssh` fork. Before
Phase 4, run real-server tests for strict host-key validation, all required
authentication methods, directory-handle cleanup, permissions, symlinks, old
servers, 5 GB transfers, Universal 2 signing, and cancellation under network
loss. Compare the result with maintained libssh/libssh2 wrappers before making
the production backend irreversible.

## Exit Condition

The Phase 1 viability gate is complete. Phase 4 product work cannot ship until
the real-server and 5 GB matrix above passes and this ADR is amended with those
results.
