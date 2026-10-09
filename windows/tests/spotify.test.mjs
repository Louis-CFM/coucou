// The Spotify pill (Linux) and Mochi's dance: the page's rules in
// src/core/spotify.ts, the dance in src/mochi/engine.ts, the report handling in
// src/island/spotify.ts and the views in src/views/spotify.ts. The MPRIS side —
// metadata, position, the bus itself — is tested in src-tauri/src/spotify.rs.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { emit, sent } from "./tauri.mjs";
import { installFakeDom } from "./fakedom.mjs";
import {
  ANNOUNCE_SECONDS, IDLE_SPOTIFY, SPOTIFY_ID, Spotify, currentArtwork, desktopDances, formatTime, isAd,
  isNewSong, islandDances, musicPlaying, spotifyPosition, volumeLevel, withPlaying,
} from "../src/core/spotify.ts";
import { BotEngine, DanceClock, danceTransform, stepDanceLevel } from "../src/mochi/engine.ts";
import { registerSpotifyHandlers } from "../src/island/spotify.ts";
import { buildSpotifyCard, buildSpotifyPill } from "../src/views/spotify.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";
import { lookup, setLanguage } from "../src/i18n/i18n.ts";

installFakeDom();

const track = (over = {}) => ({
  id: "spotify:track:abc", title: "Get Lucky", artist: "Daft Punk", album: "Random Access Memories",
  duration: 180, artUrl: "https://i.scdn.co/image/abc", ...over,
});

const playing = (over = {}) => ({
  ...IDLE_SPOTIFY, running: true, installed: true, track: track(), playing: true,
  position: 10, positionAt: 1_000, volume: 70, ...over,
});

// ── Position ──────────────────────────────────────────────────────────────────

test("the position runs on from its timestamp while playing, and stops at the end", () => {
  const s = playing();
  assert.equal(spotifyPosition(s, 1_000), 10);
  assert.equal(spotifyPosition(s, 3_500), 12.5);
  assert.equal(spotifyPosition(s, 0), 10, "a clock behind the anchor never moves it back");
  assert.equal(spotifyPosition(s, 1_000_000), 180, "capped at the track's length");
  assert.equal(spotifyPosition({ ...s, playing: false }, 60_000), 10, "paused, it stays put");
  assert.equal(spotifyPosition({ ...s, track: null }, 3_000), 12, "no length, no cap");
});

test("a play/pause click freezes or restarts the clock where it is", () => {
  const paused = withPlaying(playing(), false, 5_000);
  assert.equal(paused.playing, false);
  assert.equal(paused.position, 14);
  assert.equal(paused.positionAt, 5_000);
  assert.equal(spotifyPosition(paused, 9_000), 14);
  const again = withPlaying(paused, true, 9_000);
  assert.equal(spotifyPosition(again, 10_000), 15);
  const same = playing();
  assert.equal(withPlaying(same, true, 99), same, "no change, same object");
});

test("times read like the Mac's player", () => {
  assert.equal(formatTime(0), "0:00");
  assert.equal(formatTime(65.9), "1:05");
  assert.equal(formatTime(599), "9:59");
  assert.equal(formatTime(3725), "1:02:05");
  assert.equal(formatTime(-3), "0:00");
  assert.equal(formatTime(Number.NaN), "0:00");
});

test("the volume icon has the Mac's thresholds", () => {
  assert.deepEqual([0, 1, 33, 34, 66, 67, 100].map(volumeLevel), [0, 1, 1, 2, 2, 3, 3]);
});

test("ads are told by their id", () => {
  assert.ok(isAd(track({ id: "spotify:ad:123" })));
  assert.ok(!isAd(track()));
  assert.ok(!isAd(null));
});

test("a cover shows only on the track it belongs to", () => {
  Spotify.artwork = { artUrl: "https://i.scdn.co/image/abc", dataUrl: "data:image/jpeg;base64,AA" };
  assert.equal(currentArtwork(playing()), "data:image/jpeg;base64,AA");
  assert.equal(currentArtwork(playing({ track: track({ artUrl: "https://i.scdn.co/image/zzz" }) })), null);
  assert.equal(currentArtwork(playing({ track: null })), null);
  Spotify.artwork = null;
});

// ── When Mochi dances ─────────────────────────────────────────────────────────

test("music counts only when it plays on a declared Spotify pill", () => {
  assert.ok(musicPlaying(playing(), [SPOTIFY_ID]));
  assert.ok(!musicPlaying(playing(), ["integration_n8n"]));
  assert.ok(!musicPlaying(playing({ playing: false }), [SPOTIFY_ID]));
  assert.ok(!musicPlaying(playing({ track: null }), [SPOTIFY_ID]));
});

test("the island's Mochi dances by the Mac's rules", () => {
  const base = { music: true, state: "idle", mode: "compact", view: "overview", focusId: "integration_claude" };
  // Compact: whenever music plays, in the calm and busy states.
  for (const state of ["idle", "working", "thinking", "searching", "finished"]) {
    assert.ok(islandDances({ ...base, state }), state);
  }
  // An alert, an error, sleep or a daze win.
  for (const state of ["approval", "question", "error", "ratelimit", "sleeping", "dizzy"]) {
    assert.ok(!islandDances({ ...base, state }), state);
  }
  assert.ok(!islandDances({ ...base, music: false }));
  assert.ok(!islandDances({ ...base, mode: "hidden" }));
  // Expanded: only on the overview, with the music pill in front.
  assert.ok(!islandDances({ ...base, mode: "expanded" }));
  assert.ok(islandDances({ ...base, mode: "expanded", focusId: SPOTIFY_ID }));
  assert.ok(!islandDances({ ...base, mode: "expanded", focusId: SPOTIFY_ID, view: "prompt" }));
});

test("Mochi on the desktop dances by the compact island's rules", () => {
  assert.ok(desktopDances(true, "working"));
  assert.ok(!desktopDances(true, "approval"));
  assert.ok(!desktopDances(false, "idle"));
});

// ── The dance itself (BotEngine.applyDance) ───────────────────────────────────

test("the dance fades in over 0.3 s and out over 0.5 s", () => {
  assert.equal(stepDanceLevel(0, true, 0.15), 0.5);
  assert.equal(stepDanceLevel(0.9, true, 0.15), 1);
  assert.equal(stepDanceLevel(1, false, 0.25), 0.5);
  assert.equal(stepDanceLevel(0.1, false, 0.25), 0);
  assert.equal(stepDanceLevel(1, true, 0.05), 1);
});

test("112 BPM: still on the beat, highest half a beat later, nothing at level 0", () => {
  const R = 10;
  const onBeat = danceTransform(0, 1, R);
  assert.equal(onBeat.dx, 0);
  assert.equal(onBeat.dy, -0);
  assert.equal(onBeat.rotate, 0);
  assert.ok(Math.abs(onBeat.sx - 1.045) < 1e-9 && Math.abs(onBeat.sy - 0.94) < 1e-9, "squashed on landing");
  const top = danceTransform(0.5 * 60 / 112, 1, R);
  assert.ok(Math.abs(top.dy + 2) < 1e-9, "hops 0.2 R");
  assert.ok(Math.abs(top.dx - 0.8) < 1e-9 && Math.abs(top.rotate - 0.1) < 1e-9);
  assert.ok(Math.abs(top.sx - 1) < 1e-9 && Math.abs(top.sy - 1) < 1e-9);
  const off = danceTransform(0.3, 0, R);
  assert.deepEqual([off.dx, off.dy, off.rotate, off.sx, off.sy].map((v) => Math.abs(v)), [0, 0, 0, 1, 1]);
});

test("the engine dances only once asked, and keeps its frames going meanwhile", () => {
  const ops = [];
  const ctx = {
    translate: (x, y) => ops.push(["translate", x, y]),
    rotate: (a) => ops.push(["rotate", a]),
    scale: (x, y) => ops.push(["scale", x, y]),
  };
  const engine = new BotEngine();
  engine.applyDance(ctx, 100, 100);
  assert.deepEqual(ops, [], "not dancing: the context is left alone");
  engine.setDancing(true);
  engine.update(0.05);
  assert.ok(engine.dancingLevel > 0 && engine.busy);
  engine.applyDance(ctx, 100, 100);
  assert.deepEqual(ops.map((o) => o[0]), ["translate", "rotate", "scale", "translate"]);
  // Around the bottom of the body: back where it started.
  assert.equal(ops[3][1], -(50 + engine.ox * 30));
  engine.setDancing(false);
  for (let i = 0; i < 20; i++) engine.update(0.05);
  assert.equal(engine.dancingLevel, 0);
});

// ── Reports from Rust ─────────────────────────────────────────────────────────

const island = {
  reveals: 0,
  revealSilently() { this.reveals += 1; },
  /** The glances asked for, and whether the island is free to give one. */
  glances: [],
  free: true,
  glance(seconds, done) {
    if (!this.free) return false;
    this.glances.push({ seconds, done });
    State.mode = "expanded";
    return true;
  },
};
registerSpotifyHandlers(island);

beforeEach(() => {
  setLanguage("en");
  State.settings = { ...DEFAULT_SETTINGS, activeIntegrations: [SPOTIFY_ID] };
  State.os = "linux";
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.view = "overview";
  State.paused = false;
  State.loadIntegrationTasks();
  Spotify.state = { ...IDLE_SPOTIFY };
  Spotify.artwork = null;
  Spotify.heard = null;
  Spotify.announcing = 0;
  Spotify.dancing = false;
  State.mochiOnDesktop = false;
  DanceClock.tempo = 0;
  DanceClock.beatAt = 0;
  island.reveals = 0;
  island.glances = [];
  island.free = true;
});

const spotifyTask = () => State.tasks.find((t) => t.id === SPOTIFY_ID);

test("the pill wears the track's title, and its own name when nothing plays", () => {
  assert.equal(spotifyTask().name, "Spotify");
  emit("spotify", playing());
  assert.equal(Spotify.state.track.title, "Get Lucky");
  assert.equal(spotifyTask().name, "Get Lucky");
  emit("spotify", playing({ track: track({ id: "spotify:ad:1", title: "" }) }));
  assert.equal(spotifyTask().name, "Advertisement");
  emit("spotify", { ...IDLE_SPOTIFY, running: true });
  assert.equal(spotifyTask().name, "Spotify");
});

test("music starting shows the hidden island once, silently; nothing while the pill is not declared", () => {
  emit("spotify", playing({ playing: false }));
  assert.equal(island.reveals, 0);
  emit("spotify", playing());
  assert.equal(island.reveals, 1);
  emit("spotify", playing({ position: 30 }));
  assert.equal(island.reveals, 1, "only on not playing → playing");
  assert.ok(State.spotifyPlaying);

  // Not declared: nothing dances, nothing shows.
  emit("spotify", { ...IDLE_SPOTIFY });
  State.settings.activeIntegrations = [];
  emit("spotify", playing());
  assert.equal(island.reveals, 1);
  assert.ok(!State.spotifyPlaying);
});

test("the cover arrives on its own event", () => {
  emit("spotify", playing());
  emit("spotify-artwork", { artUrl: "https://i.scdn.co/image/abc", dataUrl: "data:image/png;base64,AA" });
  assert.equal(currentArtwork(), "data:image/png;base64,AA");
});

test("the card reads the player again each time it comes on screen", () => {
  const before = sent("spotify_refresh").length;
  State.mode = "expanded";
  State.view = "overview";
  State.setFocus(SPOTIFY_ID);
  assert.equal(sent("spotify_refresh").length, before + 1);
  State.notify();
  assert.equal(sent("spotify_refresh").length, before + 1, "not again while it stays");
  State.mode = "compact";
  State.notify();
  State.mode = "expanded";
  State.notify();
  assert.equal(sent("spotify_refresh").length, before + 2);
});

// ── Views ─────────────────────────────────────────────────────────────────────

test("the idle card: not playing, or not installed with a way to get it", () => {
  const card = buildSpotifyCard();
  Spotify.state = { ...IDLE_SPOTIFY, installed: true };
  card.sync();
  assert.match(card.el.textContent, /Spotify.*Integration.*Not playing.*Open Spotify/);
  Spotify.state = { ...IDLE_SPOTIFY };
  card.sync();
  assert.match(card.el.textContent, /Spotify not installed.*Get Spotify/);
  card.el.find("BUTTON")[0].fire("click");
  assert.ok(sent("spotify_open").length > 0);

  setLanguage("fr");
  card.sync();
  assert.ok(card.el.textContent.includes(lookup("Get Spotify", "fr")));
});

test("where shuffle and repeat cannot be set, the card leaves the two buttons out", () => {
  const card = buildSpotifyCard();
  Spotify.state = playing({ modes: false });
  card.sync();
  const [shuffle, prev, play, next, repeat] = card.el.querySelector("np-buttons").children;
  assert.equal(shuffle.style.display, "none");
  assert.equal(repeat.style.display, "none");
  for (const button of [prev, play, next]) assert.notEqual(button.style.display, "none");
  // Where they work, they are there.
  Spotify.state = playing({ modes: true });
  card.sync();
  assert.notEqual(shuffle.style.display, "none");
  assert.notEqual(repeat.style.display, "none");
});

test("the playing card: title, artist · album, times, and the controls", () => {
  const card = buildSpotifyCard();
  Spotify.state = playing({ playing: false, shuffle: true });
  card.sync();
  const text = card.el.textContent;
  assert.ok(text.includes("Get Lucky"));
  assert.ok(text.includes("Daft Punk · Random Access Memories"));
  assert.ok(text.includes("0:10") && text.includes("-2:50"));

  const [shuffle, prev, play, next, repeat] = card.el.querySelector("np-buttons").children;
  assert.equal(shuffle.title, "Shuffle on");
  assert.equal(repeat.title, "Repeat off");
  assert.equal(play.title, "Play");
  const before = sent("spotify_control").length;
  shuffle.fire("click");
  repeat.fire("click");
  prev.fire("click");
  next.fire("click");
  play.fire("click");
  assert.deepEqual(sent("spotify_control").slice(before), [
    { action: "shuffle", value: 0 },
    { action: "repeat", value: 1 },
    { action: "previous", value: null },
    { action: "next", value: null },
    { action: "playPause", value: null },
  ]);
  // The page shows the clicks at once.
  assert.equal(Spotify.state.shuffle, false);
  assert.equal(Spotify.state.repeat, true);
  assert.equal(Spotify.state.playing, true);

  Spotify.state = playing({ track: track({ id: "spotify:ad:9", title: "x", artist: "", album: "" }) });
  card.sync();
  assert.ok(card.el.textContent.includes("Advertisement"));
});

test("the pill shows play/pause and next on hover, only with a track", () => {
  const task = spotifyTask();
  const pill = buildSpotifyPill(task, () => {});
  pill.el.fire("mouseenter");
  assert.ok(!pill.el.classList.contains("controls"), "nothing loaded: no controls");
  Spotify.state = playing();
  pill.sync();
  assert.ok(pill.el.classList.contains("controls"));
  const [playBtn] = pill.el.querySelector("np-pill-controls").children;
  assert.equal(playBtn.title, "Pause");
  const before = sent("spotify_control").length;
  playBtn.fire("click");
  assert.deepEqual(sent("spotify_control").slice(before), [{ action: "playPause", value: null }]);
  assert.equal(Spotify.state.playing, false);
  pill.el.fire("mouseleave");
  assert.ok(!pill.el.classList.contains("controls"));
});

// ── A new song ────────────────────────────────────────────────────────────────

const other = (over = {}) => playing({ track: track({ id: "spotify:track:xyz", title: "Da Funk", ...over }) });
/** The glance ends: the island folds on its own (`untouched`), or somebody took it over. */
const endGlance = (untouched) => {
  if (untouched) State.mode = "compact";
  island.glances.at(-1).done(untouched);
};

test("a new song is one that starts after another: not the first, a pause, a seek or an ad", () => {
  const first = playing();
  assert.ok(!isNewSong(null, first), "the first heard since Spotify started");
  assert.ok(!isNewSong(first.track.id, first), "the same one going on");
  assert.ok(!isNewSong(first.track.id, playing({ position: 90 })), "a seek");
  assert.ok(isNewSong(first.track.id, other()));
  assert.ok(!isNewSong(first.track.id, { ...other(), playing: false }), "not while paused");
  assert.ok(!isNewSong(first.track.id, other({ id: "spotify:ad:1" })), "never an ad");
  assert.ok(!isNewSong(first.track.id, { ...IDLE_SPOTIFY }));
});

test("new songs are not announced unless asked for", () => {
  assert.equal(DEFAULT_SETTINGS.announceSongs, false);
  emit("spotify", playing());
  emit("spotify", other());
  assert.equal(island.glances.length, 0);
  assert.equal(State.focusId, "integration_claude");
});

test("a new song opens the island on Spotify's card for a moment, then the front goes back", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  State.settings.announceSongs = true;
  emit("spotify", playing({ playing: false }));
  emit("spotify", playing());
  emit("spotify", playing({ position: 60 }));
  assert.equal(island.glances.length, 0, "the first song, then the same one going on");

  emit("spotify", other());
  assert.equal(island.glances.length, 1);
  assert.equal(island.glances[0].seconds, ANNOUNCE_SECONDS);
  assert.equal(State.focusId, SPOTIFY_ID, "Spotify's card in front");
  assert.ok(Spotify.announcing, "and lit");
  emit("spotify", other({ title: "Da Funk" }));
  assert.equal(island.glances.length, 1, "the answer to the card's refresh is not another song");

  // Nobody touched it: the island folds, and only then does the front go back.
  endGlance(true);
  assert.equal(Spotify.announcing, 0);
  assert.equal(State.focusId, SPOTIFY_ID, "not while the card is still folding away");
  t.mock.timers.tick(500);
  assert.equal(State.focusId, "integration_claude");
});

test("a pause between two songs still announces the second, once it plays", () => {
  State.settings.announceSongs = true;
  emit("spotify", playing());
  // Windows names the new track before it says it plays.
  emit("spotify", { ...other(), playing: false });
  assert.equal(island.glances.length, 0);
  emit("spotify", other());
  assert.equal(island.glances.length, 1);
});

test("an announcement somebody took over leaves the front where they see it", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  State.settings.announceSongs = true;
  emit("spotify", playing());
  emit("spotify", other());
  endGlance(false);              // the mouse came, a key, an alert
  assert.equal(Spotify.announcing, 0);
  t.mock.timers.tick(5_000);
  assert.equal(State.focusId, SPOTIFY_ID);
});

test("songs skipped through: one announcement carries on, and the front still goes back to the first pill", (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  State.settings.announceSongs = true;
  emit("spotify", playing());
  emit("spotify", other());
  const lit = Spotify.announcing;
  emit("spotify", playing({ track: track({ id: "spotify:track:third", title: "Around the World" }) }));
  assert.equal(island.glances.length, 2);
  assert.notEqual(Spotify.announcing, lit, "the card's light plays again");
  endGlance(true);
  // One more, while the last is being put away.
  t.mock.timers.tick(200);
  emit("spotify", other());
  assert.equal(island.glances.length, 3);
  assert.equal(State.focusId, SPOTIFY_ID);
  endGlance(true);
  t.mock.timers.tick(500);
  assert.equal(State.focusId, "integration_claude");
});

test("no announcement when the island is not free, when paused, or when Spotify quit in between", () => {
  State.settings.announceSongs = true;
  emit("spotify", playing());
  island.free = false;           // open, under the mouse, or waiting for an answer
  emit("spotify", other());
  assert.equal(State.focusId, "integration_claude");
  assert.equal(Spotify.announcing, 0);

  island.free = true;
  State.paused = true;
  emit("spotify", playing());
  assert.equal(island.glances.length, 0);

  State.paused = false;
  emit("spotify", { ...IDLE_SPOTIFY });
  emit("spotify", other());
  assert.equal(island.glances.length, 0, "the first song after Spotify came back");
});

test("the card wears its light for as long as the song is announced, and plays it again for the next", () => {
  const card = buildSpotifyCard();
  Spotify.state = playing();
  card.sync();
  assert.ok(!card.el.classList.contains("announce"));
  Spotify.announcing = 1;
  card.sync();
  assert.ok(card.el.classList.contains("announce"));
  assert.equal(card.el.style["--np-announce"], `${ANNOUNCE_SECONDS}s`);
  assert.equal(card.el.style["--np-light"], "29, 185, 84", "Spotify's green, the pill's own colour");
  // A colour picked for the pill's Mochi in Settings is the light's too.
  State.settings.pillColors = { [SPOTIFY_ID]: "#14B8A6" };
  State.loadIntegrationTasks();
  Spotify.announcing = 2;
  card.sync();
  assert.ok(card.el.classList.contains("announce"));
  assert.equal(card.el.style["--np-light"], "20, 184, 166");
  Spotify.announcing = 0;
  card.sync();
  assert.ok(!card.el.classList.contains("announce"));
});

// ── The song's own beat ───────────────────────────────────────────────────────

test("the bounce keeps any tempo it is given: still on each beat, highest between two", () => {
  const R = 10;
  for (const bpm of [87.4, 112, 142]) {
    const beat = 60 / bpm;
    for (const n of [0, 1, 7]) {
      const on = danceTransform(n * beat, 1, R, bpm);
      assert.ok(Math.abs(on.dy) < 1e-9 && Math.abs(on.sy - 0.94) < 1e-9, `${bpm}: lands on beat ${n}`);
      assert.ok(Math.abs(danceTransform((n + 0.5) * beat, 1, R, bpm).dy + 2) < 1e-9, `${bpm}: highest after beat ${n}`);
    }
  }
  // Told nothing, it is the Mac's 112.
  assert.deepEqual(danceTransform(1.3, 1, R), danceTransform(1.3, 1, R, 112));
});

test("Mochi dances to the song's beat once it has been heard, and at 112 until then", () => {
  State.settings.danceToBeat = true;
  emit("spotify", playing());
  assert.equal(DanceClock.tempo, 0, "not heard yet: the Mac's bounce");
  emit("spotify", playing({ tempo: 87.4, beatAt: 1_700_000_000_000 }));
  assert.deepEqual(DanceClock, { tempo: 87.4, beatAt: 1_700_000_000_000 });
  // After a seek the tempo holds and where the beats fall is not known yet: he keeps the tempo.
  emit("spotify", playing({ position: 90, tempo: 87.4, beatAt: 0 }));
  assert.deepEqual(DanceClock, { tempo: 87.4, beatAt: 0 });
  // Paused, the song's beat is no longer where it was.
  emit("spotify", playing({ playing: false, tempo: 87.4, beatAt: 1_700_000_000_000 }));
  assert.equal(DanceClock.tempo, 0);
  // Linux, and a song whose beat was not found: no tempo.
  emit("spotify", playing({ track: track({ id: "spotify:track:other" }) }));
  assert.equal(DanceClock.tempo, 0);
});

test("the song's beat is not danced to unless asked for, and no longer once it is not", () => {
  assert.equal(DEFAULT_SETTINGS.danceToBeat, false);
  emit("spotify", playing({ tempo: 87.4, beatAt: 1_700_000_000_000 }));
  assert.equal(DanceClock.tempo, 0);
  State.settings.danceToBeat = true;
  State.notify();
  assert.equal(DanceClock.tempo, 87.4, "asked for: at once, without waiting for Spotify to say something");
  State.settings.danceToBeat = false;
  State.notify();
  assert.equal(DanceClock.tempo, 0);
});

test("the song is listened to only when asked, and only while a Mochi is seen dancing to it", () => {
  const told = () => sent("spotify_dancing").map((args) => args.on);
  const before = told().length;
  const since = () => told().slice(before);
  // Not asked for: music plays, he dances in the compact island, and Rust is told nothing.
  emit("spotify", playing());
  State.mode = "compact";
  State.notify();
  assert.deepEqual(since(), []);
  // Asked for.
  State.settings.danceToBeat = true;
  State.notify();
  assert.deepEqual(since(), [true]);
  State.notify();
  assert.deepEqual(since(), [true], "said once");
  // The island hides and he is not on the desktop: nobody to dance for.
  State.mode = "hidden";
  State.notify();
  assert.deepEqual(since(), [true, false]);
  // He lives on the desktop, where he dances while the island is hidden.
  State.mochiOnDesktop = true;
  State.notify();
  assert.deepEqual(since(), [true, false, true]);
  // The music stops.
  emit("spotify", playing({ playing: false }));
  assert.deepEqual(since(), [true, false, true, false]);
  emit("spotify", playing());
  assert.deepEqual(since(), [true, false, true, false, true]);
  // The app is paused.
  State.paused = true;
  State.notify();
  assert.deepEqual(since(), [true, false, true, false, true, false]);
  State.paused = false;
  // Expanded on another pill's card, with Mochi back in the island, he does not dance.
  State.mochiOnDesktop = false;
  State.mode = "expanded";
  State.focusId = "integration_claude";
  State.notify();
  assert.deepEqual(since(), [true, false, true, false, true, false]);
  State.setFocus(SPOTIFY_ID);
  assert.deepEqual(since(), [true, false, true, false, true, false, true]);
  // And the choice withdrawn is heard at once.
  State.settings.danceToBeat = false;
  State.notify();
  assert.deepEqual(since(), [true, false, true, false, true, false, true, false]);
});
