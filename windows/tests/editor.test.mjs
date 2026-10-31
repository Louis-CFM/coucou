// The wheel's image editor: crop frames and the background's canvas (src/editor/geometry.ts).

import { test } from "node:test";
import assert from "node:assert/strict";
import { backgroundLayout, clampRect, cropToAspect, initialCrop, rectFrom } from "../src/editor/geometry.ts";

test("a rectangle from two corners, either way", () => {
  assert.deepEqual(rectFrom(50, 40, 10, 100), { x: 10, y: 40, w: 40, h: 60 });
});

test("a frame stays inside the image", () => {
  assert.deepEqual(clampRect({ x: -10, y: 20, w: 500, h: 50 }, 400, 300), { x: 0, y: 20, w: 400, h: 50 });
});

test("a ratio gives the largest frame that fits, centred", () => {
  assert.deepEqual(initialCrop(1, 400, 300), { x: 50, y: 0, w: 300, h: 300 }, "square in a landscape image");
  const wide = initialCrop(16 / 9, 400, 300);
  assert.equal(Math.round(wide.w), 400);
  assert.equal(Math.round(wide.h), 225);
  assert.equal(Math.round(wide.y), 38);
  assert.deepEqual(initialCrop(null, 400, 300), { x: 0, y: 0, w: 400, h: 300 }, "free: the whole image");
});

test("a frame dragged near an edge is pushed back in", () => {
  const r = cropToAspect({ x: 350, y: 250, w: 200, h: 200 }, 1, 400, 300);
  assert.ok(r.x + r.w <= 400 && r.y + r.h <= 300 && r.x >= 0 && r.y >= 0);
  assert.equal(r.w, r.h);
});

test("the background's canvas: padding all round, then the shape", () => {
  assert.deepEqual(backgroundLayout(400, 200, 0.1, null), { width: 480, height: 280, x: 40, y: 40 });
  const square = backgroundLayout(400, 200, 0.1, 1);
  assert.equal(square.width, square.height);
  assert.equal(square.x, 40);
  assert.equal(square.y, 140, "centred");
  const tall = backgroundLayout(400, 200, 0, 9 / 16);
  assert.equal(tall.width, 400);
  assert.equal(tall.height, 711);
});
