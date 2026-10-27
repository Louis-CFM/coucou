// The Apple Music pill on Windows: pure state rules in src/core/music.ts,
// views in src/views/music.ts, event handlers in src/island/music.ts, and Mochi's dancing.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { calls, emit, sent } from "./tauri.mjs";
import { installFakeDom } from "./fakedom.mjs";
import {
  IDLE_MUSIC, MUSIC_ID, MUSIC_RED, Music, currentArtwork, desktopDances, formatTime,
  islandDances, appleMusicPlaying, musicPosition, volumeLevel, withPlaying,
} from "../src/core/music.ts";
import { registerMusicHandlers } from "../src/island/music.ts";
import { buildMusicCard, buildMusicPill } from "../src/views/music.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

installFakeDom();

const track = (over = {}) => ({
  id: "music:track:123", title: "Blinding Lights", artist: "The Weeknd", album: "After Hours",
  duration: 200, artUrl: "https://music.apple.com/image/123", ...over,
});

const playing = (over = {}) => ({
  ...IDLE_MUSIC, running: true, installed: true, track: track(), playing: true,
  position: 20, positionAt: 1_000, volume: 80, ...over,
});

// ── Position & Time ──────────────────────────────────────────────────────────

test("music position runs on from its timestamp while playing, and caps at duration", () => {
  const s = playing();
  assert.equal(musicPosition(s, 1_000), 20);
  assert.equal(musicPosition(s, 4_000), 23);
  assert.equal(musicPosition(s, 500), 20, "clock behind anchor does not regress");
  assert.equal(musicPosition(s, 1_000_000), 200, "capped at track duration");
  assert.equal(musicPosition({ ...s, playing: false }, 50_000), 20, "paused stays at current position");
  assert.equal(musicPosition({ ...s, track: null }, 5_000), 24, "no track length = no cap");
});

test("play/pause toggle freezes or resumes position correctly", () => {
  const paused = withPlaying(playing(), false, 6_000);
  assert.equal(paused.playing, false);
  assert.equal(paused.position, 25);
  assert.equal(paused.positionAt, 6_000);
  assert.equal(musicPosition(paused, 10_000), 25);
  const resumed = withPlaying(paused, true, 10_000);
  assert.equal(musicPosition(resumed, 12_000), 27);
  const same = playing();
  assert.equal(withPlaying(same, true, 50), same, "same state returns same object");
});

test("formatTime formats correctly for sub-hour and hour durations", () => {
  assert.equal(formatTime(0), "0:00");
  assert.equal(formatTime(75), "1:15");
  assert.equal(formatTime(599), "9:59");
  assert.equal(formatTime(3665), "1:01:05");
  assert.equal(formatTime(-10), "0:00");
  assert.equal(formatTime(Number.NaN), "0:00");
});

test("volume icon matches levels (0=muted, 1, 2, 3)", () => {
  assert.deepEqual([0, 1, 33, 34, 66, 67, 100].map(volumeLevel), [0, 1, 1, 2, 2, 3, 3]);
});

test("artwork is only shown for matching track URL", () => {
  Music.artwork = { artUrl: "https://music.apple.com/image/123", dataUrl: "data:image/jpeg;base64,XYZ" };
  assert.equal(currentArtwork(playing()), "data:image/jpeg;base64,XYZ");
  assert.equal(currentArtwork(playing({ track: track({ artUrl: "https://music.apple.com/image/other" }) })), null);
  assert.equal(currentArtwork(playing({ track: null })), null);
  Music.artwork = null;
});

// ── Dancing Rules ─────────────────────────────────────────────────────────────

test("appleMusicPlaying requires active playback with a track on a declared pill", () => {
  assert.ok(appleMusicPlaying(playing(), [MUSIC_ID]));
  assert.ok(!appleMusicPlaying(playing(), ["integration_spotify"]));
  assert.ok(!appleMusicPlaying(playing({ playing: false }), [MUSIC_ID]));
  assert.ok(!appleMusicPlaying(playing({ track: null }), [MUSIC_ID]));
});

test("island Mochi dances in compact mode whenever music plays", () => {
  const base = { music: true, state: "idle", mode: "compact", view: "overview", focusId: "integration_claude" };
  for (const state of ["idle", "working", "thinking", "searching", "finished"]) {
    assert.ok(islandDances({ ...base, state }), state);
  }
  for (const state of ["approval", "question", "error", "ratelimit", "sleeping", "dizzy"]) {
    assert.ok(!islandDances({ ...base, state }), state);
  }
});

test("island Mochi dances in expanded mode only when the music card is in front", () => {
  const expanded = { music: true, state: "idle", mode: "expanded", view: "overview", focusId: MUSIC_ID };
  assert.ok(islandDances(expanded));
  assert.ok(!islandDances({ ...expanded, focusId: "integration_claude" }));
  assert.ok(!islandDances({ ...expanded, view: "history" }));
  assert.ok(!islandDances({ ...expanded, music: false }));
});

test("desktop Mochi dances during active music playback in calm states", () => {
  assert.ok(desktopDances(true, "idle"));
  assert.ok(desktopDances(true, "working"));
  assert.ok(!desktopDances(false, "idle"));
  assert.ok(!desktopDances(true, "sleeping"));
});

// ── Island Events & Views ─────────────────────────────────────────────────────

beforeEach(() => {
  Music.state = { ...IDLE_MUSIC };
  Music.artwork = null;
  State.os = "windows";
  State.settings = { ...DEFAULT_SETTINGS, activeIntegrations: [MUSIC_ID] };
  State.tasks = [
    { id: "agent_code", name: "VS Code", state: "idle", color: "#007ACC", isIntegration: false, steps: [] },
    { id: MUSIC_ID, name: "Apple Music", state: "idle", color: MUSIC_RED, isIntegration: true, steps: [] },
  ];
  State.focusId = "agent_code";
  State.mode = "hidden";
  calls.length = 0;
});

test("music event updates player state and silently reveals the hidden island", async () => {
  let revealed = false;
  registerMusicHandlers({ revealSilently: () => { revealed = true; } });

  await emit("music", playing());
  assert.equal(Music.state.playing, true);
  assert.equal(Music.state.track?.title, "Blinding Lights");
  assert.equal(revealed, true);
  assert.equal(State.tasks.find((t) => t.id === MUSIC_ID)?.name, "Blinding Lights");
});

test("buildMusicCard renders idle view when not running", () => {
  const card = buildMusicCard();
  Music.state = { ...IDLE_MUSIC, installed: true };
  card.sync();
  assert.ok(card.el.querySelector(".idle-wrap"));
  assert.match(card.el.textContent, /Apple Music.*Integration.*Not playing.*Open Apple Music/);

  Music.state = { ...IDLE_MUSIC, installed: false };
  card.sync();
  assert.match(card.el.textContent, /Apple Music not installed.*Get Apple Music/);
});

test("buildMusicPill displays track title and controls", () => {
  const task = State.tasks.find((t) => t.id === MUSIC_ID);
  const pill = buildMusicPill(task, () => {});
  assert.ok(pill.el);
  pill.sync();
  assert.equal(pill.el.querySelector(".lbl")?.textContent, "Apple Music");
});
