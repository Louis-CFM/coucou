// Synced lyrics: reading LRC and following the song (src/core/lyrics.ts).

import { test } from "node:test";
import assert from "node:assert/strict";
import { fromAnswer, lineAt, parseLrc } from "../src/core/lyrics.ts";

const LRC = `[ar:Lumen Coast]
[00:12.40] we fold the summer light
[00:16.05]into paper birds tonight
[00:20.5] and send them through the sky
[00:24.00][01:10.00] every wing a little song
[00:30.00]`;

test("LRC lines are read with their times, tags skipped, repeats unfolded", () => {
  const lines = parseLrc(LRC);
  assert.deepEqual(lines.map((l) => l.text), [
    "we fold the summer light", "into paper birds tonight", "and send them through the sky",
    "every wing a little song", "", "every wing a little song",
  ]);
  assert.equal(lines[0].at, 12.4);
  assert.equal(lines[2].at, 20.5);
  assert.equal(lines[5].at, 70);
});

test("the line being sung follows the position", () => {
  const lines = parseLrc(LRC);
  assert.equal(lineAt(lines, 3), -1, "before the first line");
  assert.equal(lineAt(lines, 12.4), 0);
  assert.equal(lineAt(lines, 16), 1, "a hair early counts");
  assert.equal(lineAt(lines, 25), 3);
  assert.equal(lineAt(lines, 999), 5);
  assert.equal(lineAt([], 10), -1);
});

test("an answer becomes lyrics, or nothing", () => {
  assert.equal(fromAnswer(null), null);
  assert.equal(fromAnswer({ synced: null, plain: "  ", instrumental: false }), null);
  const plain = fromAnswer({ synced: null, plain: "la la", instrumental: false });
  assert.deepEqual([plain.lines.length, plain.plain], [0, "la la"]);
  assert.equal(fromAnswer({ synced: null, plain: null, instrumental: true }).instrumental, true);
  assert.equal(fromAnswer({ synced: LRC, plain: null, instrumental: false }).lines.length, 6);
});
