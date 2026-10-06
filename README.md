<div align="center">

<img src="NotchBuddy/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="96" alt="Coucou icon">

# Coucou

**Lighto Edition · Version 1.0.0**

*A desktop companion for your AI coding agents.*

On macOS, Mochi lives in the notch. On Windows, he lives at the top of your screen—and can pop out onto the desktop.

[![Lighto Edition 1.0.0](https://img.shields.io/badge/Lighto%20Edition-v1.0.0-0A84FF)](https://github.com/lighto124/coucou/releases)
![Version](https://img.shields.io/github/v/release/Louis-CFM/coucou?filter=v*&label=version&color=0A84FF)](https://github.com/Louis-CFM/coucou/releases)
![Windows 10/11](https://img.shields.io/badge/Windows-10%2F11-0078D4?logo=windows&logoColor=white)
![Tauri 2](https://img.shields.io/badge/Tauri-2-FFC131?logo=tauri&logoColor=black)
![Rust](https://img.shields.io/badge/Rust-backend-000?logo=rust)
![TypeScript](https://img.shields.io/badge/TypeScript-frontend-3178C6?logo=typescript&logoColor=white)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

<img src="docs/media/demo.gif" width="760" alt="Coucou in action">

</div>

---

## About this fork

Coucou — Lighto Edition is a fork of [Louis Raillé's Coucou](https://github.com/Louis-CFM/coucou), based on upstream **0.1.8**. This fork's own version line starts at **1.0.0**. It keeps the island, integrations and Mochi character while focusing this release on the Windows experience and expanded coding-agent support.

The initial Lighto Edition release is for **Windows 10/11**. The repository retains upstream-derived macOS and Linux code, but those platforms do not have a Lighto Edition 1.0.0 installer here. See [`CHANGELOG.md`](CHANGELOG.md) for this fork's changes and [`windows/README.md`](windows/README.md) for Windows-specific details.

## What you can do

- **Follow five coding agents:** Claude Code, Pi, GitHub Copilot CLI, Codex and Antigravity. Each has its own pill and color; install and manage its hooks from Settings.
- **Handle permission requests in the island:** supported agents can wait for Allow or Deny in Coucou. Agent identity is kept separate so one session's request cannot land on another agent's pill.
- **Chat with Claude or Pi:** use your Anthropic API key for Claude, or your existing local Pi installation without entering another key.
- **Let Mochi loose on Windows:** pop him out of the island, move him around the desktop, and bring him home again. Choose his size in island Settings (72–240 px, 120 px by default) and reset it when you like. Desktop Mochi follows the focused pill's color and state, reacts to alerts, and sings along with Music.
- **See what's playing:** the Windows Music pill reads media sessions published by apps such as Spotify, browsers and VLC. It needs no API key.
- **Connect service integrations:** Stripe, GitHub, Vercel, n8n, Resend, Notion and Cal.com. Enable only the pills you want; agents and integrations share a five-pill limit.
- **Drop a file on the island** to add it to a chat.
- **Keep credentials local:** API keys are stored in Windows Credential Manager. Coucou has no account or telemetry; network requests go to the services you configure.

The Windows edition does not currently include the macOS wardrobe/outfits or macOS global-shortcut editor. See [`windows/README.md`](windows/README.md#known-windows-differences) for other platform differences.

## Install

### Windows 10/11

Download the **Coucou-Windows-1.0.0-setup.exe** installer from the [Windows release](https://github.com/lighto124/coucou/releases/tag/windows-latest). It installs for the current user; no administrator prompt is required. The rolling [Windows latest release](https://github.com/lighto124/coucou/releases/tag/windows-latest) is updated as new Windows builds are published.

The installer is unsigned, so Windows may show a SmartScreen warning. Only proceed if you trust the source and have verified the release.

### macOS and Linux

The Lighto Edition 1.0.0 release does not publish macOS or Linux installers. Those source trees are retained from upstream; for released builds and platform instructions, see the [upstream Coucou project](https://github.com/Louis-CFM/coucou).

## Setup

Open Coucou's tray menu and choose **Settings…**. Agent hook installers show a preview before writing and back up managed configuration files. They avoid replacing hooks or extensions they do not own.

| Set up | What it does | Where / notes |
|---|---|---|
| **Claude Code** | Session events and island permission cards | Settings → Agents → Claude Code. Manages `%USERPROFILE%\.claude\settings.json` with a dated backup. |
| **Pi** | Sessions, tool activity and blocking permission requests | Settings → Agents → Pi. Installs one extension at `%USERPROFILE%\.pi\agent\extensions\coucou.ts`; it will not overwrite an extension it does not own. Restart Pi afterward. |
| **Copilot CLI** | Session activity and permission requests | Settings → Agents → Copilot CLI. Adds Coucou's entries to `%USERPROFILE%\.copilot\hooks\coucou.json` while preserving other hooks. Start a new CLI session afterward. |
| **Codex** | Session activity and permission requests | Settings → Agents → Codex. Manages `%USERPROFILE%\.codex\hooks\hooks.json` while preserving other hooks. Restart Codex afterward. |
| **Antigravity** | Session activity and permission requests | Settings → Agents → Antigravity. Manages `%USERPROFILE%\.gemini\config\hooks.json`. Restart Antigravity afterward. |
| **Claude chat** | Chat and file questions with Claude | Settings → Chat. Add an Anthropic API key; Coucou stores it in Windows Credential Manager. |
| **Pi chat** | Chat through your own Pi installation | Settings → Chat → Pi. No additional API key; Pi uses its own sign-in and configuration. |
| **Music** | Shows the current Windows media session and playback state | Settings → Integrations → Music. No key required; works with apps that publish a Windows media session. |
| **Service integrations** | Optional Stripe, GitHub, Vercel, n8n, Resend, Notion and Cal.com pills | Settings → Integrations. Add only the credentials for services you enable; secrets are stored in Windows Credential Manager. |
| **Desktop Mochi** | Toggles the floating desktop pet | Settings → General. The size slider and Reset control are in the island's Settings view. |

Coucou combines enabled agents and integrations under a shared limit of five visible pills. At least one pill stays enabled.

## Try it

| Do this | Mochi / Coucou does this |
|---|---|
| Move the pointer to the top-centre edge | The island peeks out. |
| Click the island | It opens; click Mochi to pat him. Repeated fast clicks make him dizzy. |
| Start an agent session | Its pill shows activity, tool calls and state. |
| Trigger a supported permission request | The island surfaces the request so you can Allow or Deny. |
| Drag a file onto the island | Mochi turns into a box and accepts the file for chat. |
| Pop Mochi out to the desktop | He follows the focused pill; use the size control in island Settings. |
| Double-click Desktop Mochi | He returns to the island. |
| Open the tray menu | Open the island, Settings, pause Coucou or quit. |

## How the Windows build works

- **Island and pet:** Tauri 2 hosts a TypeScript/Canvas 2D interface. The island and Desktop Mochi reuse the same `BotEngine` for rendering and animation.
- **Native behavior:** Rust manages transparent windows, monitor geometry, desktop cursor polling, click-through, settings and media-session updates. Cursor tracking is native because a click-through WebView cannot reliably receive pointer events.
- **Agent hooks:** `coucou-hook.exe` relays agent events through a per-user Windows named pipe. Hook changes are previewed and backed up; unrelated configuration is preserved.
- **Secrets:** API keys live in Windows Credential Manager. The app logs locally to `%LOCALAPPDATA%\Coucou\coucou.log`.

## Build from source (Windows)

Requirements: Windows 10/11, [Rust](https://rustup.rs), Node 20+, and Visual Studio Build Tools with **Desktop development with C++**. WebView2 is included with current Windows installations.

```powershell
git clone https://github.com/lighto124/coucou.git
cd coucou/windows
npm install
npm run tauri dev
```

Build only the NSIS installer (the supported Windows package; MSI is not part of this release):

```powershell
npm run tauri build -- --bundles nsis
```

The installer is written to `windows/target/release/bundle/nsis/`. Run `target/release/coucou.exe` to launch the built app directly. More build notes are in [`windows/README.md`](windows/README.md).

## Version

| Lighto Edition | Based on | Highlights |
|---|---|---|
| **1.0.0** | Upstream 0.1.8 | Windows-focused release; Pi, Copilot CLI, Codex and Antigravity support alongside Claude Code; safer per-agent hook management and permission routing; Desktop Mochi controls and pill-state synchronization; Windows media-session Music pill. |

See [`CHANGELOG.md`](CHANGELOG.md) for detailed notes.

## Contributing

Issues and pull requests are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md). Please include the platform and app version when reporting a bug; for Windows, attach relevant lines from `coucou.log` after removing private information.

## Credits and license

This is an independent fork maintained by **Lighto** and based on Coucou by [Louis Raillé](https://louisraille.fr). It is not affiliated with Apple, Microsoft, Claude, Anthropic or the services integrated by the app.

- **Code:** [MIT](LICENSE). Keep the applicable copyright notice when redistributing.
- **Name, Mochi character, icon, sounds and media:** © Louis Raillé, all rights reserved. See [`LICENSE-ASSETS.md`](LICENSE-ASSETS.md). Forks shipping the character or assets should use their own name and artwork unless they have permission.

<div align="center">

[Lighto Edition releases](https://github.com/lighto124/coucou/releases) · [Upstream Coucou](https://github.com/Louis-CFM/coucou) · [Agent integration guide](docs/AGENTS.md)

</div>
