import { test } from "node:test";
import assert from "node:assert/strict";
import { FrameLoop } from "../src/core/frame-loop.ts";

function harness(draw) {
  const queue = [], errors = [];
  let id = 0;
  const loop = new FrameLoop(draw, error => errors.push(error), fn => { queue.push(fn); return ++id; });
  return { loop, queue, errors, tick: () => queue.shift()(performance.now() + 16) };
}

test("a failed frame does not permanently disable input or spin at idle", () => {
  let fail = true, draws = 0;
  const h = harness(() => { draws++; if (fail) throw new TypeError("test frame"); return false; });
  h.loop.wake(); h.tick();
  assert.equal(h.errors.length, 1);
  assert.equal(h.queue.length, 0, "no automatic retry storm");
  fail = false;
  h.loop.wake(); h.tick();
  assert.equal(draws, 2, "the next input can redraw");
  assert.equal(h.queue.length, 0);
});

test("repeated notifications schedule only one frame", () => {
  const h = harness(() => false);
  for (let i = 0; i < 100; i++) h.loop.wake();
  assert.equal(h.queue.length, 1);
  h.tick();
  assert.equal(h.queue.length, 0);
});

test("a notification during drawing is rendered on the next frame", () => {
  let draws = 0;
  const h = harness(() => { if (++draws === 1) h.loop.wake(); return false; });
  h.loop.wake(); h.tick();
  assert.equal(h.queue.length, 1);
  h.tick();
  assert.equal(draws, 2);
  assert.equal(h.queue.length, 0);
});

test("animation runs until settled and caps the time step", () => {
  let draws = 0;
  const h = harness(dt => { assert.ok(dt >= 0 && dt <= 0.05); return ++draws < 3; });
  h.loop.wake(); h.tick(); h.tick(); h.tick();
  assert.equal(draws, 3);
  assert.equal(h.queue.length, 0);
});
