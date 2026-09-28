<div align="center">

<img src="NotchBuddy/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="96" alt="Coucou icon">

# Coucou

**A tiny friend that lives in your MacBook's notch and keeps an eye on your Claude Code sessions.**

Approve permissions, answer questions, watch your agents work, drop a file, chat with Claude — all without leaving what you're doing.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-native-0A84FF)
![License: MIT](https://img.shields.io/badge/license-MIT-green)
![GitHub stars](https://img.shields.io/github/stars/Louis-CFM/coucou?style=social)

<img src="docs/media/demo.gif" width="760" alt="Coucou in action">

</div>

---

## Why

Some studios showed off gorgeous notch companions… and never let anyone use them.
**Coucou is the open version.** Every line of code, every animation, every sound — free to use, read, fork and remix.

Meet **Mochi**: a soft little squircle with big eyes that pops out of your notch, waves hello, follows your cursor with its eyes, gets annoyed when you poke it (and dizzy if you insist), and tells you the moment Claude Code needs you.

## Features

- 🤖 **Claude Code, live** — see every session in your notch: what it reads, edits and runs, step by step. Finished? Mochi does a happy little jump.
- ✅ **Approve from the notch** — permission requests show up with **Allow / Always / Deny**. Questions come with their answer buttons. One click, back to work.
- 🧑‍💻 **Jump to the right terminal** — open the exact terminal window of a session.
- 💬 **Ask Claude anything** — built-in chat, straight from the notch.
- 📎 **Drop a file on the notch** — Mochi turns into a box and swallows it, then ask a question about it or send it by email (Mail.app).
- 🪟 **Drag Mochi onto any window** — attach that window as context for Claude.
- 🔌 **Integrations** — Stripe payments, n8n workflows, GitHub, Vercel deployments, Resend emails, Notion, Cal.com. Each one gets its own little colored Mochi.
- 🎭 **A real character** — idle breathing, blinks, eyes on a sphere that follow your mouse, emotes, 28 handcrafted sounds, a greeting on launch.
- 🫥 **Invisible when idle** — hides away when nothing is running, peeks out when you hover the notch.
- 🔒 **Private by design** — no telemetry, no account. Keys live in your macOS Keychain. The app only talks to the services you plug in.

<table>
<tr>
<td><img src="docs/media/claude-code.png" alt="Claude Code session"></td>
<td><img src="docs/media/stripe.png" alt="Stripe payments"></td>
</tr>
<tr>
<td><img src="docs/media/chat.png" alt="Chat with Claude"></td>
<td><img src="docs/media/dizzy.png" alt="Too many hits"></td>
</tr>
</table>

## Install

### Download

1. Grab the latest `Coucou.zip` from [Releases](https://github.com/Louis-CFM/coucou/releases).
2. Unzip and move **Coucou.app** to `/Applications`.
3. Launch — no extra steps needed.

### Build from source

Requirements: macOS 15+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone https://github.com/Louis-CFM/coucou.git
cd coucou/NotchBuddy
xcodegen
open NotchBuddy.xcodeproj   # then ⌘R
```

## Linux

Coucou also has a **Linux** companion (floating top-center island — most PCs have no notch). Stack: Tauri 2 + TypeScript/Canvas under `apps/linux/`. The macOS app is untouched.

Full detail: **[docs/linux.md](docs/linux.md)** · Codex: **[docs/codex-linux.md](docs/codex-linux.md)** · quickstart: **[apps/linux/README.md](apps/linux/README.md)**.

### What you need

| Need | Why |
|---|---|
| **Rust** (`rustup`) + **Node 20+** | build / run Tauri |
| **System deps** (GTK, WebKit, pkg-config, …) | real desktop window — without these, `tauri:dev` fails |
| **Python 3** + **uv** (optional) | Claude hooks + Codex ChatGPT sign-in bridge |
| **xdotool** / **playerctl** / **grim** (optional) | desktop control (Shift+M): keys, media, screenshots |

One-shot on Ubuntu/Debian:

```bash
./scripts/install-linux-deps.sh
# also installs Rust PATH helper usage; if cargo is missing:
# curl https://sh.rustup.rs -sSf | sh && source ~/.cargo/env
```

### Run correctly (important)

Use the **desktop app** (`tauri:dev`), not browser-only Vite, if you want Codex sign-in, secrets, hooks socket, or Shift+M desktop control.

```bash
# 1) once: system packages
./scripts/install-linux-deps.sh

# 2) app deps
cd apps/linux
npm install

# 3) optional — Codex “Sign in with ChatGPT”
npm run codex:setup          # needs `uv`

# 4) run the real window (cargo must be on PATH)
npm run tauri:dev
```

From the repo root you can also use `./scripts/dev-linux.sh` for a **browser preview only** (UI polish / no native APIs). That mode cannot sign in to Codex.

### Connect Claude Code / Codex

1. Open the island → **gear (Settings)**.
2. **Claude Code** → **Install hooks** (backs up `~/.claude/settings.json`, shows a merge preview, writes only after you confirm in the UI flow).
3. **Cloud AI** → **Sign in with ChatGPT** (Codex) — only works inside `tauri:dev` / a built AppImage·deb.
4. Optional: save an **Anthropic API key** for chat / screen analysis.

Hotkey: **Shift+M** — ask Coucou to open YouTube, change the song, analyze the screen, type text, press Enter, etc.

### Package / install

```bash
./scripts/install-linux-deps.sh   # once
./scripts/build-linux.sh          # → dist/linux/*.deb and *.AppImage
```

```bash
sudo dpkg -i dist/linux/*.deb
# or
chmod +x dist/linux/*.AppImage && ./dist/linux/*.AppImage
```

Secrets use Secret Service (GNOME Keyring / KWallet) when available; otherwise a `0600` file fallback. Hook protocol matches macOS (`nb-hook` → Unix socket under `~/.local/share/coucou/`).

## Setup

Click the Coucou icon in the menu bar → **Settings…**

| What | Why | Where the key goes |
|---|---|---|
| **Claude Code hooks** | live sessions, approvals, questions | **Install hooks** — Coucou backs up `~/.claude/settings.json`, merges its hooks and shows you the diff before writing anything |
| **Anthropic API key** | chat and questions about files/windows | Keychain |
| Stripe, n8n, GitHub, Vercel, Resend, Notion, Cal.com | the integration pills | Keychain, all optional |

If Coucou isn't running, the hook exits immediately: **Claude Code is never blocked.**

## Things to try

| Do this | Mochi does that |
|---|---|
| Hover the notch | peeks out and says hi 👋 |
| Click it | opens |
| Hover Mochi | blinks, eyes grow |
| Click Mochi | squish + annoyed |
| Click 3 times fast | 😵‍💫 dizzy for a few seconds |
| Drag a file onto the notch | turns into a box and swallows it |
| Drag Mochi onto a window | attaches it as context |

## How it works

- **Island**: a borderless `NSPanel` hugging the notch, driven by a small state machine (`hidden → petit → home`).
- **Character**: drawn in SwiftUI `Canvas` + `TimelineView` at 60 fps — squircle body, eyes projected on a sphere, spring animations. No Rive, no Lottie, no images.
- **Claude Code**: a tiny `nb-hook` script receives hook events and forwards them over a Unix socket to the app. For approvals it waits for your click, then answers the hook.
- **Integrations**: lightweight pollers, paused when nothing is watching.
- **Sounds**: 28 short WAVs played through preloaded `AVAudioPlayer`s.

Everything is native Swift 6 / SwiftUI / AppKit with **zero third-party dependencies**.

## Contributing

Issues and PRs are very welcome — new integrations, new emotes, new sounds, bug fixes. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits

Built by [Louis Raillé](https://louisraille.fr) with Claude Code.
Inspired by the notch-companion concepts shared by design studios — this project is independent and not affiliated with any of them.

## License

- **Code:** [MIT](LICENSE) — use it, fork it, learn from it, just keep the copyright notice.
- **Name, Mochi character, icon, sounds and media:** © Louis Raillé, all rights reserved — see [LICENSE-ASSETS.md](LICENSE-ASSETS.md). Shipping your own fork? Give it your own name and character.

<div align="center">

**If Mochi made you smile, a ⭐ helps a lot.**

[Website](https://louis-cfm.github.io/coucou/) · [Privacy](https://louis-cfm.github.io/coucou/privacy.html) · [Terms](https://louis-cfm.github.io/coucou/terms.html) · [Support](https://louis-cfm.github.io/coucou/support.html)

</div>
