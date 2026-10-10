// The movable island, page side (src/island/window-drag.ts): where a press can grab it, when it
// becomes a drag, and what the bridge sends to Rust (src-tauri/src/island/placement.rs).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { calls, sent } from "./tauri.mjs";
import { installFakeDom } from "./fakedom.mjs";
import { WINDOW_DRAG_THRESHOLD, WindowDragGesture, canGrab, isBarTarget } from "../src/island/window-drag.ts";
import { EXPANDED_W } from "../src/core/layout.ts";
import { Bridge } from "../src/core/bridge.ts";

/** A press on the empty part of the open island's bar, in the overview: grabbable. */
const bar = { capable: true, mode: "expanded", view: "overview", mochiMoving: false, onBot: false, onBar: true };

// ── canGrab ───────────────────────────────────────────────────────────────────

test("the small island, or the empty part of the open island's bar, can be grabbed", () => {
  assert.equal(canGrab({ ...bar, mode: "compact", onBar: false }), true, "compact, anywhere off Mochi");
  assert.equal(canGrab(bar), true, "expanded, on the bar, overview");
});

test("nothing else can be grabbed", () => {
  assert.equal(canGrab({ ...bar, capable: false }), false, "Linux or outside Tauri");
  assert.equal(canGrab({ ...bar, capable: false, mode: "compact" }), false, "Linux, compact");
  assert.equal(canGrab({ ...bar, mode: "hidden" }), false, "hidden");
  assert.equal(canGrab({ ...bar, onBar: false }), false, "expanded, on a button, a card or the chat field");
  assert.equal(canGrab({ ...bar, view: "greeting" }), false, "greeting: no header");
  assert.equal(canGrab({ ...bar, view: "confused" }), false, "confused: no header");
  for (const mode of ["compact", "expanded"]) {
    assert.equal(canGrab({ ...bar, mode, mochiMoving: true }), false, `${mode}: Mochi carried or flying`);
    assert.equal(canGrab({ ...bar, mode, onBot: true }), false, `${mode}: a press on Mochi takes him out`);
  }
});

// ── isBarTarget, on the real header (views.ts, buildHeader) ───────────────────

test("only the empty part of the bar is a handle: never a tab, a button, a pill or what they hold", async () => {
  installFakeDom();
  const { buildHeader } = await import("../src/views/views.ts");
  const header = buildHeader({ blip() {}, setView() {}, toggleSound() {} }).el;
  const content = document.createElement("div");
  const view = document.createElement("div");
  content.append(view);

  // A button added straight into #header would become a handle: the header holds only these two rows.
  assert.deepEqual(header.children.map((c) => c.className), ["tabs", "header-actions"]);
  const [tabs, actions] = header.children;
  for (const [el, what] of [[header, "#header"], [tabs, ".tabs"], [actions, ".header-actions"], [content, "#content"]]) {
    assert.equal(isBarTarget(el, header, content), true, what);
  }
  assert.equal(isBarTarget(view, header, content), false, "a view inside #content");
  const below = [...tabs.walk(), ...actions.walk()];
  assert.ok(below.some((e) => e.classList.contains("tab")), "the tabs are there");
  assert.ok(below.some((e) => e.classList.contains("plan-pills")), "the pills are there");
  for (const el of below) {
    assert.equal(isBarTarget(el, header, content), false, `${el.tagName.toLowerCase()}.${el.className}`);
  }
});

// ── WindowDragGesture ─────────────────────────────────────────────────────────

test("the constants the page shares with Rust (placement.rs) are equal", () => {
  const rust = readFileSync(new URL("../src-tauri/src/island/placement.rs", import.meta.url), "utf8");
  const css = readFileSync(new URL("../src/style.css", import.meta.url), "utf8");
  const constant = (name) => {
    const m = rust.match(new RegExp(`const ${name}: f64 = ([\\d.]+);`));
    assert.ok(m, `${name} in placement.rs`);
    return Number(m[1]);
  };
  assert.equal(WINDOW_DRAG_THRESHOLD, constant("MIN_MOVE"), "the press-to-drag threshold cancels a drop too");
  assert.equal(EXPANDED_W / 2, constant("HALF_W"), "half the open island");
  const capsule = css.match(/html\[data-placement="floating"\] #wake-strip \{ width: (\d+)px; height: (\d+)px; \}/);
  assert.ok(capsule, "the floating capsule in style.css");
  assert.deepEqual([Number(capsule[1]), Number(capsule[2])], [constant("REST_W"), constant("REST_H")]);
});

test("a press becomes a drag at 8 px, and hands the press point over once", () => {
  const g = new WindowDragGesture();
  assert.equal(g.armed, false);
  assert.equal(g.move(50, 50, 1), null, "nothing armed");
  g.press(100, 20);
  assert.equal(g.armed, true);
  assert.equal(g.move(107.9, 20, 1), null, "7.9 px: still a click");
  assert.equal(g.armed, true);
  assert.deepEqual(g.move(108, 20, 1), { x: 100, y: 20 }, "8 px: the press point");
  assert.equal(g.armed, false);
  assert.equal(g.move(140, 20, 1), null, "only once");
});

test("a button let go, or a reset, disarms the press", () => {
  const g = new WindowDragGesture();
  g.press(0, 0);
  assert.equal(g.move(20, 0, 0), null, "main button no longer down");
  assert.equal(g.armed, false);
  assert.equal(g.move(30, 0, 1), null, "pressed again elsewhere: not this press");

  g.press(0, 0);
  g.reset();
  assert.equal(g.armed, false);
  assert.equal(g.move(30, 0, 1), null);
});

// ── Bridge ────────────────────────────────────────────────────────────────────

test("the bridge sends the press point and the two other commands", async () => {
  calls.length = 0;
  assert.equal(await Bridge.islandDragBegin(10, 20), null);
  assert.deepEqual(sent("island_drag_begin"), [{ x: 10, y: 20 }]);
  assert.equal(await Bridge.islandResetPosition(), null);
  assert.deepEqual(sent("island_reset_position"), [{}]);
  assert.equal(await Bridge.islandPlacement(), null);
  assert.deepEqual(sent("island_placement"), [{}]);
});
