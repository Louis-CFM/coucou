// The fix loop (src/island/loop.ts), driven like a Claude Code session: hook
// events in the way Rust emits them, and the word the island hands back to the
// waiting relay read from the loop_answer it invokes.

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { calls, emit, sent } from "./tauri.mjs";
import { registerHookHandlers } from "../src/island/hooks.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";
import { setLanguage } from "../src/i18n/i18n.ts";

const CLAUDE = "integration_claude";
const island = { alert() {}, setView() {}, reveal() {}, dropPin() {} };
registerHookHandlers(island);

const cwd = "C:\\proj";
let session = 0;
let S = "s0";
let n = 0;
// Each event a few milliseconds after the last: the rules go by what came after what.
const hook = (payload) => {
  mock.timers.tick(5);
  emit("hook", { session_id: S, cwd, ...payload });
};
const settle = async () => {
  for (let i = 0; i < 30; i++) await new Promise((r) => setImmediate(r));
};
const steps = () => State.tasks.find((t) => t.id === CLAUDE)?.steps ?? [];

/** A tool call that runs through, with no wait. */
function tool(name, input) {
  const id = `t${++n}`;
  hook({ hook_event_name: "PreToolUse", tool_name: name, tool_use_id: id, tool_input: input });
  hook({ hook_event_name: "PostToolUse", tool_name: name, tool_use_id: id, tool_input: input });
}

/** What the loop answered the relay for one event it waits on: Claude Code's JSON, or null. */
async function waited(payload) {
  const before = sent("loop_answer").length;
  hook({ ...payload, coucou_loop_id: `L${++n}` });
  await settle();
  const answers = sent("loop_answer");
  assert.equal(answers.length, before + 1, "the relay always gets a word");
  const a = answers.at(-1).answer;
  return a == null ? null : JSON.parse(a);
}

/** A test command ran, with this output; the relay waits after it. */
function tests(output, ok = true, command = "npm test") {
  const id = `t${++n}`;
  const input = { command };
  hook({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_use_id: id, tool_input: input });
  return waited({
    hook_event_name: ok ? "PostToolUse" : "PostToolUseFailure",
    tool_name: "Bash", tool_use_id: id, tool_input: input,
    coucou_test_output: output, coucou_test_failed: !ok, coucou_test_stopped: false,
  });
}
const FAIL = "FAIL src/sum.test.js\n  ● sum › adds\n\nTests:       1 failed, 47 passed, 48 total";
const PASS = "PASS src/sum.test.js\nTests:       48 passed, 48 total";
const stop = () => waited({ hook_event_name: "Stop" });
const shipping = (command) => {
  const id = `t${++n}`;
  return waited({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_use_id: id, tool_input: { command } });
};
const editCode = () => tool("Edit", { file_path: "C:\\proj\\src\\sum.js", old_string: "return a + b;", new_string: "return a - b;" });

beforeEach(() => {
  setLanguage("en");
  mock.timers.enable({ apis: ["setTimeout", "Date"], now: 1_800_000_000_000 + session * 3_600_000 });
  calls.length = 0;
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.paused = false;
  State.pendingApproval = null;
  State.settings = { ...DEFAULT_SETTINGS, fixFailingTests: true };
  State.loadIntegrationTasks();
  S = `s${++session}`;
  hook({ hook_event_name: "UserPromptSubmit", prompt: "fix the sum" });
});

afterEach(() => {
  mock.timers.runAll();
  mock.timers.reset();
});

test("a failing run Claude caused: told at once, sent back twice when it stops, then let go", async () => {
  editCode();
  const told = await tests(FAIL, false);
  assert.equal(told.hookSpecificOutput.hookEventName, "PostToolUseFailure");
  assert.match(told.hookSpecificOutput.additionalContext, /^Coucou: this test run failed \(1 failed, 47 passed.*Fix it before you finish/);
  assert.ok(steps().includes("Told Claude to fix them."));

  const first = await stop();
  assert.equal(first.decision, "block");
  assert.match(first.reason, /the tests are failing .* Fix them and run the tests again before you finish/);
  assert.ok(steps().includes("Claude tried to finish with failing tests. Sent it back to fix them."));
  assert.equal(State.tasks.find((t) => t.id === CLAUDE).state, "working", "sent back: still at work");
  assert.equal((await stop()).decision, "block");
  assert.equal(await stop(), null, "at most twice per request");
  assert.ok(steps().includes("Claude stopped, but the tests still fail."));
});

test("tests passing again: fixed, and it may finish", async () => {
  editCode();
  await tests(FAIL, false);
  editCode();
  assert.equal(await tests(PASS), null);
  assert.ok(steps().includes("Fixed: tests pass now ✓"));
  assert.equal(await stop(), null);
});

test("code changed after the last passing run: sent back to run them", async () => {
  editCode();
  await tests(PASS);
  editCode();
  const back = await stop();
  assert.match(back.reason, /you changed sum\.js after the last test run\. Run the tests again before you finish/);
  assert.ok(steps().includes("Claude changed code after the last test run. Sent it back to run them."));
});

test("failures found before Claude changed anything are told, not forced", async () => {
  const told = await tests(FAIL, false);
  assert.match(told.hookSpecificOutput.additionalContext, /were failing before this session changed anything, so they aren't yours to fix/);
  assert.ok(steps().includes("They were failing before Claude changed anything."));
  assert.equal(await stop(), null, "nothing changed: it may stop");
  // Claude then changes code and the same test still fails: not its doing, still not forced.
  editCode();
  await tests(FAIL, false);
  assert.equal(await stop(), null);
});

test("a commit or push while the tests fail is held back; `npm test && git commit` is not", async () => {
  editCode();
  await tests(FAIL, false);
  const denied = await shipping("git commit -am 'sum'");
  assert.equal(denied.hookSpecificOutput.permissionDecision, "deny");
  assert.match(denied.hookSpecificOutput.permissionDecisionReason, /before you commit or push/);
  assert.ok(steps().includes("Stopped a commit or push: the tests are failing."));
  assert.equal(await shipping("npm test && git commit -am 'sum'"), null);
  assert.equal(await shipping("git status"), null);
});

test("a test weakened to pass is caught, and Claude is sent back once to put it back", async () => {
  editCode();
  await tests(FAIL, false);
  tool("Edit", {
    file_path: "C:\\proj\\src\\sum.test.js",
    old_string: "  expect(sum(1, 2)).toBe(3);\n  expect(sum(2, 2)).toBe(4);",
    new_string: "  expect(sum(2, 2)).toBe(4);",
  });
  const caught = await tests(PASS);
  assert.match(caught.hookSpecificOutput.additionalContext, /only after you changed them: removed 1 assertion in sum\.test\.js/);
  assert.ok(steps().includes("Claude changed the tests to make them pass."));
  const back = await stop();
  assert.match(back.reason, /you made the tests pass by changing them/);
  assert.equal(await stop(), null, "sent back for it once");
});

test("an unreadable run: Claude is asked to run them again, then you are asked to look", async () => {
  editCode();
  const again = await tests("done", true, "npm test | tail -5");
  assert.match(again.hookSpecificOutput.additionalContext, /can't tell whether this test run passed: its output went through a pipe/);
  const look = await tests("done", true, "npm test | tail -5");
  assert.match(look.hookSpecificOutput.additionalContext, /asked the user to take a look/);
  assert.ok(steps().includes("Couldn't tell whether Claude's tests passed. Please take a look."));
});

test("with the loop off, or the island paused, the relay is let go at once", async () => {
  State.settings.fixFailingTests = false;
  editCode();
  assert.equal(await tests(FAIL, false), null);
  assert.equal(await stop(), null);
  State.settings.fixFailingTests = true;
  State.paused = true;
  assert.equal(await stop(), null);
});

test("Claude Code in the Claude app is held to the same loop, on its own pill", async () => {
  const desktop = (payload) => ({ ...payload, coucou_agent: "claude-desktop" });
  hook(desktop({ hook_event_name: "UserPromptSubmit", prompt: "fix the sum" }));
  const id = `t${++n}`;
  const input = { file_path: "C:\\proj\\src\\sum.js", old_string: "a + b", new_string: "a - b" };
  hook(desktop({ hook_event_name: "PreToolUse", tool_name: "Edit", tool_use_id: id, tool_input: input }));
  hook(desktop({ hook_event_name: "PostToolUse", tool_name: "Edit", tool_use_id: id, tool_input: input }));
  const run = `t${++n}`;
  hook(desktop({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_use_id: run, tool_input: { command: "npm test" } }));
  await waited(desktop({
    hook_event_name: "PostToolUseFailure", tool_name: "Bash", tool_use_id: run, tool_input: { command: "npm test" },
    coucou_test_output: FAIL, coucou_test_failed: true,
  }));
  const back = await waited(desktop({ hook_event_name: "Stop" }));
  assert.equal(back.decision, "block");
  const pill = State.tasks.find((t) => t.id === "agent_claude-desktop");
  assert.ok(pill.steps.includes("Claude tried to finish with failing tests. Sent it back to fix them."));
  assert.equal(pill.state, "working");
});

test("another agent's events are not the loop's", async () => {
  hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "codex" });
  const id = "c1";
  hook({ hook_event_name: "PreToolUse", coucou_agent: "codex", tool_name: "Bash", tool_use_id: id, tool_input: { command: "npm test" } });
  const before = sent("loop_answer").length;
  hook({
    hook_event_name: "PostToolUse", coucou_agent: "codex", tool_name: "Bash", tool_use_id: id,
    tool_input: { command: "npm test" }, coucou_test_output: FAIL, coucou_loop_id: "Lc",
  });
  await settle();
  assert.equal(sent("loop_answer").length, before + 1);
  assert.equal(sent("loop_answer").at(-1).answer, null);
});
