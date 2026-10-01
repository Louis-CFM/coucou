# Codex coding-agent support

Codex is an **optional local coding-session provider** beside Claude Code.
Coucou monitors hooks; it does not start/authenticate Codex or switch API chat
away from Anthropic. This adapter needs no additional API key.

## Setup

Build this contribution branch; upstream release downloads are not assumed to
contain it. Open **Coucou Settings -> Codex -> Install hooks**. Review the
preview and explicitly confirm. The config is `~/.codex/hooks.json` (Windows:
`%USERPROFILE%\.codex\hooks.json`) or `CODEX_HOME/hooks.json`. Set `CODEX_HOME`
in the environments launching both Coucou and Codex for a custom directory.
App Store Mac builds ask you to select that folder.

Installation preserves foreign handlers, creates a dated byte backup and rejects
stale previews. Removal uses the same reviewed flow. Claude config and Codex
`config.toml` stay untouched. Start a new Codex session and review/trust the
definitions using `/hooks`; Coucou does not bypass Codex trust.
[Official hook documentation](https://learn.chatgpt.com/docs/hooks).

The optional pill appears after installation or receipt of a Codex event.
Unconfigured defaults remain unchanged.

## Local contract

Registered events: SessionStart, SessionEnd, UserPromptSubmit, PreToolUse,
PostToolUse, PermissionRequest, Stop, Interrupt, SubagentStart and SubagentStop.
Claude-specific Notification, StopFailure and PostToolUseFailure are not
registered for Codex. Stop reads `last_assistant_message`.
[Protocol reference](https://learn.chatgpt.com/docs/hooks).

```json
{
  "agent_provider": "codex",
  "hook_event_name": "PreToolUse",
  "session_id": "fixture-session",
  "cwd": "/fixture/project",
  "tool_name": "apply_patch",
  "tool_input": { "command": "*** Begin Patch" }
}
```

`agent_provider` is Coucou's extension inserted by the relay. Untagged legacy
events remain Claude. Windows invocation: `"coucou-hook.exe" --provider codex
PreToolUse`. Mac invocation: `/usr/bin/env python3 '/path/to/nb-hook' --codex`.
Existing IPC is reused; unused transcript/response fields are omitted.

Allow/Deny requires a click. Silence leaves the ordinary approval flow in charge;
timeout is neither deny nor allow. Output is a PermissionRequest decision inside
`hookSpecificOutput`, without Claude's `updatedPermissions` suggestions.
[Permission contract](https://learn.chatgpt.com/docs/hooks).

Windows: connect budget 300 ms, ordinary relay budget 2 s, UI acknowledgment
800 ms, server decision 108 s inside the relay's 110 s. Mac: connect 300 ms,
permission read 118 s and UI timeout 115 s. Installed timeouts are 3 s for
Interrupt, 10 s for ordinary events and 120 s for PermissionRequest. Closed app,
malformed input or no explicit decision prints nothing.

## Compatibility and limits

- Inspected CLI: `codex-cli 0.153.3`, hooks stable/on. Oldest compatible release
  is not established.
- Only clients loading/emitting these hooks are covered. Desktop, extension and
  cloud behavior needs individual verification; hosted tools are not all visible.
- One current-session pill per provider, not one per thread. A competing approval
  returns to its terminal without replacing the reviewed card.
- Codex works outside VS Code; Mac Claude retains its existing terminal filter.
  Open-project still uses Coucou's existing VS Code action.
- Disposable config/synthetic events are used by tests. Installed-version
  inspection is not live Codex dogfood.

## Checks

From `windows/` (frontend checks need only Node):

```powershell
npm ci
npm test
npm run typecheck
npm run build:frontend
cargo build --release -p coucou-hook --locked
cargo test -p coucou-hook --locked
cargo test -p coucou --lib --release --locked
cargo build --release -p coucou --locked
npm run pack
```

Native Mac:

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
swiftc NotchBuddy/Sources/App/CodexHooks.swift tests/codex-hooks/main.swift -o /tmp/coucou-codex-tests
/tmp/coucou-codex-tests
cd NotchBuddy && xcodegen
for scheme in NotchBuddy CoucouAppStore; do
  xcodebuild -scheme "$scheme" -configuration Debug build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
done
```

Native jobs: `.github/workflows/agent-providers.yml`. Report their results
separately from local execution.

The native library tests use the release profile to eliminate unused GUI imports
from the test harness. On the inspected portable GNU toolchain, the full
workspace DLL build hits the PE export limit and the debug library harness hits
`STATUS_ENTRYPOINT_NOT_FOUND`. The separate hook and release-library suites run
successfully; MSVC builds and packaging remain separate checks.

Before merging, dogfood default Claude; optional Codex editing/shell/finish/
interrupt; simultaneous providers; Allow/Deny/no-answer/competing approvals;
closed app; custom folder; shared foreign hooks; uninstall; old preferences;
idle CPU and pill overflow. Compare additions to existing visual references.
