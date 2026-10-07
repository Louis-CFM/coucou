# Windows Multi-Agent Activity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Do not commit unless the user explicitly requests a commit.

**Goal:** Build and install Windows Coucou from source so Claude Code, local Codex CLI, Kimi Code CLI, and Hermes Agent each show a separate task and use Coucou's finish sound and island indicator at turn completion.

**Architecture:** Keep the current Windows named-pipe server and relay. Normalize tool-specific hook payloads at an adapter boundary, key tasks by agent and session, and make activity and lifecycle UI independent of the agent. Preserve unrelated hooks while explicitly installing each user-level CLI adapter after a preview and backup; provider-specific hook trust remains with the user.

**Tech Stack:** Rust/Tauri 2, Windows named pipes, TypeScript/Vite, existing Rust test suites. No frontend test runner is present.

**Spec:** `docs/superpowers/specs/2026-10-01-windows-agent-activity-design.md`

## Global Constraints

- Windows only; no second listener, no automatic CLI hook installation, no cross-agent approval buttons.
- Preserve Claude Code approval response contract and fail-open relay behavior.
- Use `(agent, session_id)` for distinct sessions; legacy untagged Claude events without session ID remain supported.
- A Hermes turn-end is not a session-end; only a confirmed finalization removes that session.
- No plaintext credential, full prompt, tool input or file content in log messages.
- The existing `windows/package.json` has no frontend test runner: verify UI through build and real Tauri interaction, not new test scaffolding.

## Review Focus

- Oversized pipe frame with a newline just after the limit is rejected before JSON parse; pin in Task 1's payload validator test.
- Invalid *present* `coucou_agent` never becomes Claude activity; pin in Task 1 and manually exercise Task 2.
- Delayed Stop timer cannot erase a newer turn or sibling session; exercise Task 2's UI fixture sequence.
- Malformed or concurrently edited CLI configuration is never overwritten; pin in Task 4's temporary-config Rust tests.
- Observer script without Coucou running exits promptly and emits no permission decision; pin in Task 3's relay tests and live check.

---

## File ownership map

- `windows/src-tauri/src/pipe.rs`: bounded, validated pipe ingress and Claude approval handshake.
- `windows/hook/src/main.rs`: relay argument/input mapping, bounded reads, observer-only output for external agents.
- `windows/src/core/state.ts`: stable session identity, task ordering and bounded steps.
- `windows/src/island/hooks.ts`: source-independent activity transitions, finish/stale timers, Claude approval routing.
- `windows/src/views/views.ts`, `windows/src/views/integrations.ts`, `windows/src/island/island.ts`: truthful ticker/cards/actions for all sessions.
- `windows/src-tauri/src/agent_hooks.rs` (new): provider-specific configuration preview/status/apply, safe backup and reversible ownership-scoped removal for Codex TOML, Kimi TOML and Hermes YAML.
- `windows/src-tauri/src/lib.rs`, `windows/src/core/bridge.ts`, `windows/src/settings/main.ts`: adapter commands, typed frontend API, opt-in controls.
- `docs/AGENTS.md`, `windows/README.md`: wire protocol and supported setup/limitations. Existing modifications in `windows/src-tauri/src/pipe.rs`, `windows/hook/src/main.rs`, `windows/hook/tests/` and `windows/package-lock.json` predate this approval: preserve and review them, never reset them as cleanup.

### Task 1: Harden and Test the Existing Pipe

**Files:** Modify `windows/src-tauri/src/pipe.rs:98-155`; test in its existing Rust test module; modify `windows/hook/src/main.rs:117-197` and its existing tests.

**Interfaces:** Consumes newline-delimited hook JSON. Produces `parse_hook_frame(line: &[u8]) -> Result<Value, FrameError>` for a bounded JSON object and unchanged `PermissionRequest` decision path; relay supplies tagged canonical JSON to it.

- [ ] **Step 1: Write failing validator tests.** For example, `assert!(parse_hook_frame(&vec![b'x'; MAX_PAYLOAD + 1]).is_err())`; also test an over-limit object followed by `\n`, JSON array, empty event name, invalid tagged agent, and an absent tag with valid Claude payload. Test the external relay path with no server: it exits with success and empty stdout, not a fake allow.
- [ ] **Step 2: Run `cargo test --workspace` from `windows/`; confirm the new tests fail for the intended validation gaps.**
- [ ] **Step 3: Extract frame validation and bound the read before parsing.** Reject `line.len() > MAX_PAYLOAD` even if newline exists; put a short timeout around reading the ordinary frame; validate `hook_event_name` and a present `coucou_agent` (`^[a-z0-9-]{1,24}$`, except reserved `claude`) at this ingress boundary. Preserve absent-tag Claude and the existing short ack/long decision handshake without changing its output.
- [ ] **Step 4: Run `cargo test --workspace`; inspect failure cases and adjust only this boundary until green.**

### Task 2: Session-Scoped Activity and Honest UI

**Files:** Modify `windows/src/core/state.ts:9-22,179-250`, `windows/src/island/hooks.ts:123-335`, `windows/src/views/views.ts:175-380`, `windows/src/views/integrations.ts`, and `windows/src/island/island.ts` open-target handling.

**Interfaces:** Consumes canonical hook events from Task 1. Produces `taskId(agent: string, sessionId: string): string` with collision-free IDs, `upsertAgentSession(agent, sessionId, projectName, cwd)` and `removeTask(id)` on State; retains `integration_claude` only for legacy sessionless Claude events.

- [ ] **Step 1: Record a manual event fixture matrix before editing.** Inject SessionStart/Prompt/PreTool/Stop for `claude/s1`, `claude/s2`, `codex/s1`; verify baseline conflates sessions and non-Claude focused views omit ticker. This is the failing scenario because no TypeScript test harness exists.
- [ ] **Step 2: Add stable task identity and session metadata.** Do not concatenate ambiguous strings without escaping/encoding. Limit steps to the existing 20. Preserve integration task ordering and four-visible-pill behavior while ensuring active sessions can be found/focused (scroll or overflow if necessary).
- [ ] **Step 3: Refactor `handleHook` to upsert on prompt/tool/failure when start is missed.** On Stop mark that session finished and schedule removal/idle only if its generation is unchanged; on new events cancel the timer. On SessionEnd remove only that session; handle out-of-order end and stale sessions. Leave Claude approval pending request ID and acknowledgement semantics unchanged; direct a valid Claude session's approval to its actual task.
- [ ] **Step 4: Update focused ticker and cards.** In `buildOverview()` choose ticker for active `source === 'agent' || source === 'claudeCode'`. Use task name rather than hardcoded Claude in question/finished/error views. Do not label opening a folder in VS Code as opening the originating terminal; hide or relabel unavailable actions. The current Windows `hooks.ts:3-4` already says it has *no terminal filter*, so do not add a needless VS Code filter change; verify both launch contexts.
- [ ] **Step 5: Run `npm run build`, then manually repeat the fixture matrix including missed start, two same-agent sessions, `Stop → new prompt → old timer`, simultaneous Claude approval and Codex work, SessionEnd, and stale event retirement.** No task should overwrite a sibling or vanish due to an old timer.

### Task 3: Event Translation for Three CLIs

**Files:** Modify `windows/hook/src/main.rs` and its Rust tests; add focused translator module under `windows/hook/src/` if the existing file becomes unwieldy. Update `windows/Cargo.toml` only if a truly required dependency is absent.

**Interfaces:** Consumes stdin native hook JSON plus explicit source argument (`--agent kimi-code|codex|hermes`), yields canonical `hook_event_name`, `session_id`, `cwd`, `prompt`, `tool_name`, `tool_input`; observer output is empty. Claude relay behavior and permission translation remain unchanged. `--agent` alone is a tag and does not translate Hermes's native event names.

- [ ] **Step 1: Pin redacted fixture payloads for installed Kimi 2.1.1, Codex 0.157.0 and Hermes 0.21.5.** Inspect the installed hook contracts where docs omit field names. Codex's documented `[[hooks.Stop]]` command receives stdin JSON, while `notify` uses an argv JSON argument; Hermes fields such as `completed`, `failed`, `interrupted` and `assistant_response` are in `extra`. Keep unrelated config private.
- [ ] **Step 2: Write failing translator tests for each native fixture.** Assert Kimi foreground `Stop` and `Notification`/`task.completed` mapping without duplicate alerts, Codex Stop/session identity, and Hermes `on_session_end → Stop|StopFailure`, `on_session_finalize → SessionEnd`, tool events and failure outcome. Malformed payload emits no event; no external hook returns a permission decision.
- [ ] **Step 3: Run `cargo test -p coucou-hook`; confirm failures, then implement minimal source translators.** Keep Claude native handling and `--agent` support intact. Bound stdin at or below the pipe limit and truncate preview fields without logging source JSON.
- [ ] **Step 4: Run `cargo test -p coucou-hook` and invoke the real relay with Coucou closed; verify quick exit and empty stdout for each observer source.** Test paths containing spaces and Windows quoting in the process invocation.

### Task 4: Explicit Installation and Removal of Agent Hooks

**Files:** Create `windows/src-tauri/src/agent_hooks.rs`; modify `windows/src-tauri/src/lib.rs:3-13,187-219`, `windows/src/core/bridge.ts:63-72`, `windows/src/settings/main.ts:44-172`.

**Interfaces:** Expose Tauri `agent_hooks_status(agent)`, `agent_hooks_preview(agent, install)` returning `{diff, fingerprint, backup, settingsPath, hookPath, hookReady}`, and `agent_hooks_apply(agent, install, fingerprint)` returning the backup path. Only whitelist the three supported agent IDs; never accept arbitrary paths from the UI.

- [ ] **Step 1: Write failing Rust temporary-directory tests for config parsing and writes.** Kimi and Codex TOML plus Hermes YAML must preserve unrelated entries; cover invalid encoding/config, idempotent reinstall, remove-only-Coucou uninstall, no-file case, whitespace/quotes in paths, overlong Windows command, changed fingerprint, and byte-for-byte backup. A second same-second operation must not overwrite the first backup. Pin an Orca-managed Kimi block that survives install and removal.
- [ ] **Step 2: Run `cargo test --workspace`; confirm the precise config ownership tests fail.**
- [ ] **Step 3: Implement source-specific config merge/formatting with no shell execution at install time.** Codex uses `[[hooks.Stop]]` with a nested `[[hooks.Stop.hooks]]` and quoted `command_windows` calling the relay; Kimi uses `[[hooks]]` and a `Notification` matcher for `task.completed`; Hermes uses `hooks:` YAML for turn and finalization events, with an explicit translator. Check parser availability before adding dependencies; preserve unrelated comments/blocks rather than serializing them away. Parse before backup, recheck fingerprint, use an adjacent temporary file and atomic replace where supported, and refuse uncertain config.
- [ ] **Step 4: Expose typed commands and add one UI section per source.** Distinguish available, configured, Codex and Hermes trust-not-yet-verified, and live-event-seen; show exact diff then a confirm action. No hooks are installed merely on Coucou startup. A canceled preview has no side effect.
- [ ] **Step 5: Run `cargo test --workspace` and `npm run build`; manually preview, cancel, install, restart each CLI, and uninstall in a temporary profile before touching the real user config.** Verify an existing unrelated hook survives every operation. Do not turn on Codex or Hermes auto-trust: guide the user through each provider's consent UI.

### Task 5: Windows Delivery and Documentation

**Files:** Modify `docs/AGENTS.md`, `windows/README.md`, and stale nearby code comments.

**Interfaces:** User-facing setup and troubleshooting instructions for Task 1-4; no new API.

- [ ] **Step 1: Correct `docs/AGENTS.md:5-10,27-79`.** Document invalid tagged-name rejection, exact session identity and lifecycle, external approvals remaining in their originating CLIs, and observer-only delivery.
- [ ] **Step 2: Update `windows/README.md` with opt-in preview/install/trust steps and tested CLI version range; state unavailable or untested adapters honestly.** Note Claude Code works in VS Code and standalone terminals if the real test verifies it.
- [ ] **Step 3: Run `cargo test --workspace`, `npm run build`, and `npm run pack` from `windows/`.** Install the produced current-user setup only after confirming its actual destination and package contents; avoid overwriting an active executable. Confirm the installed relay and app versions match the built artifacts. Exercise real Windows sessions for each available agent (start, prompt, tool, stop and teardown), two simultaneous sessions of one agent, Claude approval in VS Code and terminal, Coucou closed/paused, and invalid payload/config. Observe the finish sound and island state; report any provider requiring outstanding trust or a test that cannot run as unverified, never as complete.
