# ADR-007: Release and Signing

Status: Accepted with external prerequisites

## Decision

Build arm64 and x86_64 using SwiftPM, link a Universal 2 executable, assemble
`TermPilot.app`, enable Hardened Runtime during signing, verify with `codesign`,
and publish ZIP plus DMG through GitHub Releases.

CI produces an ad-hoc signed test bundle. Release signing, notarization,
stapling, Gatekeeper assessment, and a clean-machine install test require:

- Apple Developer ID Application identity.
- App Store Connect notarization credentials.
- A release repository and protected secret storage.

These credentials are intentionally not present in source control.
