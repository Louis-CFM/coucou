import { test } from "node:test";
import assert from "node:assert/strict";
import { CoucoudoroEngine, DEFAULT_CONFIG } from "../src/core/coucoudoro.ts";

const T0 = 1_700_000_000 * 1000;
const work = 25 * 60;
const rest = 5 * 60;
const config = { work, rest };

test("CoucoudoroEngine clock formatting", () => {
  assert.equal(CoucoudoroEngine.clock(1500), "25:00");
  assert.equal(CoucoudoroEngine.clock(90), "01:30");
  assert.equal(CoucoudoroEngine.clock(0), "00:00");
  assert.equal(CoucoudoroEngine.clock(6000), "100:00");
});

test("CoucoudoroEngine sanitize config", () => {
  assert.deepEqual(CoucoudoroEngine.sanitize({ work: 0, rest: -5 }), { work: 1, rest: 1 });
  assert.deepEqual(CoucoudoroEngine.sanitize({ work: 25.7, rest: 5.2 }), { work: 25, rest: 5 });
});

test("CoucoudoroEngine start and phase transitions", () => {
  let { snapshot: snap, events } = CoucoudoroEngine.start(config, T0);
  assert.equal(snap.phase, "work");
  assert.equal(snap.deadline, T0 + work * 1000);
  assert.deepEqual(events, ["workStarts"]);

  // Tick before deadline
  let res = CoucoudoroEngine.tick(snap, config, T0 + (work - 1) * 1000);
  snap = res.snapshot;
  assert.equal(res.events.length, 0);
  assert.equal(snap.phase, "work");
  assert.equal(CoucoudoroEngine.remaining(snap, T0 + (work - 1) * 1000), 1);

  // Tick at deadline -> rest starts
  res = CoucoudoroEngine.tick(snap, config, T0 + work * 1000);
  snap = res.snapshot;
  assert.deepEqual(res.events, ["restStarts"]);
  assert.equal(snap.phase, "rest");
  assert.equal(snap.deadline, T0 + (work + rest) * 1000);

  // Tick at rest deadline -> work starts again
  res = CoucoudoroEngine.tick(snap, config, T0 + (work + rest) * 1000);
  snap = res.snapshot;
  assert.deepEqual(res.events, ["workStarts"]);
  assert.equal(snap.phase, "work");
  assert.equal(snap.deadline, T0 + (work + rest + work) * 1000);
});

test("CoucoudoroEngine pause, resume and stop", () => {
  let { snapshot: snap } = CoucoudoroEngine.start(config, T0);
  // Pause after 10 minutes
  snap = CoucoudoroEngine.pause(snap, T0 + 600 * 1000);
  assert.equal(snap.paused, true);
  assert.equal(snap.pausedRemaining, 15 * 60);
  assert.equal(snap.deadline, null);

  // Resume 5 minutes later
  snap = CoucoudoroEngine.resume(snap, T0 + 900 * 1000);
  assert.equal(snap.paused, false);
  assert.equal(snap.pausedRemaining, null);
  assert.equal(snap.deadline, T0 + (900 + 15 * 60) * 1000);

  // Stop
  snap = CoucoudoroEngine.stop();
  assert.equal(snap.phase, "idle");
  assert.equal(snap.deadline, null);
});
