# ADR-002: Terminal Engine and PTY

Status: Accepted for Phases 1-3

## Decision

Use SwiftTerm 1.15.0. `LocalProcessTerminalView` owns local PTY creation,
resize, input, output, clipboard, search, links, OSC title/current-directory,
IME, Unicode rendering, and process termination. The application owns the
session registry and decides when a hidden terminal is retained or destroyed.

## Rationale

The selected version includes the macOS 26 mouse tracking correction and public
terminal search APIs. It supports AppKit embedding without rendering terminal
cells as SwiftUI views.

## Revisit Triggers

- 20 MB output, latency, memory, or 24-hour tests miss the approved budgets.
- TUI, CJK, Emoji, or IME compatibility has a blocking defect.
- The maintained fork delta becomes material.
