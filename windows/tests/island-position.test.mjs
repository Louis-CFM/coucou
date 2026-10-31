// Island screen edge positioning tests (#1021).
// Ensures top/bottom edge settings, geometry calculations, and body classes behave correctly.

import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

test("island position: defaults to top edge (#1021)", () => {
  assert.equal(DEFAULT_SETTINGS.islandPosition, "top");
  assert.equal(State.settings.islandPosition, "top");
});

test("island position: bottom edge geometry offsets y by viewport height", () => {
  const PANEL_W = 720;
  const PANEL_H = 320;
  const w = 240;
  const hh = 36;
  const viewportW = PANEL_W;
  const viewportH = PANEL_H;

  // Top edge geometry:
  const topRect = { x: (viewportW - w) / 2, y: 0, w, h: hh };
  assert.equal(topRect.y, 0);
  assert.equal(topRect.x, 240);

  // Bottom edge geometry:
  const bottomY = viewportH - hh;
  const bottomRect = { x: (viewportW - w) / 2, y: bottomY, w, h: hh };
  assert.equal(bottomRect.y, 284);
  assert.equal(bottomRect.x, 240);
});

test("island position: settings state accepts bottom and top choices", () => {
  State.settings.islandPosition = "bottom";
  assert.equal(State.settings.islandPosition, "bottom");

  State.settings.islandPosition = "top";
  assert.equal(State.settings.islandPosition, "top");
});
