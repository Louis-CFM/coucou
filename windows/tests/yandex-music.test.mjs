// The Yandex Music pill (Windows): the page's rules in src/core/yandex-music.ts,
// the report handling in src/island/yandex-music.ts and the views in
// src/views/yandex-music.ts. The system media controls side — sessions,
// thumbnails, the mixer — is tested in src-tauri/src/yandex_music.rs.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { emit, sent } from "./tauri.mjs";
import { installFakeDom } from "./fakedom.mjs";
import {
  IDLE_YANDEX_MUSIC, YANDEX_MUSIC_ID, YANDEX_MUSIC_YELLOW, YandexMusic, currentYandexArtwork,
  yandexIslandDances, yandexMusicPlaying,
} from "../src/core/yandex-music.ts";
import { SPOTIFY_ID, desktopDances } from "../src/core/spotify.ts";
import { registerYandexMusicHandlers } from "../src/island/yandex-music.ts";
import { buildYandexMusicCard, buildYandexMusicPill } from "../src/views/yandex-music.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";
import { lookup, setLanguage } from "../src/i18n/i18n.ts";

installFakeDom();

const track = (over = {}) => ({
  id: "yandex:track:0123456789abcdef", title: "Группа крови", artist: "Кино", album: "Группа крови",
  duration: 285, artUrl: "smtc:0123456789abcdef", ...over,
});

const playing = (over = {}) => ({
  ...IDLE_YANDEX_MUSIC, running: true, installed: true, track: track(), playing: true,
  position: 10, positionAt: 1_000, volume: 70, ...over,
});

// ── The page's rules ──────────────────────────────────────────────────────────

test("the pill is Yandex Music's yellow, and idle until Rust reports", () => {
  assert.equal(YANDEX_MUSIC_ID, "integration_yandex_music");
  assert.equal(YANDEX_MUSIC_YELLOW, "#FFEE00");
  assert.equal(IDLE_YANDEX_MUSIC.track, null);
  assert.ok(!IDLE_YANDEX_MUSIC.shuffle && !IDLE_YANDEX_MUSIC.repeat);
});

test("a cover shows only on the track it belongs to", () => {
  YandexMusic.artwork = { artUrl: "smtc:0123456789abcdef", dataUrl: "data:image/png;base64,AA" };
  assert.equal(currentYandexArtwork(playing()), "data:image/png;base64,AA");
  assert.equal(currentYandexArtwork(playing({ track: track({ artUrl: "smtc:ffffffffffffffff" }) })), null);
  assert.equal(currentYandexArtwork(playing({ track: null })), null);
  YandexMusic.artwork = null;
});

test("music counts only when it plays on a declared Yandex Music pill", () => {
  assert.ok(yandexMusicPlaying(playing(), [YANDEX_MUSIC_ID]));
  assert.ok(!yandexMusicPlaying(playing(), [SPOTIFY_ID]));
  assert.ok(!yandexMusicPlaying(playing({ playing: false }), [YANDEX_MUSIC_ID]));
  assert.ok(!yandexMusicPlaying(playing({ track: null }), [YANDEX_MUSIC_ID]));
});

test("the island's Mochi dances by the Mac's rules, with Yandex Music in front when expanded", () => {
  const base = { music: true, state: "idle", mode: "compact", view: "overview", focusId: "integration_claude" };
  for (const state of ["idle", "working", "thinking", "searching", "finished"]) {
    assert.ok(yandexIslandDances({ ...base, state }), state);
  }
  for (const state of ["approval", "question", "error", "ratelimit", "sleeping", "dizzy"]) {
    assert.ok(!yandexIslandDances({ ...base, state }), state);
  }
  assert.ok(!yandexIslandDances({ ...base, music: false }));
  assert.ok(!yandexIslandDances({ ...base, mode: "hidden" }));
  assert.ok(!yandexIslandDances({ ...base, mode: "expanded" }));
  assert.ok(yandexIslandDances({ ...base, mode: "expanded", focusId: YANDEX_MUSIC_ID }));
  assert.ok(!yandexIslandDances({ ...base, mode: "expanded", focusId: SPOTIFY_ID }), "Spotify's card is not ours");
  assert.ok(!yandexIslandDances({ ...base, mode: "expanded", focusId: YANDEX_MUSIC_ID, view: "prompt" }));
  // Mochi on the desktop shares Spotify's rule.
  assert.ok(desktopDances(true, "working"));
  assert.ok(!desktopDances(true, "approval"));
});

// ── Reports from Rust ─────────────────────────────────────────────────────────

const island = { reveals: 0, revealSilently() { this.reveals += 1; } };
registerYandexMusicHandlers(island);

beforeEach(() => {
  setLanguage("en");
  State.settings = { ...DEFAULT_SETTINGS, activeIntegrations: [YANDEX_MUSIC_ID] };
  State.os = "windows";
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.view = "overview";
  State.paused = false;
  State.loadIntegrationTasks();
  YandexMusic.state = { ...IDLE_YANDEX_MUSIC };
  YandexMusic.artwork = null;
  island.reveals = 0;
});

const yandexTask = () => State.tasks.find((t) => t.id === YANDEX_MUSIC_ID);

test("the pill wears the track's title, and its own name when nothing plays", () => {
  assert.equal(yandexTask().name, "Yandex Music");
  emit("yandex-music", playing());
  assert.equal(YandexMusic.state.track.title, "Группа крови");
  assert.equal(yandexTask().name, "Группа крови");
  emit("yandex-music", { ...IDLE_YANDEX_MUSIC, running: true });
  assert.equal(yandexTask().name, "Yandex Music");
});

test("music starting shows the hidden island once, silently", () => {
  emit("yandex-music", playing({ playing: false }));
  assert.equal(island.reveals, 0);
  emit("yandex-music", playing());
  assert.equal(island.reveals, 1);
  emit("yandex-music", playing({ position: 30 }));
  assert.equal(island.reveals, 1, "only on not playing → playing");
  assert.ok(State.yandexMusicPlaying);
  assert.ok(!State.spotifyPlaying, "not Spotify's music");

  // Not declared: nothing dances, nothing shows.
  emit("yandex-music", { ...IDLE_YANDEX_MUSIC });
  State.settings.activeIntegrations = [];
  emit("yandex-music", playing());
  assert.equal(island.reveals, 1);
  assert.ok(!State.yandexMusicPlaying);
});

test("the cover arrives on its own event", () => {
  emit("yandex-music", playing());
  emit("yandex-music-artwork", { artUrl: "smtc:0123456789abcdef", dataUrl: "data:image/png;base64,AA" });
  assert.equal(currentYandexArtwork(), "data:image/png;base64,AA");
});

test("the card reads the player again each time it comes on screen", () => {
  const before = sent("yandex_music_refresh").length;
  State.mode = "expanded";
  State.view = "overview";
  State.setFocus(YANDEX_MUSIC_ID);
  assert.equal(sent("yandex_music_refresh").length, before + 1);
  State.notify();
  assert.equal(sent("yandex_music_refresh").length, before + 1, "not again while it stays");
  State.mode = "compact";
  State.notify();
  State.mode = "expanded";
  State.notify();
  assert.equal(sent("yandex_music_refresh").length, before + 2);
});

// ── Views ─────────────────────────────────────────────────────────────────────

test("the idle card: not playing, or not installed with a way to get it", () => {
  const card = buildYandexMusicCard();
  YandexMusic.state = { ...IDLE_YANDEX_MUSIC, installed: true };
  card.sync();
  assert.match(card.el.textContent, /Yandex Music.*Integration.*Not playing.*Open Yandex Music/);
  YandexMusic.state = { ...IDLE_YANDEX_MUSIC };
  card.sync();
  assert.match(card.el.textContent, /Yandex Music not installed.*Get Yandex Music/);
  card.el.find("BUTTON")[0].fire("click");
  assert.ok(sent("yandex_music_open").length > 0);

  const fr = lookup("Get Yandex Music", "fr");
  assert.equal(typeof fr, "string", "the key is in src/i18n/strings.json");
  setLanguage("fr");
  card.sync();
  assert.ok(card.el.textContent.includes(fr));
});

test("the playing card: title, artist · album, times, and controls without shuffle or repeat", () => {
  const card = buildYandexMusicCard();
  YandexMusic.state = playing({ playing: false });
  card.sync();
  const text = card.el.textContent;
  assert.ok(text.includes("Группа крови"));
  assert.ok(text.includes("Кино · Группа крови"));
  assert.ok(text.includes("0:10") && text.includes("-4:35"));

  const buttons = card.el.querySelector("np-buttons").children;
  assert.equal(buttons.length, 3, "previous, play/pause, next");
  const [prev, play, next] = buttons;
  assert.equal(play.title, "Play");
  const before = sent("yandex_music_control").length;
  prev.fire("click");
  next.fire("click");
  play.fire("click");
  assert.deepEqual(sent("yandex_music_control").slice(before), [
    { action: "previous", value: null },
    { action: "next", value: null },
    { action: "playPause", value: null },
  ]);
  // The page shows the click at once.
  assert.equal(YandexMusic.state.playing, true);
  assert.ok(!text.includes("Advertisement"));
});

test("a click on the cover opens Yandex Music", () => {
  const card = buildYandexMusicCard();
  YandexMusic.state = playing();
  card.sync();
  const art = card.el.querySelector("np-art");
  assert.equal(art.title, "Группа крови — open Yandex Music");
  const before = sent("yandex_music_open").length;
  art.fire("click");
  assert.equal(sent("yandex_music_open").length, before + 1);
});

test("the pill shows play/pause and next on hover, only with a track", () => {
  const pill = buildYandexMusicPill(yandexTask(), () => {});
  pill.el.fire("mouseenter");
  assert.ok(!pill.el.classList.contains("controls"), "nothing loaded: no controls");
  YandexMusic.state = playing();
  pill.sync();
  assert.ok(pill.el.classList.contains("controls"));
  const [playBtn, nextBtn] = pill.el.querySelector("np-pill-controls").children;
  assert.equal(playBtn.title, "Pause");
  const before = sent("yandex_music_control").length;
  playBtn.fire("click");
  nextBtn.fire("click");
  assert.deepEqual(sent("yandex_music_control").slice(before), [
    { action: "playPause", value: null },
    { action: "next", value: null },
  ]);
  assert.equal(YandexMusic.state.playing, false);
  pill.el.fire("mouseleave");
  assert.ok(!pill.el.classList.contains("controls"));
});
