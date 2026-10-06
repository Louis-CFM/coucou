# 1.0.0 Lighto Edition — divergence from upstream Coucou 0.1.7

What this build changed on top of upstream `0.1.7`, and why.

- **Upstream base:** `0.1.7` (`Louis-CFM/coucou` @ `v0.1.7`, commit `2d3a169`)
- **This tree:** `C:\Users\msi\coucou`, version `1.0.0` — *1.0.0 Lighto Edition, 0.1.7 base*
- **Diff basis:** file-by-file comparison against upstream 0.1.7

Upstream 0.1.7 is the comparison base for this audit. The agent/Pi sections below record
the original 1.0.0 divergence; the current Windows tree has since gained a substantial
Desktop Mochi port and other follow-up work, summarized in §10. The macOS Desktop Mochi
implementation remains the behavioral reference; Windows has its own Tauri/WebView
implementation. Wardrobe, greetings, live file-edit tickers/diffs and expanded GitHub
integration remain upstream unless noted elsewhere.

---

## 1. Scope of the original agent-support change

The following counts describe the original agent-support audit, not the current total
working-tree diff. Later work (including Desktop Mochi) is recorded in §10.

25 source files differed from upstream at that audit. Of those:

| Category | Files | What |
|---|---|---|
| Real agent work | 14 | The Pi / Copilot / Antigravity support described below |
| `cargo fmt --all` only | 10 | Reformatted, **zero behaviour change** |
| Docs & metadata | 6 | Version, changelog, agent docs |

At that historical audit, 20 files under `windows/src`, `windows/src-tauri/src`,
`windows/hook/src` and `windows/scripts` were byte-identical to upstream, including
`src/views/chat.ts`, `src/views/ticker.ts`, `src/views/upload.ts` and `src/views/dom.ts`.
That statement does not describe the current tree: `src/mochi/` now contains the Windows
Desktop Mochi renderer and shared animation changes.

### The 10 formatting-only files

`cargo fmt --all` was run, and these upstream files were not rustfmt-clean, so they were
reformatted. Verified by re-formatting pristine upstream copies and confirming the result
is byte-identical to what's in this tree:

```
src-tauri/src/claude.rs          src-tauri/src/island.rs
src-tauri/src/integrations.rs    src-tauri/src/files.rs
src-tauri/src/pipe.rs            src-tauri/src/log.rs
src-tauri/src/platform/linux.rs  src-tauri/src/platform/windows.rs
hook/src/unix.rs                 hook/src/win.rs
```

Cosmetic only. Worth knowing because it inflates the apparent diff — `platform/windows.rs`
shows `+6/-4`, which is entirely import reordering and line wrapping.

---

## 2. Agent support: what was built

Upstream 0.1.7 knows one agent shape — Claude Code's `~/.claude/settings.json`, where
Coucou merges its own entries into a matcher map. This build generalises that to four
agents, each with **its own file, its own pill, and its own hook dialect**.

### The core change

`src-tauri/src/hooks.rs` went from single-agent to agent-parameterised. `status()`,
`preview()` and `write()` all take an `agent: &str`; `settings_path_for_agent()` resolves
where that agent lives. Hook commands are now emitted with an `--agent <name>` tag
(`hook_command(agent, event)`), which is how an event finds the right pill.

| Agent | Config file | Install shape |
|---|---|---|
| Claude Code | `~/.claude/settings.json` | upstream matcher-map merge |
| Copilot CLI | `~/.copilot/hooks/coucou.json` | flat `exec`/`args`/`timeoutSec` |
| Antigravity | `~/.gemini/config/hooks.json` | matcher map, Antigravity event names |
| Pi | `~/.pi/agent/extensions/coucou.ts` | **a file that is written / removed** |

One agent writing to another's file was the main hazard: a single shared path would let
installing Copilot clobber Claude Code's hooks. There is a test asserting no two agents
resolve to the same path (`every_agent_gets_its_own_settings_file`).

---

## 3. Per-agent detail

### 3.1 Pi

**Install model is different.** Pi loads TypeScript extensions, not a settings map. So for
Pi, "install" means writing one file and "uninstall" means removing it — there is no merge,
and nothing of the user's lives in that file. `pi_extension_code()` substitutes the relay's
real path into the source at write time (placeholder `__COUCOU_HOOK_EXE__`, JSON-escaped)
rather than hardcoding `%USERPROFILE%\AppData\Local\...`, which silently breaks under a
redirected `LOCALAPPDATA`. The same substitution is what makes the extension correct on
Linux, where the relay is `coucou-hook`, not `.exe`.

**Ownership, and why reinstall is safe.** `HookStatus` gained a `managed` flag, true only
when the file on disk is byte-for-byte what Coucou generates. An extension you have edited
is yours, and Coucou will not overwrite or delete it:

| State | Install | Uninstall |
|---|---|---|
| absent | writes Coucou's extension | no-op |
| == Coucou's | rewrites (idempotent) | removes |
| **yours / edited** | **refused** | **refused** |

Three layers, so it cannot be bypassed: the Settings UI renders **no** install/uninstall
button and says why; the preview shows an explanation instead of a misleading `+`-only
diff; and `pi_write` refuses before touching anything. Pinned by
`coucou_never_overwrites_or_deletes_an_extension_it_did_not_write`.

**Permissions — the part that was actually broken.** See §5.

Events emitted: `session_start`, `session_shutdown`, `before_agent_start`,
`turn_start`, `message_update` (debounced keep-alive), `tool_execution_start`,
`tool_execution_end`, `turn_end`, `agent_settled`. `agent_settled` walks
`ctx.sessionManager.getEntries()` and reports a per-turn tool-call summary; Pi's summary
beat carries its text in `tool_input.note`, so `stepLabel` reads `note` instead of
rendering a bare row reading "summary".

### 3.2 Copilot CLI

Copilot's config is a **flat** object rather than a matcher block, so its entries carry
`exec` / `args` / `timeoutSec` directly and do not nest a command:

```json
{ "type": "command", "exec": "...coucou-hook.exe", "args": ["--agent", "copilot", "PreToolUse"], "timeoutSec": 10 }
```

`entry_is_ours()` had to learn a second shape — it now matches a flat `exec` string as well
as a nested `hooks[].command`, so uninstall removes exactly Coucou's entries and leaves the
user's. Events (`COPILOT_HOOK_EVENTS`): `SessionStart`, `SessionEnd`, `UserPromptSubmit`,
`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `Stop`. Only
`PermissionRequest` gets the long 120s timeout; everything else is 10s so a hung relay can
never stall a tool call.

### 3.3 Antigravity

Antigravity (`agy`) nests hooks like Claude Code, so the matcher shape carries over — only
the event names differ. Two tables are installed together:

- `ANTIGRAVITY_HOOK_EVENTS` — `PreInvocation`, `PreToolUse`, `PostToolUse`, `PostInvocation`, `Stop`
- `ANTIGRAVITY_LIFECYCLE_EVENTS` — `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Stop`

The second table is deliberate: older Gemini/agy builds emit the legacy lifecycle names, and
installing both means a session is never half-tracked on a build that only speaks one of
them. Uninstall is asserted to restore the file exactly.

### 3.4 Claude Code

Upstream behaviour is preserved as-is. The only changes are mechanical: the
`--agent claudeCode` tag on generated commands, and agent-aware plumbing through the
bridge, settings and UI. Existing hooks installed by an older build carry no tag and land on
the Claude pill unchanged — that is the backwards-compatibility path.

### 3.5 Other models — third-party `coucou_agent` pills

Unchanged from upstream, deliberately. Any agent sending a valid `coucou_agent` that is not
one of the four above gets its own auto-created pill with a generated colour, and its pill is
**removed when the session ends**. `PermissionRequest` from such a pill is declined
immediately: it does not block on the relay, so showing a card would hang it forever on a
decision it never receives.

The distinction is explicit in code — `DECLARED_AGENTS` (Pi, Copilot, Antigravity) versus
`isTransient` third-party pills. Declared pills keep their name and colour and reset to idle
at session end rather than disappearing.

---

## 4. Frontend and UI changes

- **`core/state.ts`** — three declared pills added (`agent_pi` `#8B5CF6`, `agent_copilot`
  `#58A6FF`, `agent_antigravity` `#E879F9`, same ids/colours as macOS);
  `ApprovalInfo.agentId`; `Settings.activeAgent`; `hooksInstalledByAgent` +
  `isAgentHooked()`.
- **`island/hooks.ts`** — declared-agent routing. The approval card, its badge and every
  state write now use `req.agentId` instead of a hardcoded Claude id. Previously a Pi
  approval would light up the Claude pill.
- **`island/island.ts`** — `decide()` clears state and badge on `req.agentId`.
- **`island/integrations.ts`** — `refreshHookStatus()` asks Rust per agent; `configured` for
  a hook pill now reflects real installation state instead of being hardcoded `true`.
- **`views/views.ts`** — the status dot is green only when something is really listening,
  amber while unknown. Previously it was green unconditionally, which was a decoration that
  lied about uninstalled hooks.
- **`views/integrations.ts`** — `agentCard()` for agent pills; Pi's internal `generating` and
  `turn_complete` keep-alive beats filtered out of the step list.
- **`settings/main.ts`** — the Claude section became an **Agents section**: a picker over
  Pi / Copilot CLI / Antigravity / Claude Code, each with its own status, diff preview,
  backup and fingerprint guard.
- **`core/bridge.ts`** — `hooksStatus` / `hooksPreview` / `hooksApply` take an optional agent.
- **CSS** — `.int-rows.agent-rows` (bounded, scrollable step log) in `style.css`;
  `.seg` segmented control in `settings.css`.

---

## 5. The Pi permission bug, and the final architecture

**This was the substantive fix, and it was not in the repo — it was in the user's Pi
install.**

### Symptom

Permission prompts never got answered from the island. The request waited **800ms** for a
human to notice a card and click Allow:

```js
const timeoutPromise = new Promise((r) => setTimeout(() => r(null), 800));
const result = await Promise.race([decisionPromise, timeoutPromise]);
```

Nobody clicks in 800ms. Nearly every request fell through to Pi while the Coucou card was
still on screen, unanswered — Coucou looked broken exactly when it was working. The relay
itself holds the connection open for 110s, so Coucou was asking 137× faster than Pi was
willing to wait.

Two adjacent faults: `if (!ctx.hasUI) return { block: true }` hard-denied every
`bash`/`write`/`edit` in print and JSON mode; and per Pi's docs *"a `tool_call` handler
failure blocks the tool as a fail-safe"*, so any throw in that handler was itself a denial.

### Root cause: two extensions answering one decision

`pi-permission-system` v0.8.0 is installed and owns permission decisions. Coucou's extension
was **also** registering a `tool_call` handler and asking. One decision, two cards, two
answers.

### Final architecture — one asker

```
pi-permission-system  ──asks Coucou first──▶  coucou-hook  ──▶  island card
        │                                                    
        └── Coucou silent / closed / timeout ──▶ Pi's own dialog
```

`pi-permission-system` is the single asker, because it is the thing that knows Pi's rules.
`coucou.ts` no longer registers a `tool_call` handler at all and only observes — sessions,
tool calls, completion. The shipped extension in the repo does the same, and a test asserts
it never re-registers `tool_call` or carries its own `COUCOU_TOOLS` allowlist.

The timeout is now **110s**, matched to the relay's `DECISION_BUDGET`, and the rule is
**fail open**: Coucou closed, relay missing, empty or unrecognised answer, timeout, or any
exception all return `handled: false` → Pi's dialog, unchanged. Coucou-closed is still
detected instantly, because the relay exits immediately when the pipe is absent — so the
long budget costs nothing when Coucou isn't running.

### Two files outside this repo

These live in the user's Pi install and are **not** shipped in the installer:

| File | Change |
|---|---|
| `~/.pi/agent/npm/node_modules/pi-permission-system/src/index.ts` | forwarding re-implemented (110s, fail-open, `existsSync` probe) |
| `~/.pi/agent/extensions/coucou.ts` | `tool_call` handler removed; `event.text` → `event.prompt`; factory typed `ExtensionAPI` |

The first lives in `node_modules` and **will be clobbered by `npm update`**. Made durable by
`~/.pi/agent/scripts/patch-coucou-permissions.mjs` — idempotent, version-tolerant, re-runnable
after any update.

Backups: both files saved as `*.20260410-before-coucou-permission-fix.bak`.

### A third bug, found by typing it

`coucou.ts` typed its factory as `pi: any`, which hid
`event.prompt || event.text` — `BeforeAgentStartEvent` has **no** `text`, so the prompt
ticker always sent `undefined`. **The same bug was in the repo's shipped extension**, caught
only because the generated code was extracted and typechecked against real Pi 1.0.2
`types.d.ts`. Both fixed; both now typecheck clean.

---

## 5a. Permission outcomes beyond Allow / Deny

Upstream 0.1.7 renders exactly two buttons and the action type is binary. That was deliberate
(`views.ts`: *"Always" is gone until the remembered-rules list exists to back it*), but
`pi-permission-system` actually speaks six states:

```ts
type PermissionDecisionState =
  "approved" | "denied" | "denied_with_reason" | "once" | "always" | "reject";
```

Binary was enforced in **six independent places**, and two of them *deliberately* collapsed a
third option — `"allow" | "always" => "allow"` appeared in both `pipe.rs` and the relay.
Three states are now reachable.

### Deny with a reason — `denied_with_reason`

Worth having: a plain denial gives the model nothing to correct against.

- Island: a **Why not?** button reveals a text field; Enter denies with the note,
  Escape clears it. An empty note never becomes a blank-string reason — it falls back to a
  plain deny.
- `decide(d, note?)` → `bridge.approvalDecision(id, d, note)` → `pipe::answer(..., note)`
  → relay emits `{"behavior":"deny","message":"<the human's words>"}`.
- Previously the relay hardcoded `"message":"Denied from Coucou"`, so the channel existed but
  never carried anything the human wrote.

### Always — `always`

The island's **Always** (A) now emits `{"behavior":"allow","always":true}` instead of being
folded into a plain allow.

- `parseCoucouDecision` returns an `always` flag; `persistSessionApprovalDecision` is called
  with `state: coucouResult.always ? "always" : "once"` at both approval branches, so it lands
  in `sessionApprovals.approveAlways(...)` for the rest of the session.
- **Claude Code ignores the scope** — it reads `behavior` and nothing else, so for Claude
  Always degrades to an ordinary Allow rather than doing something it cannot honour.
- The skill branch (the third call site) has no persistence plumbing and returns `{}` on
  approve, so Always behaves as Allow there. Not claimed otherwise.

### YOLO mode — Coucow is not asked at all

`tryCoucouPermissionRequest` now checks `isYoloModeEnabled(extensionConfig)` **first** and
returns `{ approved: true, handled: true }` without spawning the relay. Rationale: yolo means
"approve without asking", so putting a card on screen for a decision already made globally
would be a rubber stamp at best, and toggling yolo would otherwise leave a stale card up.

This mattered because yolo was consulted at `index.ts:1306/1722` while the three Coucow calls
sit at `2148/2244/2378` — *after* those checks — so the later paths were reachable with yolo
on. The guard inside the single function covers all three call sites at once.

### The wire format is backward-compatible

`pipe::answer` now sends JSON rather than a bare word, but `coucou-hook` accepts **both**:

| Input | Result |
|---|---|
| `{"behavior":"deny","message":"..."}` | used as-is, note preserved |
| `allow` / `always` (bare word) | `{"behavior":"allow"}` |
| anything unrecognised | prints nothing → caller falls back |

An older relay paired with a newer island, or the reverse, degrades instead of breaking. The
existing test `a_permission_decision_that_is_not_allow_or_deny_prints_nothing` still guards the
silence case.

---

## 5b. A silent-failure bug in the patch mechanism itself

While hardening `patch-coucou-permissions.mjs`, three defects were found in the mechanism that
was supposed to survive `npm update`. All three failed *silently* — the script reported success.

1. **Brace matching stopped inside the signature.** The return type is
   `Promise<{ approved: boolean; ... }>`, so the type literal's braces come *before* the body's.
   Counting from the function name therefore ended the replacement at the type literal, leaving
   the real body untouched. Now anchored on the **column-0 `}`** — the function is top-level, so
   its closing brace is unambiguous and nested blocks are all indented.

2. **The "already patched" marker was too coarse.** It matched on the presence of
   `COUCOU_PERMISSION_TIMEOUT_MS`, which an *older* patch also contains — so running the script
   over an older patch reported success and upgraded nothing. Now keyed on
   `COUCOU_PERMISSION_PATCH_REV = 2`, which makes "already current" mean what it says and lets an
   older patch be upgraded in place.

3. **The import was never patched.** The block calls `isYoloModeEnabled`, but the import list is
   outside the replaced region. A freshly patched file would have thrown `ReferenceError` on the
   first permission request — indistinguishable from Coucow being broken. The script now rewrites
   the import and refuses to write without it.

Two further gaps closed while testing: the two `state: "once"` approval branches live outside the
block and are now wired separately (**fails closed** if absent, since a silently-ignored `always`
is exactly the failure mode worth catching), and upstream's stale
`// Coucou integration is now handled by the coucou.ts extension` comment is removed rather than
left asserting something untrue.

Verification — pristine backup + script reproduces the live patched file exactly, bar one blank
line:

| Case | Result |
|---|---|
| live file | reports "Already patched" |
| never-patched backup | installs all four features |
| **older patch → upgrade** | upgrades correctly (previously skipped) |
| re-run | no-op |
| import line | `isYoloModeEnabled` present |
| `always` wiring | both branches |

---

## 6. Version metadata

The release is **1.0.0 Lighto Edition, on a 0.1.7 base**. The version field is plain
`1.0.0` — Cargo, npm and Tauri all validate it as semver, so the "Lighto Edition"
suffix cannot live there and is carried by the changelog heading and this document
instead.

The base is stated explicitly because the version deliberately does *not* track
upstream's number. An earlier iteration pinned the build to upstream's `0.1.7` so a
future pull would not fight over version strings; that was abandoned in favour of
owning a real `1.0.0` major, with "0.1.7 base" recorded here and in the changelog so
the provenance stays legible at a glance.

| File | Upstream 0.1.7 | This tree |
|---|---|---|
| `windows/Cargo.toml`, `Cargo.lock` (`coucou`, `coucou-hook`) | 0.1.1 | 1.0.0 |
| `windows/package.json`, `package-lock.json` | 0.1.1 | 1.0.0 |
| `windows/src-tauri/tauri.conf.json` | 0.1.1 | 1.0.0 |
| `NotchBuddy/Resources/Info.plist` | 0.1.7 / build 8 | 1.0.0 / build 8 |
| `NotchBuddy/project.yml` (`NotchBuddy` target) | 0.1.7 / build 8 | 1.0.0 / build 8 |

Upstream's Windows manifests still say `0.1.1` while its release is 0.1.7 — an upstream
inconsistency that is inherited here rather than corrected, because "fixing" it would
guarantee a conflict on every future pull. Both lockfiles are regenerated by the build
tooling (`cargo metadata`, `npm install --package-lock-only`) rather than hand-edited;
note that `scopeguard` is also at `1.2.0` in `Cargo.lock` as a third-party dependency and
must not be caught by a blanket find-and-replace.

macOS `CFBundleVersion` stays at `8`, matching upstream. The version *string* is what
distinguishes the builds, so no bump is needed; raise it only if a future release has to
supersede an installed 1.0.0 in place.

Verified: `ProductVersion 1.0.0`, `FileVersion 1.0.0` in the built binary.

`productName` is **deliberately still `Coucou`**. Renaming it moves `%APPDATA%\Coucou` and
the `\\.\pipe\coucou-*` name, which would orphan existing settings. Flagged rather than done.

---

## 7. macOS side

Only `PillCatalog.swift` changed (+11/-0): `agent_pi` and `agent_copilot` added as declared
pills with the same ids and colours as Windows, plus `sessionSubtitle` cases for all three
agents. `agent_antigravity` already existed upstream.

macOS hook installation for these agents is upstream's own; this build did not extend the
Swift installer.

---

## 8. Verification

| Check | Result |
|---|---|
| `cargo test` | **14 passed** (8 upstream + 6 new) |
| `coucou-hook` tests | 3 passed |
| `cargo fmt --all --check` | clean |
| `cargo clippy` | 3 warnings, all pre-existing upstream |
| repo `tsc --noEmit` | clean |
| `vite build` | ok |
| `coucou.ts` vs Pi 1.0.2 types | clean |
| shipped extension vs Pi 1.0.2 types | clean |
| `pi-permission-system` vs Pi types | no new errors (one pre-existing `.state` error, present in the backup too) |
| Installer | `Coucou-Windows-1.0.0-setup.exe` (NSIS) + `.msi` |
| **Live Pi permission round trip** | **passed** — allow, deny and fail-open all observed |

### Live end-to-end run (2026-10-04)

Coucou Lighto Edition installed, Pi reloaded, real session. Every tool call produced a complete round trip:

```
11:51:46 hook PermissionRequest id=33540-1
11:51:52 ui  decide allow req=33540-1        <- island card answered in 6s
11:51:52 hook id=33540-1 answered allow
```

Observed human response times: **2s, 2s, 6s, 10s, 12s**. Every one of these would have
expired the old 800ms budget and fallen through to Pi's dialog while the island card was
still on screen. This is the direct confirmation that §5's root-cause analysis was right.

Confirmed: one card per request, no duplicates, no competing decisions, the relay held the
pipe open until the click and then released it (no orphaned connections), and request ids are
namespaced by Coucou process id.

### Coucou-closed fallback (same session)

With Coucou quit, the next tool call fell through to Pi's native dialog and completed
immediately — no 110s stall.

The instructive part: `existsSync(COUCOU_HOOK_EXE)` still returned **true**, because quitting
Coucou leaves the installed relay on disk. The file-existence probe is therefore *not*
sufficient on its own. What actually prevented the hang was the relay exiting immediately
when no island pipe is listening — see §5.

> **The relay's exit-when-no-pipe is load-bearing.** It is the only thing standing between
> "Coucou is closed" and "Pi blocks for 110s on every tool call". A future change that makes
> the relay wait for a pipe, or that swallows its early exit, would break Pi whenever Coucou
> is not running. Leave it alone.

### Deny path (same session)

A write was issued and explicitly denied at the island:

```
18092-6  21:49:11 PermissionRequest
         21:50:06 decide deny  ->  hook answered deny
```

The target file did not exist afterwards, and the refusal surfaced in Pi attributed to
Coucou ("Denied from Coucou") rather than to Pi's own policy — so the decision provably
came from the island.

**Response-time data:** the observed human decision times were 2s, 2s, 6s, 10s, 12s, and
**55s** for the deliberate deny. The 55s case is the informative one: it would have expired
the old 800ms budget several times over, and it lands comfortably inside the current 110s
budget. It does show the budget is not unbounded — a decision at roughly two minutes would
now cross over into Pi's own dialog.

### Approve/deny UI scope

The island offers exactly two buttons, `Deny` (N) and `Allow` (Y), and the action type is
binary: `decide(d: "allow" | "deny")`. This is **upstream 0.1.7 behaviour, not agent-specific**
— Claude Code gets the same two. Per the comment in `views/views.ts`, upstream deliberately
removed the "Always" option for every agent because the remembered-rules list it would write
to does not exist yet; the button was removed rather than left as a dead control. Restoring
it is a real feature (persisted rules + a write path), not a UI tweak.

### Not verified

- **`bun` is not installed**, so `pi-permission-system`'s own test suite could not be run
  against the patched file. Typechecking is clean; the real proof is a `bash` permission
  prompt in a live Pi session.
- **The 110s timeout expiry is untested.** Allow, deny and the Coucou-closed fallback have all
  been observed live; the expiry path itself has not. It is enforced in code and unit-tested,
  and the 55s deny above confirms ordinary decisions sit well inside the budget.
- **No live end-to-end run of Copilot / Antigravity hooks.** Those paths are covered by
  unit tests and typechecks only.
- **`npm install` emitted a warning**: `esbuild@0.25.12` postinstall was blocked as not
  covered by `allowScripts`. The build succeeded, so it appears benign here — noting it in
  case it bites later.

---

## 9. File manifest — original agent-support divergence

This is the manifest from the original audit; it is not a current complete diff.

### Real edits

```
windows/src-tauri/src/hooks.rs              +860 / -68
windows/src/settings/main.ts                +131 / -37
windows/src/views/integrations.ts           +62  / -4
windows/src/island/hooks.ts                 +50  / -14
windows/src-tauri/src/lib.rs                +46  / -15
windows/src/core/state.ts                   +38  / -11
windows/src/views/views.ts                  +40  / -13
windows/src/island/integrations.ts          +33  / -5
windows/hook/src/main.rs                    +25  / -7
windows/src-tauri/src/settings.rs           +10  / -0
windows/src/core/bridge.ts                  +15  / -7
windows/src/island/island.ts                +5   / -2
windows/src/main.ts                         +3   / -1
```

### Formatting only (`cargo fmt --all`)

```
windows/src-tauri/src/integrations.rs  +207 / -101
windows/src-tauri/src/island.rs        +36  / -13
windows/src-tauri/src/claude.rs        +29  / -6
windows/src-tauri/src/files.rs         +19  / -5
windows/src-tauri/src/pipe.rs          +19  / -5
windows/src-tauri/src/platform/linux.rs +13 / -4
windows/hook/src/win.rs                +9   / -3
windows/src-tauri/src/platform/windows.rs +6 / -4
windows/hook/src/unix.rs               +5   / -1
windows/src-tauri/src/log.rs           +4   / -1
```

### CSS and docs

```
windows/src/settings/settings.css   +29 / -0
docs/AGENTS.md                      +35 / -5
CHANGELOG.md                        +18 / -0
windows/src/style.css               +16 / -0
NotchBuddy/Sources/App/PillCatalog.swift  +11 / -0
NotchBuddy/Resources/Info.plist     +2  / -2
NotchBuddy/project.yml              +2  / -2
windows/Cargo.toml                  +1  / -1
windows/package.json                +1  / -1
windows/src-tauri/tauri.conf.json   +1  / -1
windows/Cargo.lock                  +2  / -2
windows/package-lock.json           +2  / -2
```

---

## 10. Current Windows follow-up — Desktop Mochi and Music

This section supersedes any earlier statement above that Windows Desktop Mochi was not
implemented or that `src/mochi/` was unchanged. It describes the current code direction;
installation and visual behavior still need real-device verification after the latest edits.

### Desktop Mochi port

Windows now creates a separate, transparent Tauri WebView window (`mochi.html`) during
Tauri setup, hidden, and later shows it on demand. The pet reuses the island's
`BotEngine`; its own frontend loop continues while the island is hidden. The Rust window
and WebView code is in `windows/src-tauri/src/desktop.rs` and
`windows/src/mochi/desktop-main.ts`; portable geometry/lifecycle rules are in
`windows/src/mochi/desktop.ts` with `windows/tests/desktop-mochi.test.ts`.

Current behavior/configuration:

- Borderless, transparent, topmost pet; settings persist enablement, size and physical
  virtual-screen position.
- Size is configurable from island Settings: **72–240 logical px**, default **120 px**;
  Reset returns to 120 px. Older settings files receive that default.
- Initial placement is inset in the monitor work area. Saved positions and dragging use
  full physical monitor bounds, allowing overlap with the taskbar while remaining
  recoverable on-screen.
- Rust samples the global cursor and controls circular hit-testing/click-through. Drag
  movement is now also polled natively while the left button is held, so a WebView losing
  mouse events or the pointer entering the taskbar does not end the drag. Position is
  persisted once at release.
- A 50 ms native runtime poll returns focus snapshot, global cursor offset, visibility
  and drag state; this avoids cross-WebView event-delivery assumptions.
- Hover/click/double-click, teleport effects, and idle sleep/wake remain in the shared
  renderer. A proximity wake refreshes the idle timer; sleep itself is intentionally
  based on the existing idle-time + cursor-distance policy, not on island visibility.

### Focus color/state and special pill effects

`main.ts` sends focused task ID/color/state to Rust, which stores the snapshot for the
pet WebView. The desktop body follows the selected pill; BotEngine's status dots remain
state-colored: purple for `thinking`, blue for `working`. Pi changes between those hook
states when it moves between model reasoning and tool execution; the color switch is
semantic, not random.

Music now has an explicit `music_playing` signal. The Music mini Mochi emits floating
notes and mouth movement while media is playing; the desktop/island Mochi can sing while
Music is focused. The desktop RAF delta is seconds (BotEngine's unit), so transient notes
and teleport particles persist rather than expiring immediately. The Music card keeps
Music and Playing/Paused together in its header, with matched dot diameter, font size and
gap.

A second explicit snapshot signal, `permission_pending`, lets an out-on-desktop Mochi
show its approval warning, pause briefly, animate back to the island, and hide after the
return. The island's settings-changed path reforms the home Mochi. This behavior is
implemented but not yet claimed as visually verified in an installed build.

### Verification / release boundary

Latest source checks in this working tree include TypeScript, Vite, Mochi/pill tests,
Rust formatting and Rust unit tests (33 passed, 2 ignored). A Windows NSIS installer was
built at `windows/target/release/bundle/nsis/Coucou_1.0.0_x64-setup.exe` with SHA-256
`C9A3EA805C3A18F29E80BC7A99C691A520AFA509D0E597685DEC203CC0FF63C0`. It has not been
installed or visually tested. Builds do not prove WebView rendering, taskbar z-order,
real GSMTC playback animation or live permission timing. Do not build MSI or install/
overwrite a binary without approval; test the installer on the actual display and with
real media/permission events before calling these behaviors done.

The macOS `DesktopMochi.swift` / `DesktopMochiLogic.swift` remains the reference for
shared behavior. The Windows Rust/WebView implementation is a platform-specific port;
new shared user-facing behavior should be checked against Swift and ported there when
appropriate. This current divergence does not assert that Music notes or approval-return
are already at parity on macOS.