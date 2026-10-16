# Native main-session attention (experimental, opt-in)

Coucou can show a read-only reminder when a **main desktop chat** of Codex or
OpenCode is waiting for the user: a pending permission in OpenCode, an accepted
question or a human-reviewed permission in Codex. The card only opens the
native app and deep-links the Codex thread; **it never approves, denies or
answers anything, and it never mutates the agents' own stores or settings.**

This feature is **off by default** and opt-in (`AppState.nativeAttentionEnabled`,
persisted, GitHub/non-App Store build only). With it off, nothing launches: no
reader process, no timer, and every hook keeps its shipped lifecycle — Codex
permission requests still get the regular blocking approval card. Snapshots
from a stale reader are ignored while the feature is off.

## Scope

- `mainSessionAttentionOnly` (default `true`, persisted): verified **Desktop
  root** sessions only. When set to `false`, the reader is relaunched with
  `--include-child-sessions`.
- Include-child mode widens only the real metadata: a Codex child transcript
  must carry the actual `thread_spawn` chain — `thread_source` `subagent`,
  `id` = the child session, `session_id` = the parent session, and
  `source.subagent.thread_spawn.parent_thread_id` naming that same parent,
  still spawned by the `Codex Desktop` originator (the index query admits
  `subagent` rows only in this mode). Guardian, memory and every other origin
  are rejected in both modes. OpenCode sessions must still be viewed,
  unarchived and active — only the `parent_id IS NULL` restriction is dropped.
  Origin is **never** inferred from a cwd or a title.

## Architecture

- `MainSessionAttentionController` (Swift) launches
  `Resources/attention_bridge.py` via `/usr/bin/python3` (3.9), feeds it hook
  hints over a pipe, and reconciles atomic snapshots into
  `MainSessionAttentionQueue`. Its expiry timer exists **only while an entry is
  on the card**; a dead reader is relaunched with exponential backoff (bounded
  at 5 attempts) and the pending list is cleared on death or disable.
- `HookServer` forwards Codex hook payloads to the reader as hints **only when
  the feature is enabled**, and answers Codex `PermissionRequest` with `ask`
  immediately so Codex's own reviewer UI proceeds; every other Codex event also
  continues through the normal lifecycle pipeline. OpenCode events keep their
  external-agent routing in every mode, and no OpenCode questions are answered
  here.
- `attention_bridge.py`:
  - **Codex**: reads the private `state_5.sqlite` index (read-only) for
    candidate transcripts, then verifies each rollout's `session_meta`
    (root metadata, or the real `thread_spawn` chain in include-child mode).
    Questions require an accepted `request_user_input[_async]` call and match
    native widget replies; permissions come from hook hints re-verified
    against the transcript (turn, per-call reviewer marker, tool completion).
  - **OpenCode**: GET-only loopback `/api/session/<id>/permission` per viewed
    candidate session. The service password never leaves the process; no
    proxies, no redirects, loopback only. The native pending list is the truth
    — the SQLite index is only used to discover candidates. Because
    `permission.asked` lives in server memory, not SQLite, an active viewed
    candidate session is re-queried at most every 3 s even after an empty GET
    with no database change; **idle means no active candidate sessions**,
    nothing pending and no outstanding query.
  - The loop (`AttentionLoop`) drains hook hints at the top of every pass,
    before the snapshot: a permission that just arrived on the pipe is
    emitted in that same pass, with no filesystem event in between. Hook
    hints reconcile independently of the index — an absent or locked catalog
    never hides an already-verified native request.
  - `SourceWatcher` sleeps on `select.kqueue` `EVFILT_VNODE` filters
    (registered with `EV_ADD|EV_CLEAR`, so an unchanged source does not keep
    waking the loop) over read-only descriptors: Codex index/WAL, current
    transcripts and their source parent directories, OpenCode index/WAL and
    service parent directory; nearest existing parent for an absent file.
    Idle means zero periodic scanning; bursts are coalesced to ≤4 source
    checks/s, pending requests refresh the lease at least every 8 s, and
    outstanding OpenCode queries use a short bounded wait. `update()` closes
    every watch descriptor and re-opens the current set, recovering
    replacement and creation.

## Local native acceptance

Validated on macOS against Codex Desktop/CLI `0.162.0-alpha.17.2` and OpenCode
`2.0.30`. The Debug app used a separate bundle identifier and isolated
`/private/tmp/coucou-attention-smoke-*` socket, with normal integrations disabled.
The vendor installation, production Coucou socket and native agent settings
were not replaced.

- A real question in the current main Codex Desktop chat appeared on the actual
  island card with the correct question text. The user confirmed seeing it;
  replying cleared the reminder. `Back to chat` successfully opened the Codex
  URL and dismissed the card. The destination chat was not inspected through
  automation, so exact destination selection remains a manual check.
- A real OpenCode main Desktop session called Shell in a disposable directory
  and waited at the native permission UI. Its native pending request reached
  the compiled app's Swift queue, then cleared after the user manually chose
  Allow; the harmless printf marker completed. No permission response was sent
  by the reader. `Open OpenCode` was separately verified on an explicitly
  labelled UI fixture card; it opened OpenCode and dismissed the reminder.
- The compiled-app headless socket test verified immediate `ask`, snapshot
  deduplication and clearing, and an unchanged production socket inode.
- Both NotchBuddy and CoucouAppStore Debug builds passed. Existing approval,
  question, session-registry and auto-close suites also passed.

![Rendered component preview](images/native-attention-preview.png)

The image uses fixture text and is a component preview, not native pending
request evidence. Native acceptance above was performed on the compiled island.

## Evidence limits and assumptions

- Codex **0.162** private transcript/index format (`state_5.sqlite`,
  `sessions/*.jsonl`, `has_user_event=0`) and OpenCode **2.0.30**
  (`session_v2`, local `service.json`) are private formats verified against
  the local root-session scenarios above; either app may change them without
  notice. The include-child `thread_spawn` chain has fixture coverage but was
  not re-validated with a newly spawned live child during acceptance.
- OpenCode "viewed" (`time_viewed`) is a heuristic for "the user cares about
  this session", not a guarantee.
- Codex approvals can be reviewed **per call** (`approvals_reviewer` per turn);
  MCP tools are conservatively excluded because per-call reviewer state for
  MCP calls could not be confirmed. The per-call reviewer check only bounds
  which hook hints are considered — it does **not** prove that a real, visible
  human prompt is shown in the native app.
- Codex Desktop's actual human approval UI remains unverified for this reminder
  feature; its main-session questions and OpenCode's native Allow path were
  exercised above. The separate auto-review relay fix has native CLI approval
  coverage. Do not treat a PermissionRequest hint alone as proof of a visible
  human prompt.
- Discovery is bounded to 100 recent candidates per app and 96 watched source
  paths. Unreadable, unknown or unverified native state produces no reminder.
- The GET-only loopback permission query is the only service access; no new
  remote service is added.

## Guarantees

- Never approves, denies or answers; never writes to Codex/OpenCode state.
- Default off: no reader, no timers, shipped lifecycle and cards preserved.
- Every hint from the hook relay is independently re-verified against the
  transcript before a reminder is shown.
- The DEBUG headless smoke test (`--attention-smoke-test`) runs against an
  isolated `/private/tmp/coucou-attention-smoke-*` directory only: it accepts
  synthetic snapshots without starting the real reader, keeps the fail-closed
  path for invalid directories, and never touches the production socket
  (inode-guarded) or profiles. Adding `--show-native-attention` uses the real
  read-only reader and island for manual acceptance, still with that isolated
  socket; the flag fails closed without a valid smoke-test directory and is
  absent from App Store builds.

## Tests

`scripts/test-main-session-attention.sh` runs:

- `tests/test_attention_bridge.py` — reader/permission/OpenCode unit tests
  (Python 3.9, stdlib only), including the real thread_spawn include-child
  scope, source-loss pruning, the loop contract (a pipe hint wakes the loop
  and is emitted with no filesystem write; EOF exits) and the memory-only
  OpenCode pending transition;
- `tests/test_attention_watch.py` — kqueue watcher tests (idle sleep past the
  coalescing window, change, creation, replacement, update, stdin, coalescing);
- `tests/MainSessionAttentionTests.swift` — queue lifecycle, isolation,
  safe navigation and the disabled-by-default route/snapshot policy, compiled
  with the app's model file.

The compiled-app smoke test lives in `tests/smoke_attention_socket.py`.
