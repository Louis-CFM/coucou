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

afterEach(async () => {
  // Let a push still in flight finish before the next test starts.
  mock.timers.runAll();
  for (let i = 0; i < 10; i++) await flush();
  mock.timers.runAll();
  mock.timers.reset();
  resetResponders();
});

/** The pushes the relay was sent: { payload, alert } each. */
const pushes = () => sent("phone_state");

test("a fresh card wakes the phone before the session lists are read", async () => {
  respond("claude_sessions", () => [{ id: "abc", title: "t", dir: "/p", model: "", lastActivityAt: 1 }]);
  card("r1");
  State.notify();
  await settle();
  const first = pushes();
  assert.equal(first.length, 1);
  assert.equal(first[0].alert, true);
  assert.equal(first[0].payload.awaiting.requestId, "r1");
  const order = calls.map(([cmd]) => cmd);
  const alertAt = order.indexOf("phone_state");
  const listsAt = order.indexOf("claude_sessions");
  assert.ok(listsAt === -1 || listsAt > alertAt, "the lists come after the alert");

  // The lists follow on their own push, which does not wake the phone again.
  await settle();
  const all = pushes();
  assert.equal(all.length, 2);
  assert.equal(all[1].alert, false);
  assert.equal(all[1].payload.chatSessions.length, 1);
});

test("an unchanged state is not pushed again", async () => {
  card("r1");
  State.notify();
  await settle();
  await settle();
  const before = pushes().length;
  State.notify();
  await settle();
  assert.equal(pushes().length, before);
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
  assert.equal(pushes().filter((p) => p.alert).length, 2);
});

test("the phone is told which questions take several answers", async () => {
  card("q-r1", [
    { question: "Extras?", options: [{ label: "Tests", description: "" }, { label: "Docs", description: "" }], multiSelect: true },
  ]);
  State.notify();
  await settle();
  assert.deepEqual(pushes()[0].payload.awaiting.questions, [
    { q: "Extras?", options: ["Tests", "Docs"], multi: true },
  ]);
});

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

test("each CLI's session goes to its own commands; unknown agents fall back to Devin", async () => {
  for (const [agent, cmd] of [["claude", "claude_resume"], ["codex", "codex_resume"], ["opencode", "opencode_resume"], ["devin", "devin_resume"]]) {
    resetPhoneState();
    respond(`${agent}_sessions`, () => [{ id: "s1", title: "t", dir: "/p", lastActivityAt: 1 }]);
    emit("phone-remote", [{ type: "chat", at: 1, text: "hi", sessionId: "s1", agent }]);
    await settle();
    assert.deepEqual(sent(cmd).at(-1), { sessionId: "s1", text: "hi" }, agent);
  }
});
