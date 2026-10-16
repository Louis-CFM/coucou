// Windows and Linux additions: the pure parts of the chat's mic.

import { test } from "node:test";
import assert from "node:assert/strict";
import { isHallucination, wav } from "../src/views/dictation.ts";

test("Whisper's inventions on a breath are dropped, real short answers kept", () => {
  assert.ok(isHallucination("Thank you.", 400));
  assert.ok(isHallucination("Thanks for watching!", 5000));
  assert.ok(isHallucination("   ", 3000));
  assert.ok(!isHallucination("Thank you.", 2000));
  assert.ok(!isHallucination("Open the settings", 600));
});

test("a recording becomes a 16 kHz mono WAV", async () => {
  const blob = wav([new Float32Array(48_000).fill(0.5)], 48_000);
  assert.equal(blob.type, "audio/wav");
  const bytes = new Uint8Array(await blob.arrayBuffer());
  const text = (a, b) => String.fromCharCode(...bytes.slice(a, b));
  assert.equal(text(0, 4), "RIFF");
  assert.equal(text(8, 12), "WAVE");
  const view = new DataView(bytes.buffer);
  assert.equal(view.getUint32(24, true), 16_000);
  // One second at 16 kHz, 16-bit: 32 000 bytes of samples.
  assert.equal(view.getUint32(40, true), 32_000);
  assert.equal(view.getInt16(44, true), Math.trunc(0.5 * 0x7fff));
});
