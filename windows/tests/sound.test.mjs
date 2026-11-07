// The sound engine's audio context (src/core/sound.ts). A running AudioContext
// keeps an audio thread rendering silence, so a page that only preloads the
// sounds and plays none — the desktop Mochi's window, hidden until he is sent
// out of the island — must not leave one running.

import { test } from "node:test";
import assert from "node:assert/strict";
import { Sound } from "../src/core/sound.ts";

/** The context of the page under test, as last created. */
let ctx = null;

class FakeAudioContext {
  constructor() {
    this.state = "running";
    this.destination = {};
    ctx = this;
  }
  createGain() {
    return { gain: { value: 1 }, connect() {} };
  }
  async decodeAudioData() {
    return {};
  }
  async suspend() {
    this.state = "suspended";
  }
  async resume() {
    this.state = "running";
  }
}

globalThis.AudioContext = FakeAudioContext;
// No sound file is served here: the engine must cope, as it does in the app.
globalThis.fetch = async () => ({ ok: false });

test("a page that preloads the sounds and plays none lets the context go", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  await Sound.preload();
  assert.equal(ctx.state, "running");
  t.mock.timers.tick(1500);
  assert.equal(ctx.state, "suspended", "nothing was played: no audio thread left behind");
});

test("input brings it back, and a quiet page lets it go again", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  await Sound.preload();
  Sound.resume();
  await Promise.resolve();
  assert.equal(ctx.state, "running");
  Sound.idle();
  Sound.resume();
  t.mock.timers.tick(1500);
  assert.equal(ctx.state, "running", "resume() cancels a pending suspend");
  Sound.idle();
  t.mock.timers.tick(1500);
  assert.equal(ctx.state, "suspended");
});
