// The sound engine and Linux's pipewire freeze (#420): a running AudioContext
// holds a PipeWire sink input open even in silence, so with sound off the page
// must never keep one running. These tests pin the lifecycle: muted means
// suspended, and nothing resumes it behind the user's back.

import { test } from "node:test";
import assert from "node:assert/strict";
import { SoundEngine } from "../src/core/sound.ts";

let contexts = [];

class FakeParam {
  constructor() { this.value = 1; }
  setValueAtTime() {}
  linearRampToValueAtTime() {}
  cancelScheduledValues() {}
}

class FakeGain {
  constructor() { this.gain = new FakeParam(); }
  connect() { return this; }
  disconnect() {}
}

class FakeSource {
  constructor() { this.buffer = null; this.onended = null; }
  connect() { return this; }
  start() {}
  stop() {}
}

class FakeAudioContext {
  constructor() {
    this.state = "running";
    this.currentTime = 0;
    this.destination = {};
    this.suspended = 0;
    this.resumed = 0;
    contexts.push(this);
  }
  createGain() { return new FakeGain(); }
  createBufferSource() { return new FakeSource(); }
  decodeAudioData() { return Promise.resolve({}); }
  suspend() { this.state = "suspended"; this.suspended += 1; return Promise.resolve(); }
  resume() { this.state = "running"; this.resumed += 1; return Promise.resolve(); }
}

globalThis.AudioContext = FakeAudioContext;

/** A fresh engine with the fake context installed, and its own timer cleared. */
function engine() {
  const e = new SoundEngine();
  e.__settled = () => {
    if (e.idleTimer != null) clearTimeout(e.idleTimer);
    e.idleTimer = null;
  };
  return e;
}

test("preload with sound off leaves the context suspended, never running", async () => {
  contexts = [];
  const e = engine();
  e.setEnabled(false); // as applySettings does for a muted user
  await e.preload();

  assert.equal(contexts.length, 1, "one context was created");
  const ctx = contexts[0];
  assert.equal(ctx.state, "suspended", "a muted page must not keep an audio stream open");
  assert.ok(ctx.suspended >= 1, "suspend() was actually called");
  assert.equal(e.idleTimer, null, "no idle timer is left armed");
});

test("preload with sound on lets the context rest shortly after", async () => {
  contexts = [];
  const e = engine();
  await e.preload();

  // Nothing is playing yet: an idle wait is armed rather than holding the
  // stream forever, exactly as PR #404 intended.
  assert.notEqual(e.idleTimer, null, "idle() armed a suspend wait");
  e.__settled();
  assert.equal(contexts[0].state, "running", "the wait has not fired yet");
});

test("turning sound off suspends at once and clears a pending idle wait", async () => {
  contexts = [];
  const e = engine();
  await e.preload();
  const ctx = contexts[0];
  assert.notEqual(e.idleTimer, null, "sound on: an idle wait is pending");

  e.setEnabled(false);
  assert.equal(e.idleTimer, null, "the pending wait is gone");
  assert.equal(ctx.state, "suspended", "the stream closes immediately, not in 1.5 s");
});

test("resume() cancels a pending idle wait, keeping the stream for the sound that follows", async () => {
  contexts = [];
  const e = engine();
  await e.preload(); // sound on, nothing played yet
  const ctx = contexts[0];
  assert.notEqual(e.idleTimer, null, "an idle wait is armed after preload");

  e.resume(); // a click just before Mochi speaks
  assert.equal(e.idleTimer, null, "the pending suspend is cancelled");
  assert.equal(ctx.state, "running", "the stream stays for the upcoming sound");
  e.setEnabled(false); // tidy up: close the stream
});

test("resume() never reopens a muted page's stream", async () => {
  contexts = [];
  const e = engine();
  e.setEnabled(false);
  await e.preload();
  const ctx = contexts[0];
  const before = ctx.resumed;

  e.resume(); // pointerdown handlers call this unconditionally
  assert.equal(ctx.resumed, before, "a muted page stays suspended");
  assert.equal(ctx.state, "suspended");
});

test("play() is silent while muted but resumes once sound is on", async () => {
  contexts = [];
  const e = engine();
  await e.preload();
  const ctx = contexts[0];
  e.__settled();
  // decodeAudioData resolves to {} here; give play() a buffer to find.
  e.buffers.set("blip", {});

  ctx.state = "suspended";
  e.setEnabled(false);
  const suspended = ctx.suspended;
  e.play("blip");
  assert.equal(ctx.suspended, suspended, "a muted play() does not touch the context");

  e.setEnabled(true);
  ctx.state = "suspended";
  const before = ctx.resumed;
  e.play("blip");
  assert.ok(ctx.resumed > before || ctx.state === "running", "playing a sound wakes the stream");
  e.setEnabled(false);
});
