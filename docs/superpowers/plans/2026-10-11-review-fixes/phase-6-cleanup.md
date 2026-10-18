# Phase 6 — Dead code, stale docs, session plumbing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the code the review found unreachable (D1–D4), fix comments and docs that describe things that do not exist (D5), and replace the four copy-pasted session switches in `phone.ts` with one table, with no behaviour change.

**Architecture:** Pure deletions and one table-driven refactor. The guard for each task is the platform's full test suite plus its compiler. Every deletion was checked with a word-boundary grep across sources and tests, and the task shows that grep so the executor can re-run it first.

**Tech Stack:** TypeScript (`tsc`, `node --test`), Rust (`cargo`), Swift (`xcodebuild` on macOS), Kotlin (`gradlew`).

**Spec:** `README.md` in this folder (Section 1 findings D1–D5).

## Global Constraints

See `README.md` → Global Constraints. For this phase:
- **Do Phase 6 after Phases 2–5.** Several items here are edited by those phases, and deleting first would make their diffs conflict.
- Before deleting anything, re-run the task's grep. If it now shows a use outside the definition, skip that item and note it in the commit message.
- Keep test seams that tests rely on (`resetHookState`, `isComplete`, `liveTextCount`, …). They are not dead.

## Review Focus

Nothing new: these tasks change no behaviour. Each task's guard is "the full suite still passes".

---

### Task 6.1: Delete the TypeScript that nothing uses (D1)

**Files:**
- Modify: `windows/src/core/layout.ts` (`WAKE_STRIP_W`, `WAKE_STRIP_H`, `colorForProject` with its `PROJECT_COLORS` / `FALLBACK_COLORS`)
- Modify: `windows/src/i18n/i18n.ts` (`allKeys`)
- Modify: `windows/src/mochi/engine.ts` (`STATE_SOUND`)
- Modify: `windows/src/mochi/minibots.ts` (`releaseMiniBot`, `miniBotCount`)
- Modify: `windows/src/core/bridge.ts` (`BridgeEvent`; the stray doc comment above `localSetKey`)
- Modify: `windows/src/island/queue.ts` (`shift`, `contains`, `entries`)

- [ ] **Step 1: Re-check that each one is unused**

Run from `windows/`:

```bash
for s in WAKE_STRIP_W WAKE_STRIP_H colorForProject PROJECT_COLORS FALLBACK_COLORS allKeys STATE_SOUND releaseMiniBot miniBotCount BridgeEvent; do
  echo "== $s"; grep -rnw "$s" src tests dev *.html | grep -v "^src/i18n/.*\.json"
done
grep -rnE "\.(shift|contains)\(|\.entries\b" src/island tests | grep -iE "queue|approval"
```

Expected:
- Each name appears only on its own definition line(s). `PROJECT_COLORS` and `FALLBACK_COLORS` are used only inside `colorForProject`.
- No `queue.shift()`, `queue.contains(` or `queue.entries`.

- [ ] **Step 2: Delete**

- `layout.ts`: delete the doc comment `/** Invisible hover strip that wakes the island when hidden. */` and the two lines `export const WAKE_STRIP_W = 240;` and `export const WAKE_STRIP_H = 6;`. Delete `const PROJECT_COLORS …`, `const FALLBACK_COLORS …` and `export function colorForProject(…) { … }` (lines ~213-238).
- `i18n.ts`: delete `/** Every key of both tables, for the tests. */` and `export function allKeys() { … }`.
- `engine.ts`: delete `/** State → sound, as in BotStateCfg.sound. */` and `export const STATE_SOUND … };`.
- `minibots.ts`: delete `export function releaseMiniBot(…) { … }` and `export const miniBotCount = () => live.size;`.
- `bridge.ts`: delete `export type BridgeEvent = …;` (4 lines). Above `localSetKey`, delete the orphaned line `/** Settings → Local models → Connect: does the server answer, and with which models? */`, then move that comment above `localConnect`, where it belongs.
- `queue.ts`: delete the `get entries()` getter, `contains(id)`, and `shift()`.

- [ ] **Step 3: Run the suite and types**

Run: `cd windows && npx tsc --noEmit && npm test`
Expected: clean, `# fail 0`.

- [ ] **Step 4: Commit**

```bash
git add windows/src/core/layout.ts windows/src/i18n/i18n.ts windows/src/mochi/engine.ts windows/src/mochi/minibots.ts windows/src/core/bridge.ts windows/src/island/queue.ts
git commit -m "Windows/Linux: remove exports and methods nothing uses"
```

---

### Task 6.2: Delete the Rust that only its own tests use, and the session field nothing reads (D3)

`i18n::tn` and `plural_category` (`i18n.rs:225-240`, `:152`) are called only by `plurals_follow_the_language`. `SessionMeta.model` is empty for three of the four readers, and neither `phone.ts` nor the relay forwards it.

**Files:**
- Modify: `windows/src-tauri/src/i18n.rs` (`tn`, `plural_category`, the test `plurals_follow_the_language`)
- Modify: `windows/src-tauri/src/devin_sessions.rs` (`SessionMeta.model`, the SQL column, `list_recent_in`)
- Modify: `windows/src-tauri/src/claude_sessions.rs:154`, `codex_sessions.rs:136`, `opencode_sessions.rs:53` (`model: String::new(),`)
- Modify: `windows/src/core/bridge.ts:167,179` (`model: string;` in the two session list types)

- [ ] **Step 1: Re-check**

Run from `windows/`:

```bash
grep -rnw "tn\|plural_category" src-tauri/src | grep -v "fn tn\|fn plural_category"
grep -rn "\.model\b" src/core/phone.ts src/views src/settings | grep -i session
```

Expected:
- `tn` and `plural_category` appear only inside `plurals_follow_the_language` (and `plural_category` inside `tn`).
- Nothing reads a session's `model`.

- [ ] **Step 2: Delete**

- `i18n.rs`:
  - Delete `fn plural_category`.
  - Delete the `/// A count with its words…`, `#[allow(dead_code)]` and `pub fn tn(…) { … }` block.
  - Delete the test `fn plurals_follow_the_language() { … }`.
  - Keep `pick_plural`, which `tf` uses.
- `devin_sessions.rs`:
  - Delete `pub model: String,` from `SessionMeta`.
  - In `list_recent_in`'s SQL, change `SELECT id, title, working_directory, model, last_activity_at` to `SELECT id, title, working_directory, last_activity_at`.
  - Delete the `model: …` line, and change `r.get::<_, Option<i64>>(4)` to `r.get::<_, Option<i64>>(3)`.
- `claude_sessions.rs`, `codex_sessions.rs`, `opencode_sessions.rs`: delete the `model: String::new(),` line.
- `bridge.ts`: in `devinSessions` and `claudeSessions`, change `{ id: string; title: string; dir: string; model: string; lastActivityAt: number }` to `{ id: string; title: string; dir: string; lastActivityAt: number }`.

- [ ] **Step 3: Run the suites**

Run: `cd windows && cargo test --workspace && cargo check --workspace --all-targets && npx tsc --noEmit && npm test`
Expected: all pass, no warnings.

- [ ] **Step 4: Commit**

```bash
git add windows/src-tauri/src/i18n.rs windows/src-tauri/src/devin_sessions.rs windows/src-tauri/src/claude_sessions.rs windows/src-tauri/src/codex_sessions.rs windows/src-tauri/src/opencode_sessions.rs windows/src/core/bridge.ts
git commit -m "Windows/Linux: drop tn() and the session model field nobody reads"
```

---

### Task 6.3: Delete the Swift functions nothing calls (D4)

These 13 functions appear only on their own declaration line, across `NotchBuddy/Sources` and `tests/`:

| File:line | Function |
|---|---|
| `App/GreetingCanvasView.swift:566` | `drawHeader` |
| `App/IslandWindowController.swift:574` | `scheduleHover` |
| `App/IslandWindowController.swift:1249` | `baseMode` |
| `App/IslandWindowController.swift:1256` | `resetActivity` |
| `App/IslandWindowController.swift:1262` | `pinForFinished` |
| `App/IslandWindowController.swift:1740` | `showVoiceResult` |
| `App/MusicController.swift:253` | `playArtist` |
| `App/SettingsView.swift:1404` | `localModelStatusLabel` |
| `App/Voice/VoiceEngine.swift:133` | `reloadLanguage` |
| `CoucouKit/MochiOutfitDrawing.swift:70` | `mochiEyePositions` (its replacement `EyeFrame` is at `:37`) |
| `CoucouKit/MochiOutfitDrawing.swift:204` | `mRingPoints` |
| `App/HookServer.swift:2076` | `withoutCopilotHooks` (Copilot uninstall deletes its own file) |
| `App/HookServer.swift:2876` | nested `removeCoucouPlugin()` inside `mergedHermesConfig` (uninstall goes through `hermes plugins disable coucou`, `:2968`) |

**Files:** the eight Swift files above.

- [ ] **Step 1: Re-check**

Run from `NotchBuddy/Sources`:

```bash
for n in drawHeader scheduleHover baseMode resetActivity pinForFinished showVoiceResult playArtist localModelStatusLabel reloadLanguage mochiEyePositions mRingPoints withoutCopilotHooks removeCoucouPlugin; do
  echo "== $n $(grep -rnw "$n" --include=*.swift . ../../tests | wc -l)"
done
grep -rn "#selector(\(scheduleHover\|resetActivity\|pinForFinished\|reloadLanguage\)" --include=*.swift . | head
```

Expected: each count is `1` (the declaration), and no `#selector` references.

- [ ] **Step 2: Delete**

Delete each function's full body and its doc comment. For `removeCoucouPlugin`, delete only the nested `func removeCoucouPlugin() { … }` inside `mergedHermesConfig`. For `mochiEyePositions`, also delete the `// MARK: - EyeFrame (replaces mochiEyePositions)` wording if it names the deleted function, keeping the MARK itself as `// MARK: - EyeFrame`.

- [ ] **Step 3: Build every target (on macOS)**

Run:

```bash
cd NotchBuddy && xcodegen && \
xcodebuild -scheme NotchBuddy -configuration Debug build CODE_SIGNING_ALLOWED=NO && \
xcodebuild -scheme NotchBuddy -configuration DebugCloud build CODE_SIGNING_ALLOWED=NO && \
xcodebuild -scheme CoucouAppStore -configuration Debug build CODE_SIGNING_ALLOWED=NO && \
xcodebuild -scheme CoucouPhone -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
cd .. && for s in scripts/test-*.sh; do bash "$s" || exit 1; done
```

Expected: every build succeeds and every script passes. (`MochiOutfitDrawing.swift` is in CoucouKit, which the iPhone app also compiles.)

- [ ] **Step 4: Commit**

```bash
git add NotchBuddy/Sources
git commit -m "Mac: remove 13 functions nothing calls"
```

---

### Task 6.4: Delete the Kotlin constant nothing uses

`Theme.kt`'s `CornerPanel` appears only on its declaration line.

**Files:**
- Modify: `android/app/src/main/java/fr/louisraille/coucou/phone/Theme.kt`

- [ ] **Step 1: Re-check**

Run: `cd android && grep -rnw CornerPanel app/src`
Expected: one line, in `Theme.kt`.

- [ ] **Step 2: Delete the `CornerPanel` declaration line (and its comment, if any).**

- [ ] **Step 3: Build and test**

Run: `cd android && ./gradlew :app:testDebugUnitTest :app:assembleDebug`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add android/app/src/main/java/fr/louisraille/coucou/phone/Theme.kt
git commit -m "Android: remove an unused theme constant"
```

---

### Task 6.5: Comments and docs say what is actually there (D5)

Stale text:
- The headers of `approvals.ts`, `queue.ts` and `sessions.ts` cite `ApprovalQueue.swift`, `PillSessionRegistry.swift` and "HookServer's approvalQueue". None of these exists in any git ref; the Mac has a single pending slot (`HookServer.swift:41, 753-764`).
- CLAUDE.md says "28 WAV sounds", but `NotchBuddy/Resources/sounds/` holds 29.

**Files:**
- Modify: `windows/src/island/approvals.ts:1-5`
- Modify: `windows/src/island/queue.ts:1-3`
- Modify: `windows/src/island/sessions.ts:1`
- Modify: `CLAUDE.md` ("the 28 WAV sounds")

- [ ] **Step 1: Edit**

- `approvals.ts` first comment line → `// The approval wait line. The Mac keeps a single pending request (HookServer.swift pendingApprovalFD); this port queues up to ApprovalQueue.maxPending instead (#157).`
- `queue.ts` first line → `// The wait line of permission requests (#157). Pure FIFO, no I/O: approvals.ts`
- `sessions.ts` first line → `// The live agent sessions behind each pill (#245).`
- `CLAUDE.md`: change `the 28 WAV sounds` to `the 29 WAV sounds`.

- [ ] **Step 2: Check**

Run: `ls NotchBuddy/Resources/sounds/*.wav | wc -l && cd windows && npx tsc --noEmit`
Expected: `29`; clean.

- [ ] **Step 3: Commit**

```bash
git add windows/src/island/approvals.ts windows/src/island/queue.ts windows/src/island/sessions.ts CLAUDE.md
git commit -m "Docs: comments cite code that exists; 29 sounds"
```

---

### Task 6.6: One table for the four CLI session sources in `phone.ts`

`phone.ts:94-131` routes list, transcript and resume through three hand-written switches, one entry per CLI. Adding a fifth CLI means editing all three, plus `Bridge`.

**Files:**
- Modify: `windows/src/core/phone.ts` (`agentTranscript`, `agentResume`, and the fetch list in `remoteSessions`)
- Test: `windows/tests/phone.test.mjs` (Phase 3) guards the behaviour

**Interfaces:**
- Produces: `const SESSION_SOURCES: Record<string, { list; transcript; resume }>`, with `"devin"` as the fallback.

- [ ] **Step 1: Write the test that pins the routing**

Append to `windows/tests/phone.test.mjs`:

```js
test("each CLI's session goes to its own commands; unknown agents fall back to Devin", async () => {
  for (const [agent, cmd] of [["claude", "claude_resume"], ["codex", "codex_resume"], ["opencode", "opencode_resume"], ["devin", "devin_resume"]]) {
    resetPhoneState();
    respond(`${agent}_sessions`, () => [{ id: "s1", title: "t", dir: "/p", lastActivityAt: 1 }]);
    emit("phone-remote", [{ type: "chat", at: 1, text: "hi", sessionId: "s1", agent }]);
    await settle();
    assert.deepEqual(sent(cmd).at(-1), { sessionId: "s1", text: "hi" }, agent);
  }
});
```

- [ ] **Step 2: Run it (it passes before the refactor)**

Run: `cd windows && node --import ./tests/setup.mjs --test tests/phone.test.mjs`
Expected: PASS. This test guards the refactor rather than a new behaviour.

- [ ] **Step 3: Refactor**

In `phone.ts`, replace `agentTranscript` and `agentResume` with:

```ts
type SessionList = () => Promise<{ id: string; title: string; dir: string; lastActivityAt: number }[] | null>;

/** Each CLI's session store, by the agent id the phone sends. */
const SESSION_SOURCES: Record<string, {
  list: SessionList;
  transcript: (id: string) => Promise<ChatLine[] | null>;
  resume: (id: string, text: string) => Promise<string>;
}> = {
  devin: { list: Bridge.devinSessions, transcript: Bridge.devinTranscript, resume: Bridge.devinResume },
  claude: { list: Bridge.claudeSessions, transcript: Bridge.claudeTranscript, resume: Bridge.claudeResume },
  codex: { list: Bridge.codexSessions, transcript: Bridge.codexTranscript, resume: Bridge.codexResume },
  opencode: { list: Bridge.opencodeSessions, transcript: Bridge.opencodeTranscript, resume: Bridge.opencodeResume },
};

const source = (agent: string) => SESSION_SOURCES[agent] ?? SESSION_SOURCES.devin;
const agentTranscript = (agent: string, id: string) => source(agent).transcript(id);
const agentResume = (agent: string, id: string, text: string) => source(agent).resume(id, text);
```

In `remoteSessions`, replace the `const [devin, claude, codex, opencode] = await Promise.all([ … ]);` and the `sessionsCache = [ … ]` lines with:

```ts
    const lists = await Promise.all(
      Object.entries(SESSION_SOURCES).map(([agent, s]) => fetch(s.list, agent)),
    );
    sessionsCache = lists.flat();
```

- [ ] **Step 4: Run the suite**

Run: `cd windows && npx tsc --noEmit && npm test`
Expected: clean, `# fail 0`.

- [ ] **Step 5: Commit**

```bash
git add windows/src/core/phone.ts windows/tests/phone.test.mjs
git commit -m "Windows/Linux: one table for the phone's four CLI session sources"
```

---

## Phase 6 done when

- [ ] `cd windows && cargo test --workspace && cargo check --workspace --all-targets && npm test && npx tsc --noEmit` all pass, with no warnings.
- [ ] On macOS, every scheme builds and every `scripts/test-*.sh` passes.
- [ ] `cd android && ./gradlew :app:testDebugUnitTest :app:assembleDebug` succeeds.
- [ ] `cd relay && npm test` passes. Phase 6 does not touch the relay; this confirms nothing upstream regressed.
