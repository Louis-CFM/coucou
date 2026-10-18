// Windows and Linux additions: the desktop Mochi wears the look of the Mochi
// dragged out of the island.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { sent } from "./tauri.mjs";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";
import { DesktopLink } from "../src/island/desktop.ts";
import { MAIN_MOCHI } from "../src/mochi/wardrobe.ts";

beforeEach(() => {
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.view = "overview";
  State.paused = false;
  State.settings = { ...DEFAULT_SETTINGS };
  State.loadIntegrationTasks();
});

// ── The desktop Mochi wears the dragged-out Mochi's own look ──────────────────

test("a coloured Mochi dragged out of the island wears its own look on the desktop", () => {
  const pill = State.tasks.find((t) => t.isIntegration && t.id !== State.mainPillId);
  assert.ok(pill, "a declared coloured pill");
  State.settings.mochiLooks = { [MAIN_MOCHI]: { outfit: "pumpkin", shape: "" }, [pill.id]: { outfit: "crown", shape: "bean" } };
  const link = new DesktopLink({ reveal() {}, wardrobeFromDesktop() {}, dizzyFromDesktop() {} });
  const snapshot = () => sent("plugin:event|emit_to").map((a) => a.payload).at(-1);

  link.push();
  assert.equal(snapshot().outfit, "pumpkin", "the main Mochi by default");
  State.focusId = pill.id;
  link.pickUp(0, 0);
  link.push();
  assert.deepEqual([snapshot().outfit, snapshot().shape], ["crown", "bean"]);
});
