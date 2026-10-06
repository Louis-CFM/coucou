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

The downloadable installer is **temporarily unavailable** while a Microsoft
Defender detection of the unsigned installer (`Trojan:Win32/Wacatac.H!ml`) is
under review. Do not bypass security warnings on the assumption that a local
build or this README proves the binary safe. Until a verified release is
available, [build it yourself](#build-it-yourself), inspect the output, and
install only if you trust the source and resulting installer. The NSIS package
is configured for the current user, not a machine-wide installation.

## Using it

<img src="screenshots/compact.png" width="292" alt="The compact island, with the integration pills as mini Mochis">
<img src="screenshots/overview.png" width="640" alt="The overview: the focused integration on the left, the other pills on the right">
<img src="screenshots/approval.png" width="640" alt="A Claude Code permission request, with Deny and Allow">
<img src="screenshots/chat.png" width="640" alt="Chatting with Claude from the island">
<img src="screenshots/drop.png" width="640" alt="Mochi turned into a box, waiting for a file">

| What you do | What happens |
|---|---|
| Move the mouse to the very top-centre of the screen (or wherever you moved the island) | Mochi peeks out |
| Click the small island | It opens |
| Click Mochi | It gets annoyed. Three times in a row and it goes dizzy |
| Rest the pointer on Mochi for two seconds | Hearts |
| Drag a file onto the island | Mochi turns into a box, swallows it, then offers to answer questions about it |
| `Esc` | Closes the island (and dismisses a finished/error/question/notice card) |
| Lock button in the island header | Unlock / lock the island's position |
| Unlocked: hold the mouse on an empty part of the island, then drag | Moves the island anywhere, on any display |
| Tray icon | Open, Settings…, Pause, Lock position, Reset position, Quit |

With Claude Code hooks installed, permission requests can show **Deny / Allow**
in Coucou; if Coucou is paused, closed or cannot display a card, Claude Code
asks in its own interface. Agent activity is session-scoped, but a built package
alone does not establish that a provider's hooks or finish alert work in a real
session.

Codex approvals are answerable the same way. Codex's `PermissionRequest` hook
gets the documented `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny"}}}`.
With no click within 110 s, Codex shows its own prompt. Kimi Code and Hermes
approvals appear as a read-only amber card (what is asked, plus **Open**). Their
hooks cannot answer, so you approve or deny in their own window.

When any session finishes or fails, Coucou plays the sound, focuses that session
and opens its finished/error card, even if another pill was selected. If an
approval or question card is up, or you are typing in chat or + Task, the pill
gets a badge instead; the badge stays until you click the pill.

**Alerts stay up until you act on them.** A finished, error, approval, question
or approval-notice card opens the island even when it was hidden, and stays
open, with no auto-close countdown, until you click **OK** / **Open** / a pill / a
tab, or press `Esc`. Then the normal auto-close starts again. An approval card
stays until it is answered, or until the relay gives up after 110 s. While a
pill still has a badge, the compact island does not retract into the top edge. Sounds play
without a prior click: the webview runs with
`--autoplay-policy=no-user-gesture-required`.

A Claude Code multiple-choice question (`AskUserQuestion`) shows each question
with its options instead of Deny / Allow: pick one option (or several on a
multi-select question), and **Submit** becomes available once every question
is answered. **Answer in app** hands the question back to Claude Code; **Open**
brings its window forward. It plays its own "question" sound. Kimi Code
(`AskUserQuestion`), Codex (`request_user_input`) and Hermes (`clarify`, only
questions with choices) questions are shown read-only with **Open**. Answer
them in their own app. Answering from the island still needs a live Claude
check.

### + New task

The **+ Task** tab starts an agent with a prompt: pick Claude, Codex, Kimi or
Hermes, **CLI** or **Desktop**, a folder (type it or press **Browse…** for the
Windows folder picker), type the prompt and press **Go** (or `Ctrl+Enter`).
`Esc` cancels. Agents start in their own default permission mode.

The folder is remembered separately for each of the 8 agent + CLI/Desktop pairs
(`taskProfiles` in `settings.json`, keyed `"claude/cli"`, `"kimi-code/desktop"`…),
and each agent's last CLI/Desktop choice too. Switching agent or CLI/Desktop
loads that pair's folder; a pair never used falls back to the last folder used
anywhere (`lastTaskFolder`, which older settings files already have), else
empty. It is saved after each launch that went through, from the card or the
chat. Prompts are never saved.

| Agent | CLI | Desktop |
|---|---|---|
| Claude | Windows Terminal: `claude "<prompt>"` | `claude://code/new?q=…&folder=…` (new Claude Code session, prompt prefilled), then Enter |
| Codex | Windows Terminal: `codex "<prompt>"` | `codex://threads/new?prompt=…&path=…` (new thread in that workspace), then Enter |
| Kimi | Windows Terminal: `kimi`, then the prompt is pasted + Enter | `Kimi Code.exe --workspace=<folder>`, then (once that call is handed over) `Kimi Code.exe --new-chat`, then paste + Enter |
| Hermes | Windows Terminal: `hermes chat --cli -q "<prompt>"` | `Hermes.exe` with `HERMES_DESKTOP_CWD=<folder>`; `Ctrl+N` (if already open) and `Ctrl+L`, then paste + Enter |

Kimi Code 1.0.4 turns `--new-chat` and `--workspace=` into two actions and
always runs "new chat" before "open workspace", whatever the argument order;
opening a workspace that already has sessions selects its newest one. One call
with both flags therefore ends in an old session. Two calls in the order above
end on a new, empty session in the folder. Its `kimi-code://` links only handle
sign-in, so there is no way to pass the prompt: it is pasted.

The prompt is one argument, never part of a shell string. Windows Terminal
re-reads its command line, so `;`, quotes and backslashes are escaped for it;
it also expands `%NAME%` with no escape, so a prompt containing `%` opens in a
plain new console instead. Newlines become spaces on a command line.

Coucou only presses keys in a window it has verified: the window's process
image must be the expected app (by exe path, never by title; the Kimi terminal
also carries a title Coucou pinned), it must be in the foreground, and that is
re-checked before every keystroke batch. If anything fails, nothing is typed:
the prompt stays on the clipboard and the island says **Press Ctrl+V then
Enter in …**. A paste restores your previous clipboard text afterwards. The log
records agent, target, folder and outcome, never the prompt.

### Starting tasks from the chat

The island chat can start the same tasks: *"start a Codex task in
C:\work\app to fix the failing test"*. It runs **with no confirmation**, through
the same launcher as **+ Task** (same validation, typing checks and log line),
and the agent starts in its own default permission mode. Both chat providers get
three tools:

- `start_task {agent: claude|codex|kimi-code|hermes, target?: cli|desktop,
  folder?, prompt}`. Without `target` it uses the agent's last target, else CLI;
  without `folder`, the folder saved for that agent and target (same rule as
  the card: else the last folder used anywhere). A folder that does not exist is
  reported back, not guessed.
- `list_sessions` (read-only): agent, project folder name and status of the
  sessions the island shows. The island sends this snapshot with each message;
  it never includes prompts, tool inputs or paths.
- `robot_task {task}`: starts the background robot (see [Robot](#robot)) and
  returns at once. A second request while one runs gets "busy".

Each action shows as a short line in the chat log, built from the structured
result (not the model's text): `▶ Started Codex (CLI) in app`,
`⚠ Prompt copied. Press Ctrl+V then Enter in …`, or `✕ … not started: …`.
Limits per message: 3 tool calls and 4 model requests. Tool results sent back to
the model contain only status text. If a 9router model refuses tools (a 4xx
other than 401/403/404/408/429, or an error body), the chat retries without
tools and adds a note that this model cannot start tasks.

### Robot

The **Robot** tab (and the chat's `robot_task` tool) hands a web task to a
background agent working in a hidden, logged-in browser: the CloakBrowser
daemon on `127.0.0.1:9222`. Your mouse, keyboard and windows are never touched.

- If `GET http://127.0.0.1:9222/json/version` does not answer, Coucou runs
  `robotBrowserStart` hidden and waits up to 30 s.
- Agents run headless with no console window, in the order of `robotAgents`
  (default `["hermes:amanda", "codex"]`): `hermes -p amanda --usage-file … -z
  "<prompt>"` with `BROWSER_CDP_URL=http://127.0.0.1:9222`, then
  `codex exec … "<prompt>"`. A quota, rate-limit or sign-in error, or a non-zero
  exit with no result, moves on to the next agent once.
- Coucou wraps the task in rules: browser tool only, never the desktop,
  downloads to `%USERPROFILE%\Downloads\Coucou-Robot`, and before an action
  that reaches other people or changes money, data or accounts (messages,
  emails or comments to others, payments, deletions, account or security
  settings), stop with `NEEDS_APPROVAL: <action>` unless the action is in
  `robotPreapproved`. Prompts to AI assistants, searching, navigating,
  generating and downloading need no approval.
  The run ends with `RESULT: <summary>`.
- `NEEDS_APPROVAL` opens the island's Allow/Deny card. Allow resumes the Hermes
  session (`--resume <session id>` from the usage report) with "User approved:
  …"; without a session the task re-runs with that action pre-approved. Deny,
  or no answer in 10 minutes, ends the task as denied.
- Pre-approved matching is strict: the same sentence, ignoring case, quotes,
  spacing and a final full stop.
- Before every fresh agent run and when the task ends (done, denied, failed or
  stopped), Coucou closes every page of the hidden browser but one
  `about:blank` page, over the browser DevTools socket (`Target.getTargets`,
  `Target.closeTarget`, `Target.createTarget`). Two Telegram Web tabs freeze
  each other. A Hermes resume after Allow keeps its page.
- **Stop** kills the agent's process tree (`taskkill /T /F`). An agent run
  still going after 15 minutes is killed the same way and counts as failed
  (the next agent is tried).
- When it ends, the island shows **Robot done: <RESULT>** and lists new files in
  `Downloads\Coucou-Robot`. While it runs, the Robot tab shows a read-only
  screenshot of the hidden browser's active page every 1.5 s.
- One task at a time. Edit the agents, the pre-approved list and the browser
  start command in **Settings… → Robot**. The log records phases and agents,
  never the task text.

## Hotkeys and voice

Three global hotkeys work from any app. Change them in **Settings… → Hotkeys**:
click a field, press the combination, then **Save hotkeys**.

| Hotkey | Default | Does |
| --- | --- | --- |
| Quick chat | `Ctrl+Alt+C` | Opens or hides a small chat window |
| New task | `Ctrl+Alt+N` | Opens or hides a small **+ Task** window |
| Voice | `Ctrl+Alt+V` | Opens the chat window and records; press again to stop and send |

- A combination needs Ctrl, Alt or Win (F1–F24 may stand alone). Combinations
  Windows keeps (Win+L, Alt+F4…) are refused. **Off** removes one.
- A combination another app already holds shows *Taken by another app* under
  its field. The other two still work.
- Saved in `settings.json` as `hotkeys: {chat, task, voice}`. Registered from
  Rust (`hotkeys.rs`, tauri-plugin-global-shortcut); the pages cannot touch them.

The two small windows have no frame:
- Drag them by the top bar. **Esc** or **×** hides them.
- Position and size are remembered across restarts, by
  tauri-plugin-window-state in `%APPDATA%\fr.louisraille.coucou\.window-state.json`.
- The chat window shares the island chat's conversation and model picker. A
  message sent in one shows in the other.
- The task window is the same card as the island's. After **Go** starts the
  task, the result shows for 1.5 s, then the window hides.

**Voice.** The mic button sits in the island chat bar, the quick chat window
and the task prompt.
- Click once to record, again to stop. Recording stops by itself after 60 s.
- In the chat, the text is sent straight away. In the task window, it only
  fills the prompt.
- The recording goes to your 9router as `POST {base}/audio/transcriptions`
  (multipart `file` + `model`, same key as chat). The model is set in
  **Settings… → Voice** (`sttModel`, default `groq/whisper-large-v3`).
- 9router needs a speech-to-text provider: add a Groq or OpenAI key in
  9router. Without one, the button says so. Errors always end with *Press
  Win+H to dictate instead* (Windows voice typing works in any text field).
- The Windows privacy switch must allow the microphone: **Settings → Privacy &
  security → Microphone**, both *Microphone access* and *Let desktop apps
  access*. When it is off, the button explains this and offers **Open
  microphone settings**.
- On Remote Desktop, the client must also redirect audio recording.
- Audio is never saved. The log records size and outcome, not the text.

## Agent activity preview

Coucou observes Claude Code and has **opt-in** hook configuration for Kimi Code,
Codex and Hermes. This is not a chat-provider switch. Codex approvals can be
answered from the island; Kimi and Hermes approvals are shown only. The three external adapters were implemented against these specific CLI
interfaces: **Kimi Code CLI 2.1.1**, **Codex CLI 0.157.0**, and **Hermes Agent
0.21.5**. Settings runs each executable's `--version` (no console window, stdin
closed, the whole process tree killed via a Job Object after at most 5 s, or
10 s for Hermes) and caches a successful result per executable until it changes.
The tested version installs normally. A different version, or one that cannot
be read (the reason, such as a timeout or exit code, is shown), can still be
installed, but Settings and the install preview show an explicit untested-version
warning and your confirmation is the approval. A CLI not found on `PATH` can
still be installed when the agent's desktop app or config folder is found (see
[One-step setup](#one-step-setup)); the warning then reads "CLI not found;
desktop app detected" (or "config folder detected") because the version cannot
be checked. With no trace of the agent at all, installation stays unavailable.
A matching version string is not a live guarantee that its hook
schema behaves identically. Existing Coucou hooks may always be uninstalled.
Codex hooks apply to local CLI turns and to the Codex desktop app (ChatGPT),
which reads the same `~/.codex/config.toml`. They do not apply to cloud
sessions. Do not infer that an installed entry is trusted or that live events
have arrived.

1. Build and run Coucou, then open **Settings…**. Confirm its relay path is ready.
   Under the desired agent, read **Detected version**, **Configuration**, **Live
   event** and any error separately. `Configured` means an owned config block was found,
   not that the CLI has trusted or run it; a live event means only that Coucou
   received an event during this app run.
2. Click **Review install…** for one CLI and inspect the proposed owned hook
   commands, config path and projected backup name. Previewing or starting
   Coucou does not write CLI hook configurations; startup can still stage the
   relay into `%LOCALAPPDATA%\Coucou\bin\` (see the warning below). Only click
   **Back up and install** if those paths and commands are correct. Existing
   config is backed up to a unique `*.bak-coucou-*` path; the actual path is
   reported after the write. A new config has no prior file to back up.
   Unchanged config values are hidden in the preview, not removed.
   Malformed/unsupported config, edited managed blocks, a missing relay, a busy
   file or a change since preview stops the write; review again rather than
   overriding it.
3. Restart the CLI to load its hooks. For Codex, inspect and trust each exact
   non-managed command in **`/hooks`** yourself (or in the desktop app's hook
   review). Codex records trust per hook hash, so every new or changed entry
   needs trust again. For Hermes, review and approve each exact event/command
   when Hermes asks; Coucou cannot verify or grant that consent. Kimi uses the
   CLI's `[[hooks]]` configuration. Then exercise a real session before
   expecting activity or a finish indication.
   **Review reinstall…** recognises a block written by an earlier Coucou release
   with fewer events, for example the old Codex `Stop`-only block. The preview
   shows those lines being removed and the current block being added, in one
   backed-up write.
4. To revert, use **Review uninstall…**, inspect the removal and click **Back
   up and uninstall**. This removes Coucou-owned entries, leaving other hooks
   in place. A modified managed block is refused rather than guessed away.

The paths are `%USERPROFILE%\.kimi-code\config.toml` for Kimi,
`%USERPROFILE%\.codex\config.toml` for Codex, and the active Hermes profile's
`config.yaml` under `HERMES_HOME` when set, else `%USERPROFILE%\.hermes`, else
the Windows installer's `%LOCALAPPDATA%\hermes` when only that one exists.
Kimi's `Notification` matcher `task.completed` becomes a background-task step,
not a duplicate foreground completion. Kimi's `PermissionRequest` (fire-and-forget
in Kimi) becomes a read-only approval notice.

Codex gets `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`PermissionRequest`, `PostToolUse` and `Stop`. Each runs through
`command_windows = '& "…coucou-hook.exe" --agent codex <Event>'`, the
PowerShell-safe form. Every hook has `timeout = 3`, except `PermissionRequest`,
which has `timeout = 120` so it outlasts the relay's 110 s wait. Codex's separate
`notify` setting is **not** this relay, and a `Stop` is a turn completion, not a
session teardown.

Hermes maps a completed `on_session_end` to `Stop`, a failed/interrupted one to
`StopFailure`, and `on_session_finalize` to teardown. An interrupted turn need
not emit `post_llm_call`. Hermes `pre_approval_request` (a shell-hook observer
event: it cannot veto or answer) becomes a read-only approval notice, and its
`clarify` tool becomes a read-only question card.

The external relay passes generic prompt labels and safe tool names, not raw
prompts, tool arguments, results or conversation histories. The exceptions are
capped question text and options, and one capped approval target line.

Each `(agent, session_id)` has its own pill, even when two sessions of the same
CLI overlap. Prompt/tool events can recover a missed start. A `Stop` plays
Coucou's configured finish sound and opens that session's finished card. When
the island is busy (an approval or question card, chat, + Task), it gives the
pill a badge instead, which stays until clicked. The bot returns to idle rather
than deleting the session. `SessionEnd` removes only that session;
late events after teardown are ignored until a new start **while the teardown
tombstone remains (up to 30 minutes)**. If that same ID restarts, Coucou ignores
the first subsequent `SessionEnd` conservatively, since an old delayed end and
a new end are indistinguishable without a provider generation marker; a genuine
new end may therefore leave the pill until another end or the 30-minute stale
retirement. After the tombstone expires, a later prompt/tool event can create
a new pill for the same identity. Pausing Coucou suppresses hook display; when closed, the relay
exits without blocking the originating CLI. These are implementation behaviors,
**not a claim of observed end-to-end alerts**: real provider sessions, two
concurrent sessions, paused/closed cases, VS Code and standalone Claude approval,
and audible finish/visible island checks remain to be verified before promising
them as tested. Troubleshooting: confirm relay readiness, CLI version and
config path, restart the CLI, complete its native trust step, check **Live
event**, then inspect `%LOCALAPPDATA%\Coucou\coucou.log` without sharing
private content. Do not solve an absent live event by installing blindly.

## One-step setup

**Settings → Set up all my agents** (top of the window) and
`coucou.exe --setup-agents` run the same Rust function, `setup::setup_all_detected`.
For each of Claude Code, Codex, Kimi Code and Hermes it:

1. detects the agent — CLI on `PATH`, desktop app, or config folder:
   | Agent | Desktop app | Config folder |
   |---|---|---|
   | Claude Code | `%LOCALAPPDATA%\Packages\Claude_*` or `%LOCALAPPDATA%\AnthropicClaude` | `~\.claude` |
   | Codex | `%LOCALAPPDATA%\Packages\OpenAI.Codex_*` | `~\.codex` |
   | Kimi Code | `%LOCALAPPDATA%\Programs\Kimi Code\Kimi Code.exe` | `~\.kimi-code` |
   | Hermes | — | `HERMES_HOME`, `~\.hermes` or `%LOCALAPPDATA%\hermes` |
2. skips an agent that is not found — no config is ever created for it;
3. stages the relay (`coucou-hook.exe` from the app resources, or next to
   `coucou.exe` when run from the command line);
4. previews the install and applies it with the usual backup, or reports
   **already set up** when nothing would change (a second run writes nothing);
5. reports per agent: installed / already set up / skipped: not found / error,
   with the message, the backup path and the manual follow-ups (restart;
   Codex `/hooks` trust; Hermes approval or `hermes --accept-hooks`).

The report is also written to `%LOCALAPPDATA%\Coucou\setup-report.txt`.

On first launch (`setupOffered` false in settings) Coucou looks for agents that
are not set up yet and, if there are any, the island says
"Coucou found: Claude Code, Codex. Set them up?". **Set them up** only opens
Settings with the button highlighted; nothing is installed without that click.
Either answer stops the offer from coming back.

Command line (no island, no window, works while Coucou is running — the flags
are handled in `main` before Tauri and its single-instance plugin start):

```
coucou.exe --setup-agents [--dry-run]    install for every agent found
coucou.exe --remove-agents [--dry-run]   remove Coucou's hooks from every agent
```

`--dry-run` writes nothing (not even the relay) except the report. Output goes
to the calling terminal when there is one (PowerShell: append `| Out-Null` so
it waits for the windowed exe), and always to `setup-report.txt`. Exit code `0`
when every agent is installed, already set up or skipped; `1` when any failed.

For sharing, `target/share/` holds `Setup-Coucou.cmd` (silent install, then
`--setup-agents`, shows the report, starts Coucou), `AGENT-SETUP.md`
(instructions a coding agent can follow: "Read AGENT-SETUP.md in this folder and
set up Coucou for me.") and `READ ME FIRST.txt`, next to the installer.

## Claude Code

<img src="screenshots/settings.png" width="562" alt="The settings window">

Open **Settings… → Claude Code → Install hooks…**. You get the exact diff of what
will change in `%USERPROFILE%\.claude\settings.json`, the path of the dated backup
that will be taken, and nothing is written until you click. Your own hooks are
never touched, and uninstalling removes only Coucou's entries.

The relay is `coucou-hook.exe`, staged to `%LOCALAPPDATA%\Coucou\bin\`
when Coucou launches. It budgets 300 ms to connect and up to 2 s for an
ordinary observer event; if Coucou is closed or unreachable it prints nothing
and exits successfully. A Claude `PermissionRequest` may wait for a human after
the island acknowledges a visible card (up to about 110 s); if no decision
arrives, Claude Code handles approval in its own interface. Do not treat that
permission wait as a guarantee that hooks never delay the CLI.

For an `AskUserQuestion` request the island returns one line,
`{"answers":[["label"],["a","b"]]}` (picked labels per question, by index).
The relay checks every label against its own untruncated copy of
`tool_input` (single-select: exactly one) and prints `updatedInput` with
`answers` keyed by the original question text, multi-select labels joined with
`", "`. Anything invalid, and a bare Allow on a question, prints nothing.

The Windows code has no terminal filter and is intended for VS Code and
standalone terminals (Windows Terminal, PowerShell, Git Bash). Approval in
both contexts still requires a real session check; it is not yet a verified
platform claim.

## Chat and keys

**Settings… → Claude** takes your Anthropic API key. Keys live in the **Windows
Credential Manager**, never on disk and never in the interface — the island can
only ask whether a key exists. Same for every integration key.

**Settings… → Chat provider** switches the island chat between Anthropic and a
self-hosted **9router** (any OpenAI-compatible gateway):

1. Pick *9router (OpenAI-compatible)*.
2. Enter the base URL, e.g. `https://router.example.com/9router/v1`, and **Save URL**.
   It must be `https://`; plain `http://` is accepted only for `localhost` or a
   private/loopback IP. A trailing slash is removed.
3. Save the gateway API key (stored as `router-api-key` in the Credential
   Manager), then **Test connection** — it lists `GET {base}/models`.
4. Choose the model in the small dropdown left of the chat field. It shows the
   live 9router list (cached 5 minutes; *↻ Refresh list* reloads it) or the
   Claude models when Anthropic is selected. The choice is saved as `model`.

9router chat sends `POST {base}/chat/completions` (non-streaming, 90 s timeout)
with Mochi's system prompt, the conversation so far and the task tools
(OpenAI function calling; see [Starting tasks from the chat](#starting-tasks-from-the-chat)). It has no web search,
and only text files can ride along — PDFs and images need Anthropic. TLS uses
the Windows certificate store, so a self-signed gateway certificate works once
Windows trusts it (as it does for curl). Changing provider or model keeps the
current conversation (9router sees its text parts and task tool calls, not web
search blocks); dropping a file starts
a fresh one.

No telemetry. The only network requests Coucou makes are to the services you
configure yourself.

## Hindsight memory

Hindsight is optional and disabled until you enable it in **Settings… →
Hindsight memory**. Configure:

1. **Base URL** — the deployment root, including its path prefix when it has one.
   Coucou appends `/v1/{tenant}/banks/{bank}/…`. HTTPS is required in normal
   use; development HTTP is not exposed by the Windows settings UI.
2. **Tenant** and **Bank** — the memory namespace. Check these before any
   mutation; changing either points the manager at different data.
3. **Bearer token** — paste it into the password field and choose **Save token**.
   It is stored under `hindsight-bearer-token` in Windows Credential Manager.
   Settings can check whether it exists, replace it or remove it, but cannot read
   the stored value back into the web UI or settings file.
4. Turn on **Enabled**, then use **Test connection**. Testing performs a
   read-only, authenticated list request against the configured tenant and bank.

When enabled, **Automatic recall** asks Hindsight for relevant context before an
Anthropic or 9router chat message. Recalled content is bounded and clearly
marked as untrusted data before it reaches the chat provider. Recall failure is
non-blocking: the provider request continues without recalled context and the UI
reports that memory was unavailable. Coucou writes no offline retry queue.

Retention has two paths:

- **Remember turn** and **Remember selection** are explicit saves available on
  completed, eligible chat content. Explicit saves still work when inferred
  retention is off.
- **Inferred retention** can save an eligible successful completed turn in the
  background. Cancelled/failed turns, attachments, tool material, credentials or
  hidden-prompt material are excluded; transient formatting requests are also
  excluded from inferred saves. The message shows **Saving memory…**, **Memory
  saved**, or **Memory not saved**.

The chat's eye button enables **Private chat** for the current app session. While
private chat is on, Coucou performs no memory recall, inferred save or explicit
save. It is not a separate bank and is not persisted across app launches. A turn
is registered for later explicit saving or inferred retention only when memory
is enabled and private chat is off both when the turn starts and when it
completes. A temporary mid-turn toggle is not sticky if the original eligible
state is restored before completion. Provider chat still uses its normal network
connection.

Choose **Open Memory Manager** to browse newest-first with text, state, type,
date, platform, retention and source filters. You can inspect details, edit
world/experience memories with conflict detection, export the loaded page as
JSON or Markdown, retire a memory, view retired memories, and restore them.
Observation memories are read-only. Retirement sets the memory to invalidated;
there is deliberately **no hard-delete action**. Bulk retirement is limited to
the exact valid-memory filter, tenant and bank shown in its confirmation, and
reports individual failures after refreshing the list.

Treat live lifecycle testing as destructive even though retirement is
reversible. Use a dedicated disposable bank (never a production or personal
bank), verify its tenant/bank in the confirmation, and test retain, discovery,
edit, export, retire and restore only there. Connection tests and recall are
read-only, but still send data and credentials to the configured service.

### Memory differences from macOS

- Windows stores the bearer token in Windows Credential Manager; macOS stores it
  in Keychain. Neither platform persists the token in ordinary settings.
- Windows supports Anthropic and 9router chat; macOS memory is attached to its
  Claude chat path.
- macOS Settings additionally exposes **Allow HTTP for development**. Keep it
  off outside a controlled local test service.
- Both managers browse, edit, export, retire and restore; neither offers hard
  delete. Their controls and window layout are native to each platform.

## Build it yourself

You need [Rust](https://rustup.rs), [Node 20+](https://nodejs.org), and the
**MSVC build tools** (Visual Studio Build Tools with "Desktop development with
C++"). WebView2 ships with Windows 10/11.

```powershell
cd windows
npm ci
cargo test --workspace
npm run build
npm run pack           # builds the current-user NSIS installer in windows/release/
# npm run tauri dev    # optional live-reloading development app
```

`npm run pack` builds the app, bundles `target/release/coucou-hook.exe` as a
resource and copies the newest NSIS output to both release names below. Inspect
`target/release/bundle/nsis/` and the release files before running any setup.
The default NSIS destination is `%LOCALAPPDATA%\Coucou` for the current user
(although a prior install can restore another destination). Package inspection
does not install, update a running executable or change any CLI config. A
running app copies its relay into `%LOCALAPPDATA%\Coucou\bin\` on launch, so
starting it can replace a local relay; close it first if you need a controlled
comparison.

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
    quick/             the hotkey windows (quick chat, quick task)
  src-tauri/           Rust backend: window, named pipe, Claude API / 9router, pollers,
                       task launcher (launch.rs), hotkeys (hotkeys.rs), quick
                       windows (quick.rs), voice transcription (voice.rs)
  hook/                coucou-hook.exe, Claude and external observer relay
  scripts/             icon generator
```

### Log

`%LOCALAPPDATA%\Coucou\coucou.log` — hook events, permission decisions, poller
problems, task launches (agent, target, folder, outcome; no prompt text). It
stays on your machine.

## What's different from the Mac version

- No notch, so the island lives at the top centre of the screen and retracts into
  the top edge instead of hiding in a notch. Unlock it (header lock button, tray
  **Lock position**, or Settings → General) to drag it anywhere. The spot is saved
  in `settings.json` as `islandPosition` (the island's top centre, physical
  pixels), with `islandLocked` (default `true`). The window hangs from that point,
  so the island grows downward. It is kept inside the display's work area. A
  display change re-clamps the spot instead of resetting it. The hover-to-wake
  strip sits at the same spot. **Reset position** goes back to the top centre.
- Claude permission routing has no Windows terminal filter, unlike the Mac
  build's VS Code filter; VS Code and standalone approval still need live checks.
- Not in this version: sending a file by email, or dragging Mochi onto a window
  to attach it as context.
- Jumping back to a session: the relay records the top-level window the agent
  was started from and forwards only its handle and process id, never a title.
  It looks, in order, for:
  - its own console's owner;
  - else the first ancestor process with a visible window: Windows Terminal, a
    console, or the VS Code window whose title names the session folder;
  - for a desktop agent app in the chain (`ChatGPT.exe`, `Kimi Code.exe`,
    `Hermes.exe`, `Claude.exe`), the app's main window, even when hidden in the
    tray or minimised;
  - for Codex CLI, whose hooks run in a detached app-server daemon, the
    terminal window running the `codex` TUI, else the top Windows Terminal
    window.

  **Open** on the finished, question or notice card, clicking the finished
  card, and the ↗ button bring that window to the front (a hidden tray window
  is shown again) and fold the island. If the window is closed or the handle
  was recycled (different process), only Claude Code sessions fall back to
  opening the folder: in VS Code when `code` is on `PATH`, else Explorer. Codex,
  Kimi and Hermes sessions never open an editor, and their Open button is
  hidden when no window is known. The window is the session's window, not a
  specific terminal tab or VS Code terminal panel.
- Cal.com shows the next bookings as a list rather than the Mac's calendar.
