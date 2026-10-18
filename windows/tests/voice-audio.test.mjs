import { test } from "node:test";
import assert from "node:assert/strict";
import { VoiceAudio } from "../src/pill/voice-audio.ts";

function fixture() {
  const clips = [];
  const voice = new VoiceAudio((source) => {
    const clip = { src: source, pauses: 0, onended: null, onerror: null, pause() { this.pauses++; } };
    clip.play = () => new Promise((resolve, reject) => { clip.start = resolve; clip.fail = reject; });
    clips.push(clip);
    return clip;
  });
  return { voice, clips };
}

test("Super can cancel a reply before the browser has started playback", async () => {
  const { voice, clips } = fixture();
  const done = voice.play("data:audio/mpeg;base64,reply");
  voice.cancel();
  assert.equal(await done, true); // consumed; never trigger a fallback voice
  assert.equal(clips[0].src, "");
  clips[0].start();
  await Promise.resolve();
  assert.equal(clips[0].pauses, 2); // late play is stopped too
});

test("a new preview stops the previous reply; its late completion cannot stop the new voice", async () => {
  const { voice, clips } = fixture();
  const first = voice.play("legacy-mp3");
  const second = voice.play("data:audio/wav;base64,local");
  assert.equal(await first, true);
  assert.equal(clips[1].src, "data:audio/wav;base64,local");
  clips[0].start();
  clips[1].start();
  await Promise.resolve();
  assert.equal(clips[1].pauses, 0);
  clips[1].onended();
  assert.equal(await second, true);
});

test("playback failure is reported, and legacy MP3 stays supported", async () => {
  const { voice, clips } = fixture();
  const done = voice.play("legacy");
  assert.equal(clips[0].src, "data:audio/mpeg;base64,legacy");
  clips[0].fail(new Error("audio device unavailable"));
  assert.equal(await done, false);
});
