// When the Coucou window draws its canvases (src/hub/frames.ts): only while it
// is on screen, and only the canvases in sight. Issue #792: a hidden window
// kept a WebKitWebProcess busy on Linux.

import { test } from "node:test";
import assert from "node:assert/strict";
import { onScreen, shouldAnimate } from "../src/hub/frames.ts";

test("the loop runs only with something to draw, the window shown and the page visible", () => {
  assert.equal(shouldAnimate(3, "visible", true), true);
  assert.equal(shouldAnimate(0, "visible", true), false);
  // WebKitGTK can still say "visible" for a hidden window: Rust's word wins.
  assert.equal(shouldAnimate(3, "visible", false), false);
  assert.equal(shouldAnimate(3, "hidden", true), false);
  assert.equal(shouldAnimate(3, "hidden", false), false);
});

const box = (top, left, width, height) => ({ top, left, width, height, bottom: top + height, right: left + width });

test("a canvas in the window is drawn", () => {
  assert.equal(onScreen(box(0, 0, 800, 200), 1100, 720), true);
  // Half scrolled out at the top or the bottom: still drawn.
  assert.equal(onScreen(box(-150, 240, 800, 200), 1100, 720), true);
  assert.equal(onScreen(box(600, 240, 800, 200), 1100, 720), true);
});

test("a canvas scrolled out of sight, or not laid out, is skipped", () => {
  assert.equal(onScreen(box(-200, 240, 800, 200), 1100, 720), false);
  assert.equal(onScreen(box(720, 240, 800, 200), 1100, 720), false);
  assert.equal(onScreen(box(900, 240, 800, 200), 1100, 720), false);
  assert.equal(onScreen(box(0, 1100, 300, 200), 1100, 720), false);
  assert.equal(onScreen(box(100, 240, 0, 0), 1100, 720), false);
});
