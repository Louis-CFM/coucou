import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { calls, emit, sent } from "./tauri.mjs";
import { registerVoiceSpeech, VoiceSpeech } from "../src/pill/voice-speech.ts";

const reply = { id: 42, text: "Olá, Pedro.", lang: "pt-PT", audio: "data:audio/mpeg;base64,reply", gender: "female", allowSystemFallback: false };
beforeEach(() => { calls.length = 0; });

test("the mapped pet surface can play and acknowledge speech without the hidden pill", async () => {
  let heard;
  await registerVoiceSpeech(() => {}, { cancel() {}, async play(source) { heard = source; return true; } });
  emit("voice-say", reply);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(heard, reply.audio);
  assert.deepEqual(sent("voice_done"), [{ id: 42, text: null, played: true }]);
  assert.deepEqual(sent("voice_say_native"), []);
});

test("Raquel playback failure stays in text instead of using another voice", async () => {
  const speaker = new VoiceSpeech(() => {}, { cancel() {}, async play() { return false; } });
  await speaker.say(reply);
  assert.equal(sent("voice_done")[0].played, false);
  assert.deepEqual(sent("voice_say_native"), []);
});

test("cancelling a pending reply acknowledges cancellation without marking it played", async () => {
  let finish;
  const speaker = new VoiceSpeech(() => {}, { cancel() { finish?.(true); }, play() { return new Promise(resolve => { finish = resolve; }); } });
  const pending = speaker.say(reply);
  speaker.cancel();
  await pending;
  assert.equal(sent("voice_done")[0].played, false);
});
