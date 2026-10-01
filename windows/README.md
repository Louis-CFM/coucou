<div align="center">

<img src="src-tauri/icons/128x128.png" width="96" alt="Coucou icon">

# Coucou for Windows

**Mochi doesn't get a notch on a PC — so it lives at the top of your screen instead.**

Approve Claude Code permissions, watch your session work, drop a file, chat with Claude, keep an eye on your services — without leaving what you're doing.

![Windows 10/11](https://img.shields.io/badge/Windows-10%2F11-0078D4?logo=windows)
![Tauri 2](https://img.shields.io/badge/Tauri-2-FFC131?logo=tauri&logoColor=black)
![Rust](https://img.shields.io/badge/Rust-backend-000?logo=rust)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

</div>

<img src="screenshots/greeting.png" width="640" alt="Mochi waving hello at launch">

---

## Install

The downloadable installer is **temporarily unavailable**. Microsoft Defender
wrongly flags the unsigned installer as malware (`Trojan:Win32/Wacatac.H!ml`, a
machine-learning false positive). A report is under review at Microsoft, and the
installer will be published again once it is cleared and code-signed.

Until then, [build it yourself](#build-it-yourself): it takes a few minutes and
installs for the current user only — no admin prompt.

## Using it

<img src="screenshots/compact.png" width="292" alt="The compact island, with the integration pills as mini Mochis">
<img src="screenshots/overview.png" width="640" alt="The overview: the focused integration on the left, the other pills on the right">
<img src="screenshots/approval.png" width="640" alt="A Claude Code permission request, with Deny and Allow">
<img src="screenshots/chat.png" width="640" alt="Chatting with Claude from the island">
<img src="screenshots/drop.png" width="640" alt="Mochi turned into a box, waiting for a file">

| What you do | What happens |
|---|---|
| Move the mouse to the very top-centre of the screen | Mochi peeks out |
| Click the small island | It opens |
| Click Mochi | It gets annoyed. Three times in a row and it goes dizzy |
| Rest the pointer on Mochi for two seconds | Hearts |
| Drag a file onto the island | Mochi turns into a box, swallows it, then offers to answer questions about it |
| `Esc` | Closes the island |
| Tray icon | Open, Settings…, Pause, Quit |

Everything else happens on its own: a Claude Code permission request opens the
island with **Deny / Allow**, a finished session shows what it did, and
your integrations sit in the coloured pills next to Mochi.

## Claude Code

<img src="screenshots/settings.png" width="562" alt="The settings window">

Open **Settings… → Claude Code → Install hooks…**. You get the exact diff of what
will change in `%USERPROFILE%\.claude\settings.json`, the path of the dated backup
that will be taken, and nothing is written until you click. Your own hooks are
never touched, and uninstalling removes only Coucou's entries.

The relay is a tiny executable, `coucou-hook.exe`, copied to
`%LOCALAPPDATA%\Coucou\bin\` at launch. It is given 300 ms to reach Coucou and
exits cleanly if the app is closed, slow or crashed — **a Claude Code session is
never blocked or slowed down by Coucou.** If nobody answers a permission request
in time, Coucou stays quiet and Claude Code asks in the terminal as usual.

It works from any terminal — Windows Terminal, PowerShell, VS Code, Git Bash.

## Other CLIs: Gemini + opencode

Claude is the default, but the island watches the other two side by side:

- **Antigravity (`agy`, recommended)** — since June 2026 this is what new installs get instead of Gemini CLI. Open **Settings… → Antigravity (agy) → Install Antigravity hooks…**. This writes Coucou's relay into `%USERPROFILE%\.gemini\config\hooks.json` under the `"coucou"` key (dated backup + diff preview, your other hooks untouched) for `PreToolUse/PostToolUse/PreInvocation/PostInvocation/Stop`. Timeouts are in seconds. `agy` sessions appear as pink `agy · <folder>` pills with their own steps. Approvals stay in the terminal — the island only shows activity.
- **Gemini CLI (legacy)** — open **Settings… → Gemini CLI → Install Gemini hooks…**. This merges Coucou's relay into `%USERPROFILE%\.gemini\settings.json` (dated backup + diff preview, your own hooks untouched) for `SessionStart/SessionEnd/BeforeTool/AfterTool/AfterModel/BeforeAgent/AfterAgent`. Timeouts are in ms. Gemini sessions appear as blue `Gemini · <folder>` pills with their own steps. Approvals stay in the terminal — Gemini has no blocking permission hook, so the island only shows activity.
- **opencode** — copy `windows/opencode-plugin/coucou.ts` to `~/.config/opencode/plugins/coucou.ts` (or `<project>/.opencode/plugins/coucou.ts`) and restart opencode. The plugin forwards `session.created/deleted/idle/error` and `tool.execute.before/after` (+ `permission.asked` as activity) to the same island pipe. opencode sessions appear as purple `opencode · <folder>` pills. Fire-and-forget: if Coucou is closed the plugin silently does nothing and never blocks your session.

Each CLI gets its own task (no more single-task overwrite): the most recently active one takes focus, `Stop` toasts 5.2 s, then ephemeral Gemini/opencode tasks disappear while Claude's pill persists.

## Chat and keys

**Settings… → Chat AI** takes your keys and lets you pick the provider:

- **Claude (Anthropic)** — `sk-ant-…` key, models Opus 5 / Sonnet 5 / Haiku 4.5, with web search.
- **Gemini (Google)** — `AIza…` key from [Google AI Studio](https://aistudio.google.com/apikey), models 2.5 Flash / 2.5 Pro / 2.0 Flash, plain chat for now (no web search yet).

Keys live in the **Windows
Credential Manager**, never on disk and never in the interface — the island can
only ask whether a key exists. Same for every integration key.

No telemetry. The only network requests Coucou makes are to the services you
configure yourself.

## Build it yourself

You need [Rust](https://rustup.rs), [Node 20+](https://nodejs.org), and the
**MSVC build tools** (Visual Studio Build Tools with "Desktop development with
C++"). WebView2 ships with Windows 10/11.

```powershell
cd windows
npm install
npm run tauri dev      # live-reloading development build
npm run pack           # builds the installer and drops it in windows/release/
```

`npm run dev` alone serves the front end in an ordinary browser, which is enough
to work on the island's looks. It also serves `dev/upload-preview.html`, which
replays the whole file-drop choreography on a loop — the one part of the UI that
otherwise needs a real drag from Explorer to see. Neither page ships in the app.

`npm run pack` leaves two files in `windows/release/`, the same names the release
workflow publishes:

```
Coucou-Windows-X.Y.Z-setup.exe    the versioned installer
Coucou-Windows-setup.exe          the same file under the rolling name
```

Installing is optional — `target/release/coucou.exe` runs on its own. There is no
window in the taskbar and no console: the island at the top of the screen and the
Mochi in the notification area are the whole app, and Quit lives in its menu.

The 28 sounds are the macOS app's own files; they are never duplicated in this
folder. The path is declared once, in `SOUNDS_DIR` at the top of
`vite.config.ts` — when they move to `shared/sounds/`, change that one line.

The app icon and the tray icon are drawn in code, like Mochi itself:

```powershell
npm run icons          # regenerates src-tauri/icons from scripts/gen-icons.mjs
```

### Layout

```
windows/
  src/                 island front end (TypeScript, no framework)
    mochi/             Mochi and the launch greeting, in Canvas 2D
    island/            state machine, hooks, integrations
    views/             every island view
    settings/          the settings window
  src-tauri/           Rust backend: window, named pipe, Claude API, pollers
  hook/                coucou-hook.exe, the Claude Code relay
  scripts/             icon generator
```

### Log

`%LOCALAPPDATA%\Coucou\coucou.log` — hook events, permission decisions, poller
problems. It stays on your machine.

## What's different from the Mac version

- No notch, so the island lives at the top centre of the screen and retracts into
  the top edge instead of hiding in a notch.
- Permission approval works from **any** terminal; the Mac build only listens to
  VS Code sessions.
- Not in this version: sending a file by email (no scriptable Mail.app
  equivalent — `mailto:` cannot carry attachments) and the Cal.com month
  calendar (list instead).
- New in this fork: drag Mochi onto any window to attach a screenshot of it as
  chat context, jump-to-terminal (focuses the console whose title shows the
  project folder, falls back to VS Code/Explorer), Gemini CLI + Antigravity
  (`agy`) + opencode pills, a Gemini chat provider, and a keyless Spotify
  now-playing pill (reads the desktop app's window title). The island stays
  pinned while a Drop view is open so it cannot retract mid-drag.
