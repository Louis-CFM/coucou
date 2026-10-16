# Review fixes (2026-10-11) — Implementation Plan Index

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix every bug, invariant risk and cleanup item from the 2026-10-11 full-codebase review of the `feat/phone-android` branch, without changing how any shipped view looks.

**Architecture:** Six phase plans, one per subsystem. Each phase ships on its own and keeps old clients working. Phase 1 (relay) goes first because Phases 3 and 4 send new fields to it. Each phase's tasks are TDD: a failing test, the minimal fix, then a passing test. Logic that only runs on a device or in a GUI is pulled out into small pure functions, so a test can cover it.

**Tech Stack:** Rust 2021 / Tauri 2 / tokio (Windows/Linux app and `coucou-hook`), TypeScript + `node --test` (island), TypeScript Cloudflare Worker + Durable Objects (relay), Kotlin + Jetpack Compose (Android), Swift 6 + `swiftc` script tests, Python 3 `unittest` (Mac relay script).

**Spec:** The review delivered in the session of 2026-10-11 (Sections 1 dead code, 2 correctness, 3 improvements). Finding IDs (C1…C20, D1…D5, V1…V15) are quoted in each task so a reviewer can trace it.

## Phases (do them in this order)

| Phase | File | Fixes | Verified by |
|---|---|---|---|
| 1 | [phase-1-relay.md](phase-1-relay.md) | quota burn on `take`, body caps, one-phone claim, dead FCM tokens, multi-select on the wire, `pair` rate limit | `cd relay && npm test && npm run typecheck` |
| 2 | [phase-2-windows-rust.md](phase-2-windows-rust.md) | settings clobber (C1), re-pair wipes secret (C4), dropped trailing push (C5), idle phone loop, keychain/HTTP reuse, log rotation, session-reader hardening (C9, C10, C13), hook stdin + budget (C15), pipe release + ordering (C17), main-thread commands (C18), drop-zone wakeups | `cd windows && cargo test --workspace` |
| 3 | [phase-3-windows-island.md](phase-3-windows-island.md) | red i18n test, alert-first phone push, push dedupe, remote-chat allowlist and in-flight guard, multi-select answers, late-event guard, released cards | `cd windows && npm test` |
| 4 | [phase-4-android.md](phase-4-android.md) | FCM token re-claim (C3), work inside the FCM window, notification expiry + unlock for Allow (C12), multi-select answers (C8), encrypted pairing secret, urgency parity, chat autoscroll, idle Mochi frames, process-death screen | `cd android && ./gradlew :app:testDebugUnitTest` (+ device checks listed per task) |
| 5 | [phase-5-mac.md](phase-5-mac.md) | APNs retry loop (C2), hook server accept loop (C6), 5.2 s idle timer (C7), relay ack fast-fail (C16), relay truncation, single Python template, `nb-hook` marker (C20), instruction watchdog | macOS CI: `scripts/test-*.sh` + `python3 -m unittest tests/test_nb_hook.py` + `xcodebuild` |
| 6 | [phase-6-cleanup.md](phase-6-cleanup.md) | dead code D1–D5, stale comments/docs, session plumbing table | all of the above suites |

**Branch:** create `fix/review-2026-10` from `feat/phone-android` (preferably in a worktree, see superpowers:using-git-worktrees). Commit after every task.

> ⚠ `docs/` is the GitHub Pages root (`docs/.nojekyll`), so anything committed under `docs/` is published. These plan files describe vulnerabilities that are not fixed yet, so keep them uncommitted (or move them outside `docs/`) until Phases 1–5 have shipped.

## Global Constraints

Copied from `CLAUDE.md`. Every task in every phase must respect them:

- Swift 6, SwiftUI + AppKit. **No third-party dependencies unless truly unavoidable.** (A Gradle `testImplementation("junit:junit:4.13.2")` for Android unit tests is the one test-only exception this plan takes. Enabling tokio's `macros` feature is not a new dependency.)
- **Secrets live in the Keychain** (OS secure storage), never on disk or in git.
- **No telemetry.** Network calls only to services the user configured.
- **Never block Claude Code:** if the app doesn't answer, the hook exits immediately.
- **Never overwrite `~/.claude/settings.json`:** dated backup, merge, show the diff, write only after the user confirms.
- **Never send an email or approve a Claude Code or Codex permission without an explicit click.** Nothing in this plan may print an allow without a human decision.
- **Performance: 0 % CPU when the island is hidden.**
- Keep the bundle identifier `fr.louisraille.NotchBuddy`.
- **Never restyle what already ships.** Changes to an existing view are behaviour fixes, with no visual change. New UI follows the existing style.
- **Pill IDs are stable contract values.** Never rename one.
- `NotchBuddy/project.yml` is the XcodeGen source: never edit the `.xcodeproj` by hand.
- Windows/Linux strings: every string in `windows/src/i18n/*.json` must exist in every language (`windows/tests/i18n.test.mjs` enforces it). **This plan adds no new user-facing string on Windows/Linux.** Messages that already exist only in English (`phone.ts`, the `*_sessions.rs` errors) stay in English.
- Old clients keep working. The relay must accept requests from the PC and phone builds of today, and the Mac app must accept an `nb-hook.py` written by an older build (the App Store build only rewrites it when hooks are reinstalled).
- Releases (CHANGELOG section, README Versions row, regenerated Info.plist) are **not** part of this plan. Do them when cutting the next release.

## Cross-phase contracts

These wire formats are defined once here. The phases that produce or consume them repeat the exact shapes.

1. **Question card (PC → relay → phone):** `awaiting.questions[i] = { q: string, options: string[], multi: boolean }`. Produced by Phase 3 Task 3.2, stored by Phase 1 Task 1.5, read by Phase 4 Task 4.4.
2. **Question answer (phone → relay → PC):** `answers: Record<string, string | string[]>`. A string answers a single-select question, a non-empty list a multi-select one. Produced by Phase 4 Task 4.4, clipped by Phase 1 Task 1.5, forwarded by Phase 3 Task 3.2, validated by the existing `windows/hook/src/reply.rs::answers_fit`.
3. **Claim (phone → relay):** `{ id, secret, token, name, device }`, where `device` is 32 lowercase hex characters generated once per pairing on the phone. Defined by Phase 1 Task 1.3 and sent by Phase 4 Task 4.1. A box that is already paired returns **409** to any other `device`.
4. **Hook timestamp (relay process → island):** `coucou_ts: number` (milliseconds since the Unix epoch) on every forwarded hook payload. Produced by Phase 2 Task 2.11, consumed by Phase 3 Task 3.3.
5. **Released request (Rust → island):** event `approval-released` with payload `{ requestId: string }`, emitted when a held PermissionRequest ends without a decision (relay gone or timed out). Produced by Phase 2 Task 2.12, consumed by Phase 3 Task 3.3.
6. **Phone push result (Rust → island):** the `phone_state` command returns `bool`, where `true` means delivered (or deliberately skipped because no phone is paired). Produced by Phase 2 Task 2.3, consumed by Phase 3 Task 3.1.
7. **Mac relay ack (app → nb-hook.py):** the relay adds `"coucou_ack": 1` to PermissionRequest and `--ask` payloads. When it does, the app writes the line `{"ack":true}` the moment the card is up, and the relay gives up after 1.5 s without it. Defined in Phase 5 Task 5.4.

## Review Focus

These are the five failure modes most likely to bite a real user that no single task naturally exercises. Each has a pinned test in the owning task, listed in brackets.

1. **Mixed versions.** The new app meets an older relay or `nb-hook.py`, or the new relay meets an older phone. Expected: degrade to "ask in the terminal" / "no alert", never an allow and never a crash. [Phase 5 Task 5.4 `test_an_immediate_answer_without_ack_still_counts`; Phase 5 Task 5.4 `HookAckTests` (no `coucou_ack` → no ack written); Phase 1 Task 1.3 "a box paired before device ids existed is taken by the first phone that sends one"]
2. **The relay or network is down while a card is up.** Expected: the PC stops waiting at its normal deadline, the phone's buttons stop offering a decision that can no longer land, and the next state change retries the alert. [Phase 3 Task 3.1 "an alert that did not get through is sent again with the next change"; Phase 4 Task 4.3 (notification TTL, device check)]
3. **Late or out-of-order hook events from the same session.** Expected: a turn that is over stays over. [Phase 3 Task 3.3 "a tool event older than the turn's Stop does not wake the pill back up"]
4. **Paths and prompts with spaces, quotes, `-`, line breaks and non-ASCII text** (Windows usernames, French project names, pasted multi-line prompts). Expected: the session runs with the text as typed (line breaks become spaces only for `.cmd` launchers). [Phase 2 Task 2.8 `a_prompt_never_reads_as_an_option` incl. `é` and `\r\n`; Phase 2 Task 2.9 torn-UTF-8 transcript test]
5. **Huge histories.** A 10 MB+ JSONL session, a `session_meta` line over 64 KiB, an OpenCode session with thousands of parts. Expected: the picker and transcript still answer, and only the tail is read. [Phase 2 Task 2.9 `a_long_session_is_read_from_its_end` and `a_huge_session_meta_line_still_names_the_session`; Phase 2 Task 2.10 `only_the_last_parts_are_read`]

## Deferred (needs a product decision or on-device validation; not in any phase)

- **`keep_topmost` (Windows, `platform/windows.rs:364-372`)** wakes every 2 s, even while hidden. An event-driven replacement (`SetWinEventHook(EVENT_SYSTEM_FOREGROUND)`) needs testing on a machine with a topmost status bar before it replaces a fix that shipped for a real bug.
- **True 0 % for the hidden-island drop watch.** Phase 2 Task 2.14 cuts it from 20 wakeups/s to about 8/s and to zero while the island is open. Getting to zero needs an OLE/WinEvent design.
- **`/v1/live-activity` authentication.** Shipped Mac/iPhone builds call it without credentials. Adding auth needs a coordinated app release.
- **Mac single-slot approvals vs. the Windows FIFO queue.** Porting the queue is a feature, not a fix.
- **Whether `claude -p --resume <id>` keeps the same session file.** If it forks a new id, the phone transcript never shows the answer. Verify on a machine with Claude Code; if it forks, show the `resume` reply text in the transcript.
- **A size cap for dropped files** (`files.rs::ingest`). Phase 2 Task 2.13 moves the copy off the UI thread. A cap needs a new message translated into 10 languages.
- **A separate opt-in for phone-started CLI runs on Windows/Linux.** The Mac has one, `iPhoneInstructionsEnabled`, off by default. Phases 2–3 add id validation, the offered-sessions allowlist and the one-run-per-session guard; the toggle itself needs a new translated Settings string.
- **C11 — killing a timed-out CLI run with its children.** `cli_chat.rs:55` `kill_on_drop` stops only npm's `.cmd` shim, and `node` lives on. A fix means a Windows Job Object or a Linux process group per run.

## Left as they are (low severity, by decision)

- `pipe.rs:189` has no read timeout. The only client is `coucou-hook`, which has its own deadline.
- `pipe.rs:347-350` maps an unknown decision to `deny`. That is fail-closed, and the island only sends allow/deny.
- `"always"` handling in `reply.rs`, `pipe.rs` and `recap` is kept for parity with the Mac relay, which uses it.
- The session window snapshot is still lost when a fire-and-forget relay exits before it (Phase 2 Task 2.12 only moves it after the event).
- `hook/src/main.rs:227` names the field `session_pid` but fills it from `CLAUDE_CODE_SSE_PORT` (naming only).
- `agents.rs:59` double-quotes the relay path for Git Bash, so `$` in a Windows username would expand.
- Android: concurrent `refresh()` calls can apply an older answer last, and `pair()` accepts any URL scheme (cleartext is blocked by the target SDK anyway).
- The Windows bundle ships the Mac-only strings that `gen-strings.mjs` copies from the Mac catalog.
- The duplicated editor-launch code in `lib.rs` (`open_in_vscode` vs `open_session`).
- The relay's `take` is at-most-once: a PC that crashes mid-drain loses those phone messages.
