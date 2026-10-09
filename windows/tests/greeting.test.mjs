// The launch greeting (src/nova/greeting.ts): Nova must never be cut off by
// the island while it grows, while he bounces and waves, or while it shrinks
// back to the compact island.

import { test } from "node:test";
import assert from "node:assert/strict";
import { GREETING_END, GREETING_W, greetingPose, novaBounds } from "../src/nova/greeting.ts";
import { Tracked } from "../src/core/anim.ts";
import { COMPACT_W, NOTCH_H, NOTCH_W, VIEW_LAYOUTS } from "../src/core/layout.ts";

const FRAME = 1 / 60;
const SLACK = 0.5; // anti-aliasing

/** Nova's box against the island's, which is centred in the 640 px greeting canvas. */
function assertInside(t, tc, w, h) {
  const b = novaBounds(greetingPose(t, tc));
  if (!b) return;
  const left = GREETING_W / 2 - w / 2;
  const right = GREETING_W / 2 + w / 2;
  const at = `t=${t.toFixed(3)} tc=${tc}`;
  // No check on the top: he drops in from the edge of the screen, like out of
  // the notch on a Mac, so his head is meant to come out of it.
  assert.ok(b.bottom <= h + SLACK, `${at}: bottom ${b.bottom.toFixed(1)} below the island (${h.toFixed(1)})`);
  assert.ok(b.left >= left - SLACK, `${at}: left ${b.left.toFixed(1)} outside ${left.toFixed(1)}`);
  assert.ok(b.right <= right + SLACK, `${at}: right ${b.right.toFixed(1)} outside ${right.toFixed(1)}`);
}

/** Runs the island geometry the way Island does: spring open, then the 340 ms close curve. */
function run(tc) {
  const width = new Tracked(NOTCH_W);
  const height = new Tracked(0);
  width.springTo(GREETING_W);
  height.springTo(VIEW_LAYOUTS.greeting.height);
  let collapsed = false;
  const stop = Number.isFinite(tc) ? tc + 0.6 : GREETING_END + 0.5;
  for (let t = 0; t <= stop; t += FRAME) {
    const now = t * 1000;
    if (!collapsed && t >= tc) {
      collapsed = true;
      width.curveTowards(COMPACT_W, 340, now);
      height.curveTowards(NOTCH_H, 340, now);
    }
    width.step(FRAME, now);
    height.step(FRAME, now);
    assertInside(t, tc, width.value, height.value);
  }
}

test("Nova stays inside the island for the whole greeting", () => {
  run(Number.POSITIVE_INFINITY);
});

test("Nova stays inside the island when the greeting is cut short", () => {
  for (let tc = 0.3; tc < GREETING_END + 0.4; tc += 0.1) run(tc);
});

test("he slides to the side to wave, then comes back to the middle", () => {
  const atWave = greetingPose(2.0);
  assert.ok(atWave.x < 290, `waving at x=${atWave.x}`);
  assert.ok(atWave.handL > 0.9 && atWave.handR > 0.9, "both hands out");
  assert.ok(atWave.wave >= 0, "waving");
  const back = greetingPose(3.6);
  assert.equal(back.x, 320);
  assert.equal(back.handL, 0);
});

test("he lands where the compact island's Nova sits", () => {
  const end = greetingPose(10, 5);
  assert.equal(end.y, NOTCH_H / 2);
  assert.equal(end.x, GREETING_W / 2 - COMPACT_W / 2 + 40);
  assert.equal(end.minis, 1);
});
