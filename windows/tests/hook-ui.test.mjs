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
    testState.timers.set(id, { callback, delay });
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

const { State, codeSessionTaskId, declinePendingApproval, registerHookHandlers } = await import(pathToFileURL(bundledEntry).href);

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

test("Interrupt leaves the session idle instead of marking it finished", () => {
  dispatchHook({ provider: "codex", hook_event_name: "UserPromptSubmit", session_id: "interrupted-session", turn_id: "turn-interrupted", cwd: "C:/work/interrupted", prompt: "work" });
  const task = sessionTask("codex", "interrupted-session");

  dispatchHook({ provider: "codex", hook_event_name: "Interrupt", session_id: "interrupted-session", turn_id: "turn-interrupted" });

  assert.equal(task.state, "idle");
  assert.equal(task.pillBadge, null);
  assert.ok(task.steps.includes("Interrupted"));
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
