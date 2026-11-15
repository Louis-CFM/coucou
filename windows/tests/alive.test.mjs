// Mochi stays alive while the island is on screen (src/mochi/engine.ts,
// src/island/island.ts). The Mac draws every frame while the island is visible
// (BotCanvasView: TimelineView(.animation(paused: mode == .hidden))); here the
// frame loop stops when the engine has nothing moving, so whatever runs on the
// clock rather than on a tween has to say so, or it freezes mid-way.

import { test, mock } from "node:test";
import assert from "node:assert/strict";
import { BotEngine } from "../src/mochi/engine.ts";

/** A clock the engine reads through performance.now(), with timers that follow it. */
function clock(t) {
  let ms = 100_000;
  mock.method(performance, "now", () => ms);
  t.mock.timers.enable({ apis: ["setTimeout"] });
  return {
    /** Runs the engine for `seconds`, one 50 ms frame at a time. */
    run(engine, seconds) {
      for (let i = 0; i < seconds * 20; i++) {
        ms += 50;
        t.mock.timers.tick(50);
        engine.update(0.05);
      }
    },
    advance(by) {
      ms += by;
      t.mock.timers.tick(by);
    },
  };
}

/** Puts the next blink `seconds` away (TypeScript's `private` is not there at run time). */
const blinkIn = (engine, seconds) => { engine.nextBlink = performance.now() / 1000 + seconds; };

test("the working dots keep their frames: they pulse on the clock, not on a tween", (t) => {
  const time = clock(t);
  const engine = new BotEngine();
  engine.setState("working");
  // Past the state change's own tweens, before the first blink (1.5 s at the earliest).
  time.run(engine, 1);
  assert.equal(engine.badge?.kind, "dots");
  assert.ok(engine.busy, "a pulsing badge needs every frame");
  // And for as long as he works, blinks or not.
  blinkIn(engine, 600);
  time.run(engine, 30);
  assert.ok(engine.busy);
});

test("thinking and searching pulse the same dots", (t) => {
  const time = clock(t);
  for (const state of ["thinking", "searching"]) {
    const engine = new BotEngine();
    engine.setState(state);
    time.run(engine, 1);
    assert.ok(engine.busy, state);
  }
});

test("a still badge asks for nothing", (t) => {
  const time = clock(t);
  const engine = new BotEngine();
  engine.setState("error");
  time.run(engine, 0.6);
  assert.equal(engine.badge?.kind, "dot");
  blinkIn(engine, 60);
  time.run(engine, 1.5);
  assert.equal(engine.busy, false);
});

test("an idle Mochi is not busy, and says when his next blink is due", (t) => {
  const time = clock(t);
  const engine = new BotEngine();
  time.run(engine, 0.1);
  blinkIn(engine, 3);
  time.run(engine, 1);
  assert.equal(engine.busy, false, "nothing moves between two blinks");
  const wait = engine.msUntilBlink();
  assert.ok(wait > 1900 && wait <= 2000, `due in ${wait} ms`);

  // The island sleeps until then; the first frame after it blinks.
  time.advance(wait + 1);
  assert.equal(engine.msUntilBlink(), 0);
  engine.update(0.016);
  assert.ok(engine.busy, "the blink is a tween, it keeps the loop going");
  assert.ok(engine.msUntilBlink() > 2000, "and the next one is scheduled");
});

test("a sleeping or dizzy Mochi does not blink, so nothing wakes the loop for it", (t) => {
  const time = clock(t);
  for (const state of ["sleeping", "dizzy"]) {
    const engine = new BotEngine();
    engine.setState(state);
    time.run(engine, 0.1);
    assert.equal(engine.msUntilBlink(), null, state);
  }
});

test("only the dots moving is told apart, so the island can pace those frames", (t) => {
  const time = clock(t);
  const engine = new BotEngine();
  assert.equal(engine.onlyPulsing, false, "idle: no badge at all");
  engine.setState("working");
  blinkIn(engine, 600);
  time.run(engine, 2);
  assert.ok(engine.busy && engine.onlyPulsing);

  // A blink is real motion: full frame rate for as long as it lasts.
  engine.blink();
  assert.ok(engine.busy);
  assert.equal(engine.onlyPulsing, false);
  time.run(engine, 1);
  assert.ok(engine.onlyPulsing);

  // So is a state with a loop of its own.
  engine.setState("searching");
  time.run(engine, 1);
  assert.ok(engine.busy);
  assert.equal(engine.onlyPulsing, false, "the scan turns his head every frame");
});
