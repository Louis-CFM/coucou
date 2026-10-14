# Coucou ZirconX Architecture & System Overview

Coucou (Custom Edition by ZirconX) is a native-like assistant app powered by Tauri (Windows/Linux) and Swift (macOS), featuring the animated Mochi character that monitors and audits coding agents in real-time.

---

## 1. Core Architecture
- **Desktop Frontend**: Webview using TypeScript, HTML Canvas, and Custom CSS (`windows/src/`).
- **Native Host Backend**: Rust Tauri 2.0 app (`windows/src-tauri/`) handling OS lifecycle, registry, tray menus, window management, and global shortcuts.
- **Hook Relay (`coucou-hook`)**: Lightweight command-line binary (`windows/hook/`) receiving JSON payloads via `stdin` from coding agents and communicating with the app via IPC pipes.
- **i18n Translation Engine**: High-performance key-based translation catalog in TypeScript (`windows/src/i18n/`) and Rust (`windows/src-tauri/src/i18n.rs`).

---

## 2. Key Modules & Directory Structure
- `.agent/`: Agent workspace configurations, rules, and procedures for ZirconX.
- `windows/src/i18n/`:
  - `strings.json`: Core localization strings including Thai (`th`).
  - `extra.json`: Windows/Linux specific localization entries.
  - `i18n.ts`: Language resolver and selector definitions.
- `windows/src-tauri/src/`:
  - `agents.rs`: Agent discovery, configuration patcher, and hook automations.
  - `lib.rs`: Tauri app runtime bootstrap and lifecycle listeners.
  - `i18n.rs`: Backend localized strings for system tray and notifications.
- `windows/hook/`: Standalone hook relay (`coucou-hook.exe`).

---

## 3. Automation & Custom Workflows
- **`sync_and_update.bat`**: One-click local synchronization with upstream repository (`Louis-CFM/coucou`) and automatic rebuild.
- **`.github/workflows/sync-upstream.yml`**: Daily automated upstream sync on GitHub.

---

## 4. Chat Providers & Speech
- **Antigravity (agy)**: Custom integrated provider in `windows/src/core/providers.ts` and `windows/src-tauri/src/chat.rs`. Runs `agy -p` with `CREATE_NO_WINDOW` and turn history context.
- **Voice Wake Detection**: `windows/src/island/voice.ts` listens for wake words ("คูกู", "Coucou") to expand the prompt island. (In progress: Windows WebView2 native audio stream pipeline refinement).
