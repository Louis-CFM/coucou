<div align="center">

<img src="src-tauri/icons/128x128.png" width="96" alt="Coucou icon">

# Coucou for Windows

**Mochi doesn't get a notch on a PC — so it lives at the top of your screen instead.**

Approve Claude Code permissions, watch your session work, drop a file, chat with Claude, keep an eye on your services — without leaving what you're doing.

![Windows 10/11](https://img.shields.io/badge/Windows-10%2F11-0078D4?logo=windows)
![Tauri 2](https://img.shields.io/badge/Tauri-2-FFC131?logo=tauri&logoColor=black)
![Rust](https://img.shields.io/badge/Rust-backend-000?logo=rust)
![Code: MIT](https://img.shields.io/badge/code-MIT-green)

</div>

<img src="screenshots/greeting.png" width="640" alt="Mochi waving hello at launch">

---

## Install

Download **[Coucou-Windows.msi](https://github.com/Louis-CFM/coucou/releases/download/windows-latest/Coucou-Windows.msi)**
(Windows Installer) or **[Coucou-Windows-setup.exe](https://github.com/Louis-CFM/coucou/releases/download/windows-latest/Coucou-Windows-setup.exe)**,
always the newest version, and run it. The .exe installs for the current user only, with no admin prompt; the .msi may ask for admin rights.

**Windows will show a warning the first time — that's expected.** The installer isn't code-signed yet, so SmartScreen doesn't know the publisher:

1. A **"Windows protected your PC"** screen appears, with *Publisher: Unknown publisher*.
2. Click **More info** (*Informations complémentaires* in French). This reveals a **Run anyway** button.
3. Click **Run anyway** (*Exécuter quand même*). The installer starts normally.

This is only because the app isn't signed with a paid certificate yet. Coucou is open source, and Microsoft Defender scans the installer as clean.

Microsoft Defender once flagged the installer by mistake (`Trojan:Win32/Wacatac.H!ml`,
a machine-learning false positive); Microsoft reviewed it and removed the detection.
If Defender still blocks it on your PC, update its definitions (`Update-MpSignature`
in PowerShell) and try again.

You can also [build it yourself](#build-it-yourself).

## Using it

<img src="screenshots/compact.png" width="292" alt="The compact island, with the integration pills as mini Mochis">
<img src="screenshots/overview.png" width="640" alt="The overview: the focused integration on the left, the other pills on the right">
<img src="screenshots/approval.png" width="640" alt="A Claude Code permission request, with Deny and Allow">
<img src="screenshots/chat.png" width="640" alt="Chatting with Claude from the island">
<img src="screenshots/drop.png" width="640" alt="Mochi turned into a box, waiting for a file">

| What you do | What happens |
|---|---|
| Move the mouse to the very top-centre of the screen | Mochi peeks out |
| Click the small island | It opens. With **Settings → General → Open on hover**, resting the pointer on it is enough, and it folds again shortly after the pointer leaves (click inside to keep it open) |
| Click Mochi | It gets annoyed. Three times in a row and it goes dizzy |
| Rest the pointer on Mochi for two seconds | Hearts |
| Right-click Mochi | The wardrobe: rest the pointer on an outfit to try it on, click to keep it. **Auto** dresses him for the season (witch hat in October, Santa hat in December…) |
| Drag Mochi out of the island | He moves onto your desktop and hangs out there, in his outfit, watching your cursor. Drop him back on the island to bring him home |
| On the desktop: click / right-click / double-click Mochi | Poke him / the wardrobe / he flies home. Drag him to move him |
| Drag a file onto the island | Mochi turns into a box, swallows it, then offers to answer questions about it |
| Click a file in the session ticker | Its diff opens in the island; ↗ opens the file in VS Code, ‹ or `Esc` goes back |
| `Esc` | Closes the island |
| Put a file named like one of Mochi's sounds (`finish.wav`, `approval.mp3`, `greet.m4a`…) in the sounds folder | It replaces that sound after **Settings → General → Reload sounds**. **Open sounds folder** shows the folder: `~/.config/coucou/sounds` on Linux, `%APPDATA%\Coucou\sounds` on Windows |
| Tray icon | Open, Weekly recap, Wardrobe…, Settings…, Pause, Quit |
| `Ctrl+Alt+Space` | Opens the chat, from any app |
| `Ctrl+Alt+A` | Jumps to the waiting permission or question |
| `Ctrl+Alt+T` | Brings the session's window forward ("Open terminal") |
| `Ctrl+Alt+→` / `Ctrl+Alt+←` | Next / previous pill |
| `Ctrl+Alt+S` | Mutes or unmutes Mochi |
| `Ctrl+Alt+G` | Opens the wardrobe |
| `Ctrl+Alt+D` | Sends Mochi to the desktop, or brings him home |
| `Ctrl+Alt+N` | Opens and closes the island (off until you turn it on) |
| In the open island: `Ctrl+→` `Ctrl+←`, `Ctrl+1`–`Ctrl+9` | Switch pills |
| In the open island: `Ctrl+↓` `Ctrl+↑`, `Ctrl+O` | Walk the open GitHub list, open the highlighted row |
| In the open island: `Ctrl+E` | Opens the latest edit's diff, or closes the diff |
| In the open island: `Ctrl+Enter`, `Ctrl+K` | Send, start a new chat |
| In the open island: `Ctrl+,`, `Ctrl+P` | Settings, keep the island open |

### Keyboard shortcuts

Every global shortcut can be changed or turned off in **Settings… → Shortcuts**:
click it and press the new keys. A combination another app already holds is
flagged *In use*, and two Coucou shortcuts on the same keys are flagged *Used
twice*. While you record a new one, Coucou lets go of its own so the keys reach
the recorder.

The defaults are not the Mac's `⌃⌥` letters. On Windows, `Ctrl+Alt` is `AltGr`,
so a global `Ctrl+Alt+E` would swallow every `€` typed on a French or German
keyboard. The defaults were checked against the AltGr layer of the French,
German, Spanish, Italian, Portuguese and Brazilian (ABNT2) layouts — that is why
pill switching uses the arrows rather than `[` `]`, and mute is `S` rather than
`M` (`AltGr+M` is `µ` in German). On top of that, Coucou asks Windows what each
`Ctrl+Alt` combination types on the layouts you have installed and leaves any
that types a character unregistered, flagged *Types “ą”* in Settings: Polish,
for one, puts `ą` on `AltGr+A` and `ś` on `AltGr+S`. The recorder refuses such
a combination too.

Older Intel graphics drivers rotate the screen on `Ctrl+Alt+←` / `→`; if yours
still does, those two show up as *In use*. On Linux, Xfce and MATE keep
`Ctrl+Alt+D` to show the desktop, so there **Send Mochi to the desktop** shows
up as *In use* until you give it other keys.

Everything else happens on its own: a Claude Code permission request opens the
island with **Deny / Allow**, a question from Claude Code shows its options to
pick from, a finished session shows what it did, and
your integrations sit in the coloured pills next to Mochi.

A permission card or a question stays until you answer it: the mouse leaving
never folds it, it comes up even when the island is already open or another
pill is in front, and the pill you were on comes back once you answer. To keep
it for later, fold it with the **⌃** in its corner (or `Esc` in the island): the
island shrinks to its compact size and stays on screen, nothing is answered, and
opening it again shows the card. **Open terminal** brings the window the session
runs in to the front.

When Mochi lives on the desktop, he flies back to the island with a permission
request or a question and returns to his spot once you have answered; he does a
little jump when a task finishes, and dozes off when nothing has happened for
two minutes and your cursor is elsewhere — asleep, he costs nothing: no cursor
polling, a few frames a second. He remembers his spot between launches; if it
was on a display that is no longer connected, he stays in the island.

**Live diff.** Every file Claude edits (Edit, MultiEdit, Write) shows up in the
session ticker with its **+N −M** lines; click it for the diff. Same limits as the
Mac: past 200 KB or 4 000 lines only the counts are kept, at most 50 diffs per
session, and they are forgotten an hour after the last edit or when the session
ends. When Claude finishes, the card keeps the first paragraph of its final
answer on one line, still, until the next prompt.

## Your pills

**Settings… → Active pills** lists the tools you use, from the same catalog as
the Mac app. Pick your **main tool** — VS Code, Cursor, Codex or Antigravity —
which is always there and doesn't take a slot, then declare up to four more:
agents (Gemini CLI, Copilot CLI, Muse Code, OpenCode, Amp, Hermes, Claude
Desktop), the chat providers (Anthropic, Google AI, OpenAI, Ollama, LM Studio),
and the services under **Integrations**. A pill fed by hooks says whether its
hooks are installed, never asks for a key; a local model server's pill says
whether the chat is connected to it. A session on a pill you didn't
declare still shows up, for as long as it runs.

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

### Plan usage

As on the Mac, the island's header can show your plan limits: a small pill
("Claude 73%", green below 50 %, orange up to 80 %, red above) for the 5-hour and
weekly Claude limits, and another for Codex. Click one for the details and the
reset times. Both are off by default; turn them on in **Settings… → Plan usage**.

- **Claude** (Pro and Max plans): the numbers come from Claude Code's own status
  line. **Show in notch** first shows you the diff of the `statusLine` change in
  `%USERPROFILE%\.claude\settings.json`, takes a dated backup and writes only
  after your click, with the same writer as the hooks: the status line becomes `coucou-hook --statusline`, which
  passes only the limits on (300 ms at most) and runs the status line you had
  before — kept in `statusline-previous.json` next to the relay — with the same
  input, printing what it prints. On Windows that one runs through Git Bash, as
  Claude Code runs it (`CLAUDE_CODE_GIT_BASH_PATH`, then the Git for Windows that
  `git.exe` on `PATH` belongs to, then the usual install folders); it gets 10 s
  and 64 KB of output. **Uninstall relay** puts your status line back. The
  numbers arrive with Claude Code's replies.
- **Codex**: nothing is installed. When the pill shows (or is clicked, at most
  once a minute) Coucou starts `codex app-server` and asks it
  `account/rateLimits/read`, as Codex's `/status` does, then stops it (15 s at
  most, never while paused). Codex must be signed in with ChatGPT.

## Weekly recap

On Monday from 8 am, the first time Coucou starts, an agent starts working or
you wake the island, a card sums up the past week: time spent, sessions, files
and lines changed, commands run, permissions and questions, your top agent,
top project, busiest day and longest session. **Tray → Weekly recap** opens it
any day.

**Share image** turns it into a 1080 × 1920 picture with Mochi. **Save image**
writes it to your Pictures folder (Downloads if there is none) as
`Coucou weekly recap YYYY-MM-DD.png`, never over an existing file; **Copy** puts
it on the clipboard. **Hide project names** leaves the project out of the image.

The history is `recap.json` next to the log, a 12-week rolling window: counts,
the agent and the project folder's name — never a command, a file path, file
contents or a prompt. It never leaves your machine. **Settings → General →
Weekly recap** turns it off or clears it.

## Languages

Coucou speaks the same ten languages as the Mac app: English, 简体中文, हिन्दी,
Español, العربية, Français, বাংলা, Português (Brasil), Русский and Bahasa
Indonesia. **Settings… → General → Language** picks one; **System** (the
default) follows your system's language when it is one of these, English
otherwise. The island, the settings window and the tray menu switch at once —
nothing restarts, and the island keeps its sessions, steps and chat.

In Arabic the island's cards read right to left; Mochi, the pills and the
header stay where they are, and commands, code and file paths stay left to
right. Steps already in a session's ticker keep the language they were written
in, as on the Mac.

The translations are the Mac's own (`NotchBuddy/Resources/Localizable.xcstrings`,
turned into `src/i18n/strings.json` by `node scripts/gen-strings.mjs`), plus
`src/i18n/extra.json` for what only Windows and Linux show. Both are keyed by
the English text; a string missing in a language shows in English. The Rust
side (tray, errors) embeds the same two files.

## Chat and keys

**Settings… → Claude** takes your Anthropic API key. Keys live in the **Windows
Credential Manager**, never on disk and never in the interface — the island can
only ask whether a key exists. Same for every integration key.

The chat also talks to **Google AI (Gemini)**, **OpenAI** and **OpenRouter**:
add their keys in **Settings… → Chat providers**, then click the model name
above the chat box to switch provider and model, as on the Mac. The model list
is fetched from the provider only once you pick it and it has a key. Switching
mid-conversation carries the conversation over as plain text, so nothing in one
provider's format is ever sent to another. These providers get no web search
and no tools — they answer, they never act on your PC.

**Local models**: **Settings… → Local models** connects **Ollama** or **LM
Studio** (leave the address empty for the usual one on this PC; Ollama's
`OLLAMA_HOST` is honoured) or any server that speaks the OpenAI API (vLLM,
llama.cpp…), with an optional key kept in the credential store. Answers stream
in as they are written, and the `<think>` blocks of reasoning models stay
hidden. A text file you dropped goes along inline (24 000 characters at most);
images and PDFs by name only. Settings tells you whether the address is this
PC — nothing leaves it then — and warns before a key would travel over plain
`http://` to another machine.

Answers from every provider are shown as **Markdown**: headings, lists, bold,
inline code, quotes, and code blocks with a copy button. It is built from text
nodes, never parsed as HTML, and only `http`/`https` links open. Mochi greets
you by your first name when your account has one (the Windows display name or
the Linux GECOS full name; a bare login name is not used).

To send the Claude chat through an Anthropic-compatible gateway, set
`COUCOU_ANTHROPIC_BASE_URL` (for example `https://gateway.example.com`;
`/v1/messages` is added). It must be `https://`, or `http://` to this PC only.
Claude Code's own `ANTHROPIC_BASE_URL` is deliberately ignored: your key only
goes where you told Coucou to send it. The gateway's host is written to the log
once; the key never is.

No telemetry. The only network requests Coucou makes are to the services you
configure yourself.

## GitHub

With a token in **Settings… → Integrations → GitHub** — a classic token with
the `repo` scope, or a fine-grained one with read access to Pull requests,
Commit statuses and Actions — the GitHub pill shows:

- **My PRs**: your open pull requests and their CI status.
- **To review**: the pull requests waiting for your review.
- **Default branch CI**: the CI of the default branch of your 10 most recently
  pushed repositories.
- Your stars and the **last 7 days of contributions** in the card header; click
  them for the past 23 weeks, and hover or click a day for its count.

Click a row for the list, then an item to open it on github.com. The pill gets
a badge and a sound when the CI of one of your pull requests turns red or green
(fast runs between two checks included), when a default branch breaks, or when
someone requests your review. Pull requests are checked every 5 minutes, every
minute while a CI is running, and as soon as you open the card on data older
than a minute; contributions every 30 minutes. Nothing is fetched while the pill
is off or Coucou is paused.

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
otherwise needs a real drag from Explorer to see — and `dev/recap-preview.html`,
the weekly recap card and its shared image on a sample week. None of these pages
ships in the app.

`npm run pack` leaves two files in `windows/release/`, the same names the release
workflow publishes:

```
Coucou-Windows-X.Y.Z-setup.exe    the versioned installer
Coucou-Windows-setup.exe          the same file under the rolling name
```

Installing is optional — `target/release/coucou.exe` runs on its own. There is no
window in the taskbar and no console: the island at the top of the screen and the
Mochi in the notification area are the whole app, and Quit lives in its menu.

The 29 sounds are the macOS app's own files; they are never duplicated in this
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
    desktop/           Mochi's own little window, when he lives on the desktop
    island/            state machine, hooks, integrations
    views/             every island view
    settings/          the settings window
  src-tauri/           Rust backend: window, named pipe, Claude API, pollers
  hook/                coucou-hook.exe, the Claude Code relay
  scripts/             icon generator
```

### Log

`%LOCALAPPDATA%\Coucou\coucou.log` — hook events, permission decisions, poller
problems. It stays on your machine. The weekly recap's history sits beside it in
`recap.json`.

## Supported agents

Every agent below is installed from **Settings → Agents** with the same steps as
Claude Code: the exact diff, the path of the dated backup, nothing written until
you click, and uninstalling removes only Coucou's entries. A config Coucou cannot
read, or where it finds something it does not expect, is left alone and the
reason is shown. Each agent gets its own pill (`agent_<name>`, the Mac's ids and
colours). The files are the Mac's, under `%USERPROFILE%` on Windows and `~` on
Linux.

| Agent | Installs | Permissions |
|---|---|---|
| Claude Code | `.claude\settings.json` (**Settings → Claude Code**) | Allow / Deny and questions in the island |
| Codex | `.codex\hooks.json` — then trust the hooks once with `/hooks` in Codex | Allow / Deny in the island |
| GitHub Copilot CLI | `.copilot\hooks\coucou.json` | Allow / Deny in the island |
| Muse Code | `.config\muse\settings.json` | Allow / Deny in the island |
| Gemini CLI | `.gemini\settings.json` | asked in Gemini CLI |
| Antigravity | `.gemini\config\hooks.json` (a `coucou` hook group) | asked in Antigravity |
| Cursor Agent | `.cursor\hooks.json` — Claude Code in Cursor's terminal also goes on the Cursor pill, through the Claude Code hooks | asked in Cursor |
| Claude Desktop (Windows) | nothing to install: Claude Code sessions from the Claude app are tagged by the relay | asked in the Claude app |
| OpenCode | plugin `.config\opencode\plugins\coucou.js` | asked in OpenCode |
| Amp | plugin `.config\amp\plugins\coucou.ts` | asked in Amp |
| Hermes Agent | plugin `.hermes\plugins\coucou\` — then `hermes plugins enable coucou` once | asked in Hermes |
| Any other | run `coucou-hook --agent <name> [<Event>]` from your tool's hooks | asked in the tool |

The relay maps every agent's event and field names onto Claude Code's (Gemini
CLI's `BeforeTool`, Copilot's `preToolUse`, Cursor's `beforeSubmitPrompt`…), and
answers each agent the way it expects. It never lets anything through on its
own: with no click it prints no decision at all (`{}` for the agents that need
JSON, `"ask"` for Copilot, which is fail-closed), so the agent asks in its own
terminal exactly as without Coucou — including when Coucou is closed.

The plugins start the relay directly, with no shell in between, and never wait
for it. Amp's steps appear as each tool finishes: its "before" hook must return
a verdict, and Coucou never gives one.

**How each agent runs the relay on Windows.** Hook commands are written for the
shell that runs them: Git Bash for Claude Code (quoted, forward slashes),
PowerShell for Gemini CLI and Copilot CLI (`& '…\coucou-hook.exe'`), `cmd /C`
for Codex. Cursor, Antigravity and Muse Code do not document theirs: the relay
path is written bare when it has no space or special character — which works in
cmd, PowerShell and when started directly — and in double quotes otherwise.
These three are untested on Windows.

A pill is **connected** when Coucou finds its own entries in the files above —
the same check as Settings → Agents (for Claude Code: a SessionStart hook
running Coucou's relay; the Cursor pill also counts Claude Code's hooks).
Coucou only reads these files, each time the island opens. Permission requests
get the island's card for Claude Code (in any terminal, and in Cursor's),
Codex, Copilot CLI and Muse Code; other agents and Claude Desktop ask in their
own window.

## What's different from the Mac version

- No notch, so the island lives at the top centre of the screen and retracts into
  the top edge instead of hiding in a notch.
- Permission approval works from **any** terminal; the Mac build only listens to
  VS Code sessions.
- "Open terminal" finds the session's window by walking up from the relay's
  process to the terminal or editor that runs it. A session in a classic
  console window (`cmd.exe` or PowerShell without Windows Terminal) has no such
  ancestor — conhost owns that window — so its folder opens in VS Code instead,
  as it does when `code` is on your `PATH` and nothing was found. Linux walks
  the same tree; what it can bring forward depends on the desktop (see Linux).
- Global keyboard shortcuts are hot keys on Windows, key grabs on Linux under
  X11, and go through the desktop's GlobalShortcuts portal under Wayland (see
  [Linux](#linux)). A waiting card is also folded with its **⌃** or `Esc` in
  the island, and reopened by clicking the island, Open in the tray or **Go to
  alert**.
- Apple Music, the one pill from the Mac catalog with nothing behind it here,
  is left out. Spotify is on Linux only (see [Linux](#linux)): Windows has
  nothing to read it from yet.
- Not in this version: sending a dropped file by email and dragging Mochi onto
  a window to attach it as context. On the Mac, email goes through Resend or
  Apple Mail's scripting; neither has a safe equivalent that attaches a file
  here, and the drop card would need a third button it doesn't have.
- Cal.com shows the next bookings as a list rather than the Mac's calendar.
- The Cursor pill carries both Cursor Agent's own hooks and Claude Code running
  in Cursor's terminal.
- Hermes: Coucou writes the plugin but does not run the `hermes` CLI, so it is
  turned on once by hand. Hermes runs natively on Linux; on Windows it is
  untested.
- Plan usage: the user's previous status line runs through Git Bash on Windows
  (`/bin/sh` on Linux and Mac); without Git Bash it is not run, rather than
  guessed at with `cmd`. The Codex CLI is looked for on `PATH` and in npm's,
  Volta's, Bun's and pnpm's folders (and nvm's on Linux).
- The chat's model picker opens inside the chat card instead of a popover, and
  it also offers OpenRouter and any OpenAI-compatible server, which the Mac
  does not. Google AI, OpenAI and OpenRouter can see an image you dropped (sent
  inline), where the Mac sends its name only.
- Live diff: the relay forwards an edit's text whole only once the edit is done
  (PostToolUse), up to 256 KB per string and 512 KB per event. A bigger edit
  shows its "Edits · file" step without counts rather than wrong ones. The
  diff's ↗ needs `code` on your `PATH`; without it, it opens the file's folder —
  never the file itself. Counts and diffs come from Claude Code's Edit,
  MultiEdit and Write, on whichever pill its session is on (VS Code, Cursor,
  Claude Desktop); other agents' edits show as plain steps.
- There is no iPhone to keep fetching the GitHub lists while the pill is off.
- Keyboard shortcuts use `Ctrl+Alt` where the Mac uses `⌃⌥`, with different
  keys (see [Keyboard shortcuts](#keyboard-shortcuts)), and `Ctrl` where the
  Mac uses `⌘` inside the island. "Bring the terminal forward" is "Open
  terminal" here. Not in this version: attaching the front window (its id is
  kept for later). The island only reads its own shortcuts while it has the
  keyboard: in the chat, or after a global shortcut opened it. `Ctrl+↓`
  `Ctrl+↑` `Ctrl+O` walk the GitHub lists, as on the Mac, and the highlighted
  row scrolls into view where the Mac's three-row list doesn't follow it; in the
  chat field `Ctrl+↑` `Ctrl+↓` keep moving the cursor. **Go to alert** brings
  up any agent's waiting card on its own pill; **Toggle the island** folds a
  waiting card rather than dropping it, like `Esc` in the island. **Send Mochi
  to the desktop** (`Ctrl+Alt+D`, the Mac's `⌃⌥D`)
  flies him to his spot, or to the bottom-right corner when that spot was on a
  display that is gone; pressed again, he flies home.
- Weekly recap:
  - Sharing happens inside the island instead of a separate panel, and Save
    writes straight into Pictures (or Downloads) instead of asking where. There
    is no system Share sheet; Copy uses the web clipboard.
  - Questions are counted when an agent asks one (`AskUserQuestion`), whether
    it is then answered in the island or in the terminal. Permissions count the
    Allow and Deny clicks on the island's card, for every agent that gets one.
  - There is no sleep/wake notification to listen to without a background
    loop, so after the machine wakes the Monday card waits for the first agent
    to start or for you to hover the island.
  - The card is 24 px taller than the Mac's: it also lists top agent, project,
    busiest day, longest session, permissions and questions, which the Mac
    leaves to the image. A turn cut short by the session ending still counts.
  - Tray → Pause doesn't stop the history (it stays on the machine anyway);
    switch it off in Settings → General.
- The wardrobe opens with a right-click on Mochi, from the tray menu, or with
  its global shortcut (`Ctrl+Alt+G` by default). In the compact island a tall hat
  is cut by the top edge of the screen, as it is by the notch on a Mac.
- Languages: chosen in Settings, independently of the system, and applied
  without a restart (the Mac's **Restart Coucou** isn't needed). Arabic turns
  the island's text right to left but not its layout: Mochi and the pills keep
  their sides.
- Mochi on the desktop dances only on Linux, to Spotify; on Windows there is
  no music integration to dance to yet. While he dances he stays awake (the
  Mac lets him doze off mid-dance). Dropping him on a window doesn't attach it
  to the chat. While he
  sleeps, the transparent square around him (120 px) takes the first mouse
  move, which wakes him and gives the rest back to the desktop.

## Linux

The same app builds for Linux: everything that differs lives in
`src-tauri/src/platform/`, and the relay's transport in `hook/src/unix.rs`.

```bash
sudo apt install build-essential pkg-config \
  libwebkit2gtk-4.1-dev libgtk-layer-shell-dev libayatana-appindicator3-dev \
  librsvg2-dev libssl-dev libdbus-1-dev patchelf \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good
npm install
npm run tauri dev      # live-reloading development build
npm run pack           # AppImage, .deb and .rpm in windows/release/
```

On Arch Linux, build and install the package from `linux/arch/`:

```bash
git clone https://github.com/Louis-CFM/coucou.git
cd coucou/linux/arch
makepkg -si
```

It needs `webkit2gtk-4.1`, `gtk-layer-shell` and `libayatana-appindicator`
(pulled in as dependencies); store API keys with GNOME Keyring or KWallet.

What changes on Linux:

- **The island** is a gtk-layer-shell overlay anchored to the top edge, over any
  top panel, on compositors that support it: COSMIC, KDE Plasma, Hyprland, Sway
  and other wlroots compositors. GNOME has no layer-shell and ignores where a
  Wayland window asks to go, so there Coucou runs through XWayland as a dock
  window: top centre, on every workspace, still there after Super+D.
  `COUCOU_X11=0` keeps the native Wayland window, `COUCOU_DOCK=0` makes it a
  utility window instead of a dock. `COUCOU_LAYER_SHELL=0` forces the regular
  window anywhere.
- **Click-through** is the window's input region, kept equal to the island
  shape, so the compositor sends every other click to what is underneath.
- **Mochi's eyes** follow the pointer only while it is over the island: Wayland
  gives no app the cursor position anywhere else. On the desktop, likewise,
  they follow it only while it is over him, and "the cursor is far away" (so
  he may fall asleep) means it hasn't been over him for a few seconds.
- **Mochi on the desktop** is a layer-shell surface on the island's display
  (KDE Plasma, COSMIC, Hyprland, Sway…), placed with margins and dragged within
  that display; on X11 it is an ordinary always-on-top window that goes
  anywhere. **GNOME on Wayland** has no layer-shell and lets no app place its
  own window, so there Mochi can't leave the island: dragging him does nothing,
  and the desktop shortcut only makes him grumble.
- **Claude Code hooks** go through `~/.local/share/coucou/bin/coucou-hook` and a
  Unix socket at `$XDG_RUNTIME_DIR/coucou.sock`. Both ends check that the other
  runs as the same user. Every other agent uses the same relay, single-quoted
  for `sh`, and its config under `~` (see Supported agents). A config that is a
  symlink (dotfiles) is written through to its target, with its permissions
  kept.
- **Global shortcuts** are X11 key grabs in an X11 session.
  On X11, AltGr is a modifier of its own and never clashes with `Ctrl+Alt`;
  combinations the desktop already uses (GNOME's `Ctrl+Alt+T` terminal and
  `Ctrl+Alt+←`/`→` workspace switching) show up as *In use*.
  Wayland has no key grabs, so there Coucou hands its shortcuts to the desktop
  through the XDG **GlobalShortcuts portal** (`xdg-desktop-portal`, with a
  backend that has it: KDE Plasma 6, GNOME 48+, Hyprland, COSMIC…). Each
  shortcut goes with its description and your keys as the preferred trigger;
  the desktop may show its own window to confirm them or to pick other keys,
  and it has the last word: a shortcut it already knows keeps the keys it was
  given there, and you change them in the desktop's own shortcut settings.
  **Settings → Shortcuts** says the shortcuts are registered with the desktop,
  shows next to each one the keys the desktop reports (*Desktop: …*), and flags
  one it left out. Changing or turning off a shortcut in Coucou binds the new
  set in a new portal session. Coucou names itself `fr.louisraille.coucou` to
  the portal where the portal allows it (`xdg-desktop-portal` 1.19+); a
  desktop that wants an app name may otherwise refuse.
  Where there is no such portal, or the desktop refuses, nothing is registered
  and **Settings → Shortcuts** lists commands to bind in your
  desktop's own keyboard settings instead (they are shown with the portal too,
  for any shortcut that doesn't work):
  `coucou --shortcut openChat` (or the AppImage's path) runs the action in the
  Coucou that is already open. The ids are `toggleIsland`, `openChat`,
  `goToAlert`, `jumpToTerminal`, `nextPill`, `prevPill`, `muteToggle`,
  `desktopToggle` and `wardrobeToggle`.
- **Keys** live in the Secret Service (GNOME Keyring, KWallet).
- **Spotify** (Settings → Integrations) is read over MPRIS, Spotify's D-Bus
  interface on the session bus: the pill shows the track and plays, pauses
  or skips on hover, the card has the cover, the progress bar (drag to
  seek), shuffle, previous, next, repeat and the volume, and Mochi dances
  while it plays — in the compact island, on the Spotify card, on the pill
  and on the desktop. Nothing is polled: one thread waits on the bus for
  Spotify's own signals while the pill is declared, and stops when it isn't.
  **Open Spotify** brings it forward or starts `spotify` from your `PATH`,
  else the Flatpak (`com.spotify.Client`) or the Snap; without one, **Get
  Spotify** opens its download page. Covers come from Spotify's image CDN
  (or a local track's file) and are fetched by Coucou itself, not the page.
  Spotify builds that don't report the position over MPRIS show the bar
  from where the track started; the Mac's Automation prompt has no
  equivalent here.
- **Plan usage**: the status line relay is `~/.local/share/coucou/bin/coucou-hook
  --statusline` and runs your previous status line with `/bin/sh -c`, like Claude
  Code. Codex is found on `$PATH`, in `~/.local/bin`, npm's global prefix, Volta,
  Bun, pnpm, or nvm (newest Node first), since a desktop launch often has a
  shorter `$PATH` than your shell.
- **Mochi's greeting** uses the full name in your account's GECOS field
  (`chfn` sets it); without one the chat stays neutral.
- **Files**: preferences in `~/.config/coucou/`, the log at
  `~/.local/share/coucou/coucou.log`, the weekly recap history beside it in
  `recap.json`. A saved recap image goes to the pictures folder named in
  `~/.config/user-dirs.dirs`, else `~/Pictures`, else `~/Downloads`.
- **Languages**: Hindi, Bengali, Chinese and Arabic need fonts that carry those
  scripts; Coucou asks for the Noto families (`fonts-noto-core` and
  `fonts-noto-cjk` on Debian and Ubuntu, `noto-fonts` and `noto-fonts-cjk` on
  Arch). **System** reads the language from the webview, which follows
  `LANGUAGE` / `LANG`.
- **Copying the recap image** needs a WebKitGTK with image clipboard support;
  where it is missing, the island says so and Save still works.
- What the Windows build leaves out, this one does too: sending a file by
  email and dragging Mochi onto a window.
- **Open terminal** walks up from the relay through `/proc` (stopping at
  systemd, logins, ssh, session managers and panels, and at any process of
  another user) to the terminal or editor the session runs in, then brings its
  window forward — the one titled after the session's folder if it has several:
  - **X11** (any desktop): EWMH — the window whose `_NET_WM_PID` is the nearest
    ancestor gets a `_NET_ACTIVE_WINDOW` request, on its workspace. A terminal
    that doesn't set `_NET_WM_PID` (some old `xterm` builds) isn't found.
  - **KDE Plasma on Wayland**: a few lines of KWin script, loaded over D-Bus
    from `$XDG_RUNTIME_DIR`, activate the window by process ID and are unloaded
    right after; Plasma 5 and 6.
  - **kitty**, anywhere: its tab is selected too when remote control listens on
    a socket (`allow_remote_control` and `listen_on` in kitty.conf).
  - **GNOME on Wayland** and other Wayland compositors let no app bring another
    app's native window forward (an XWayland one, such as VS Code's by default,
    still can be). There, and for a session under tmux, screen or ssh, whose
    terminal is no ancestor, the folder opens in VS Code as before.
- No **Claude Desktop** pill: the Claude app has no Linux build.
