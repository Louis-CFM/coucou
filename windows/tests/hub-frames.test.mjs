// When the Coucou window draws its canvases (src/hub/frames.ts): only while it
// is on screen, and only the canvases in sight. Issue #792: a hidden window
// kept a WebKitWebProcess busy on Linux.

import { test } from "node:test";
import assert from "node:assert/strict";
import { frameDue, frameInterval, onScreen, shouldAnimate } from "../src/hub/frames.ts";

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

// The canvases are drawn at 30 frames a second with the focus, 10 without:
// at 60 a WebKitWebProcess kept a CPU core busy on Linux while the window was open (#792).
test("frames are drawn at 30 a second with the focus, 10 behind other windows", () => {
  assert.equal(Math.round(frameInterval(true)), 33);
  assert.equal(Math.round(frameInterval(false)), 100);
});

test("a 60 Hz screen draws every other frame with the focus", () => {
  const interval = frameInterval(true);
  let lastDrawn = -Infinity;
  let drawn = 0;
  // One second of 60 Hz frames, with a little jitter.
  for (let i = 0; i < 60; i++) {
    const now = i * (1000 / 60) + (i % 2 ? 0.7 : -0.7);
    if (frameDue(now, lastDrawn, interval)) {
      drawn++;
      lastDrawn = now;
    }
  }
  assert.equal(drawn, 30);
});

test("behind other windows, a 60 Hz screen draws one frame in six", () => {
  const interval = frameInterval(false);
  let lastDrawn = -Infinity;
  let drawn = 0;
  for (let i = 0; i < 60; i++) {
    const now = i * (1000 / 60);
    if (frameDue(now, lastDrawn, interval)) {
      drawn++;
      lastDrawn = now;
    }
  }
  assert.equal(drawn, 10);
});

test("the first frame is always drawn", () => {
  assert.equal(frameDue(0, -Infinity, frameInterval(true)), true);
});
