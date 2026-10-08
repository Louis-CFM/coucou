# Coucou — third-party agent integration

Any tool that can write to a Unix domain socket (macOS, Linux) or a named pipe (Windows) can send events to Coucou and have its own pill next to Claude Code.

## The `coucou_agent` field

Add the optional field `coucou_agent` to any hook JSON payload. Coucou will create a pill labelled with the agent name and route all events to it.

**Validation:** the name must match `^[a-z0-9-]{1,24}$` (lowercase letters, digits and hyphens, 1–24 characters). An absent or invalid name routes the event to the Claude Code pill instead.

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

Same pattern with the Windows relay:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "type": "command", "command": "C:\\path\\to\\coucou-hook.exe --agent my-tool" }
    ]
  }
}
```

## Hook command (Linux)

Same pattern with the Linux relay. Coucou copies the relay to `~/.local/share/coucou/bin/coucou-hook` at startup.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "type": "command", "command": "/path/to/coucou-hook --agent my-tool" }
    ]
  }
}
```

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
- **Linux:** `$XDG_RUNTIME_DIR/coucou.sock` (usually `/run/user/<uid>/coucou.sock`). Only your own user account can connect.

## Supported events

Canonical hook events route to the named agent's pill. On macOS, the blocking relay
supports permission cards for Claude Code, Codex, Copilot CLI and Muse Code.
Codex hook decisions are **Allow / Deny**; the relay does not send Claude-specific
permission updates to Codex. Display-only integrations such as Amp and OpenCode do
not gain blocking approvals merely by forwarding a `PermissionRequest` event.

The pill lifecycle:

| Event | Effect |
|---|---|
| `SessionStart` | Creates the pill (if absent), sets state to idle |
| `UserPromptSubmit` | State → thinking; prompt shown in ticker |
| `PreToolUse` | State → working; tool label shown in ticker |
| `PostToolUse` / `PostToolUseFailure` | State → working |
| `Notification` | Rate-limit or question state if applicable |
| `Stop` | State → finished for 5 s; active declared pills (catalog + checked in Settings) reset to idle — all others are removed |
| `StopFailure` | State → error |
| `SessionEnd` | Active declared pills (catalog + checked in Settings) reset to idle — all others are removed |
| `SubagentStart` / `SubagentStop` | Step added to ticker |

## Declared pills

A **declared pill** is a catalog entry (`PillCatalog.swift`) that has been enabled in **Settings → Active pills**. When a session ends for a declared pill, the pill stays visible and resets to idle instead of disappearing.

A catalog pill that is not checked in Settings behaves like any other agent: it gets an automatic pill when a session starts, and that pill is removed when the session ends.

The GitHub build exposes Gemini CLI (`agent_gemini`), Antigravity (`agent_antigravity`),
GitHub Copilot CLI (`agent_copilot`), Muse Code (`agent_muse`), OpenCode (`agent_opencode`),
Amp (`agent_amp`) and Hermes (`agent_hermes`) in Settings → Active pills. Cursor (`agent_cursor`) and Codex
(`agent_codex`, GitHub build only) are there too — their pills can be declared and set as
the main pill. Live sessions still arrive when a different workspace, such as VS Code,
is the Main tool.

Claude Desktop (`agent_claude-desktop`, every build) is there as well. Claude Code sessions started from the Claude desktop app's Code tab carry `CLAUDE_CODE_ENTRYPOINT=claude-desktop`; the relay tags them `coucou_agent: claude-desktop` on its own (an explicit `--agent` still wins), so nothing extra is installed. Declare the pill to keep it after the session ends; the ↗ button opens the Claude app.

## Real-world examples

### Codex in VS Code, the CLI or the Codex app (macOS, GitHub build)

1. Install the OpenAI Codex extension in VS Code, or the Codex CLI, and open a project.
2. Open **Settings → Agents → Codex hooks → Install hooks** in Coucou. Review the
   preview, then confirm. Coucou merges into `~/.codex/hooks.json` after making a backup.
3. In the Codex client that runs your session, enable and trust Coucou's hooks using
   `/hooks` or its Hooks settings. **Done** requires all required hooks to be enabled
   and trusted; modified, disabled, incomplete and unknown states remain distinct.
4. Start a new turn. The relay uses `--agent codex`; Coucou retains the working
   directory and available source application identity. Codex appears on its own pill
   rather than replacing Claude Code's VS Code pill.

The installed hook events are `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`PermissionRequest`, `PostToolUse`, `Stop`, `SubagentStart`, `SubagentStop`,
`Interrupt` and `SessionEnd`. Codex has a different hook payload and event set from
Claude Code; forwarding a Claude-only event does not make Codex emit it.

For Coucou-managed Codex threads, the native app-server connection also handles
question choices, free-form answers, available session approvals, completed file
changes, turn failures and search events. Responses retain thread, turn, item and
request identity and return through the original connection. Hook and native events
for a managed turn are combined without counting the same action twice. An external
IDE thread remains owned by that IDE; creating a new app-server does not attach to
its pending questions. See [Codex app-server](https://learn.chatgpt.com/docs/app-server).

The CLI version displayed in Coucou is the executable used for its native
connection. A VS Code extension may bundle a different version. Verify its hook
settings when CLI diagnostics succeed but no IDE events arrive.

### Gemini CLI (macOS)

Coucou supports Gemini CLI out of the box via **Settings → Gemini CLI → Install hooks**.
The installer writes to `~/.gemini/settings.json` and uses `--agent gemini` so
Gemini sessions get their own pill. The relay translates Gemini event names to canonical
Coucou events automatically.

| Gemini CLI event | Canonical event |
|---|---|
| `BeforeTool` | `PreToolUse` |
| `AfterTool` | `PostToolUse` |
| `BeforeAgent` | `UserPromptSubmit` |
| `AfterAgent` | `Stop` |

`AfterModel` is not installed — it fires on every response chunk and would flood the island.

### Antigravity — `agy` (macOS)

Coucou supports Antigravity out of the box via **Settings → Antigravity → Install hooks**.
The installer writes to `~/.gemini/config/hooks.json` (timeouts in seconds) and uses
`--agent antigravity`. The relay translates `toolCall.name` / `conversationId` to the
island's `tool_name` / `session_id`.

| Antigravity event | Canonical event |
|---|---|
| `PreInvocation` | `UserPromptSubmit` |
| `PreToolUse` | `PreToolUse` |
| `PostToolUse` | `PostToolUse` |
| `PostInvocation` | `PostToolUse` |
| `Stop` | `Stop` |

### GitHub Copilot CLI (macOS)

Coucou supports Copilot CLI out of the box via **Settings → GitHub Copilot CLI Hooks → Install hooks**.
The installer writes to `~/.copilot/hooks/coucou.json` and uses `--agent copilot`.
Copilot CLI uses camelCase event names and `{"bash":"…","timeoutSec":N}` entries.
Copilot CLI is fail-closed on `permissionRequest`: the relay always outputs valid JSON
and returns `{"permissionDecision":"ask"}` on timeout so Copilot re-prompts in the terminal.
Coucou shows a real Allow / Deny card for Copilot approval requests.

| Copilot CLI event | Canonical event |
|---|---|
| `sessionStart` | `SessionStart` |
| `userPromptSubmitted` | `UserPromptSubmit` |
| `preToolUse` | `PreToolUse` |
| `permissionRequest` | `PermissionRequest` |
| `postToolUse` | `PostToolUse` |
| `agentStop` | `Stop` |
| `sessionEnd` | `SessionEnd` |
| `notification` | `Notification` |

### Muse Code (macOS)

Coucou supports Muse Code out of the box via **Settings → Muse Code Hooks → Install hooks**.
The installer merges into `~/.config/muse/settings.json` and uses `--agent muse`.
Muse uses PascalCase event names. Coucou shows a real Allow / Deny card for Muse approval requests.

| Muse Code event | Canonical event |
|---|---|
| `SessionStart` | `SessionStart` |
| `UserPromptSubmit` | `UserPromptSubmit` |
| `PreToolUse` | `PreToolUse` |
| `PermissionRequest` | `PermissionRequest` |
| `PostToolUse` | `PostToolUse` |
| `Stop` | `Stop` |
| `SessionEnd` | `SessionEnd` |

### OpenCode (macOS)

Coucou supports OpenCode via **Settings → OpenCode Plugin → Install plugin**.
The installer writes a JS plugin to `~/.config/opencode/plugins/coucou.js`.
The plugin maps OpenCode event types to canonical Coucou names and forwards them fire-and-forget; OpenCode is never blocked.

| OpenCode event | Canonical event |
|---|---|
| `session.created` | `SessionStart` |
| `session.idle` | `Stop` |
| `session.error` | `StopFailure` |
| `session.deleted` | `SessionEnd` |
| `tool.execute.before` | `PreToolUse` |
| `tool.execute.after` | `PostToolUse` |
| `permission.asked` | `PermissionRequest` |

### Amp (macOS)

Coucou supports Amp via **Settings → Amp Plugin → Install plugin**.
The installer writes a TypeScript plugin to `~/.config/amp/plugins/coucou.ts`.
The `tool.call` handler returns `{ action: 'allow' }` so Amp always proceeds; all events are forwarded display-only.

| Amp event | Canonical event |
|---|---|
| `session.start` | `SessionStart` |
| `agent.start` | `UserPromptSubmit` |
| `tool.call` | `PreToolUse` |
| `tool.result` | `PostToolUse` |
| `agent.end` | `Stop` |

### Hermes Agent (macOS)

Coucou supports Hermes via **Settings → Agents → Hermes → Install plugin**.
The installer writes a Python plugin to `~/.hermes/plugins/coucou/` and enables it in
`~/.hermes/config.yaml`. The plugin uses `on_session_start` (sends the platform when running
via the gateway), `post_llm_call` (sends the final response), and a `pre_approval_request`
observer hook that fires a `⏳ Approval pending in Hermes` step in the notch.
Approving from the notch requires `register_approval_transport`, which is not yet available
in Hermes 0.15.x; the Approvals toggle activates automatically once Hermes exposes it.
Every event is fire-and-forget: if the app is closed or unreachable, nothing is sent and Hermes carries on, handling approvals itself.

| Hermes event | Canonical event |
|---|---|
| `on_session_start` | `SessionStart` |
| `post_llm_call` | `Stop` |
| `pre_approval_request` | `PreToolUse` (observer only, shows "⏳ Approval pending in Hermes") |

### Any other tool

Follow the generic pattern: call `nb-hook --agent <your-name> <EventName>` (macOS),
`coucou-hook.exe --agent <your-name> <EventName>` (Windows)
or `~/.local/share/coucou/bin/coucou-hook --agent <your-name> <EventName>` (Linux)
and let the relay forward the event.

## Quick test (Linux)

With Coucou running:

```sh
echo '{"hook_event_name":"UserPromptSubmit","session_id":"t1","prompt":"hello","coucou_agent":"demo"}' \
  | ~/.local/share/coucou/bin/coucou-hook --agent demo
```

A "demo" pill should appear in the island.

## Quick test (macOS)

With Coucou running:

```sh
echo '{"hook_event_name":"UserPromptSubmit","session_id":"t1","prompt":"hello","coucou_agent":"demo"}' \
  | /bin/sh ~/Library/Application\ Support/NotchBuddy/nb-hook --agent demo
```

A "demo" pill should appear in the island.
