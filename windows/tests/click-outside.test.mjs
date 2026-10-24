// When a click outside folds the island (src/island/click-outside.ts).

import { test } from "node:test";
import assert from "node:assert/strict";
import { AUTO_OPEN_GRACE_MS, ClickOutside } from "../src/island/click-outside.ts";

const NEVER = -Infinity;

test("a press and release outside an open island fold it", () => {
  const c = new ClickOutside();
  c.press(5000, true);
  assert.equal(c.release(true, true, NEVER), true);
});

test("a release with no press folds nothing", () => {
  assert.equal(new ClickOutside().release(true, true, NEVER), false);
});

test("one press folds at most once", () => {
  const c = new ClickOutside();
  c.press(5000, true);
  assert.equal(c.release(true, true, NEVER), true);
  assert.equal(c.release(true, true, NEVER), false);
});

test("the switch off ignores the click", () => {
  const c = new ClickOutside();
  c.press(5000, true);
  assert.equal(c.release(false, true, NEVER), false);
});

test("a press made while the island was not fully open never folds it", () => {
  const c = new ClickOutside();
  c.press(5000, false);
  // The island opened before the release, e.g. a hook opened it under the held button.
  assert.equal(c.release(true, true, NEVER), false);
});

test("a click on an island that is no longer open does nothing", () => {
  const c = new ClickOutside();
  c.press(5000, true);
  assert.equal(c.release(true, false, NEVER), false);
});

test("a mode change clears the press in flight", () => {
  const c = new ClickOutside();
  c.press(5000, true);
  c.clear();
  assert.equal(c.release(true, true, NEVER), false);
});

test("a press under a second after an automatic open is ignored, even if the release comes later", () => {
  const c = new ClickOutside();
  c.press(10_000 + AUTO_OPEN_GRACE_MS - 1, true);
  assert.equal(c.release(true, true, 10_000), false);
});

test("a press at or after the grace is honoured, even when the release is much later", () => {
  const c = new ClickOutside();
  c.press(10_000 + AUTO_OPEN_GRACE_MS, true);
  assert.equal(c.release(true, true, 10_000), true);
});

test("an open the user caused has no grace", () => {
  // lastAutoOpenAt stays at -Infinity for shortcuts, the tray, hover and clicks.
  const c = new ClickOutside();
  c.press(0, true);
  assert.equal(c.release(true, true, NEVER), true);
});
