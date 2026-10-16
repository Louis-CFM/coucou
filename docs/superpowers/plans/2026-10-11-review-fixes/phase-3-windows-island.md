# Phase 3 — Windows/Linux island (TypeScript) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get the island's test suite green again. Then make the phone push alert first, skip unchanged states and retry failed alerts; accept phone chat only for sessions the phone was offered, one at a time per session; carry multi-select answers; and make late hook events and released requests leave the island's state correct.

**Architecture:** Changes are in `windows/src/core/phone.ts`, `windows/src/island/hooks.ts`, `windows/src/island/sessions.ts` and `windows/src/island/approvals.ts`. Tests drive them through the real bridge with the existing Tauri stand-in (`windows/tests/tauri.mjs`), which this phase extends with per-command responders.

**Tech Stack:** TypeScript, `node --test` with `--import ./tests/setup.mjs`, `mock.timers`.

**Spec:** `README.md` in this folder (findings L5, L7, L8, C8, C9, C17, PIPE3, T1; contracts 1, 2, 4, 5, 6).

## Global Constraints

See `README.md` → Global Constraints. For this phase:
- No new user-facing strings in `src/i18n/*.json`. The two English notes added to `phone.ts` match that file's existing English-only notes.
- No visual change to any view.
- Run from `windows/`: `npm test`, and `npx tsc --noEmit` for types.

## Review Focus

See `README.md`. Tests this phase owns: Task 3.2 "an alert that did not get through is sent again with the next change", and Task 3.4 "a tool event older than the turn's Stop does not wake the pill back up".

---

### Task 3.1: The island suite is green again

`npm test` has 1 failure out of 421: `strings.json is what the generator makes of the Mac's catalog` (`windows/tests/i18n.test.mjs:152`). `windows/src/i18n/strings.json` is about 170 strings behind `NotchBuddy/Resources/Localizable.xcstrings`, and `windows-ci.yml:58` runs this suite, so CI is red.

**Files:**
- Modify (generated): `windows/src/i18n/strings.json`

- [ ] **Step 1: Confirm the failure**

Run: `cd windows && npm test 2>&1 | grep -E "^# (pass|fail)"`
Expected: `# fail 1`.

- [ ] **Step 2: Regenerate**

Run: `cd windows && node scripts/gen-strings.mjs`

- [ ] **Step 3: Run the suite**

Run: `cd windows && npm test 2>&1 | grep -E "^# (pass|fail)"`
Expected: `# fail 0`.

- [ ] **Step 4: Commit**

```bash
git add windows/src/i18n/strings.json
git commit -m "Windows/Linux: regenerate strings.json from the Mac catalog"
```

---

### Task 3.2: A card wakes the phone first, unchanged states are not re-sent, and a failed alert is retried (L5, L7)

`push()` in `phone.ts:152-159` has three problems:
- It awaits `remoteSessions()` (four session-store scans every 60 s) before sending an alert.
- It sends the full state on every `State.notify()` even when nothing changed.
- It marks a card alerted before knowing the push went through.

Phase 2 Task 2.3 makes `phone_state` return `bool` (contract 6).

**Files:**
- Modify: `windows/tests/tauri.mjs` (responders)
- Modify: `windows/src/core/bridge.ts:161-162` (`phoneState` return type)
- Modify: `windows/src/core/phone.ts` (`push`, `remoteSessions`, new `cachedSessions`, `lastSent`, `resetPhoneState`; `snapshot` questions carry `multi`)
- Create: `windows/tests/phone.test.mjs`

**Interfaces:**
- Consumes: `phone_state` → `boolean` (Phase 2 Task 2.3).
- Produces: `export function resetPhoneState(): void` (test seam). In `tauri.mjs`: `export function respond(cmd, fn)` and `export function resetResponders()`.

- [ ] **Step 1: Give the Tauri stand-in per-command answers**

In `windows/tests/tauri.mjs`, add above `export const internals`:

```js
const responders = new Map();

/** Makes `cmd` answer with `fn(args)` (a value or a promise) instead of null. */
export function respond(cmd, fn) {
  responders.set(cmd, fn);
}

/** Every command answers null again. */
export function resetResponders() {
  responders.clear();
}
```

and in `internals.invoke`, replace the final `return null;` with:

```js
    return responders.has(cmd) ? responders.get(cmd)(args) : null;
```

- [ ] **Step 2: Write the failing tests**

Create `windows/tests/phone.test.mjs`:

```js
// The Android companion's island side (src/core/phone.ts), driven through the
// real bridge: what the island pushes is read from the `phone_state` commands
// it invokes; what the phone sends arrives as `phone-remote` events.

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { calls, emit, resetResponders, respond, sent } from "./tauri.mjs";
import { resetPhoneState, wirePhone } from "../src/core/phone.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

let closed = 0;
wirePhone({ closeApproval: () => closed++ });

const flush = () => new Promise((resolve) => setImmediate(resolve));
async function settle() {
  mock.timers.tick(400);
  for (let i = 0; i < 10; i++) await flush();
}

const CLAUDE = "integration_claude";

function card(requestId, questions) {
  State.tasks = [
    { id: CLAUDE, name: "app", color: "#F5F6F8", state: "approval", steps: [], stepIndex: 0, source: "claudeCode" },
  ];
  State.pendingApproval = {
    id: "q1", requestId, sessionId: "s1", pillId: CLAUDE, tool: questions ? "AskUserQuestion" : "Bash",
    command: "Bash · ls", inputKey: "", ...(questions ? { questions } : {}),
  };
}

beforeEach(() => {
  mock.timers.enable({ apis: ["setTimeout"] });
  calls.length = 0;
  closed = 0;
  respond("phone_state", () => true);
  State.tasks = [];
  State.pendingApproval = null;
  State.chatHistory = [];
  State.settings = { ...DEFAULT_SETTINGS };
  resetPhoneState();
});

afterEach(() => {
  mock.timers.reset();
  resetResponders();
});

test("a fresh card wakes the phone before the session lists are read", async () => {
  respond("claude_sessions", () => [{ id: "abc", title: "t", dir: "/p", model: "", lastActivityAt: 1 }]);
  card("r1");
  State.notify();
  await settle();
  const first = sent("phone_state");
  assert.equal(first.length, 1);
  assert.equal(first[0].alert, true);
  assert.equal(first[0].payload.awaiting.requestId, "r1");
  const order = calls.map(([cmd]) => cmd);
  const alertAt = order.indexOf("phone_state");
  const listsAt = order.indexOf("claude_sessions");
  assert.ok(listsAt === -1 || listsAt > alertAt, "the lists come after the alert");

  // The lists follow on their own push, which does not wake the phone again.
  await settle();
  const pushes = sent("phone_state");
  assert.equal(pushes.length, 2);
  assert.equal(pushes[1].alert, false);
  assert.equal(pushes[1].payload.chatSessions.length, 1);
});

test("an unchanged state is not pushed again", async () => {
  card("r1");
  State.notify();
  await settle();
  await settle();
  const before = sent("phone_state").length;
  State.notify();
  await settle();
  assert.equal(sent("phone_state").length, before);
});

test("an alert that did not get through is sent again with the next change", async () => {
  let delivered = false;
  respond("phone_state", () => delivered);
  card("r1");
  State.notify();
  await settle();
  delivered = true;
  State.notify();
  await settle();
  assert.equal(sent("phone_state").filter((p) => p.alert).length, 2);
});

test("the phone is told which questions take several answers", async () => {
  card("q-r1", [
    { question: "Extras?", options: [{ label: "Tests", description: "" }, { label: "Docs", description: "" }], multiSelect: true },
  ]);
  State.notify();
  await settle();
  assert.deepEqual(sent("phone_state")[0].payload.awaiting.questions, [
    { q: "Extras?", options: ["Tests", "Docs"], multi: true },
  ]);
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd windows && node --import ./tests/setup.mjs --test tests/phone.test.mjs`
Expected: FAIL. `resetPhoneState` is not exported, the lists are fetched before the alert, and `multi` is missing.

- [ ] **Step 4: Write minimal implementation**

In `windows/src/core/bridge.ts`, change `phoneState` to:

```ts
  /** The island's visible state, pushed after each change. False: the relay was not reached. */
  phoneState: (payload: unknown, alert: boolean) =>
    call<boolean>("phone_state", { payload, alert }),
```

In `windows/src/core/phone.ts`:

1. Below `let transcriptFetchedAt = 0;`, add:

```ts
/** The last state the relay accepted, as sent: an unchanged one is not sent again. */
let lastSent = "";

/** Test seam: forgets what was pushed, offered and selected. */
export function resetPhoneState(): void {
  if (pushTimer !== undefined) clearTimeout(pushTimer);
  pushTimer = undefined;
  lastAlerted = null;
  lastSent = "";
  sessionsCache = [];
  sessionsFetchedAt = 0;
  selectedSession = null;
  transcriptCache = null;
  transcriptFetchedAt = 0;
}
```

2. In `snapshot()`, change the `questions` mapping to:

```ts
    const questions = (req.questions ?? []).map((q) => ({
      q: q.question,
      options: q.options.map((o) => o.label),
      multi: q.multiSelect,
    }));
```

3. Replace the `return { chatSessions: … }` at the end of `remoteSessions()` with `return cachedSessions();`, and add above `remoteSessions`:

```ts
/** What is already known of the CLI sessions, without asking for more. */
function cachedSessions() {
  return {
    chatSessions: sessionsCache,
    chatSel: selectedSession?.id ?? "",
    chatTranscript: selectedSession ? transcriptCache : null,
  };
}
```

4. Replace `push()` with:

```ts
async function push() {
  const base = snapshot();
  const alertId = base.awaiting?.requestId ?? null;
  const alert = alertId !== null && alertId !== lastAlerted;
  // A card wakes the phone now; the session lists are read for the next push.
  const state = { ...base, ...(alert ? cachedSessions() : await remoteSessions()) };
  const body = JSON.stringify(state);
  if (!alert && body === lastSent) return;
  // Not delivered: lastSent and lastAlerted stay as they were, so the next change retries.
  if ((await Bridge.phoneState(state, alert)) !== true) return;
  lastSent = body;
  if (alert) {
    lastAlerted = alertId;
    schedulePush();
  }
}
```

- [ ] **Step 5: Run tests**

Run: `cd windows && node --import ./tests/setup.mjs --test tests/phone.test.mjs && npm test && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add windows/tests/tauri.mjs windows/tests/phone.test.mjs windows/src/core/bridge.ts windows/src/core/phone.ts
git commit -m "Windows/Linux: alert the phone first, skip unchanged states, retry failed alerts"
```

---

### Task 3.3: Phone chat only reaches sessions the phone was offered, one run at a time per session; multi-select answers pass through (C8, C9, L8)

`remoteChat` (`phone.ts:197`) runs `claude/codex/opencode/devin` on any session id the phone sends, with no guard against two runs at once on the same session. `RemoteItem.answers` is typed `Record<string, string>`, while a multi-select answer is a list (contract 2).

**Files:**
- Modify: `windows/src/core/phone.ts` (`RemoteItem`, `remoteChat`, new `running`, new `appendTranscriptNote`, `resetPhoneState`)
- Test: `windows/tests/phone.test.mjs`

**Interfaces:**
- Consumes: `answers: Record<string, string | string[]>` from the relay (Phase 1 Task 1.5); `Bridge.approvalAnswer` already accepts `Record<string, string | string[]>`.

- [ ] **Step 1: Write the failing tests**

Append to `windows/tests/phone.test.mjs`:

```js
test("a phone message only continues a session the phone was offered", async () => {
  respond("claude_sessions", () => [{ id: "abc", title: "t", dir: "/p", model: "", lastActivityAt: 1 }]);
  emit("phone-remote", [{ type: "chat", at: 1, text: "go", sessionId: "../../etc/passwd", agent: "claude" }]);
  await settle();
  assert.deepEqual(sent("claude_resume"), []);

  emit("phone-remote", [{ type: "chat", at: 2, text: "go", sessionId: "abc", agent: "claude" }]);
  await settle();
  assert.deepEqual(sent("claude_resume"), [{ sessionId: "abc", text: "go" }]);
});

test("a second message for a session still answering waits its turn", async () => {
  respond("claude_sessions", () => [{ id: "abc", title: "t", dir: "/p", model: "", lastActivityAt: 1 }]);
  respond("claude_resume", () => new Promise(() => {})); // still running
  emit("phone-remote", [{ type: "chat", at: 1, text: "first", sessionId: "abc", agent: "claude" }]);
  await settle();
  emit("phone-remote", [{ type: "chat", at: 2, text: "second", sessionId: "abc", agent: "claude" }]);
  await settle();
  assert.deepEqual(sent("claude_resume").map((a) => a.text), ["first"]);
});

test("a multi-select answer from the phone reaches the relay as a list", () => {
  card("q-r2", [
    { question: "Extras?", options: [{ label: "Tests", description: "" }, { label: "Docs", description: "" }], multiSelect: true },
  ]);
  emit("phone-remote", [
    { type: "decision", at: 1, requestId: "q-r2", decision: "answer", answers: { "Extras?": ["Tests", "Docs"] } },
  ]);
  assert.deepEqual(sent("approval_answer"), [{ requestId: "q-r2", answers: { "Extras?": ["Tests", "Docs"] }, other: [] }]);
  assert.equal(closed, 1);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd windows && node --import ./tests/setup.mjs --test tests/phone.test.mjs`
Expected: FAIL. The `../../etc/passwd` session is resumed, and `"second"` is resumed while `"first"` runs. (The multi-select test may already pass at runtime; it pins the type change.)

- [ ] **Step 3: Write minimal implementation**

In `phone.ts`:

1. In `interface RemoteItem`, change `answers?: Record<string, string>;` to:

```ts
  /** Question text → the label picked, or the labels for a multi-select question. */
  answers?: Record<string, string | string[]>;
```

and change the `agent` comment to `/** Which CLI the session belongs to — "devin" | "claude" | "codex" | "opencode" (default devin). */`.

2. Add below `let lastSent = "";`:

```ts
/** CLI sessions a phone message is running in right now, as "agent:id". */
const running = new Set<string>();
```

and add `running.clear();` inside `resetPhoneState()`.

3. Replace the `if (sessionId) { … return; }` block of `remoteChat` with:

```ts
  if (sessionId) {
    // The id came over the network: only a session the phone was offered.
    const offered = () => sessionsCache.some((s) => s.id === sessionId && s.agent === agent);
    if (!offered()) {
      sessionsFetchedAt = 0;
      await remoteSessions();
    }
    if (!offered()) {
      void Bridge.log(`phone chat for a ${agent} session it was not offered — ignored`);
      return;
    }
    const key = `${agent}:${sessionId}`;
    if (running.has(key)) {
      appendTranscriptNote(sessionId, "(still answering the previous message)");
      void push();
      return;
    }
    running.add(key);
    try {
      await agentResume(agent, sessionId, text);
      const lines = (await agentTranscript(agent, sessionId)) ?? [];
      transcriptCache = { id: sessionId, lines };
    } catch (e) {
      appendTranscriptNote(sessionId, `(${e instanceof Error ? e.message : "the CLI could not be reached"})`);
    } finally {
      running.delete(key);
    }
    transcriptFetchedAt = Date.now();
    void push();
    return;
  }
```

4. Add below `remoteChat`:

```ts
/** One assistant line of ours at the end of the session's transcript on the phone. */
function appendTranscriptNote(sessionId: string, text: string) {
  transcriptCache = {
    id: sessionId,
    lines: [...(transcriptCache?.id === sessionId ? transcriptCache.lines : []), { role: "assistant", text }],
  };
}
```

- [ ] **Step 4: Run tests**

Run: `cd windows && node --import ./tests/setup.mjs --test tests/phone.test.mjs && npm test && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add windows/src/core/phone.ts windows/tests/phone.test.mjs
git commit -m "Windows/Linux: phone chat only reaches offered sessions, one run at a time; list answers"
```

---

### Task 3.4: A late hook event no longer restarts a finished turn, and a released request leaves the card (C17, PIPE3)

Two cases to handle:
- Separate relay processes can deliver a PostToolUse after the turn's Stop. `sessions.note(…, true)` (`hooks.ts:393`) then marks the session working again, and the 5.2 s return to idle declines (`hooks.ts:444`), so the pill stays "working".
- When the relay stops waiting, Phase 2 Task 2.12 emits `approval-released` (contract 5), and the island must take the card down without declining.

**Files:**
- Modify: `windows/src/island/sessions.ts` (`LiveSession.endedAt`, `endTurn` signature, new `sentBeforeTurnEnded`)
- Modify: `windows/src/island/hooks.ts` (`HookPayload.coucou_ts`, guard, three `endTurn` call sites, `approval-released` listener)
- Modify: `windows/src/island/approvals.ts` (new `releaseApproval`)
- Test: `windows/tests/hooks.test.mjs`, `windows/tests/sessions.test.mjs`

**Interfaces:**
- Consumes: `coucou_ts` on hook payloads (Phase 2 Task 2.11); event `approval-released { requestId }` (Phase 2 Task 2.12).
- Produces: `SessionRegistry.endTurn(pill, session, now = Date.now(), relayTs?: number)`, `SessionRegistry.sentBeforeTurnEnded(pill, session, relayTs): boolean`, `export function releaseApproval(island: Island, requestId: string): void`.

- [ ] **Step 1: Write the failing tests**

Append to `windows/tests/hooks.test.mjs`:

```js
// ── Late events and released requests ────────────────────────────────────────

test("a tool event older than the turn's Stop does not wake the pill back up", () => {
  hook({ hook_event_name: "UserPromptSubmit", session_id: "s1", cwd: "/p/app", coucou_ts: 1000 });
  hook({ hook_event_name: "Stop", session_id: "s1", cwd: "/p/app", coucou_ts: 3000 });
  // Sent by its relay before the Stop, delivered after it.
  hook({ hook_event_name: "PostToolUse", session_id: "s1", cwd: "/p/app", tool_name: "Read", coucou_ts: 2000 });
  assert.equal(task().state, "finished");
  seconds(6);
  assert.equal(task().state, "idle");
});

test("a new turn after the Stop is not mistaken for a late event", () => {
  hook({ hook_event_name: "Stop", session_id: "s1", cwd: "/p/app", coucou_ts: 3000 });
  hook({ hook_event_name: "UserPromptSubmit", session_id: "s1", cwd: "/p/app", coucou_ts: 4000 });
  hook({ hook_event_name: "PreToolUse", session_id: "s1", cwd: "/p/app", tool_name: "Bash", coucou_ts: 4100 });
  assert.equal(task().state, "working");
});

test("a request the agent stopped waiting for leaves the card without a decline", () => {
  hook({
    hook_event_name: "PermissionRequest", request_id: "r1", session_id: "s1",
    cwd: "/p/app", tool_name: "Bash", tool_input: { command: "ls" },
  });
  assert.equal(State.pendingApproval?.requestId, "r1");
  emit("approval-released", { requestId: "r1" });
  assert.equal(State.pendingApproval, null);
  assert.deepEqual(sent("approval_decline"), []);
});
```

Append to `windows/tests/sessions.test.mjs`. It imports `SessionRegistry`; reuse its existing `CLAUDE` constant, or define `const CLAUDE = "integration_claude";` if the file has none:

```js
test("an event the relay sent before the session's Stop is recognised as late", () => {
  const reg = new SessionRegistry();
  const d = { session: "s1", projectName: "app", cwd: "/p" };
  reg.note(CLAUDE, d, true, 0);
  reg.endTurn(CLAUDE, "s1", 10, 3000);
  assert.equal(reg.sentBeforeTurnEnded(CLAUDE, "s1", 2000), true);
  assert.equal(reg.sentBeforeTurnEnded(CLAUDE, "s1", 4000), false);
  assert.equal(reg.sentBeforeTurnEnded(CLAUDE, "other", 2000), false);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd windows && node --import ./tests/setup.mjs --test tests/hooks.test.mjs tests/sessions.test.mjs`
Expected: FAIL. The pill stays "working", the card stays up, and `sentBeforeTurnEnded` is not a function.

- [ ] **Step 3: Write minimal implementation**

`windows/src/island/sessions.ts`:

1. In `interface LiveSession`, add:

```ts
  /** The relay's clock (`coucou_ts`) at this session's last Stop, when it sent one. */
  endedAt?: number;
```

2. Change `endTurn`'s signature and its `if (s)` block:

```ts
  endTurn(pill: string, session: string, now = Date.now(), relayTs?: number): TerminalScope {
```

```ts
    if (s) {
      s.isWorking = false;
      s.lastSeen = now;
      if (relayTs !== undefined) s.endedAt = relayTs;
    }
```

3. Add below `workingCount`:

```ts
  /**
   * True for an event its relay stamped before this session's last Stop: each
   * event has its own relay process, and a quick one can overtake a slow one,
   * so a turn's last PostToolUse may reach the island after its Stop.
   */
  sentBeforeTurnEnded(pill: string, session: string, relayTs: number): boolean {
    const endedAt = this.pills.get(pill)?.sessions.get(session)?.endedAt;
    return endedAt !== undefined && relayTs < endedAt;
  }
```

`windows/src/island/approvals.ts`, add below `settleApproval`:

```ts
/**
 * The relay stopped waiting for this request — answered in the terminal, the
 * agent gave up, or the relay's own deadline passed. Its card goes and the next
 * request takes its place; nothing is sent back, nobody is left to answer.
 */
export function releaseApproval(island: Island, requestId: string): void {
  const entry = queue.byRequestId(requestId);
  if (!entry) return;
  const wasHead = queue.head?.id === entry.id;
  removeEntry(entry);
  syncBadge(entry.pillId);
  if (wasHead) {
    refreshApprovals(island, entry.pillId);
    return;
  }
  const head = queue.head;
  if (head && State.pendingApproval?.id === head.id) showApprovalCard(island, head, false);
  State.notify();
}
```

`windows/src/island/hooks.ts`:

1. Import: `import { enqueueApproval, releaseApproval, resetApprovals, resolveApprovals } from "./approvals";`.

2. In `interface HookPayload`, add:

```ts
  /** When the relay process saw the event (ms since the epoch): orders events that arrive out of order. */
  coucou_ts?: number;
```

3. In `registerHookHandlers`, add:

```ts
  // The relay stopped waiting for a request (src-tauri/src/pipe.rs): its card goes.
  void onEvent<{ requestId: string }>("approval-released", (p) => releaseApproval(island, p.requestId));
```

4. Add a module constant below `stopTimers`:

```ts
/** Events that only continue a turn: one stamped before the session's Stop is late, not new. */
const TURN_EVENTS = new Set([
  "PreToolUse", "PostToolUse", "PostToolUseFailure", "Notification", "SubagentStart", "SubagentStop",
]);
```

5. In `handleHook`, right after `const sessionId = payload.session_id ?? "";`, add:

```ts
  const relayTs = typeof payload.coucou_ts === "number" ? payload.coucou_ts : undefined;
  if (relayTs !== undefined && TURN_EVENTS.has(name) && sessions.sentBeforeTurnEnded(agentId, sessionId, relayTs)) {
    return; // belongs to a turn that is already over
  }
```

6. Pass the timestamp at the three turn-ending calls:
   - Stop: `const scope = sessions.endTurn(agentId, sessionId, Date.now(), relayTs);`
   - Interrupt: `if (sessions.endTurn(agentId, sessionId, Date.now(), relayTs) !== "pill") break;`
   - StopFailure: `if (sessions.endTurn(agentId, sessionId, Date.now(), relayTs) !== "pill") break;`

- [ ] **Step 4: Run tests**

Run: `cd windows && npm test && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add windows/src/island/sessions.ts windows/src/island/hooks.ts windows/src/island/approvals.ts windows/tests/hooks.test.mjs windows/tests/sessions.test.mjs
git commit -m "Windows/Linux: late tool events no longer restart a finished turn; released requests leave the card"
```

---

## Phase 3 done when

- [ ] `cd windows && npm test` reports `# fail 0`.
- [ ] `cd windows && npx tsc --noEmit` is clean.
- [ ] Manual (with Phase 2 built): answer a permission in the terminal and the island's card goes. Phone chat into a session works, and a second message while the first runs shows "(still answering the previous message)".
