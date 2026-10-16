// Claude Code's `git push` brings the GitHub card up with the push on it
// (src/island/integrations.ts pushStarted / pushEnded, wired in hooks.ts).

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { calls, emit, sent } from "./tauri.mjs";
import { registerHookHandlers } from "../src/island/hooks.ts";
import { gitPushCommand, pushRepo } from "../src/island/integrations.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

let asked;
const island = {
  alert: (view) => asked.push(`alert:${view}`),
  setView: (view) => asked.push(`setView:${view}`),
  reveal: () => asked.push("reveal"),
  dropPin: () => asked.push("dropPin"),
  hold: (on) => asked.push(`hold:${on}`),
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

test("a git push is told apart, and where it pushes from", () => {
  assert.equal(gitPushCommand("Bash", { command: "git push origin main" }), "git push origin main");
  assert.equal(gitPushCommand("Bash", { command: "cd repo && git push" }), "cd repo && git push");
  assert.equal(gitPushCommand("Bash", { command: "git status; echo push" }), null);
  assert.equal(gitPushCommand("Read", { command: "git push" }), null);
  assert.equal(pushRepo("cd /home/me/coucou && git push", "/tmp"), "coucou");
  assert.equal(pushRepo('git -C "C:\\work\\bloom" push', "C:\\x"), "bloom");
  assert.equal(pushRepo("git push", "C:\\Users\\me\\proj\\"), "proj");
});

test("Claude Code's git push brings the GitHub card up, held, and lets it go after", () => {
  State.settings = { ...DEFAULT_SETTINGS, activeIntegrations: ["integration_github"] };
  State.loadIntegrationTasks();
  const push = { session_id: "s1", cwd: "C:\\p\\proj", tool_name: "Bash", tool_input: { command: "git push" } };
  hook({ hook_event_name: "PreToolUse", ...push });
  assert.deepEqual(State.githubPush?.state, "pushing");
  assert.equal(State.focusId, "integration_github");
  assert.deepEqual(asked, ["alert:overview", "hold:true"]);
  hook({ hook_event_name: "PostToolUse", ...push });
  assert.equal(State.githubPush?.state, "done");
  assert.deepEqual(sent("refresh_integration"), [{ id: "integration_github" }]);
  mock.timers.tick(8000);
  assert.equal(State.githubPush, null);
  assert.ok(asked.includes("hold:false"));
});
