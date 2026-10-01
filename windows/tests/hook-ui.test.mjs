import assert from "node:assert/strict";
import { after, beforeEach, test } from "node:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const windowsRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const temporary = await mkdtemp(join(tmpdir(), "coucou-hook-ui-test-"));
const bundledEntry = join(temporary, "hook-ui-entry.mjs");
const testState = {
  handlers: new Map(),
  bridgeCalls: [],
  sounds: [],
  timers: new Map(),
  nextTimerId: 1,
};

globalThis.__coucouHookUiTest = testState;
globalThis.window = {
  setTimeout(callback, delay) {
    const id = testState.nextTimerId++;
    testState.timers.set(id, {
      callback: () => {
        testState.timers.delete(id);
        callback();
      },
      delay,
    });
    return id;
  },
  clearTimeout(id) {
    testState.timers.delete(id);
  },
};

await build({
  entryPoints: [resolve(windowsRoot, "tests/hook-ui-entry.ts")],
  bundle: true,
  format: "esm",
  platform: "node",
  target: "node20",
  outfile: bundledEntry,
  logLevel: "silent",
  plugins: [
    {
      name: "mock-coucou-bridge-and-sound",
      setup(buildApi) {
        buildApi.onResolve({ filter: /\.\.\/core\/bridge$/ }, () => ({ path: "bridge", namespace: "coucou-test" }));
        buildApi.onResolve({ filter: /\.\.\/core\/sound$/ }, () => ({ path: "sound", namespace: "coucou-test" }));
        buildApi.onLoad({ filter: /.*/, namespace: "coucou-test" }, (args) => ({
          loader: "js",
          contents: args.path === "bridge"
            ? `
                export const Bridge = {
                  approvalAck: (id) => globalThis.__coucouHookUiTest.bridgeCalls.push(["ack", id]),
                  approvalDecline: (id) => globalThis.__coucouHookUiTest.bridgeCalls.push(["decline", id]),
                };
                export function onEvent(name, handler) {
                  globalThis.__coucouHookUiTest.handlers.set(name, handler);
                  return Promise.resolve(() => {});
                }
              `
            : `export const Sound = { play: (name) => globalThis.__coucouHookUiTest.sounds.push(name) };`,
        }));
      },
    },
  ],
});

const { State, codeSessionTaskId, declinePendingApproval, registerHookHandlers, unseenTickerSteps } = await import(pathToFileURL(bundledEntry).href);

const islandCalls = [];
const island = {
  alert: (view) => islandCalls.push(["alert", view]),
  setView: (view) => islandCalls.push(["setView", view]),
  reveal: () => islandCalls.push(["reveal"]),
  dropPin: () => islandCalls.push(["dropPin"]),
};

registerHookHandlers(island);
const dispatchHook = (payload) => testState.handlers.get("hook")(payload);

function resetState() {
  State.tasks = [];
  State.focusId = null;
  State.loadIntegrationTasks();
  State.pendingApproval = null;
  State.paused = false;
  State.isPinned = false;
  State.mode = "hidden";
  State.view = "overview";
  State.stateOverride = null;
  testState.bridgeCalls.length = 0;
  testState.sounds.length = 0;
  testState.timers.clear();
  islandCalls.length = 0;
}

function sessionTask(provider, sessionId) {
  return State.tasks.find((task) => task.id === codeSessionTaskId(provider, sessionId));
}

beforeEach(resetState);
after(async () => {
  delete globalThis.__coucouHookUiTest;
  delete globalThis.window;
  await rm(temporary, { recursive: true, force: true });
});

test("same session id stays isolated across Claude and Codex providers", () => {
  dispatchHook({
    provider: "claude", hook_event_name: "UserPromptSubmit", session_id: "shared-session",
    turn_id: "claude-turn", cwd: "C:/work/claude-project", prompt: "Claude task",
  });
  dispatchHook({
    provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "shared-session",
    turn_id: "codex-turn", cwd: "C:/work/codex-project", prompt: "Codex task",
  });

  const claude = sessionTask("claude", "shared-session");
  const codex = sessionTask("codex", "shared-session");
  assert.ok(claude);
  assert.ok(codex);
  assert.notEqual(claude.id, codex.id);
  assert.equal(claude.source, "claudeCode");
  assert.equal(codex.source, "codex");
  assert.equal(claude.name, "claude-project");
  assert.equal(codex.name, "codex-project");
  assert.deepEqual(claude.steps, ["Claude task"]);
  assert.deepEqual(codex.steps, ["Codex task"]);
});

test("live sessions lead the pills and the first one gets focus without stealing it later", () => {
  dispatchHook({ provider: "codex", hook_event_name: "SessionStart", session_id: "focus-one", cwd: "C:/work/one" });
  const first = sessionTask("codex", "focus-one");
  assert.ok(first);
  assert.equal(State.focusId, first.id);

  dispatchHook({ provider: "codex", hook_event_name: "SessionStart", session_id: "focus-two", cwd: "C:/work/two" });
  const second = sessionTask("codex", "focus-two");
  assert.ok(second);
  assert.equal(State.focusId, first.id);
  assert.deepEqual(State.tasks.slice(0, 2), [first, second]);

  State.setFocus("integration_claude");
  dispatchHook({ provider: "codex", hook_event_name: "PreToolUse", session_id: "focus-two", turn_id: "turn-two", cwd: "C:/work/two", tool_name: "Bash", tool_input: { command: "git status" } });
  assert.equal(State.focusId, "integration_claude");
});

test("all sessions stay pill-addressable and recent active sessions rise without changing focus", () => {
  const sessionIds = Array.from({ length: 7 }, (_, index) => `many-session-${index + 1}`);
  for (const [index, sessionId] of sessionIds.entries()) {
    dispatchHook({ provider: "codex", hook_event_name: "SessionStart", session_id: sessionId, cwd: `C:/work/session-${index + 1}` });
  }
  const focusedId = State.focusId;
  assert.equal(focusedId, codeSessionTaskId("codex", sessionIds[0]));

  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: sessionIds[1], turn_id: "older-turn", cwd: "C:/work/session-2", prompt: "older active session" });
  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: sessionIds[6], turn_id: "recent-turn", cwd: "C:/work/session-7", prompt: "recent active session" });

  const availableSessions = State.otherTasks.filter((task) => !task.isIntegration);
  assert.equal(availableSessions.length, 6);
  assert.deepEqual(new Set(availableSessions.map((task) => task.sessionId)), new Set(sessionIds.slice(1)));
  assert.equal(State.otherTasks[0].sessionId, sessionIds[6]);
  assert.deepEqual(State.otherTasks.slice(0, 4).map((task) => task.sessionId).filter(Boolean).slice(0, 2), [sessionIds[6], sessionIds[1]]);
  assert.equal(State.focusId, focusedId);
});

test("ticker detects new events after the bounded step list rolls", () => {
  const previous = Array.from({ length: 20 }, (_, index) => `step-${index + 1}`);
  const current = [...previous.slice(1), "step-21"];
  const afterSeveral = [...previous.slice(4), "step-21", "step-22", "step-23", "step-24"];

  assert.deepEqual(unseenTickerSteps(previous, current), ["step-21"]);
  assert.deepEqual(unseenTickerSteps(previous, afterSeveral), ["step-21", "step-22", "step-23", "step-24"]);
});

test("removing a focused session selects another live session, then its provider card", () => {
  dispatchHook({ provider: "codex", hook_event_name: "SessionStart", session_id: "focus-end-one", cwd: "C:/work/one" });
  dispatchHook({ provider: "codex", hook_event_name: "SessionStart", session_id: "focus-end-two", cwd: "C:/work/two" });
  const first = sessionTask("codex", "focus-end-one");
  const second = sessionTask("codex", "focus-end-two");
  assert.ok(first && second);

  dispatchHook({ provider: "codex", hook_event_name: "SessionEnd", session_id: "focus-end-one" });
  assert.equal(State.focusId, second.id);
  dispatchHook({ provider: "codex", hook_event_name: "SessionEnd", session_id: "focus-end-two" });
  assert.equal(State.focusId, "integration_codex");
});

test("a stale Stop from an earlier turn cannot finish the current turn", () => {
  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "stale-stop", turn_id: "turn-new", cwd: "C:/work/stale-stop", prompt: "new" });
  dispatchHook({ provider: "codex", hook_event_name: "PreToolUse", session_id: "stale-stop", turn_id: "turn-new", cwd: "C:/work/stale-stop", tool_name: "Bash", tool_input: { command: "cargo test" } });
  const task = sessionTask("codex", "stale-stop");

  dispatchHook({ provider: "codex", hook_event_name: "Stop", session_id: "stale-stop", turn_id: "turn-old", last_assistant_message: "old turn" });

  assert.equal(task.state, "working");
  assert.ok(task.pillBadge == null);
  assert.ok(!task.steps.includes("old turn"));
});

test("a delayed finish timer cannot clear a newer run", () => {
  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "finish-timer", turn_id: "turn-1", cwd: "C:/work/finish-timer", prompt: "first" });
  dispatchHook({ provider: "codex", hook_event_name: "Stop", session_id: "finish-timer", turn_id: "turn-1", last_assistant_message: "done" });
  const task = sessionTask("codex", "finish-timer");
  const [timerId, timer] = [...testState.timers.entries()][0];
  assert.equal(timer.delay, 5200);
  assert.equal(task.state, "finished");

  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "finish-timer", turn_id: "turn-2", cwd: "C:/work/finish-timer", prompt: "second" });
  assert.ok(!testState.timers.has(timerId));
  timer.callback(); // A callback already queued by the host must still be harmless.

  assert.equal(task.state, "thinking");
  assert.equal(task.pillBadge, null);
  assert.deepEqual(task.steps.slice(-1), ["second"]);
});

test("a turnless delayed Stop cannot finish a known newer turn", () => {
  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "turnless-stop", turn_id: "turn-current", cwd: "C:/work/turnless", prompt: "current" });
  dispatchHook({ provider: "codex", hook_event_name: "PreToolUse", session_id: "turnless-stop", turn_id: "turn-current", cwd: "C:/work/turnless", tool_name: "Bash", tool_input: { command: "cargo test" } });
  const task = sessionTask("codex", "turnless-stop");

  dispatchHook({ provider: "codex", hook_event_name: "Stop", session_id: "turnless-stop", cwd: "C:/work/turnless", last_assistant_message: "ambiguous old stop" });

  assert.equal(task.state, "working");
  assert.ok(!task.steps.includes("ambiguous old stop"));
});

test("a delayed prompt from a retired turn cannot rewind the live turn", () => {
  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "retired-prompt", turn_id: "turn-old", cwd: "C:/work/retired", prompt: "old prompt" });
  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "retired-prompt", turn_id: "turn-current", cwd: "C:/work/retired", prompt: "current prompt" });
  dispatchHook({ provider: "codex", hook_event_name: "PreToolUse", session_id: "retired-prompt", turn_id: "turn-current", cwd: "C:/work/retired", tool_name: "Bash", tool_input: { command: "git status" } });
  const task = sessionTask("codex", "retired-prompt");
  const stepsBeforeLatePrompt = [...task.steps];

  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "retired-prompt", turn_id: "turn-old", cwd: "C:/work/retired", prompt: "late old prompt" });
  dispatchHook({ provider: "codex", hook_event_name: "Stop", session_id: "retired-prompt", turn_id: "turn-old", last_assistant_message: "late old stop" });

  assert.equal(task.state, "working");
  assert.deepEqual(task.steps, stepsBeforeLatePrompt);
});

test("a delayed SessionStart cannot clear an already active turn", () => {
  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "late-session-start", turn_id: "active-turn", cwd: "C:/work/late-start", prompt: "current work" });
  const task = sessionTask("codex", "late-session-start");

  dispatchHook({ provider: "codex", hook_event_name: "SessionStart", session_id: "late-session-start", cwd: "C:/work/late-start" });

  assert.equal(task.state, "thinking");
  assert.deepEqual(task.steps, ["current work"]);
});

test("same-turn tool events after Stop stay terminal until a new turn", () => {
  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "terminal-turn", turn_id: "turn-ended", cwd: "C:/work/terminal", prompt: "finish this" });
  dispatchHook({ provider: "codex", hook_event_name: "Stop", session_id: "terminal-turn", turn_id: "turn-ended", last_assistant_message: "done" });
  const task = sessionTask("codex", "terminal-turn");

  dispatchHook({ provider: "codex", hook_event_name: "PostToolUse", session_id: "terminal-turn", turn_id: "turn-ended", tool_name: "Bash", tool_status: "success" });
  assert.equal(task.state, "finished");

  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "terminal-turn", turn_id: "turn-next", cwd: "C:/work/terminal", prompt: "next turn" });
  dispatchHook({ provider: "codex", hook_event_name: "PostToolUse", session_id: "terminal-turn", turn_id: "turn-ended", tool_name: "Bash", tool_status: "success" });
  assert.equal(task.state, "thinking");
  assert.equal(task.steps.at(-1), "next turn");
});

test("an overlapping approval is declined without replacing the visible request", () => {
  dispatchHook({ provider: "codex", hook_event_name: "PermissionRequest", request_id: "approval-1", session_id: "approval-session-1", turn_id: "turn-1", cwd: "C:/work/one", tool_name: "Bash", tool_input: { command: "git status" } });
  const original = State.pendingApproval;
  assert.equal(original.requestId, "approval-1");
  assert.deepEqual(testState.bridgeCalls, [["ack", "approval-1"]]);

  dispatchHook({ provider: "codex", hook_event_name: "PermissionRequest", request_id: "approval-2", session_id: "approval-session-2", turn_id: "turn-2", cwd: "C:/work/two", tool_name: "Bash", tool_input: { command: "Remove-Item data" } });

  assert.equal(State.pendingApproval, original);
  assert.deepEqual(testState.bridgeCalls, [["ack", "approval-1"], ["decline", "approval-2"]]);
  assert.equal(sessionTask("codex", "approval-session-2").state, "idle");
});

test("an approval arriving while paused is declined without showing a card", () => {
  State.paused = true;
  dispatchHook({ provider: "codex", hook_event_name: "PermissionRequest", request_id: "paused-approval", session_id: "paused-session", tool_name: "Bash", tool_input: { command: "echo test" } });

  assert.equal(State.pendingApproval, null);
  assert.deepEqual(testState.bridgeCalls, [["decline", "paused-approval"]]);
  assert.deepEqual(islandCalls, []);
});

test("a reused request id from another session cannot close the visible approval", () => {
  dispatchHook({ provider: "codex", hook_event_name: "PermissionRequest", request_id: "same-approval-id", session_id: "same-session-one", turn_id: "turn-one", cwd: "C:/work/one", tool_name: "Bash", tool_input: { command: "git status" } });
  const original = State.pendingApproval;

  dispatchHook({ provider: "codex", hook_event_name: "PermissionRequest", request_id: "same-approval-id", session_id: "same-session-two", turn_id: "turn-two", cwd: "C:/work/two", tool_name: "Bash", tool_input: { command: "echo other" } });

  assert.equal(State.pendingApproval, original);
  assert.deepEqual(testState.bridgeCalls, [["ack", "same-approval-id"]]);
});

test("approval closure matches the exact request, session and turn", () => {
  dispatchHook({ provider: "codex", hook_event_name: "PermissionRequest", request_id: "close-approval", session_id: "close-session", turn_id: "close-turn", cwd: "C:/work/close", tool_name: "Bash", tool_input: { command: "git status" } });
  const original = State.pendingApproval;
  assert.ok(original);
  const timerId = [...testState.timers.keys()][0];

  dispatchHook({ provider: "codex", hook_event_name: "PermissionRequestClosed", request_id: "close-approval", session_id: "other-session", turn_id: "close-turn", resolution: "disconnected" });
  dispatchHook({ provider: "codex", hook_event_name: "PermissionRequestClosed", request_id: "close-approval", session_id: "close-session", turn_id: "old-turn", resolution: "disconnected" });
  assert.equal(State.pendingApproval, original);
  assert.ok(testState.timers.has(timerId));
  State.paused = true;

  dispatchHook({ provider: "codex", hook_event_name: "PermissionRequestClosed", request_id: "close-approval", session_id: "close-session", turn_id: "close-turn", resolution: "disconnected" });
  assert.equal(State.pendingApproval, null);
  assert.ok(!testState.timers.has(timerId));
  assert.equal(sessionTask("codex", "close-session").steps.at(-1), "Approval returned to Codex");
});

test("an approval timeout declines and clears only its active request", () => {
  dispatchHook({ provider: "codex", hook_event_name: "PermissionRequest", request_id: "timed-approval", session_id: "timed-session", turn_id: "timed-turn", cwd: "C:/work/timed", tool_name: "Bash", tool_input: { command: "git status" } });
  const request = State.pendingApproval;
  const [timerId, timer] = [...testState.timers.entries()][0];
  assert.equal(timer.delay, 110_000);

  timer.callback();

  assert.equal(State.pendingApproval, null);
  assert.ok(!testState.timers.has(timerId));
  assert.deepEqual(testState.bridgeCalls.slice(-1), [["decline", "timed-approval"]]);
  assert.equal(sessionTask("codex", "timed-session").steps.at(-1), "Approval timed out; returned to Codex");
  assert.notEqual(request, State.pendingApproval);
});

test("a new turn closes only its own session's old approval", () => {
  dispatchHook({ provider: "codex", hook_event_name: "PermissionRequest", request_id: "superseded-approval", session_id: "superseded-session", turn_id: "turn-old", cwd: "C:/work/old", tool_name: "Bash", tool_input: { command: "git status" } });
  const original = State.pendingApproval;
  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "other-live-session", turn_id: "other-turn", cwd: "C:/work/other", prompt: "keep the other session separate" });
  assert.equal(State.pendingApproval, original);

  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "superseded-session", turn_id: "turn-new", cwd: "C:/work/old", prompt: "new turn" });

  assert.equal(State.pendingApproval, null);
  assert.deepEqual(testState.bridgeCalls.slice(-1), [["decline", "superseded-approval"]]);
  assert.equal(sessionTask("codex", "superseded-session").state, "thinking");
  assert.equal(sessionTask("codex", "other-live-session").state, "thinking");
});

test("pausing clears and declines the approval already on screen", () => {
  dispatchHook({ provider: "codex", hook_event_name: "PermissionRequest", request_id: "visible-approval", session_id: "visible-session", tool_name: "Bash", tool_input: { command: "git status" } });
  const task = sessionTask("codex", "visible-session");
  State.view = "approval";
  State.paused = true;

  declinePendingApproval(island);

  assert.equal(State.pendingApproval, null);
  assert.equal(State.isPinned, false);
  assert.equal(task.state, "working");
  assert.equal(task.pillBadge, null);
  assert.deepEqual(testState.bridgeCalls, [["ack", "visible-approval"], ["decline", "visible-approval"]]);
  assert.ok(islandCalls.some(([name, value]) => name === "setView" && value === "overview"));
});

test("the full Codex patch remains in the approval target", () => {
  const patchText = `*** Begin Patch\n${"+preserve this exact patch line\n".repeat(2500)}*** End Patch`;
  dispatchHook({ provider: "codex", hook_event_name: "PermissionRequest", request_id: "patch-approval", session_id: "patch-session", tool_name: "apply_patch", tool_input: { patch: patchText } });

  assert.equal(State.pendingApproval.command, `apply_patch · full patch:\n${patchText}`);
  assert.ok(State.pendingApproval.command.endsWith(patchText));
});

test("Interrupt remains visible as a distinct status and badge", () => {
  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "interrupted-session", turn_id: "turn-interrupted", cwd: "C:/work/interrupted", prompt: "work" });
  const task = sessionTask("codex", "interrupted-session");
  State.setFocus("integration_claude");

  dispatchHook({ provider: "codex", hook_event_name: "Interrupt", session_id: "interrupted-session", turn_id: "turn-interrupted" });

  assert.equal(task.state, "interrupted");
  assert.equal(task.pillBadge, "interrupted");
  assert.ok(task.steps.includes("Interrupted"));

  dispatchHook({ provider: "codex", hook_event_name: "PostToolUse", session_id: "interrupted-session", turn_id: "turn-interrupted", tool_status: "success" });
  assert.equal(task.state, "interrupted");
});

test("SessionEnd declines and clears the approval for that session", () => {
  dispatchHook({ provider: "codex", hook_event_name: "PermissionRequest", request_id: "ending-approval", session_id: "ending-session", turn_id: "ending-turn", cwd: "C:/work/ending", tool_name: "Bash", tool_input: { command: "git status" } });
  const timerId = [...testState.timers.keys()][0];

  dispatchHook({ provider: "codex", hook_event_name: "SessionEnd", session_id: "ending-session" });

  assert.equal(State.pendingApproval, null);
  assert.ok(!testState.timers.has(timerId));
  assert.deepEqual(testState.bridgeCalls.slice(-1), [["decline", "ending-approval"]]);
  assert.equal(sessionTask("codex", "ending-session"), undefined);
});

test("SessionEnd removes only the matching provider and session", () => {
  for (const [provider, sessionId, cwd] of [
    ["codex", "shared-end", "C:/work/codex-one"],
    ["codex", "other-end", "C:/work/codex-two"],
    ["claude", "shared-end", "C:/work/claude-one"],
  ]) {
    dispatchHook({ provider, hook_event_name: "SessionStart", session_id: sessionId, cwd });
  }
  const ending = sessionTask("codex", "shared-end");
  const codexOther = sessionTask("codex", "other-end");
  const claudeSameId = sessionTask("claude", "shared-end");
  assert.ok(ending && codexOther && claudeSameId);

  dispatchHook({ provider: "codex", hook_event_name: "SessionEnd", session_id: "shared-end", cwd: "C:/work/codex-one" });

  assert.equal(sessionTask("codex", "shared-end"), undefined);
  assert.equal(sessionTask("codex", "other-end"), codexOther);
  assert.equal(sessionTask("claude", "shared-end"), claudeSameId);
});

test("late events cannot resurrect a closed session, but a later SessionStart can reopen it", () => {
  dispatchHook({ provider: "codex", hook_event_name: "SessionStart", session_id: "closed-session", turn_id: "old-turn", cwd: "C:/work/closed" });
  dispatchHook({ provider: "codex", hook_event_name: "SessionEnd", session_id: "closed-session" });
  assert.equal(sessionTask("codex", "closed-session"), undefined);

  dispatchHook({ provider: "codex", hook_event_name: "PreToolUse", session_id: "closed-session", turn_id: "old-turn", cwd: "C:/work/closed", tool_name: "Bash", tool_input: { command: "late" } });
  assert.equal(sessionTask("codex", "closed-session"), undefined);

  dispatchHook({ provider: "codex", hook_event_name: "SessionStart", session_id: "closed-session", turn_id: "new-turn", cwd: "C:/work/closed" });
  const reopened = sessionTask("codex", "closed-session");
  assert.ok(reopened);
  dispatchHook({ provider: "codex", hook_event_name: "Stop", session_id: "closed-session", turn_id: "old-turn", last_assistant_message: "stale after reopen" });
  assert.equal(reopened.state, "idle");
  assert.ok(!reopened.steps.includes("stale after reopen"));
});

test("SessionEnd closes its session even when its turn id is older", () => {
  dispatchHook({ provider: "codex", hook_event_name: "SessionStart", session_id: "old-end-turn", turn_id: "turn-session-start", cwd: "C:/work/end" });
  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "old-end-turn", turn_id: "turn-one", cwd: "C:/work/end", prompt: "one" });
  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "old-end-turn", turn_id: "turn-two", cwd: "C:/work/end", prompt: "two" });
  dispatchHook({ provider: "codex", hook_event_name: "SessionEnd", session_id: "old-end-turn", turn_id: "turn-one" });

  assert.equal(sessionTask("codex", "old-end-turn"), undefined);
});

test("SessionEnd tombstones a session while paused", () => {
  dispatchHook({ provider: "codex", hook_event_name: "SessionStart", session_id: "paused-ended", cwd: "C:/work/paused-ended" });
  State.paused = true;
  dispatchHook({ provider: "codex", hook_event_name: "SessionEnd", session_id: "paused-ended" });
  State.paused = false;

  dispatchHook({ provider: "codex", hook_event_name: "PreToolUse", session_id: "paused-ended", cwd: "C:/work/paused-ended", tool_name: "Bash", tool_input: { command: "late" } });

  assert.equal(sessionTask("codex", "paused-ended"), undefined);
});
