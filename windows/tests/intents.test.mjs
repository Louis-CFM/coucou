import { test } from "node:test";
import assert from "node:assert/strict";
import { callbackLine, moodOf, minutesIn, openTarget, parseIntent, voicePhrases } from "../src/core/intents.ts";

const k = (s) => parseIntent(s);

test("music, volume and cancel", () => {
  assert.deepEqual(k("Pause the music."), { kind: "music", action: "pause" });
  assert.deepEqual(k("play"), { kind: "music", action: "play" });
  assert.deepEqual(k("next song"), { kind: "music", action: "next" });
  assert.deepEqual(k("skip this"), { kind: "music", action: "next" });
  assert.deepEqual(k("previous track"), { kind: "music", action: "previous" });
  assert.deepEqual(k("volume up"), { kind: "volume", action: "up" });
  assert.deepEqual(k("turn it down"), { kind: "volume", action: "down" });
  assert.deepEqual(k("set volume to 40%"), { kind: "volume", action: "set", value: 40 });
  assert.deepEqual(k("mute"), { kind: "volume", action: "mute" });
  assert.deepEqual(k("never mind"), { kind: "cancel" });
});

test("focus, timers, reminders and to-dos", () => {
  assert.deepEqual(k("start a focus for 45 minutes"), { kind: "focus", minutes: 45 });
  assert.deepEqual(k("focus"), { kind: "focus", minutes: 25 });
  assert.deepEqual(k("stop focus"), { kind: "focusStop" });
  assert.deepEqual(k("set a timer for five minutes"), { kind: "timer", minutes: 5, label: "" });
  assert.deepEqual(k("remind me in 20 minutes to take out the laundry"), { kind: "timer", minutes: 20, label: "take out the laundry" });
  assert.deepEqual(k("add buy milk to my to-do list"), { kind: "todoAdd", text: "buy milk" });
  assert.deepEqual(k("add a todo: submit the AAL lab"), { kind: "todoAdd", text: "submit the aal lab" });
  assert.deepEqual(k("what's on my to-do list"), { kind: "todoList" });
  assert.equal(minutesIn("an hour"), 60);
  assert.equal(minutesIn("twenty five minutes"), 25);
});

test("pills, approvals and questions", () => {
  assert.deepEqual(k("add the calendar pill"), { kind: "pill", action: "add", name: "calendar" });
  assert.deepEqual(k("remove spotify"), { kind: "pill", action: "remove", name: "spotify" });
  assert.deepEqual(k("deny it"), { kind: "deny" });
  // Approving by voice is recognised only to say no.
  assert.deepEqual(k("approve"), { kind: "approve" });
  assert.deepEqual(k("how much of my Claude plan is left?"), { kind: "planUsage" });
  assert.deepEqual(k("what is Claude doing"), { kind: "agents" });
  assert.deepEqual(k("what time is it"), { kind: "time" });
  assert.deepEqual(k("who won the match last night?"), { kind: "ask", text: "who won the match last night?" });
});

test("open goes to apps, known sites, a domain or a search", () => {
  assert.deepEqual(k("open youtube"), { kind: "open", target: "youtube" });
  assert.deepEqual(openTarget("youtube"), { url: "https://www.youtube.com" });
  assert.deepEqual(openTarget("github dot com"), { url: "https://github.com" });
  assert.deepEqual(openTarget("Apple Music"), { app: "music" });
  assert.deepEqual(openTarget("vector calculus notes"), { url: "https://www.google.com/search?q=vector%20calculus%20notes" });
});

test("every phrase Maki listens for is a command, never a question", () => {
  const phrases = voicePhrases(["Spotify", "GitHub", "Calendar"]);
  assert.ok(phrases.length > 100);
  for (const p of phrases) {
    const i = parseIntent(p);
    assert.ok(i && i.kind !== "ask", `"${p}" → ${JSON.stringify(i)}`);
  }
});

test("Hermes callbacks open with two plain sentences", () => {
  assert.equal(callbackLine("**Build passed.** All 12 tests green. Logs are in out.txt."), "Hermes is back. Build passed. All 12 tests green.");
  assert.equal(callbackLine("done"), "Hermes is back. done");
  assert.ok(callbackLine("x".repeat(900)).length < 320);
});

test("Maki's mood tags drive Mochi and leave the caption", () => {
  assert.deepEqual(moodOf("[happy] Alright, playing your music!"), { clean: "Alright, playing your music!", mood: { emote: "happy" } });
  assert.deepEqual(moodOf("[laughs] [surprised] No way"), { clean: "No way", mood: { emote: "happy" } });
  assert.deepEqual(moodOf("[sad] Hmm, that failed."), { clean: "Hmm, that failed.", mood: { eye: "tired" } });
  assert.deepEqual(moodOf("[whispers] ok"), { clean: "ok", mood: null });
  assert.deepEqual(moodOf("plain"), { clean: "plain", mood: null });
});
