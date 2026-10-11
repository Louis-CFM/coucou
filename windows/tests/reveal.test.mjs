// The timing of the live-edit reveal (src/core/reveal.ts): pure numbers.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  REVEAL_CHARS_PER_SECOND, REVEAL_FADE_S, REVEAL_MAX_S, REVEAL_STAGGER_S, revealAt, revealDuration,
} from "../src/core/reveal.ts";

const ctx = (length = 10) => ({ typed: false, length });
const add = (length) => ({ typed: true, length });

test("an empty list has no duration and nothing to show", () => {
  assert.equal(revealDuration([]), 0);
  assert.deepEqual(revealAt([], 0), []);
  assert.deepEqual(revealAt([], 5), []);
});

test("lines start in order, a context line 40 ms after the one before", () => {
  const lines = [ctx(), ctx(), ctx()];
  const at = (t) => revealAt(lines, t).map((s) => s.started);
  assert.deepEqual(at(0), [true, false, false]);
  assert.deepEqual(at(REVEAL_STAGGER_S - 0.001), [true, false, false]);
  assert.deepEqual(at(REVEAL_STAGGER_S), [true, true, false]);
  assert.deepEqual(at(REVEAL_STAGGER_S * 2), [true, true, true]);
});

test("a line fades in over 150 ms from the moment it starts", () => {
  const [a, b] = revealAt([ctx(), ctx()], REVEAL_STAGGER_S + REVEAL_FADE_S / 2);
  assert.ok(Math.abs(b.opacity - 0.5) < 1e-9);
  assert.ok(a.opacity > b.opacity && a.opacity < 1);
  assert.equal(revealAt([ctx()], -1)[0].opacity, 0);
});

test("a typed line takes length / 90 s, and the next one waits for it", () => {
  const lines = [add(45), ctx()];
  assert.equal(REVEAL_CHARS_PER_SECOND, 90);
  assert.deepEqual(revealAt(lines, 0.49).map((s) => s.started), [true, false]);
  assert.deepEqual(revealAt(lines, 0.5).map((s) => s.started), [true, true]);
  const mid = revealAt(lines, 0.25)[0];
  assert.equal(mid.characters, 22);
  assert.equal(mid.typing, true);
  const done = revealAt(lines, 0.5)[0];
  assert.equal(done.characters, 45);
  assert.equal(done.typing, false);
});

test("a typed line is not typing before it starts", () => {
  const [, second] = revealAt([ctx(), add(10)], 0);
  assert.deepEqual(second, { started: false, opacity: 0, characters: 0, typing: false });
});

test("characters never go backwards, and never past the length", () => {
  const lines = [ctx(), add(30), ctx(), add(7), add(0), add(120)];
  const last = lines.map(() => 0);
  for (let t = 0; t <= revealDuration(lines) + 0.5; t += 0.01) {
    revealAt(lines, t).forEach((s, i) => {
      assert.ok(s.characters >= last[i], `line ${i} went back at ${t}`);
      assert.ok(s.characters <= lines[i].length);
      assert.ok(s.opacity >= 0 && s.opacity <= 1);
      last[i] = s.characters;
    });
  }
});

test("context and removed lines are whole as soon as they start", () => {
  const states = revealAt([ctx(25), ctx(8)], REVEAL_STAGGER_S);
  assert.deepEqual(states.map((s) => s.characters), [25, 8]);
  assert.deepEqual(states.map((s) => s.typing), [false, false]);
});

test("an empty added line still takes the minimum 40 ms and is never typing", () => {
  const lines = [add(0), ctx()];
  assert.equal(revealAt(lines, 0)[0].typing, false);
  assert.deepEqual(revealAt(lines, REVEAL_STAGGER_S).map((s) => s.started), [true, true]);
});

test("a short sequence runs at its natural pace", () => {
  // Starts 0, 0.04, 0.08; the last fade ends 150 ms later.
  const lines = [ctx(), ctx(), ctx()];
  assert.ok(Math.abs(revealDuration(lines) - (REVEAL_STAGGER_S * 2 + REVEAL_FADE_S)) < 1e-9);
  assert.equal(revealDuration([add(90)]), 1);
});

test("a long sequence is capped at 1.6 s, scaled evenly", () => {
  const lines = Array.from({ length: 10 }, (_, i) => (i % 2 ? ctx() : add(180))); // 10 s natural
  const duration = revealDuration(lines);
  assert.ok(duration <= REVEAL_MAX_S + 1e-9, `${duration}`);
  assert.ok(duration > REVEAL_MAX_S - 0.01, `${duration}`);

  // The order and the ratios survive: the second typed line starts after the first has finished.
  const before = revealAt(lines, duration / 2);
  assert.ok(before[0].characters > 0);
  const startedCount = before.filter((s) => s.started).length;
  assert.ok(startedCount > 1 && startedCount < lines.length);
});

test("the fade stays 150 ms when the sequence is scaled", () => {
  const lines = [add(900), ctx()];
  const duration = revealDuration(lines);
  assert.ok(duration <= REVEAL_MAX_S + 1e-9);
  // The last line starts 1.45 s in (cap minus the fade) and is whole 150 ms later.
  const justBefore = revealAt(lines, duration - REVEAL_FADE_S / 2)[1];
  assert.ok(Math.abs(justBefore.opacity - 0.5) < 1e-6, `${justBefore.opacity}`);
});

test("every line is whole and fully visible at the duration", () => {
  const sets = [
    [ctx()],
    [add(5)],
    [ctx(), add(40), ctx(), add(13)],
    Array.from({ length: 60 }, (_, i) => (i % 3 ? ctx() : add(80))),
    [add(900), ctx()],
  ];
  for (const lines of sets) {
    const t = revealDuration(lines);
    for (const [i, s] of revealAt(lines, t).entries()) {
      assert.equal(s.opacity, 1, `line ${i} of ${lines.length}`);
      assert.equal(s.characters, lines[i].length);
      assert.equal(s.typing, false);
    }
  }
});
