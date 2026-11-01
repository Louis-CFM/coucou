// The wheel's shapes (src/wheel/geometry.ts).

import { test } from "node:test";
import assert from "node:assert/strict";
import { fileSize, labelPoint, wedgeAt, wedgePath } from "../src/wheel/geometry.ts";

const ring = { cx: 250, cy: 250, inner: 90, outer: 210, gap: 4, corner: 8 };

test("the wedges start at the top and go clockwise", () => {
  const n = 8;
  assert.equal(wedgeAt(ring, n, 260, 60), 0, "just right of the top");
  assert.equal(wedgeAt(ring, n, 420, 250), 2, "the right");
  assert.equal(wedgeAt(ring, n, 250, 420), 4, "the bottom");
  assert.equal(wedgeAt(ring, n, 80, 250), 6, "the left");
  assert.equal(wedgeAt(ring, n, 240, 60), 7, "just left of the top");
});

test("nothing on the hub, outside the ring, or with no wedges", () => {
  assert.equal(wedgeAt(ring, 8, 250, 250), -1);
  assert.equal(wedgeAt(ring, 8, 250, 20), -1);
  assert.equal(wedgeAt(ring, 0, 260, 60), -1);
});

test("a label sits in the middle of its wedge", () => {
  const [x, y] = labelPoint(ring, 0, 4);
  // The first of four wedges is centred 45° clockwise from the top.
  assert.ok(x > 250 && y < 250);
  assert.equal(wedgeAt(ring, 4, x, y), 0);
});

test("a wedge's path is closed, goes around its arc and rounds its corners", () => {
  const d = wedgePath(ring, 0, 6);
  assert.match(d, /^M[\d.]+ [\d.]+ Q.* A210 210 0 0 1 .* Q.* L.* Q.* A90 90 0 0 0 .* Q.* Z$/);
  assert.match(wedgePath(ring, 0, 1), /A210 210 0 1 1/, "one wedge is nearly the whole ring");
  // The gap is as wide by the hub as at the rim: the wedge starts half the gap
  // right of the top's dividing line.
  const x = Number(d.slice(1).split(" ")[0]);
  assert.ok(Math.abs(x - (ring.cx + ring.gap / 2)) < 0.01);
});

test("file sizes", () => {
  assert.equal(fileSize(2_200_000, "en"), "2.2 MB");
  assert.equal(fileSize(640_000, "en"), "640 kB");
  assert.equal(fileSize(512, "en"), "512 byte");
});
