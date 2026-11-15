// Mochi falling asleep (engine.ts setState "sleeping"): the island's Mochi
// and the minis alike.

import { test } from "node:test";
import assert from "node:assert/strict";

const { BotEngine } = await import("../src/mochi/engine.ts");

test("falling asleep, Mochi's lids droop shut and he ignores the cursor", () => {
  for (const isMini of [false, true]) {
    const e = new BotEngine();
    e.isMini = isMini;
    e.setState("sleeping", true);
    assert.equal(e.eyeOverride, "droop", "the lids droop first");
    e.lookX = 1;
    e.lookY = 1;
    for (let i = 0; i < 100; i++) e.update(0.05);
    assert.equal(e.tgYaw, 0, "no turn towards the cursor");
    assert.equal(e.tgPitch, -0.14, "head down");
  }
});
