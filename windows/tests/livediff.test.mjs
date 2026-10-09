// Live diff and the finished line, end to end through the hook handler: file
// edits become ticker steps with their diff stored (and bounded), and Stop leaves
// Claude's final message on the card until the next turn.

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { emit } from "./tauri.mjs";
import { registerHookHandlers } from "../src/island/hooks.ts";
import { DEFAULT_SETTINGS, DIFF_TTL_MS, MAX_DIFFS_PER_PILL, State } from "../src/core/state.ts";
import { parseDiffStep } from "../src/core/diff.ts";

const CLAUDE = "integration_claude";

const island = { alert() {}, setView() {}, reveal() {}, dropPin() {}, collapse() {}, hide() {},
  canAutoPopup: () => !State.pendingApproval && !State.isPinned };
registerHookHandlers(island);

const hook = (payload) => emit("hook", payload);
const task = (id = CLAUDE) => State.tasks.find((t) => t.id === id);
const diffs = (id = CLAUDE) => State.sessionDiffs.get(id) ?? [];

const edit = (extra = {}) =>
  hook({
    hook_event_name: "PostToolUse",
    cwd: "/p/proj",
    tool_name: "Edit",
    tool_input: { file_path: "/p/proj/src/app.ts", old_string: "a\nb\n", new_string: "a\nc\nd\n" },
    ...extra,
  });

beforeEach(() => {
  mock.timers.enable({ apis: ["setTimeout"] });
  for (const id of [...State.sessionDiffs.keys()]) State.clearSessionDiffs(id);
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.view = "overview";
  State.paused = false;
  State.isPinned = false;
  State.pendingApproval = null;
  State.finishedPopup = null;
  State.settings = { ...DEFAULT_SETTINGS };
  State.loadIntegrationTasks();
});

afterEach(() => {
  mock.timers.runAll();
  mock.timers.reset();
});

// ── Live diff ─────────────────────────────────────────────────────────────────

test("a finished Edit adds a diff step with its counts, and keeps the diff", () => {
  edit();
  const step = parseDiffStep(task().steps.at(-1));
  assert.deepEqual({ ...step, diffId: undefined }, { filename: "app.ts", added: 2, removed: 1, diffId: undefined });
  const diff = State.findDiff(CLAUDE, step.diffId);
  assert.equal(diff.path, "/p/proj/src/app.ts");
  assert.ok(diff.hunks.length > 0);
});

test("Write and MultiEdit are diffed too; other tools and PreToolUse are not", () => {
  hook({ hook_event_name: "PostToolUse", tool_name: "Write", tool_input: { file_path: "C:\\p\\new.md", content: "x\ny\n" } });
  assert.deepEqual(parseDiffStep(task().steps.at(-1)).filename, "new.md");
  hook({
    hook_event_name: "PostToolUse",
    tool_name: "MultiEdit",
    tool_input: { file_path: "/p/m.ts", edits: [{ old_string: "a", new_string: "b" }, { old_string: "c", new_string: "d" }] },
  });
  const multi = parseDiffStep(task().steps.at(-1));
  assert.deepEqual([multi.added, multi.removed], [2, 2]);

  const before = task().steps.length;
  hook({ hook_event_name: "PostToolUse", tool_name: "Bash", tool_input: { command: "ls" } });
  hook({ hook_event_name: "PreToolUse", tool_name: "Edit", tool_input: { file_path: "/p/a.ts", old_string: "a", new_string: "b" } });
  assert.equal(task().steps.length, before + 1); // only the PreToolUse label
  assert.equal(parseDiffStep(task().steps.at(-1)), null);
  assert.equal(diffs().length, 2);
});

test("an edit with no change, or one the relay had to cut, adds no diff", () => {
  hook({ hook_event_name: "PostToolUse", tool_name: "Edit", tool_input: { file_path: "/p/a.ts", old_string: "same", new_string: "same" } });
  edit({ coucou_diff_truncated: true });
  assert.deepEqual(task().steps, []);
  assert.equal(diffs().length, 0);
});

test("diffs are capped per pill, oldest first, and ids stay unique", () => {
  for (let i = 0; i < MAX_DIFFS_PER_PILL + 5; i++) edit();
  const kept = diffs();
  assert.equal(kept.length, MAX_DIFFS_PER_PILL);
  assert.equal(new Set(kept.map((d) => d.id)).size, MAX_DIFFS_PER_PILL);
  // The ticker keeps fewer steps than diffs; every step still finds its diff.
  for (const s of task().steps) assert.ok(State.findDiff(CLAUDE, parseDiffStep(s).diffId));
  // The first ones are gone: tapping their step would be a no-op.
  assert.equal(State.findDiff(CLAUDE, kept[0].id - 1), null);
});

test("diffs are forgotten an hour after the last one, and at the end of the session", () => {
  edit();
  mock.timers.tick(DIFF_TTL_MS - 1000);
  edit(); // re-arms the hour
  mock.timers.tick(2000);
  assert.equal(diffs().length, 2);
  mock.timers.tick(DIFF_TTL_MS);
  assert.equal(diffs().length, 0);

  edit();
  hook({ hook_event_name: "SessionEnd", cwd: "/p/proj" });
  assert.equal(diffs().length, 0);
});

test("an agent pill's diffs go with the pill", () => {
  hook({ hook_event_name: "PreToolUse", coucou_agent: "gemini", tool_name: "Edit", tool_input: { file_path: "/p/a.ts" } });
  edit({ coucou_agent: "gemini" });
  assert.equal(diffs("agent_gemini").length, 1);
  hook({ hook_event_name: "SessionEnd", coucou_agent: "gemini" });
  assert.equal(task("agent_gemini"), undefined);
  assert.equal(State.sessionDiffs.has("agent_gemini"), false);
  // An event for a pill that does not exist stores nothing.
  edit({ coucou_agent: "ghost" });
  assert.equal(State.sessionDiffs.has("agent_ghost"), false);
});

// ── Final message ─────────────────────────────────────────────────────────────

test("Stop shows the first paragraph of Claude's final message, on one line", () => {
  hook({
    hook_event_name: "Stop",
    last_assistant_message: "**Done.** Fixed the `parser` and\nadded tests.\n\n## Details\n- a\n- b",
  });
  const line = "Done. Fixed the parser and added tests.";
  assert.equal(task().finalLine, line);
  assert.equal(task().steps.at(-1), line);
});

test("Stop falls back to `message`, and adds nothing when both are empty", () => {
  hook({ hook_event_name: "Stop", message: "All good." });
  assert.equal(task().finalLine, "All good.");
  hook({ hook_event_name: "UserPromptSubmit", prompt: "again" });
  hook({ hook_event_name: "Stop", last_assistant_message: "\n\n---\n" });
  assert.equal(task().finalLine, null);
  assert.equal(task().steps.at(-1), "…");
});

test("a long final message is kept to 200 characters", () => {
  hook({ hook_event_name: "Stop", last_assistant_message: "word ".repeat(100) });
  assert.ok(task().finalLine.length <= 200);
});

for (const [what, event] of [
  ["a new prompt", { hook_event_name: "UserPromptSubmit", prompt: "next" }],
  ["a tool starting", { hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: "ls" } }],
  ["a new session", { hook_event_name: "SessionStart" }],
  ["the end of the session", { hook_event_name: "SessionEnd" }],
]) {
  test(`the final message stays until ${what}`, () => {
    hook({ hook_event_name: "Stop", last_assistant_message: "Done." });
    mock.timers.tick(5200); // back to idle: the line is still there
    assert.equal(task().state, "idle");
    assert.equal(task().finalLine, "Done.");
    hook({ cwd: "/p/proj", ...event });
    assert.equal(task().finalLine, null);
  });
}
