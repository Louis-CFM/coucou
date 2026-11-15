// Settings → General → Folded island width (src/core/layout.ts).

import { test } from "node:test";
import assert from "node:assert/strict";
import { COMPACT_MAX_W, COMPACT_MIN_W, COMPACT_W, compactWidth, islandSize } from "../src/core/layout.ts";

test("no width, or not a number, is the shipped 288 px", () => {
  assert.equal(compactWidth(undefined), COMPACT_W);
  assert.equal(compactWidth("wide"), COMPACT_W);
});

test("a width is kept within the range, in whole pixels", () => {
  assert.equal(compactWidth(100), COMPACT_MIN_W);
  assert.equal(compactWidth(9999), COMPACT_MAX_W);
  assert.equal(compactWidth(320.4), 320);
});

test("the compact island takes the width, the open island keeps its own", () => {
  assert.equal(islandSize("compact", "overview", 0, 320).w, 320);
  assert.equal(islandSize("compact", "overview").w, COMPACT_W);
  assert.equal(islandSize("expanded", "overview", 0, 320).w, 640);
});
