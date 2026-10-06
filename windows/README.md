# Coucou for Windows

**Lighto Edition · Version 1.0.0**

Coucou puts the island at the top edge of your Windows desktop. Mochi follows your coding-agent activity, surfaces supported permission requests, and can pop out as a floating desktop pet.

- [Download the Windows release](https://github.com/lighto124/coucou/releases/tag/windows-latest)
- [Main README](../README.md) · [Changelog](../CHANGELOG.md) · [Agent integration guide](../docs/AGENTS.md)

## Install

Download the x64 **NSIS setup EXE** from the [Windows latest release](https://github.com/lighto124/coucou/releases/tag/windows-latest) and run it. It installs for the current user and does not require an administrator prompt. This release provides the EXE installer; MSI is not part of the supported Windows package.

The installer is not code-signed, so Windows may show a SmartScreen warning. Verify that the download came from the Coucou release page before proceeding.

## First-time setup

Open Coucou from the notification area (system tray), choose **Settings…**, and configure the sections below. Hook installers show a preview and preserve unrelated user configuration.

| Settings section | Configure |
|---|---|
| **Agents** | Select and install hooks for Claude Code, Pi, Copilot CLI, Codex or Antigravity. Restart the corresponding agent after installation. |
| **Chat** | Add an Anthropic API key for Claude, or select Pi to use your existing Pi installation without a second key. |
| **Integrations** | Enable Music and any services you use: Stripe, GitHub, Vercel, n8n, Resend, Notion or Cal.com. Agents and integrations share a five-pill limit. |
| **General** | Sound, auto-close, display selection, launch at startup and the Desktop Mochi toggle. |

API keys are stored in Windows Credential Manager. Coucou writes its local log to `%LOCALAPPDATA%\Coucou\coucou.log` and does not send telemetry.

## Supported agents

Coucou keeps each agent's events and permission requests on that agent's own pill. Choose an agent in **Settings → Agents**, preview the proposed hook change, then install it.

| Agent | Managed configuration | Notes |
|---|---|---|
| Claude Code | `%USERPROFILE%\.claude\settings.json` | Existing hooks are backed up and preserved. |
| Pi | `%USERPROFILE%\.pi\agent\extensions\coucou.ts` | Installs one extension file; it will not overwrite an extension it does not own. Restart Pi. |
| Copilot CLI | `%USERPROFILE%\.copilot\hooks\coucou.json` | Adds Coucou entries while preserving other hooks. Open a new CLI session. |
| Codex | `%USERPROFILE%\.codex\hooks\hooks.json` | Adds Coucou entries while preserving other hooks. Restart Codex. |
| Antigravity | `%USERPROFILE%\.gemini\config\hooks.json` | Uses Antigravity's invocation events. Restart Antigravity. |

Permission cards are supported for Coucou's shipped agent pills. An unknown/custom `coucou_agent` does not get a misleading approval card; its request is left for that agent's own terminal flow. See [`docs/AGENTS.md`](../docs/AGENTS.md) for payloads and event details.

## Desktop Mochi and Music

Toggle Desktop Mochi in **Settings → General**. Pop Mochi out from the island to move him around the desktop; double-click him to return. He follows the focused pill's color and activity state and responds to alerts. The island's **Settings** view contains the size slider (72–240 logical pixels, default 120) and **Reset** control.

The **Music** integration reads Windows media sessions, including compatible players and browsers. It needs no key; Mochi sings while the focused Music session is playing.

## Build from source

Requirements: Windows 10/11 x64, [Rust](https://rustup.rs), Node 20+, Visual Studio Build Tools with **Desktop development with C++**, and WebView2.

```powershell
git clone https://github.com/lighto124/coucou.git
cd coucou/windows
npm install
npm run tauri dev
```

Build only the NSIS EXE installer:

```powershell
npm run tauri build -- --bundles nsis
```

Tauri writes it to `target/release/bundle/nsis/`. The built app is `target/release/coucou.exe`. The optional `npm run icons` command regenerates the icons from `scripts/gen-icons.mjs`.

Run the frontend and Rust checks with:

```powershell
npx tsc --noEmit
npm run test:mochi
npm run test:pills
cd src-tauri
cargo fmt --all --check
cargo test --release
```

## Layout

```text
windows/
  src/                 TypeScript island, settings, integrations and Mochi
  src-tauri/           Rust windows, agent relay, media and system integration
  hook/                coucou-hook.exe named-pipe relay
  scripts/             build and icon utilities
```

## Known Windows differences

The Windows island is not a macOS notch panel. It appears at the top edge of the selected display. The macOS wardrobe/outfits, global-shortcut editor, Mail-based file sending and drag-Mochi-onto-a-window context attachment are not included in this Windows release. Opening a terminal uses the available VS Code integration rather than selecting an existing terminal window.

The Lighto Edition 1.0.0 installer targets Windows. This repository retains upstream-derived macOS and Linux sources, but their packages and fork-specific behavior are not covered by this Windows release.
