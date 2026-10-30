// The wheel's liquid glass (src/wheel/lens.ts): which piece is where, and how
// it bends what is behind it.

import { test } from "node:test";
import assert from "node:assert/strict";
import { bend, edgeAt } from "../src/wheel/lens.ts";

const pieces = {
  ring: { cx: 160, cy: 158, inner: 58, outer: 141, gap: 1.6 },
  n: 8,
  hub: 52,
  disc: 150,
  bar: { x: 10, y: 318, w: 300, h: 30, r: 15 },
};

test("each piece of glass knows its nearest edge and which way is out", () => {
  const hub = edgeAt(pieces, 160, 158 - 50);
  assert.equal(hub.bevel, 12, "the hub");
  assert.ok(Math.abs(hub.d - 2) < 1e-9);
  assert.ok(hub.ny < -0.99, "out is up, at the hub's top");

  const wedgeOuter = edgeAt(pieces, 160 + 5, 158 - 139);
  assert.equal(wedgeOuter.bevel, 15, "a wedge");
  assert.ok(wedgeOuter.d < 3 && wedgeOuter.ny < -0.9, "near the wedge's outer edge, out is up");

  const rim = edgeAt(pieces, 160, 158 - 146);
  assert.equal(rim.bevel, 9, "the disc's rim, past the wedges");

  const bar = edgeAt(pieces, 160, 320);
  assert.equal(bar.bevel, 11, "the ring pill");
  assert.ok(Math.abs(bar.d - 2) < 0.01 && bar.ny < -0.99, "near its top, out is up");

  assert.equal(edgeAt(pieces, 5, 5), null, "a corner of the window is outside the glass");
  assert.equal(edgeAt(pieces, 5, 333), null, "left of the pill too");
});

test("between two wedges, out is across the gap", () => {
  // Just clockwise of the top gap: the nearest edge is the wedge's start.
  const e = edgeAt(pieces, 162, 158 - 100);
  assert.ok(e.d < 2.5, "close to the gap");
  assert.ok(e.nx < -0.95, "out is to the left, towards the gap");
});

test("the glass bends most at its edge and not at all past its bevel", () => {
  const edge = { d: 0, nx: 1, ny: 0, bevel: 10 };
  assert.equal(bend(edge, 16), 16);
  assert.equal(bend({ ...edge, d: 10 }, 16), 0);
  assert.equal(bend({ ...edge, d: 30 }, 16), 0);
  const half = bend({ ...edge, d: 5 }, 16);
  assert.ok(half > 0 && half < 8, "a rounded rim, not a straight slope");
});
