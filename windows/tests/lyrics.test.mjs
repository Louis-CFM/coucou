// Synced lyrics on the music cards: the LRC reading and timing in
// src/core/lyrics.ts, the lookups in src/island/lyrics.ts and the line on the
// card in src/views/spotify.ts. The LRCLIB side is tested in
// src-tauri/src/lyrics.rs.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { internals, sent } from "./tauri.mjs";
import { installFakeDom } from "./fakedom.mjs";
import { Lyrics, lineAt, lyricsQuery, parseLrc, rememberLyrics } from "../src/core/lyrics.ts";
import { IDLE_NOW_PLAYING, IDLE_SPOTIFY, NOWPLAYING_ID, NowPlaying, SPOTIFY_ID, Spotify } from "../src/core/spotify.ts";
import { fetchLyrics } from "../src/island/lyrics.ts";
import { buildSpotifyCard } from "../src/views/spotify.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

installFakeDom();

const LRC = `[ar:Coldplay]
[00:12.50] First line
[00:15.00]Second line
[00:20.00] ♪
[00:25:30] Third line
[00:40.00][01:30.00] Chorus
not a timed line`;

// The lyrics Rust would answer, by track title.
const answers = new Map();
const plain = internals.invoke;
internals.invoke = async (cmd, args) => {
  const result = await plain(cmd, args);
  if (cmd === "lyrics_get") return answers.get(args.title) ?? null;
  return result;
};

const track = (over = {}) => ({
  id: "spotify:track:1", title: "Get Lucky", artist: "Daft Punk", album: "Random Access Memories",
  duration: 248, artUrl: null, ...over,
});

beforeEach(() => {
  State.os = "windows";
  State.settings = { ...DEFAULT_SETTINGS, activeIntegrations: [SPOTIFY_ID, NOWPLAYING_ID], lyricsEnabled: true };
  State.loadIntegrationTasks();
  Spotify.state = { ...IDLE_SPOTIFY };
  NowPlaying.state = { ...IDLE_NOW_PLAYING };
  Lyrics.byTrack.clear();
  Lyrics.asked.clear();
  answers.clear();
});

const flush = () => new Promise((r) => setTimeout(r, 0));

// ── Reading and timing ────────────────────────────────────────────────────────

test("LRC: timed lines sorted, metadata and untimed lines skipped, a chorus at each of its times", () => {
  const lines = parseLrc(LRC);
  assert.deepEqual(lines.map((l) => l.time), [12.5, 15, 20, 25.3, 40, 90]);
  assert.equal(parseLrc(""), null);
  assert.equal(parseLrc("plain lyrics\nno times"), null);
  assert.equal(parseLrc("[00:75.00] seconds out of range"), null);
  assert.equal(parseLrc("[00:01.00] A\r\n[00:02.00] B").length, 2);
});

test("the line being sung, and none before the first or during a break", () => {
  const lines = parseLrc(LRC);
  assert.equal(lineAt(lines, 0), null);
  assert.equal(lineAt(lines, 12.5), "First line");
  assert.equal(lineAt(lines, 14.9), "First line");
  assert.equal(lineAt(lines, 15), "Second line");
  assert.equal(lineAt(lines, 21), null, "a lone ♪ is a break");
  assert.equal(lineAt(lines, 26), "Third line");
  assert.equal(lineAt(lines, 95), "Chorus");
});

test("a song is looked up by its tags; a video by the artist and song in its title", () => {
  assert.deepEqual(lyricsQuery(track(), true), { title: "Get Lucky", artist: "Daft Punk", album: "Random Access Memories", duration: 248 });
  const video = track({ id: "media:track:2", title: "Coldplay - Hymn For The Weekend (Lyrics)", artist: "DopeMusic", album: "" });
  assert.deepEqual(lyricsQuery(video, false), { title: "Hymn For The Weekend", artist: "Coldplay", album: "", duration: 248 });
  // No dash: the title without its tags, by the channel.
  assert.equal(lyricsQuery(track({ id: "media:track:3", title: "Yellow [Official Video]", artist: "Coldplay" }), false).title, "Yellow");
  assert.equal(lyricsQuery(track({ id: "spotify:ad:1", title: "Ad", artist: "" }), true), null);
  assert.equal(lyricsQuery(track({ title: "Untitled", artist: "" }), true), null);
});

test("the store keeps the newest 30 tracks", () => {
  for (let i = 0; i < 35; i++) rememberLyrics(`t${i}`, null);
  assert.equal(Lyrics.byTrack.size, 30);
  assert.ok(!Lyrics.byTrack.has("t0"));
  assert.ok(Lyrics.byTrack.has("t34"));
});

// ── Lookups ───────────────────────────────────────────────────────────────────

test("each playing track is asked about once, only with lyrics on and its pill declared", async () => {
  answers.set("Get Lucky", LRC);
  Spotify.state = { ...IDLE_SPOTIFY, running: true, track: track() };
  const before = sent("lyrics_get").length;
  fetchLyrics();
  fetchLyrics();
  assert.equal(sent("lyrics_get").length, before + 1, "once per track");
  assert.deepEqual(sent("lyrics_get").at(-1), {
    key: "spotify:track:1", title: "Get Lucky", artist: "Daft Punk", album: "Random Access Memories", duration: 248,
  });
  await flush();
  assert.equal(lineAt(Lyrics.byTrack.get("spotify:track:1"), 13), "First line");

  // Off: nothing is asked.
  State.settings.lyricsEnabled = false;
  Spotify.state = { ...IDLE_SPOTIFY, running: true, track: track({ id: "spotify:track:9", title: "Other" }) };
  fetchLyrics();
  assert.equal(sent("lyrics_get").length, before + 1);

  // On, but the pill is not declared: nothing either.
  State.settings = { ...State.settings, lyricsEnabled: true, activeIntegrations: [NOWPLAYING_ID] };
  fetchLyrics();
  assert.equal(sent("lyrics_get").length, before + 1);
});

test("Now Playing's video is looked up by the song in its title", async () => {
  NowPlaying.state = {
    ...IDLE_NOW_PLAYING, running: true,
    track: track({ id: "media:track:7", title: "Coldplay - Hymn For The Weekend (Lyrics)", artist: "DopeMusic", album: "" }),
  };
  fetchLyrics();
  const asked = sent("lyrics_get").at(-1);
  assert.equal(asked.key, "media:track:7");
  assert.equal(asked.title, "Hymn For The Weekend");
  assert.equal(asked.artist, "Coldplay");
});

// ── The card ──────────────────────────────────────────────────────────────────

test("the card shows the line being sung in place of artist · album, and gives them back between lines", () => {
  rememberLyrics("spotify:track:1", parseLrc(LRC));
  const card = buildSpotifyCard();
  const now = Date.now();
  Spotify.state = { ...IDLE_SPOTIFY, running: true, installed: true, track: track(), playing: false, position: 13, positionAt: now };
  card.sync();
  const sub = card.el.querySelector("np-sub");
  assert.equal(sub.textContent, "First line");

  Spotify.state = { ...Spotify.state, position: 21 };
  card.sync();
  assert.equal(sub.textContent, "Daft Punk · Random Access Memories", "a break: artist · album again");

  // Lyrics off: always artist · album.
  State.settings.lyricsEnabled = false;
  Spotify.state = { ...Spotify.state, position: 13 };
  card.sync();
  assert.equal(sub.textContent, "Daft Punk · Random Access Memories");
});
