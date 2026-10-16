// Windows and Linux additions: the desktop Mochi wears the look of the Mochi
// dragged out of the island, and the pure parts of the chat's mic.

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

import { isHallucination, wav } from "../src/views/dictation.ts";

test("Whisper's inventions on a breath are dropped, real short answers kept", () => {
  assert.ok(isHallucination("Thank you.", 400));
  assert.ok(isHallucination("Thanks for watching!", 5000));
  assert.ok(isHallucination("   ", 3000));
  assert.ok(!isHallucination("Thank you.", 2000));
  assert.ok(!isHallucination("Open the settings", 600));
});

test("a recording becomes a 16 kHz mono WAV", async () => {
  const blob = wav([new Float32Array(48_000).fill(0.5)], 48_000);
  assert.equal(blob.type, "audio/wav");
  const bytes = new Uint8Array(await blob.arrayBuffer());
  const text = (a, b) => String.fromCharCode(...bytes.slice(a, b));
  assert.equal(text(0, 4), "RIFF");
  assert.equal(text(8, 12), "WAVE");
  const view = new DataView(bytes.buffer);
  assert.equal(view.getUint32(24, true), 16_000);
  // One second at 16 kHz, 16-bit: 32 000 bytes of samples.
  assert.equal(view.getUint32(40, true), 32_000);
  assert.equal(view.getInt16(44, true), Math.trunc(0.5 * 0x7fff));
});
