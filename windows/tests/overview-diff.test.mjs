// The overview with a file's diff open (src/views/views.ts): the island grows
// to WIDE_CARD_H and the left card takes the whole width, like the chat; closing the
// diff or leaving the overview gives the overview its own size back.

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { emit } from "./tauri.mjs";

installFakeDom();
// The overview listens for Escape on the window (to step out of the diff), and
// the diff card gathers its lines in a fragment: a plain element stands in.
window.addEventListener ??= () => {};
document.createDocumentFragment ??= () => document.createElement("div");
const { buildViews } = await import("../src/views/views.ts");
const { registerHookHandlers } = await import("../src/island/hooks.ts");
const { DEFAULT_SETTINGS, State } = await import("../src/core/state.ts");
const { WIDE_CARD_H, islandSize } = await import("../src/core/layout.ts");

registerHookHandlers({ alert() {}, setView() {}, reveal() {}, dropPin() {} });

const CLAUDE = "integration_claude";
const noop = () => {};
const actions = new Proxy({}, { get: () => noop });

let overview;
let heightChanges;

// The views and the diff expiry run timers: kept fake, so the file can end.
beforeEach(() => mock.timers.enable({ apis: ["setTimeout", "setInterval"] }));
afterEach(() => mock.timers.reset());

beforeEach(() => {
  for (const id of [...State.sessionDiffs.keys()]) State.clearSessionDiffs(id);
  State.tasks = [];
  State.settings = { ...DEFAULT_SETTINGS };
  State.loadIntegrationTasks();
  State.paused = false;
  State.pendingApproval = null;
  emit("hook", {
    hook_event_name: "PostToolUse",
    cwd: "/p/proj",
    tool_name: "Edit",
    tool_input: { file_path: "/p/proj/src/app.ts", old_string: "a\nb\n", new_string: "a\nc\nd\n" },
  });
  State.setFocus(CLAUDE);
  State.mode = "expanded";
  State.view = "overview";
  State.wideCard = false;
  heightChanges = 0;
  overview = buildViews(actions, () => heightChanges++).get("overview");
  overview.sync();
});

test("opening a diff grows the island and gives the left card the whole width", () => {
  assert.equal(State.wideCard, false);
  overview.command("toggleDiff"); // Ctrl+E: the latest edit
  overview.sync();
  assert.equal(State.wideCard, true);
  assert.ok(overview.el.classList.contains("wide"));
  assert.equal(heightChanges, 1);
  assert.ok(overview.el.find(".diff-card").length === 1);
  assert.ok(WIDE_CARD_H > islandSize("expanded", "overview").h);
});

test("closing the diff gives the overview its own size back", () => {
  overview.command("toggleDiff");
  overview.sync();
  overview.command("toggleDiff");
  overview.sync();
  assert.equal(State.wideCard, false);
  assert.ok(!overview.el.classList.contains("wide"));
  assert.equal(heightChanges, 2);
});

test("leaving the overview closes the diff and its size with it", () => {
  overview.command("toggleDiff");
  overview.sync();
  State.view = "prompt";
  State.notify();
  assert.equal(State.wideCard, false);
  assert.ok(!overview.el.classList.contains("wide"));
});
