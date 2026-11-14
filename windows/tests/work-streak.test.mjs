import { test } from "node:test";
import assert from "node:assert/strict";
import { WorkStreak } from "../src/mochi/work-streak.ts";

const T0 = 1_000_000 * 1000;
const at = (minutes) => T0 + minutes * 60 * 1000;

function work(streak, from, to, every = 5) {
  let m = from;
  while (m <= to) {
    streak.activity(at(m), 10);
    m += every;
  }
}

test("Sleepy after long work", () => {
  const s = new WorkStreak();
  assert.equal(s.tiredness(at(0), 0), 0, "fresh with no work");
  work(s, 0, 110);
  assert.equal(s.tiredness(at(110), 10), 0, "fresh after 1 h 50");
  work(s, 115, 125);
  assert.equal(s.tiredness(at(125), 10), 0.7, "sleepy after 2 h");
  work(s, 130, 185);
  assert.equal(s.tiredness(at(185), 10), 1, "very sleepy after 3 h");
});

test("A break makes him fresh again", () => {
  const b = new WorkStreak();
  work(b, 0, 130);
  assert.equal(b.tiredness(at(130), 10), 0.7, "sleepy before the break");
  assert.equal(b.tiredness(at(151), 10), 0, "fresh during a 20 min pause with no agent");
  b.activity(at(152), 10);
  assert.equal(b.tiredness(at(152), 10), 0, "still fresh when the agents start again");
  assert.equal(b.start, at(152), "the streak started over");
});

test("Away from keyboard is a break", () => {
  const k = new WorkStreak();
  work(k, 0, 125);
  assert.equal(k.tiredness(at(126), 25 * 60), 0, "fresh while you are away");

  const k2 = new WorkStreak();
  work(k2, 0, 125);
  k2.activity(at(130), 21 * 60);
  assert.equal(k2.start, at(130), "an event while you were away starts over");
});

test("Short pauses do not count as a break", () => {
  const p = new WorkStreak();
  work(p, 0, 60);
  work(p, 75, 125); // 15 min pause
  assert.equal(p.tiredness(at(125), 10), 0.7, "still sleepy after 15 min pause");
});
