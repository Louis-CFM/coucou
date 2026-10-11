// The approval card's Y/N keys (the click-deadzone's keyboard half) and the
// solo overview layout, on the fake DOM.

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";

installFakeDom();
const { buildViews } = await import("../src/views/views.ts");
const { DEFAULT_SETTINGS, State } = await import("../src/core/state.ts");

const press = (key, extra = {}) => {
  const e = { type: "keydown", key, target: null, preventDefault() { this.defaultPrevented = true; }, ...extra };
  window.dispatchEvent(e);
  return e;
};

// The card's 600 ms deadzone is measured on performance.now: sync() as if the
// card had appeared a second ago, and the guard has already expired.
const syncPastGuard = (view) => {
  const realNow = performance.now.bind(performance);
  performance.now = () => realNow() - 1000;
  view.sync();
  performance.now = realNow;
};

let decisions, views;
beforeEach(() => {
  installFakeDom(); // fresh window listener registry: no stale keydown handlers
  mock.timers.enable({ apis: ["setTimeout"] });
  decisions = [];
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.view = "approval";
  State.paused = false;
  State.isPinned = false;
  State.pendingApproval = {
    requestId: "r1",
    sessionId: "s1",
    pillId: "integration_claude",
    tool: "Bash",
    command: "Bash · npm test",
  };
  State.settings = { ...DEFAULT_SETTINGS };
  const actions = {
    setView() {}, mailDone() {}, cancelDrop() {}, collapse() {}, foldApproval() {},
    setFocus() {}, openTerminal() {}, openTarget() {}, openUrl() {},
    decide: (d) => decisions.push(d), answer() {}, answerInTerminal() {},
    toggleSound() {}, setVolume() {}, setAutoClose() {}, openSettingsWindow() {},
    blip() {}, chooseOutfit() {}, previewOutfit() {},
  };
  views = buildViews(actions, () => {});
});

afterEach(() => {
  mock.timers.runAll();
  mock.timers.reset();
});

// ── Approval Y/N ──────────────────────────────────────────────────────────────

test("y answers allow, n answers deny, once the card has had a moment", () => {
  const approval = views.get("approval");
  syncPastGuard(approval);
  press("y");
  assert.deepEqual(decisions, ["allow"]);
  // The card is gone after the answer: a second key does nothing.
  State.pendingApproval = null;
  press("n");
  assert.deepEqual(decisions, ["allow"]);
});

test("n answers deny", () => {
  syncPastGuard(views.get("approval"));
  press("n");
  assert.deepEqual(decisions, ["deny"]);
});

test("a key inside the click deadzone does nothing — it may be meant for the window underneath", () => {
  views.get("approval").sync();
  press("y");
  assert.deepEqual(decisions, []);
});

test("y and n stay quiet while another view is on screen", () => {
  State.view = "overview";
  syncPastGuard(views.get("approval"));
  press("y");
  press("n");
  assert.deepEqual(decisions, []);
});

test("a different request than the one shown is never answered", () => {
  syncPastGuard(views.get("approval"));
  State.pendingApproval = { ...State.pendingApproval, requestId: "r2" };
  press("y");
  assert.deepEqual(decisions, []);
});

test("modifiers and autorepeat never answer", () => {
  syncPastGuard(views.get("approval"));
  press("y", { ctrlKey: true });
  press("y", { metaKey: true });
  press("y", { altKey: true });
  press("y", { repeat: true });
  assert.deepEqual(decisions, []);
});

// ── Solo overview ─────────────────────────────────────────────────────────────

test("the overview goes full width when there is nothing to list on the side", () => {
  const overview = views.get("overview");
  overview.sync();
  assert.equal(overview.el.classList.contains("solo"), true);
  // The first pill takes the focus; a second one lands in the side list.
  State.upsertWorkspacePill("integration_claude", "proj", "C:\\proj");
  State.upsertWorkspacePill("integration_n8n", "n8n", "");
  overview.sync();
  assert.equal(overview.el.classList.contains("solo"), false);
});
