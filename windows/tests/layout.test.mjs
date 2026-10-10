// Compact island padding (Settings → General → Padding).

import { test } from "node:test";
import assert from "node:assert/strict";
import { COMPACT_PADDING, botPosition, islandSize } from "../src/core/layout.ts";
import { DEFAULT_SETTINGS } from "../src/core/state.ts";

test("the default padding stays close to the shipped compact layout", () => {
  assert.deepEqual(DEFAULT_SETTINGS.compactPadding, COMPACT_PADDING);
  assert.deepEqual(islandSize("compact", "overview"), { w: 288, h: 32 });
  const p = botPosition("compact", "overview", 32);
  assert.deepEqual([p.cx, p.cy], [38, 16]);
});

test("each side moves only its own edge", () => {
  const pad = { top: 2, right: 6, bottom: 10, left: 4 };
  assert.equal(islandSize("compact", "overview", 0, pad).h, 32);
  const p = botPosition("compact", "overview", 32, 0, pad);
  assert.deepEqual([p.cx, p.cy], [14, 12]);
  assert.equal(botPosition("expanded", "overview", 160, 0, pad).cx, botPosition("expanded", "overview", 160).cx);
  assert.equal(islandSize("expanded", "overview", 0, pad).h, islandSize("expanded", "overview").h);
});
