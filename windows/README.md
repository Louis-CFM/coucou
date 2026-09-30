<div align="center">

<img src="src-tauri/icons/128x128.png" width="96" alt="Coucou icon">

# Coucou for Windows

**Mochi doesn't get a notch on a PC — so it lives at the top of your screen instead.**

Approve Claude Code or Codex permissions, watch your sessions work, drop a file, chat with Claude or Codex, and keep an eye on your services — without leaving what you're doing.

![Windows 10/11](https://img.shields.io/badge/Windows-10%2F11-0078D4?logo=windows)
![Tauri 2](https://img.shields.io/badge/Tauri-2-FFC131?logo=tauri&logoColor=black)
![Rust](https://img.shields.io/badge/Rust-backend-000?logo=rust)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

</div>

<img src="screenshots/greeting.png" width="640" alt="Mochi waving hello at launch">

---

## Install

1. Download `Coucou-Windows-setup.exe` from the [latest release](../../releases/tag/windows-latest).
2. Run it. It installs for the current user only — no admin prompt.
3. Coucou starts, waves hello, and then gets out of the way.

### "Windows protected your PC"

The installer isn't code-signed yet, so **SmartScreen** shows a blue warning the first
few times anybody downloads it:

> Windows protected your PC — Microsoft Defender SmartScreen prevented an unrecognised app from starting.

Click **More info**, then **Run anyway**. That's it. Signing is on the list; until
then this is what an unsigned installer looks like on Windows, and you can always
[build it yourself](#build-it-yourself) if you'd rather not trust a download.

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

Everything else happens on its own: a Claude Code or Codex permission request opens the
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

## Codex

Install the [Codex CLI](https://developers.openai.com/codex/cli) and sign in once:

```powershell
codex login
```

Choose **Sign in with ChatGPT** in the browser flow to use an eligible ChatGPT
plan for Codex. Coucou uses the saved local CLI sign-in, so Codex chat does not
need an OpenAI API key. Optionally select **OpenAI API (separate billing)** under
**Settings → Chat provider → Authentication & billing** and use
`codex login --with-api-key` in a terminal, providing the key through stdin.
Coucou uses the saved CLI login and does not store the OpenAI key. API requests
are billed separately from a ChatGPT plan. A login that does not match the
selected mode is rejected; Coucou never automatically falls back between them.
The first verified Coucou CLI version is 0.151.0;
use that version or newer.

Open **Settings… → Codex → Install hooks…** to preview the change and backup for
your Codex hook configuration. Claude Code hooks remain separate. After
installing or changing Coucou's hook, open the Codex CLI, run `/hooks`, and
review and trust Coucou's current hook definition. Codex intentionally does not
run new or changed user hooks until you trust them; if you remove and reinstall
or Coucou changes its hook definition, review it again.

Codex hooks are enabled by default. If you explicitly turned them off, enable
them with `codex features enable hooks`, then restart the Codex session. Coucou
does not change your Codex feature settings.

Once trusted, Codex sessions started in Codex CLI or the Codex desktop app can
show their prompts, tool activity, and approval requests in Coucou. On a
permission card, **Allow** or **Deny** answers that request. If Coucou is
unavailable, no decision is made and Codex keeps its regular approval prompt.
Codex's approval hook only runs when Codex is about to request approval. Coucou
does not offer Claude's **Always** permission action for Codex.

## Chat and keys

**Settings… → Chat** lets you choose Claude or Codex. Claude stays the default
and uses your Anthropic API key. Choose Codex to use the local CLI sign-in above.
Each Codex turn runs as a separate, read-only CLI task and uses Coucou's own
bounded chat history; it does not join an already-open Codex conversation.

Codex chat can include text and code files up to 200 KB and image attachments.
PDF questions are not supported by the Codex chat provider yet; Coucou explains
that instead of silently leaving the PDF out.

Anthropic and integration keys live in the **Windows Credential Manager**, never
on disk and never in the interface — the island can only ask whether a key
exists. Codex credentials remain managed by the Codex CLI.

No telemetry from Coucou. Claude and Codex chat requests go to the provider you
select; integrations contact only the services you configure.

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
  src-tauri/           Rust backend: window, named pipe, Claude/Codex chat, pollers
  hook/                coucou-hook.exe, the Claude Code and Codex relay
  scripts/             icon generator
```

### Log

`%LOCALAPPDATA%\Coucou\coucou.log` — hook events, permission decisions, poller
problems. It stays on your machine.

## What's different from the Mac version

- No notch, so the island lives at the top centre of the screen and retracts into
  the top edge instead of hiding in a notch.
- Permission approval works from **any** terminal. Windows supports Codex hooks;
  the Mac build remains Claude Code-only and listens to VS Code sessions.
- Not in this version: sending a file by email, dragging Mochi onto a window to
  attach it as context, and jumping to a specific terminal window — "Open
  terminal" opens the working folder in VS Code when `code` is on your `PATH`.
- Cal.com shows the next bookings as a list rather than the Mac's calendar.
