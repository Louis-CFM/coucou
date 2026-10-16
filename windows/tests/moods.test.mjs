// Every mood the chat model may answer with (src-tauri/src/chat.rs MOODS) is
// acted out (engine.ts MOOD_ACTS), and each one draws, big and small, without
// throwing, into a context that accepts anything.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

/** A 2D context, gradient or Path2D: every call works and returns itself. */
const anything = new Proxy(function () {}, {
  get: (_, k) => (k === Symbol.toPrimitive ? () => 0 : anything),
  apply: () => anything,
  construct: () => anything,
  set: () => true,
});
globalThis.Path2D = anything;

const { BotEngine, MOOD_ACTS } = await import("../src/mochi/engine.ts");

const rust = readFileSync(new URL("../src-tauri/src/chat.rs", import.meta.url), "utf8");
const moods = [...rust.match(/const MOODS: \[&str; \d+\] = \[([^\]]*)\]/)[1].matchAll(/"(\w+)"/g)].map((m) => m[1]);

test("every chat mood is acted out, and draws at any size", () => {
  assert.ok(moods.includes("hype") && moods.includes("confused") && moods.includes("sleepy"), moods.join());
  assert.deepEqual(moods.filter((m) => !MOOD_ACTS[m]), []);
  for (const mood of moods) {
    for (const W of [200, 40]) {
      const e = new BotEngine();
      MOOD_ACTS[mood](e);
      for (let i = 0; i < 3; i++) {
        e.update(0.4);
        e.draw(anything, W, W + 40);
      }
      assert.ok(e.busy, mood);
    }
  }
});

test("the prompt tells the model when to pick every mood, and insults make Mochi angry", () => {
  const guide = rust.match(/const MOOD_GUIDE: &str = "([\s\S]*?)";/)[1];
  for (const mood of moods) assert.ok(guide.includes(`${mood} (`), `${mood} has no description`);
  assert.match(guide, /angry \([^)]*insults you/);
});
