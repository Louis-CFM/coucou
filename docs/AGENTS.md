# Coucou — third-party agent integration

Any tool that can write to a Unix domain socket (macOS) or a named pipe (Windows) can send events to Coucou and have its own pill next to Claude Code.

## The `coucou_agent` field

Add the optional field `coucou_agent` to hook JSON. On Windows, each live `(coucou_agent, session_id)` pair has its own pill; a tagged event without a nonempty `session_id` is ignored by the island. An untagged Claude Code event with a session ID also gets a separate session pill. Only legacy untagged Claude events lacking a session ID use the shared Claude Code pill.

**Validation:** names must match `^[a-z0-9-]{1,24}$` (lowercase letters, digits and hyphens, 1–24 characters); `claude` is reserved for the untagged Claude path. Windows rejects a present invalid tag at pipe ingress rather than treating it as Claude. The macOS path currently falls back to Claude for invalid names.

## Hook command (macOS)

Configure your tool to call the Coucou relay with `--agent <your-name>` after the hook executable:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "type": "command", "command": "/path/to/nb-hook --agent my-tool" }
    ]
  }
}
```

The shell wrapper passes `"$@"` to the Python relay, which extracts the agent name and injects it into the payload before forwarding to Coucou.

## Hook command (Windows)

For a custom observer, pass `--agent <name>` to the relay at `%LOCALAPPDATA%\Coucou\bin\coucou-hook.exe` and send a JSON object on stdin with a nonempty `hook_event_name` and `session_id`. For example, a `UserPromptSubmit` event with `coucou_agent: "my-tool"` and `session_id: "my-session-1"` creates that session's pill. The relay tags the event, and the Windows named-pipe ingress checks the tag and limits each frame to 1 MiB. The relay exits successfully with no output if Coucou is closed or the input cannot be forwarded. This is an **observer**, not a permission-decision bridge for another CLI.

Coucou's Settings window has separate opt-in **Review install…** and **Review uninstall…** flows for Kimi Code, Codex and Hermes; see [Windows setup](../windows/README.md#agent-activity-preview) for the tested versions and native trust steps. It also has one-click **Set up all my agents** and the equivalent `coucou.exe --setup-agents` / `--remove-agents` (see [One-step setup](../windows/README.md#one-step-setup)), which only touch agents detected on the PC. It does not install hooks on startup: the first-launch offer only opens Settings.

## Starting tasks (Windows)

The island's **+ Task** tab starts Claude, Codex, Kimi Code or Hermes in a folder, as a CLI in Windows Terminal or in the desktop app, with a prompt. Everything goes through one Rust function, `launch::execute` (Tauri command `launch_task({agent, target: "cli"|"desktop", folder, prompt})`, wrapped by `start_task` in `lib.rs`, which also remembers `lastTaskFolder`, `lastTaskTargets` and the per agent/target folder in `taskProfiles` (keys like `"claude/cli"`) in settings; prompts are never saved). Agents: `claude`, `codex`, `kimi-code`, `hermes`; the folder must exist; the prompt is non-empty, ≤ 8000 characters, no NUL. Launch methods and the typing safety rules are in [Windows setup](../windows/README.md#-new-task). A launched session reports back through the normal hooks above; launching does not change any agent config or permission mode.

The island chat can start tasks too, with no confirmation: both providers (Anthropic custom tool, 9router OpenAI function) get `start_task {agent, target?, folder?, prompt}` and a read-only `list_sessions` (agent, project name, status from a snapshot the island sends with `chat_send`). The loop lives in `windows/src-tauri/src/tools.rs` and calls the same `start_task` (max 3 tool calls and 4 model requests per message); `chat_send` returns `{text, actions[]}` and the island renders each action as a system line. See [Starting tasks from the chat](../windows/README.md#starting-tasks-from-the-chat).

The chat also gets `robot_task {task}`, and the island has a **Robot** tab: a background agent (`robotAgents`, default `["hermes:amanda", "codex"]`, run headless with `BROWSER_CDP_URL=http://127.0.0.1:9222`) does the task in the hidden CloakBrowser on `127.0.0.1:9222` (started via `robotBrowserStart` when down). Rust: `windows/src-tauri/src/robot.rs` (runner, output parsing, fallback, approvals, Stop via `taskkill /T /F`) and `cdp.rs` (liveness, read-only screenshot, download folder). Commands: `robot_status`, `robot_start {task}`, `robot_stop`, `robot_preview`, `robot_approve {id, allow}`; status arrives as the `robot-status` event. `NEEDS_APPROVAL:` lines use the island's Allow/Deny card unless the action matches `robotPreapproved` exactly; one task at a time. Before each fresh agent run and when a task ends, the hidden browser is reset to a single `about:blank` page (`cdp::reset_tabs`, browser socket); each agent run is killed after 15 minutes and counts as failed. See [Robot](../windows/README.md#robot).

Global hotkeys (Windows, `settings.json` → `hotkeys: {chat, task, voice}`, defaults `Ctrl+Alt+C`, `Ctrl+Alt+N`, `Ctrl+Alt+V`) open two small windows, `quick-chat` and `quick-task`. They reuse the island's chat and **+ Task** card, so launching from them goes through the same `launch_task` / `start_task` path and the same chat state. Voice input posts the recording to the 9router's `/audio/transcriptions` (`sttModel`). See [Hotkeys and voice](../windows/README.md#hotkeys-and-voice).

## Coucou's own chat is separate

The island chat is not a CLI agent and does not go through hooks. On Windows it talks either to the Anthropic API or to a user-configured OpenAI-compatible **9router** (`chatProvider: "router"`, `routerBaseUrl` in `%APPDATA%\Coucou\settings.json`, key `router-api-key` in the Credential Manager). Optional Hindsight recall runs before either provider and retention runs after eligible completed turns; memory failure never replaces the provider response. Private chat bypasses all memory operations for the app session. The Hindsight bearer token stays in the OS credential store, not chat/settings payloads, and the separate Memory Manager retires/restores rather than hard-deleting. See [Chat and keys](../windows/README.md#chat-and-keys) and [Hindsight memory](../windows/README.md#hindsight-memory).

## Payload format

The relay adds `coucou_agent` to the JSON it forwards. You can also add it yourself if you talk to the socket directly:

```json
{
  "hook_event_name": "UserPromptSubmit",
  "session_id": "my-session-1",
  "coucou_agent": "my-tool",
  "prompt": "Running task…"
}
```

Send newline-terminated JSON to the socket:
- **macOS (GitHub build):** `~/Library/Application Support/NotchBuddy/nb.sock`
- **macOS (App Store build):** `~/Library/Containers/fr.louisraille.Coucou/Data/nb.sock`
- **Windows:** `\\.\pipe\coucou-<user-SID>`

On Windows, the built-in Kimi, Codex and Hermes translators forward session identity, working directory, generic prompt labels, and allowlisted tool names, **not** raw prompts, tool arguments, responses or histories. There are two exceptions. (1) Questions: a `PreToolUse` for Kimi `AskUserQuestion`, Codex `request_user_input` or Hermes `clarify` forwards only `tool_input.questions`. It is reduced to question text, header, `multiSelect` and option `label`/`description`, each ≤ 300 characters, with ≤ 8 questions and ≤ 12 options. Hermes `choices`/`multi_select` are mapped to options, and Hermes questions without choices are dropped. The island shows them read-only with **Open**. (2) Approvals: a Codex `PermissionRequest`, Kimi `PermissionRequest` or Hermes `pre_approval_request` forwards only a display tool name and one target line (≤ 300 characters) in `tool_input.command`. That line is the command, or else the agent's own approval description. A custom directly tagged payload is not automatically sanitized the same way; send only data you intend Coucou to display. Native adapters and their completion sounds/indicators still need real provider-session verification; a successful build or hook configuration alone does not prove an alert fired.

## Supported events and lifecycle

Windows accepts a valid tagged observer event. It rejects a tagged `PermissionRequest` at pipe ingress, except one tagged `coucou_agent: "codex"`.

- **Answerable approval cards** come from two sources: an untagged Claude Code `PermissionRequest`, and a Codex `PermissionRequest` (Allow/Deny).
  - Both use the documented `hookSpecificOutput.decision` (`behavior: allow|deny`).
  - With no click within 110 s, or with Coucou closed, the relay prints nothing and the agent shows its own prompt.
- **Claude `AskUserQuestion`** gets a card with the options. The island replies `{"answers":[[…],…]}` by question index. The relay emits `updatedInput.answers` keyed by its own untruncated question text, or nothing if the reply is invalid.
- **Kimi and Hermes approvals are display-only.** The relay turns them into the canonical observer event `ApprovalNotice`: an amber card with what is asked, plus **Open**. Nothing is ever sent back, so they still answer in their own window. Their hooks are observer-only:
  - Kimi `PermissionRequest` is fire-and-forget.
  - Hermes `pre_approval_request` cannot veto or answer.
- **Custom agents** keep approval decisions in their own CLI.

On macOS, external `PermissionRequest` has a different no-decision fallback; do not treat this as cross-agent approval support.

Each `(agent, session_id)` is independent:

- A missed `SessionStart` does not prevent a later prompt or tool event from creating a session.
- A `Stop` finishes a **turn**; it does not remove the session. A later event cancels the pending idle transition.
- `SessionEnd` removes only that session.
- A late event after `SessionEnd` is ignored until a new `SessionStart`, while that teardown tombstone remains (up to 30 minutes). After expiry, a later prompt or tool event can recreate a pill for the same identity.
- When an explicit start reuses an ended ID, the first subsequent end is ignored, to protect against a delayed old end. Without a provider generation marker, a real new end looks the same and may leave a pill until another end or stale retirement.
- Inactive sessions are retired after 30 minutes. Steps are limited to 20 per session.

On Windows a `Stop` / `StopFailure` from **any** session, focused or not, plays the finish/error sound and does one of two things:

- **Shows the outcome.** It focuses that session and opens its finished/error card, as for the focused session.
- **Badges the pill.** This happens when the island is busy: an approval card is waiting, another session's question or notice card is up, or you are in chat, + Task, settings or a file drop. The pill gets a `finished`/`error` badge that stays until the pill is clicked, and clicking it opens that card.

Every alert card (finished, error, approval, question, approval notice) is pinned. It opens the island even from hidden, and stays until the user acts on it: OK, Open, a pill, a tab, or Esc. An approval stays until it is answered or times out. While any session pill still has a badge, the compact island never retracts to hidden. See `windows/src/island/alerts.ts`.

Pausing Coucou suppresses hook display, and a closed app cannot receive events.

| Event | Windows effect |
|---|---|
| `SessionStart` | Creates an idle session pill |
| `UserPromptSubmit` | Sets thinking; adds a step when a prompt/label is available |
| `PreToolUse` | Sets working; adds an allowlisted tool label for built-in external adapters; an external question tool opens a read-only question card |
| `PermissionRequest` | Claude / Codex only: answerable approval card (waits up to 110 s) |
| `ApprovalNotice` | Kimi / Hermes approval: read-only card with what is asked and **Open**; never answered |
| `PostToolUse` / `PostToolUseFailure` | Keeps working; failure adds a failed step |
| `Notification` | Rate-limit or question state for applicable messages; Kimi `task.completed` becomes a background-task step, not a second `Stop` |
| `Stop` / `StopFailure` | Marks turn finished/error, with sound; opens that session's card, or a persistent badge while the island is busy |
| `SessionEnd` | Removes that session's pill |
| `SubagentStart` / `SubagentStop` | Adds a step |

On Windows the relay also adds `origin_hwnd` and `origin_pid` to every event (Claude and tagged agents) when it can find the window the session was started from. When a console identified that window, it also adds `origin_console_pid`, a process on the session's console (the agent CLI or its shell, never `cmd.exe` when something longer-lived shares the console). They are omitted otherwise, and any values supplied on stdin are replaced. How the window is found:

- **Window ancestor.** The first ancestor process that owns a visible window wins.
- **Desktop apps.** When the chain contains `ChatGPT.exe` (Codex desktop), `Kimi Code.exe`, `Hermes.exe` or `Claude.exe`, the app's titled main window is used, even when it is hidden in the tray or minimised.
- **Codex CLI.** Its hooks run in a detached `codex app-server` daemon with no window ancestry. The relay uses the terminal window of a running `codex` TUI: one whose title names the session folder first, else the newest one, else the top Windows Terminal window.

Clicking **Open** on a finished, question or notice card, clicking the finished card itself, or the ↗ button brings that window to the front, showing a hidden tray window again. It does so only if the handle still exists and belongs to the same process. When the window is Windows Terminal and `origin_console_pid` is known, the session's tab is selected afterwards: the console title is briefly set to a unique marker, the tab showing it is selected through UI Automation, and the title is restored (fallback: the only tab named like the title; nothing when titles are duplicated). Without a window, a Claude Code session opens its folder in VS Code; Codex, Kimi and Hermes sessions open nothing, and the Open button is hidden.

## Quick test (macOS)

With Coucou running:

```sh
echo '{"hook_event_name":"UserPromptSubmit","session_id":"t1","prompt":"hello","coucou_agent":"demo"}' \
  | /bin/sh ~/Library/Application\ Support/NotchBuddy/nb-hook --agent demo
```

A "demo" pill should appear in the island.
