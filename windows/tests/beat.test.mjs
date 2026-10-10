// The beat clock Mochi dances to (src/mochi/beat.ts): free at 112 BPM until the
// listener speaks, then on its beat, easing toward each new estimate.

import { test } from "node:test";
import assert from "node:assert/strict";
import { beatPosition, currentBpm, feedBeat, resetBeat, DEFAULT_BPM } from "../src/mochi/beat.ts";
import { danceAtBeat, danceTransform } from "../src/mochi/engine.ts";

const frac = (x) => x - Math.floor(x);

test("without an estimate it counts the fixed 112 BPM", () => {
  resetBeat();
  assert.equal(currentBpm(), DEFAULT_BPM);
  assert.ok(Math.abs(beatPosition(60_000) - 112) < 1e-9);
  assert.deepEqual(danceTransform(0.3, 1, 20), danceAtBeat(0.3 * 112 / 60, 1, 20));
});

test("the first estimate puts the next beats where the listener says", () => {
  resetBeat();
  // 120 BPM, a beat was at t = 10 000 ms: beats at 10 500, 11 000…
  feedBeat({ bpm: 120, beatAtMs: 10_000 }, 10_200);
  assert.equal(currentBpm(), 120);
  assert.ok(Math.abs(beatPosition(10_000) - Math.round(beatPosition(10_000))) < 1e-9);
  assert.ok(Math.abs(frac(beatPosition(11_000))) < 1e-9 || Math.abs(frac(beatPosition(11_000)) - 1) < 1e-9);
  assert.ok(Math.abs(beatPosition(11_500) - beatPosition(11_000) - 1) < 1e-9);
});

test("a later estimate nudges, never jumps", () => {
  resetBeat();
  feedBeat({ bpm: 120, beatAtMs: 0 }, 1_000);
  const before = beatPosition(2_000);
  // The listener now says the beats are 100 ms later than the clock has them.
  feedBeat({ bpm: 120, beatAtMs: 100 }, 2_000);
  const after = beatPosition(2_000);
  assert.ok(Math.abs(after - before) < 0.1, `${after} vs ${before}`);
  assert.ok(Math.abs(after - before) > 0, "but it did move toward it");
  // After many consistent estimates it has settled onto them.
  for (let t = 3_000; t <= 12_000; t += 1_000) feedBeat({ bpm: 120, beatAtMs: 100 }, t);
  const settled = frac(beatPosition(12_100));
  assert.ok(settled < 0.05 || settled > 0.95, `${settled}`);
});

test("a close tempo is blended, a far one replaces it, junk is ignored", () => {
  resetBeat();
  feedBeat({ bpm: 100, beatAtMs: 0 }, 1_000);
  feedBeat({ bpm: 104, beatAtMs: 0 }, 2_000);
  assert.ok(currentBpm() > 100 && currentBpm() < 104);
  feedBeat({ bpm: 140, beatAtMs: 0 }, 3_000);
  assert.equal(currentBpm(), 140);
  feedBeat({ bpm: 0, beatAtMs: 0 }, 4_000);
  feedBeat({ bpm: NaN, beatAtMs: 0 }, 4_000);
  assert.equal(currentBpm(), 140);
});

test("landing squash is on the whole beats", () => {
  const onBeat = danceAtBeat(4, 1, 20);
  const mid = danceAtBeat(4.5, 1, 20);
  assert.ok(Math.abs(onBeat.dy) < 1e-9);
  assert.ok(mid.dy < -3);
  assert.ok(onBeat.sy < 1 && mid.sy >= 0.99);
});

test("a fast song gets a smaller dance, the fixed bounce stays full size", async () => {
  const { danceCalm, feedBeat, resetBeat } = await import("../src/mochi/beat.ts");
  resetBeat();
  assert.equal(danceCalm(), 1);
  feedBeat({ bpm: 118, beatAtMs: Date.now() });
  assert.ok(danceCalm() < 0.7 && danceCalm() >= 0.55);
  resetBeat();
  feedBeat({ bpm: 90, beatAtMs: Date.now() });
  assert.equal(danceCalm(), 1);
  resetBeat();
});
