// A pending permission card goes the moment it is settled somewhere else
// (src/island/hooks.ts, src/island/approvals.ts): the relay hanging up, or
// the very tool call it asked about running, means it was answered in the
// terminal or the Claude app.

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { calls, emit, sent } from "./tauri.mjs";
import { registerHookHandlers } from "../src/island/hooks.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

let asked;
const island = {
  alert: (view) => asked.push(`alert:${view}`),
  setView: (view) => asked.push(`setView:${view}`),
  reveal: () => asked.push("reveal"),
  dropPin: () => asked.push("dropPin"),
};
registerHookHandlers(island);

const hook = (payload) => emit("hook", payload);

beforeEach(() => {
  mock.timers.enable({ apis: ["setTimeout"] });
  asked = [];
  calls.length = 0;
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.view = "overview";
  State.paused = false;
  State.isPinned = false;
  State.pendingApproval = null;
  State.settings = { ...DEFAULT_SETTINGS };
  State.loadIntegrationTasks();
});

afterEach(() => {
  mock.timers.runAll();
  mock.timers.reset();
});

const ask = (id, extra = {}) =>
  hook({
    hook_event_name: "PermissionRequest",
    request_id: id,
    session_id: "s1",
    cwd: "C:\\p\\proj",
    tool_name: "Bash",
    tool_input: { command: "npm test" },
    ...extra,
  });

test("the relay hanging up takes the card down at once, with nobody left to release", () => {
  ask("r1");
  assert.equal(State.pendingApproval?.requestId, "r1");
  emit("approval-released", { requestId: "r1" });
  assert.equal(State.pendingApproval, null);
  assert.deepEqual(sent("approval_decline"), []);
});

test("a hang-up for another request leaves the card alone", () => {
  ask("r1");
  emit("approval-released", { requestId: "r0" });
  assert.equal(State.pendingApproval?.requestId, "r1");
});

test("the very tool call running means it was allowed in the terminal", () => {
  ask("r1");
  hook({ hook_event_name: "PostToolUse", session_id: "s1", cwd: "C:\\p\\proj", tool_name: "Bash", tool_input: { command: "npm test" } });
  assert.equal(State.pendingApproval, null);
  // The relay may still be waiting: it is released.
  assert.deepEqual(sent("approval_decline"), [{ requestId: "r1" }]);
});

test("another call's result (a subagent alongside) or another session's never counts", () => {
  ask("r1");
  hook({ hook_event_name: "PostToolUse", session_id: "s1", cwd: "C:\\p\\proj", tool_name: "Read", tool_input: { file_path: "a.ts" } });
  hook({ hook_event_name: "PostToolUse", session_id: "s1", cwd: "C:\\p\\proj", tool_name: "Bash", tool_input: { command: "ls" } });
  hook({ hook_event_name: "PostToolUse", session_id: "s2", cwd: "C:\\p\\proj", tool_name: "Bash", tool_input: { command: "npm test" } });
  hook({ hook_event_name: "PreToolUse", session_id: "s1", cwd: "C:\\p\\proj", tool_name: "Bash", tool_input: { command: "npm test" } });
  assert.equal(State.pendingApproval?.requestId, "r1");
  assert.deepEqual(sent("approval_decline"), []);
});

test("a turn ending makes the request moot in the terminal", () => {
  for (const name of ["Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt"]) {
    asked = [];
    calls.length = 0;
    State.pendingApproval = null;
    ask("r1");
    assert.equal(State.pendingApproval?.requestId, "r1", name);
    hook({ hook_event_name: name, session_id: "s1", cwd: "C:\\p\\proj" });
    assert.equal(State.pendingApproval, null, name);
    assert.deepEqual(sent("approval_decline"), [{ requestId: "r1" }], name);
  }
});

test("another session's or agent's turn ending never counts", () => {
  ask("r1");
  hook({ hook_event_name: "Stop", session_id: "s2", cwd: "C:\\p\\proj" });
  assert.equal(State.pendingApproval?.requestId, "r1");
  assert.deepEqual(sent("approval_decline"), []);
});
