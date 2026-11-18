// The Deezer pill's page rules (src/core/deezer.ts) and views
// (src/views/deezer.ts). The session side is tested in src-tauri/src/deezer.rs.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { emit, sent } from "./tauri.mjs";
import { installFakeDom } from "./fakedom.mjs";
import {
  DEEZER_ID, IDLE_DEEZER, Deezer, currentArtwork, deezerPosition, musicPlaying, withPlaying,
} from "../src/core/deezer.ts";
import { registerDeezerHandlers } from "../src/island/deezer.ts";
import { IDLE_SPOTIFY, SPOTIFY_ID, Spotify, desktopDances, islandDances } from "../src/core/spotify.ts";
import { buildDeezerCard, buildDeezerPill, seek } from "../src/views/deezer.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";
import { lookup, setLanguage } from "../src/i18n/i18n.ts";

installFakeDom();

const track = (over = {}) => ({
  id: "deezer:track:abc", title: "Darkside", artist: "Alan Walker", album: "",
  duration: 211, artUrl: "smtc:abc", ...over,
});

const playing = (over = {}) => ({
  ...IDLE_DEEZER, running: true, installed: true, track: track(), playing: true,
  position: 10, positionAt: 1_000, volume: 70, ...over,
});

test("the position runs on while playing and stops at the end", () => {
  const s = playing();
  assert.equal(deezerPosition(s, 3_500), 12.5);
  assert.equal(deezerPosition(s, 1_000_000), 211);
  assert.equal(deezerPosition({ ...s, playing: false }, 60_000), 10);
});

test("a click freezes and restarts the clock where it is", () => {
  const paused = withPlaying(playing(), false, 6_000);
  assert.equal(paused.playing, false);
  assert.equal(paused.position, 15);
  assert.equal(withPlaying(paused, false, 9_000), paused);
});

test("music plays only on a declared Deezer pill", () => {
  assert.equal(musicPlaying(playing(), [DEEZER_ID]), true);
  assert.equal(musicPlaying(playing(), ["integration_spotify"]), false);
  assert.equal(musicPlaying(playing({ track: null }), [DEEZER_ID]), false);
});

test("the cover shows only for the track it belongs to", () => {
  Deezer.artwork = { artUrl: "smtc:abc", dataUrl: "data:image/png;base64,AA" };
  assert.equal(currentArtwork(playing()), "data:image/png;base64,AA");
  assert.equal(currentArtwork(playing({ track: track({ artUrl: "smtc:other" }) })), null);
});

// ── Reports from Rust ─────────────────────────────────────────────────────────────────────

const island = { reveals: 0, revealSilently() { this.reveals += 1; } };
registerDeezerHandlers(island);

beforeEach(() => {
  setLanguage("en");
  State.settings = { ...DEFAULT_SETTINGS, activeIntegrations: [DEEZER_ID] };
  State.os = "windows";
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.view = "overview";
  State.paused = false;
  State.loadIntegrationTasks();
  Deezer.state = { ...IDLE_DEEZER };
  Spotify.state = { ...IDLE_SPOTIFY };
  Deezer.artwork = null;
  island.reveals = 0;
});

const deezerTask = () => State.tasks.find((t) => t.id === DEEZER_ID);

test("the pill wears the track's title, and its own name when nothing plays", () => {
  assert.equal(deezerTask().name, "Deezer");
  emit("deezer", playing());
  assert.equal(Deezer.state.track.title, "Darkside");
  assert.equal(deezerTask().name, "Darkside");
  emit("deezer", { ...IDLE_DEEZER, running: true });
  assert.equal(deezerTask().name, "Deezer");
});

test("music starting shows the hidden island once, silently", () => {
  emit("deezer", playing({ playing: false }));
  assert.equal(island.reveals, 0);
  emit("deezer", playing());
  assert.equal(island.reveals, 1);
  emit("deezer", playing({ position: 30 }));
  assert.equal(island.reveals, 1, "only on not playing → playing");

  // Paused app, or Deezer not declared: nothing shows.
  emit("deezer", { ...IDLE_DEEZER });
  State.paused = true;
  emit("deezer", playing());
  assert.equal(island.reveals, 1);
  State.paused = false;
  emit("deezer", { ...IDLE_DEEZER });
  State.settings.activeIntegrations = [];
  emit("deezer", playing());
  assert.equal(island.reveals, 1);
});

test("the cover arrives on its own event", () => {
  emit("deezer", playing());
  emit("deezer-artwork", { artUrl: "smtc:abc", dataUrl: "data:image/png;base64,AA" });
  assert.equal(currentArtwork(Deezer.state), "data:image/png;base64,AA");
});

test("the card reads the player again each time it comes on screen", () => {
  const before = sent("deezer_refresh").length;
  State.mode = "expanded";
  State.view = "overview";
  State.setFocus(DEEZER_ID);
  assert.equal(sent("deezer_refresh").length, before + 1);
  State.notify();
  assert.equal(sent("deezer_refresh").length, before + 1, "not again while it stays");
  State.mode = "compact";
  State.notify();
  State.mode = "expanded";
  State.notify();
  assert.equal(sent("deezer_refresh").length, before + 2);
});

// ── Mochi ─────────────────────────────────────────────────────────────────────

const spotifyPlays = () => ({
  ...IDLE_SPOTIFY, running: true, installed: true, playing: true,
  track: { id: "spotify:track:x", title: "Get Lucky", artist: "Daft Punk", album: "", duration: 180, artUrl: "" },
});

test("Mochi dances while Deezer plays on a declared pill, not paused, not undeclared", () => {
  assert.equal(State.anyMusicPlaying, false);
  Deezer.state = playing();
  assert.equal(State.deezerPlaying, true);
  assert.equal(State.spotifyPlaying, false);
  assert.equal(State.anyMusicPlaying, true);
  Deezer.state = playing({ playing: false });
  assert.equal(State.anyMusicPlaying, false);
  Deezer.state = playing();
  State.settings.activeIntegrations = [];
  assert.equal(State.anyMusicPlaying, false);
});

test("with both players, Mochi dances if either plays", () => {
  State.settings.activeIntegrations = [SPOTIFY_ID, DEEZER_ID];
  Spotify.state = spotifyPlays();
  Deezer.state = playing({ playing: false });
  assert.equal(State.anyMusicPlaying, true);
  Spotify.state = { ...IDLE_SPOTIFY };
  Deezer.state = playing();
  assert.equal(State.anyMusicPlaying, true);
  Deezer.state = playing({ playing: false });
  assert.equal(State.anyMusicPlaying, false);
});

test("expanded, Mochi dances on the Deezer card as on Spotify's; compact anywhere", () => {
  const base = { music: true, state: "idle", view: "overview" };
  assert.equal(islandDances({ ...base, mode: "expanded", focusId: DEEZER_ID }), true);
  assert.equal(islandDances({ ...base, mode: "expanded", focusId: SPOTIFY_ID }), true);
  assert.equal(islandDances({ ...base, mode: "expanded", focusId: "integration_github" }), false);
  assert.equal(islandDances({ ...base, mode: "compact", focusId: null }), true);
  assert.equal(islandDances({ ...base, music: false, mode: "compact", focusId: DEEZER_ID }), false);
  assert.equal(islandDances({ ...base, state: "error", mode: "compact", focusId: DEEZER_ID }), false);
  assert.equal(desktopDances(State.anyMusicPlaying, "idle"), false);
  Deezer.state = playing();
  assert.equal(desktopDances(State.anyMusicPlaying, "idle"), true);
});

// ── Views ─────────────────────────────────────────────────────────────────────

test("the idle card: not playing, or not installed with a way to get it", () => {
  const card = buildDeezerCard();
  Deezer.state = { ...IDLE_DEEZER, installed: true };
  card.sync();
  assert.match(card.el.textContent, /Deezer.*Integration.*Not playing.*Open Deezer/);
  Deezer.state = { ...IDLE_DEEZER };
  card.sync();
  assert.match(card.el.textContent, /Deezer not installed.*Get Deezer/);
  const before = sent("deezer_open").length;
  card.el.find("BUTTON")[0].fire("click");
  assert.equal(sent("deezer_open").length, before + 1);

  setLanguage("fr");
  card.sync();
  assert.ok(card.el.textContent.includes(lookup("Get Deezer", "fr")));
});

test("the playing card: title, artist, times, and the controls", () => {
  const card = buildDeezerCard();
  Deezer.state = playing({ playing: false });
  card.sync();
  const text = card.el.textContent;
  assert.ok(text.includes("Darkside"));
  assert.ok(text.includes("Alan Walker"));
  assert.ok(!text.includes("·"), "no album: nothing after the artist");
  assert.ok(text.includes("0:10") && text.includes("-3:21"));

  const [prev, play, next] = card.el.querySelector("np-buttons").children;
  assert.equal(prev.title, "Previous");
  assert.equal(play.title, "Play");
  const before = sent("deezer_control").length;
  prev.fire("click");
  next.fire("click");
  play.fire("click");
  assert.deepEqual(sent("deezer_control").slice(before), [
    { action: "previous", value: null },
    { action: "next", value: null },
    { action: "playPause", value: null },
  ]);
  // The page shows the click at once.
  assert.equal(Deezer.state.playing, true);

  Deezer.state = playing({ playing: false, track: track({ album: "Different World" }) });
  card.sync();
  assert.ok(card.el.textContent.includes("Alan Walker · Different World"));
});

test("a seek moves the clock at once and goes to Deezer, inside the track", () => {
  Deezer.state = playing({ playing: false });
  const before = sent("deezer_control").length;
  seek(60);
  assert.equal(Deezer.state.position, 60);
  seek(10_000);
  assert.equal(Deezer.state.position, 210, "never past the last second");
  assert.deepEqual(sent("deezer_control").slice(before), [
    { action: "seek", value: 60 },
    { action: "seek", value: 210 },
  ]);
  Deezer.state = { ...IDLE_DEEZER };
  seek(5);
  assert.equal(sent("deezer_control").length, before + 2, "nothing to seek: nothing sent");
});

test("the pill shows play/pause and next on hover, only with a track", () => {
  const task = deezerTask();
  const pill = buildDeezerPill(task, () => {});
  pill.el.fire("mouseenter");
  assert.ok(!pill.el.classList.contains("controls"), "nothing loaded: no controls");
  Deezer.state = playing();
  pill.sync();
  assert.ok(pill.el.classList.contains("controls"));
  const [playBtn, nextBtn] = pill.el.querySelector("np-pill-controls").children;
  assert.equal(playBtn.title, "Pause");
  assert.equal(nextBtn.title, "Next");
  const before = sent("deezer_control").length;
  playBtn.fire("click");
  nextBtn.fire("click");
  assert.deepEqual(sent("deezer_control").slice(before), [
    { action: "playPause", value: null },
    { action: "next", value: null },
  ]);
  assert.equal(Deezer.state.playing, false);
  pill.el.fire("mouseleave");
  assert.ok(!pill.el.classList.contains("controls"));
});
