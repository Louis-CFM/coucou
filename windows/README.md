<div align="center">

<img src="src-tauri/icons/128x128.png" width="96" alt="Coucou icon">

# Coucou for Windows

**Mochi doesn't get a notch on a PC — so it lives at the top of your screen instead.**

Approve Claude Code and Cursor permissions, watch a session work, drop a file, chat with Claude or Cursor, keep an eye on Spotify and your other services — without leaving what you're doing.

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
| Click × on the compact island (when Hide = Close button) | It disappears until you hover the top edge again |
| Click outside the open island (when Shrink = Click outside) | It shrinks back to compact |
| `Esc` | Closes the island |
| Tray icon | Open, Settings…, Pause, Quit |

Everything else happens on its own: a Claude Code or Cursor permission request
opens the island with **Deny / Allow**, a finished session shows what it did,
and your integrations sit in the coloured pills next to Mochi.

Which pill is open when Coucou starts is set in **Settings… → General →
Default pill**: VS Code, Cursor, Spotify, or any integration you have switched
on. Clicking another pill keeps that one until the next launch. Turn the chosen
integration off and Coucou goes back to VS Code.

**Settings… → General** also controls when the island goes away:

- **Hide completely** — *After a pause* (default) hides it on its own; *Close
  button* leaves a × on the compact island so it only disappears when you click.
- **Shrink** — *After you leave it* (default) folds it after a few seconds of
  idle; *Click outside* keeps it open until you click somewhere else.

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

## Cursor

Open **Settings… → Cursor → Install hooks…**. Coucou shows the diff for
`%USERPROFILE%\.cursor\hooks.json`, takes a dated backup, and writes nothing
until you click. Your own hooks are left untouched.

The same `coucou-hook.exe` relays the events, in `--cursor` mode. The pill
shows the project, the prompt, tool steps, subagents, and when the run finishes
or fails. **Deny / Allow** opens only when Cursor itself would ask: a command
that cannot stay in the sandbox, a file delete, or a change outside the
project. Edits inside the project are not interrupted. If Coucou is closed, or
nobody clicks, that call is **denied** — unlike Claude Code, Cursor never falls
back to asking in the IDE. Cloud agents do not run these hooks.

Hooks installed before this can still let the tool through when the wait runs
out. Reinstall them once from **Settings… → Cursor** (Coucou shows a banner when
the install is outdated).

While Cursor works, the overview can show the last file it changed. Click the
snippet to open a short diff inside the island, with the shell command and its
output underneath when there is one. The preview shows a change once it has
landed. A denied call never leaves a false trail.

The island chat can talk to that same local agent, with the Cursor window
closed. Open **Ask**, click **Claude** until it says **Cursor**, then pick
**Agent** (it can edit the project and run commands there) or **Ask** (it only
answers). The **Folder** button chooses the project; Coucou remembers it after
Cursor closes and after a restart. The next message resumes the same thread.

Install the [Cursor CLI](https://cursor.com/docs/cli/installation) first
(`irm 'https://cursor.com/install?win32=true' | iex` on Windows), then
`agent login`.

## Spotify

Turn on **Settings… → Integrations → Spotify**. Coucou reads whatever the Spotify
desktop app is already playing through Windows’ media session — no Spotify
account and no network call from Coucou. The pill shows the track and lets you
pause, skip or open the app. A new track never pops the island open.

## Chat and keys

**Settings… → Claude** takes your Anthropic API key. Keys live in the **Windows
Credential Manager**, never on disk and never in the interface — the island can
only ask whether a key exists. Same for every integration key. Spotify needs
none.

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
    core/              bridge, layout, state, sounds, liveChange
    mochi/             Mochi and the launch greeting, in Canvas 2D
    island/            state machine, Claude and Cursor hooks, integrations
    views/             every island view (overview, approval, diff, …)
    upload/            file-drop choreography
    settings/          the settings window
  src-tauri/           Rust backend: window, named pipe, Claude API, pollers
    src/media.rs       Spotify via the Windows media session
  hook/                coucou-hook.exe, the Claude Code and Cursor relay
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
- Spotify is read from the Windows media session (SMTC), with no Spotify API.
- Not in this version: sending a file by email, dragging Mochi onto a window to
  attach it as context, and jumping to a specific terminal window — "Open
  terminal" opens the working folder in VS Code when `code` is on your `PATH`.
- Cal.com shows the next bookings as a list rather than the Mac's calendar.
