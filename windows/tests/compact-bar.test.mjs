// The compact bar has no notch to leave room for: Mochi on the left, the mini
// grid on the right, close together, and between them the date and time when the
// clock is on (core/layout.ts, island.ts applyGeometry).

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  CLOCK_BOX_W, CLOCK_BOX_X, COMPACT_CLOCK_W, COMPACT_SIDE, COMPACT_W, NOTCH_H, botPosition, compactWidth, islandSize,
} from "../src/core/layout.ts";

// island.ts puts the mini grid's centre at width - 40; it is 29 px wide.
const GRID_HALF_W = 14.5;
const GRID_FROM_RIGHT = COMPACT_SIDE;

/** Mochi's right edge and the mini grid's left edge in a bar of width `w`. */
function edges(w) {
  const bot = botPosition("compact", "overview", NOTCH_H);
  return { mochiRight: bot.cx + bot.diameter / 2, gridLeft: w - GRID_FROM_RIGHT - GRID_HALF_W };
}

test("the compact bar is as wide as the clock needs and as tall as the notch", () => {
  assert.deepEqual(islandSize("compact", "overview"), { w: COMPACT_W, h: NOTCH_H });
  assert.deepEqual(islandSize("compact", "overview", 0, false), { w: COMPACT_W, h: NOTCH_H });
  assert.deepEqual(islandSize("compact", "overview", 0, true), { w: COMPACT_CLOCK_W, h: NOTCH_H });
  assert.equal(compactWidth(false), 149);
  assert.equal(compactWidth(true), 233);
});

test("the clock leaves the other modes alone", () => {
  for (const mode of ["hidden", "expanded"]) {
    assert.deepEqual(islandSize(mode, "overview", 0, true), islandSize(mode, "overview", 0, false));
  }
});

test("without the clock Mochi and the mini grid sit a comfortable distance apart", () => {
  const { mochiRight, gridLeft } = edges(COMPACT_W);
  const gap = gridLeft - mochiRight;
  assert.ok(gap >= 24, `they nearly touch: ${gap} px apart`);
  assert.ok(gap <= 32, `the middle is still wide: ${gap} px apart`);
});

test("with the clock the box has 24 px on each side, between Mochi and the grid", () => {
  const { mochiRight, gridLeft } = edges(COMPACT_CLOCK_W);
  assert.ok(Math.abs(CLOCK_BOX_X - mochiRight - 24) < 0.5, `Mochi to the box: ${CLOCK_BOX_X - mochiRight} px`);
  const after = gridLeft - (CLOCK_BOX_X + CLOCK_BOX_W);
  assert.ok(after >= 23.5 && after <= 25.5, `the box to the grid: ${after} px`);
});

test("both sides keep a margin to the edge of the bar", () => {
  const bot = botPosition("compact", "overview", NOTCH_H);
  assert.ok(bot.cx - bot.diameter / 2 >= 32, "Mochi is too close to the left edge");
  assert.ok(GRID_FROM_RIGHT - GRID_HALF_W >= 32, "the grid is too close to the right edge");
});
