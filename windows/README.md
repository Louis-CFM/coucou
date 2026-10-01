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

## Codex CLI

Coucou can also follow the OpenAI Codex CLI on Windows. In **Settings… → Codex CLI**,
click **Install Codex hook…**, review the diff, and confirm the dated backup. This
merges `hooks.json` under `%CODEX_HOME%` (or `%USERPROFILE%\.codex\hooks.json`)
without replacing your existing hooks. Then open Codex, run `/hooks`, and trust the
new Coucou command when Codex asks. Codex's hook trust is a required safety step;
Coucou does not bypass it.

Codex and Claude use the same relay executable. Session, tool, prompt, stop and
compact/interrupt lifecycle events plus `PermissionRequest` are forwarded to Mochi.
Allow/Deny works for Codex
approval prompts because Codex documents the `PermissionRequest` response
`hookSpecificOutput.decision.behavior` with `allow` or `deny`. If the hook is
untrusted, disabled, unavailable, or times out, Codex keeps its normal approval
prompt. Coucou cannot answer approvals for tools that do not emit
`PermissionRequest`, and it never simulates keyboard input.

Codex CLI must be installed and signed in separately. The supported local hook
configuration is available in current Codex releases; verify with `codex --version`
and `/hooks`. Project-local hooks may be ignored until that project is trusted, so
the Coucou installer intentionally uses the user-level file. `CODEX_HOME`, when
set, takes precedence over `%USERPROFILE%\.codex`.

### Diagnose the installed relay

`Stop` requires a JSON object on stdout. Coucou returns `{}` for this event:
it is valid JSON and does not ask Codex to continue the turn. Run this from
PowerShell to test the binary that Codex actually invokes:

```powershell
$hook = "$env:LOCALAPPDATA\Coucou\bin\coucou-hook.exe"
$payload = '{"session_id":"diagnostic","cwd":"C:\\Temp","hook_event_name":"Stop","turn_id":"diagnostic","stop_hook_active":false,"last_assistant_message":"diagnostic"}'
$stdout = $payload | & $hook Stop 2> "$env:TEMP\coucou-hook.stderr"
if ($LASTEXITCODE -ne 0) { throw "coucou-hook.exe exited with $LASTEXITCODE" }
$stdout | ConvertFrom-Json | ConvertTo-Json -Compress
Get-FileHash $hook -Algorithm SHA256
```

The first command must print `{}` (and no non-JSON text). Compare the hash
with the freshly built `windows\target\release\coucou-hook.exe` if an older
installer may still be installed. The launcher now compares relay bytes rather
than timestamps before replacing the copy in `%LOCALAPPDATA%\Coucou\bin`.

To inspect the effective `Stop` configuration and prove which process emits
the response, run:

```powershell
$hooks = if ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME 'hooks.json' } else { Join-Path $env:USERPROFILE '.codex\hooks.json' }
$config = Get-Content -Raw $hooks | ConvertFrom-Json
$config.hooks.Stop | ConvertTo-Json -Depth 20
$hook = "$env:LOCALAPPDATA\Coucou\bin\coucou-hook.exe"
$payload = [ordered]@{ session_id='diagnostic'; cwd=(Get-Location).Path; hook_event_name='Stop'; model='diagnostic'; turn_id='diagnostic'; permission_mode='default'; stop_hook_active=$false; last_assistant_message='diagnostic' } | ConvertTo-Json -Compress
$stdoutFile = Join-Path $env:TEMP 'coucou-stop.stdout'
$stderrFile = Join-Path $env:TEMP 'coucou-stop.stderr'
$payload | & $hook Stop 1> $stdoutFile 2> $stderrFile
Write-Host "exit=$LASTEXITCODE"
Write-Host 'stdout bytes:'
[BitConverter]::ToString([IO.File]::ReadAllBytes($stdoutFile))
Write-Host 'stderr bytes:'
[BitConverter]::ToString([IO.File]::ReadAllBytes($stderrFile))
Get-Content -Raw $stdoutFile | ConvertFrom-Json | ConvertTo-Json -Compress
```

The Coucou entry must show both `command` and `commandWindows` ending in
`"coucou-hook.exe" Stop`. Expected stdout bytes are `7B-7D-0D-0A` (or
`7B-7D-0A`) and stderr must be empty. If another `Stop` entry is present,
disable it temporarily or test its command separately: Codex validates every
matching hook, not only Coucou's entry.

After installing a new Coucou build, hooks are not migrated automatically.
Quit the old Coucou instance, install and launch the new Windows installer,
then open **Settings… → Codex CLI → Reinstall Codex hook…**, review the diff,
and confirm it. This rewrites both `command` and `commandWindows` for every
Coucou event. Restart Codex and use `/hooks` to trust the changed definition.
Verify that the displayed `Stop` commands end with `coucou-hook.exe" Stop`
before testing a session. If the old entry remains, click **Uninstall Codex
hook…**, confirm, then click **Install Codex hook…** and confirm again; this
removes only Coucou's entries and preserves unrelated hooks.

## Chat and keys

**Settings… → Claude** takes your Anthropic API key. Keys live in the **Windows
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
- Not in this version: sending a file by email, dragging Mochi onto a window to
  attach it as context, and jumping to a specific terminal window — "Open
  terminal" opens the working folder in VS Code when `code` is on your `PATH`.
- Cal.com shows the next bookings as a list rather than the Mac's calendar.
