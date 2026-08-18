# TermPilot Swift

[English](README.md) | [简体中文](README.zh-CN.md)

TermPilot Swift is a native terminal and SSH workspace for macOS. It brings host management, remote access, file transfer, and server operations into one app for developers and system administrators who manage multiple servers.

## Core Features

- **Terminal and SSH**: Use local shells, Quick Connect, and saved hosts with password, private key, certificate, SSH Agent, and proxy authentication.
- **Multi-session workspaces**: Organize tabs and horizontal or vertical splits, with drag reordering, merge, detach, duplicate, pin, and safe layout restoration.
- **Productive terminal tools**: Search, copy and paste, open links, inspect connection logs, and autocomplete commands, options, history, and local or remote paths.
- **Centralized host management**: Manage nested groups, batch actions, appearance markers, reusable credentials, proxies, and strict host-key verification.
- **SFTP/SCP file management**: Browse, upload, download, edit, move, copy, rename, change permissions, and control concurrent transfers with pause support.
- **Server operations**: View system status, manage processes, and work with Docker containers and images.
- **Workflow tools**: Configure local, remote, and dynamic port forwarding; save scripts, snippets, host notes, and connection history.
- **Encrypted backups**: Export and import password-protected `.tpbackup` files.

## Why the Swift Version

- **Native macOS experience**: Built with Swift 6, SwiftUI, and SwiftTerm for system-consistent windows, menus, shortcuts, and interactions.
- **Local-first design**: Hosts, workspaces, and preferences stay on your Mac with no cloud dependency.
- **Secure storage**: Sensitive credentials are encrypted with AES-GCM. TermPilot maintains a private `known_hosts` file and excludes passwords from logs and workspace snapshots.
- **Complete workflow**: Connect to servers, transfer files, inspect processes, and manage containers without switching between tools.
- **Universal and localized**: Supports Apple Silicon and Intel Macs, with English and Simplified Chinese interfaces.

## Requirements

- macOS 14 or later
- Xcode 26 or a Swift 6.2 toolchain
- Network access on the first build to download the locked Node.js 22 SSH runtime

## Development

```bash
swift test
swift run TermPilot
```

Build the Universal 2 app:

```bash
./scripts/build-app.sh
open dist/TermPilot.app
```

Application data is stored in `~/Library/Application Support/TermPilot/`. Workspace snapshots never contain terminal output, process state, or plaintext passwords.

## Community

Telegram: [https://t.me/Impart_Chat](https://t.me/Impart_Chat)

## License

[GPL-3.0-or-later](LICENSE)
