// Springs behind the island's and Mochi's motion (src/core/anim.ts).

import { test } from "node:test";
import assert from "node:assert/strict";
import { Spring } from "../src/core/anim.ts";

test("a frame stamped before the last one leaves a spring where it was", () => {
  const s = new Spring(20);
  s.target = 76;
  s.step(1 / 60);
  const before = s.value;
  s.step(-0.4);
  assert.equal(s.value, before);
  for (let i = 0; i < 120; i++) s.step(1 / 60);
  assert.ok(Math.abs(s.value - 76) < 0.5, `settled at ${s.value}`);
});

test("a spring never leaves finite numbers", () => {
  const s = new Spring(20);
  s.target = 76;
  s.step(NaN);
  s.step(Infinity);
  assert.ok(Number.isFinite(s.value) && Math.abs(s.value) < 1000, `value ${s.value}`);
});
