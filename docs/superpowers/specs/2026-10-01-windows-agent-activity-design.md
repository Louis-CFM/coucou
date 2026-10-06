# Windows Coucou: multi-agent live activity

## Outcome and scope

On Windows, Coucou shows live, separate sessions for Claude Code in VS Code and standalone terminals, Codex CLI, Kimi Code CLI, and Hermes Agent. A session shows its agent, current state, prompt and tool-step labels, and completion or failure. Completion uses Coucou's existing finish sound and island indicator, not a Windows toast. An unfocused agent gets an island badge rather than a forced-open alert. Claude Code retains its existing approval UI; approvals for the other three remain in their own applications. Chat provider selection is a separate design.

## Approach

Extend the existing named-pipe ingress rather than running a second listener. Each source adapter translates native hooks into Coucou's newline-delimited event JSON: `coucou_agent`, `session_id`, `hook_event_name`, `cwd`, and relevant event fields. Claude Code keeps its existing relay but no longer requires a VS Code terminal to appear. Tagged events with malformed agent names must not silently become Claude events. Validate event size and shape at the pipe boundary; never log full prompts, tool arguments, or secrets.

A small activity normalization layer in `windows/src/island/hooks.ts` maps source-independent events to the task state in `windows/src/core/state.ts`. Use `(agent, session_id)` as the key, with fallback only for legacy Claude events without a session ID. On `SessionStart` create an idle task; on prompt and tool events create it if a start was missed. `Stop` marks a turn finished without conflating it with `SessionEnd`; a delayed removal must be cancellable by subsequent events from that same session. `SessionEnd` removes only that session. Handle interruption, stale sessions, out-of-order events and overlapping sessions without removing a newer task. The overview in `windows/src/views/views.ts` shows live steps for any agent, not only Claude. Generic cards in `windows/src/views/integrations.ts` show the correct agent and status, and an unavailable terminal target is not represented as a functional open action. Existing Claude approval routing stays intact for both VS Code and standalone terminals; verify its real terminal context and fallback behavior before changing the filter.

## Source adapters and opt-in configuration

- **Claude Code:** retain the installer and relay in `windows/src-tauri/src/hooks.rs` and `windows/hook/src/main.rs`, and test both launch contexts. Do not change its permission response contract.
- **Kimi Code CLI 2.1.1:** merge documented `[[hooks]]` into `~/.kimi-code/config.toml` without changing the Orca-managed block. Map SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, SessionEnd and failures where emitted. Route `Notification` with the `task.completed` matcher to a background-task completion without duplicating a foreground `Stop` alert. A non-blocking observer returns success and no model-visible output.
- **Codex CLI 0.157.0:** merge `[[hooks.Stop]]` / `[[hooks.Stop.hooks]]` with a `command_windows` relay into `~/.codex/config.toml`. Its stdin payload is a turn completion, mapped to `Stop`, not `SessionEnd`. The separate `notify` setting passes JSON as a command-line argument and cannot directly call the present relay. Non-managed hooks require review and trust in Codex `/hooks`; local CLI completion is the supported target, not an unverified Desktop or cloud session. Do not install a Coucou permission-decision hook.
- **Hermes Agent 0.21.5:** merge shell hooks into the active profile's `config.yaml`, using a reviewed translator for the native JSON in `extra`. Map pre-LLM and tool events to prompt/tool events; map `on_session_end` to `Stop` or `StopFailure` according to outcome, and `on_session_finalize` to `SessionEnd`. `post_llm_call` may supply the final assistant response, but does not fire for an interrupted turn. The exact event-command pairs need one-time Hermes consent; do not auto-accept them. The translator forwards only the fields Coucou needs, not full tool results or histories.

Each adapter has status, preview, install and uninstall. Preview displays exactly what user config would change. Install preserves other entries, takes a dated backup, rechecks the file before writing, and refuses malformed or concurrently changed config. Uninstall removes only Coucou-owned entries. No hook installation occurs merely because Coucou starts. If a CLI is unavailable or its hook interface differs from the tested version, report that integration as unavailable instead of claiming it is active. Document the handoff in `docs/AGENTS.md` and `windows/README.md`.

## Error handling and verification

An unavailable Coucou pipe must not delay or block the originating agent. Display that an adapter is configured separately from whether it is trusted and whether live events have arrived. Bound the in-memory step history per session, and retire stale pills if a process exits without an end event. Preserve current Claude behavior in the absence of new adapters.

Add Rust tests in the existing hook/installer test suites for normalizing representative source payloads, safe merge/backup/uninstall, malformed config, quoting, and failure-to-connect. Add frontend tests only if an existing runner is present. Verify a real Windows session for each CLI with start, prompt, tool, completion and teardown; verify two simultaneous sessions of one agent, Claude in both VS Code and a terminal, restart/missed-start behavior, and Coucou being closed. Run the repository's standard Rust and frontend build/test commands on the final deliverable. If a provider cannot be exercised live, label it unverified rather than complete.

## Out of scope

Cross-agent approvals, reading desktop ChatGPT or Kimi application conversations, importing prior sessions, and silently changing user-level agent configurations are not part of this milestone.
