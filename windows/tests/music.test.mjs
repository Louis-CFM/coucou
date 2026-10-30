import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { calls, sent, emit } from "./tauri.mjs";
import { appleMusicPlayer, MUSIC_ID, Music } from "../src/core/apple-music.ts";
import { playerArtwork } from "../src/core/media.ts";
import { IDLE_MEDIA, islandDances } from "../src/core/media-state.ts";
import { Spotify } from "../src/core/spotify.ts";
import { State, DEFAULT_SETTINGS } from "../src/core/state.ts";
import { buildAppleMusicCard, buildAppleMusicPill } from "../src/views/apple-music.ts";
import { registerMusicHandlers } from "../src/island/music.ts";

installFakeDom();
function point(element, type, clientX) {
  for (const listener of element.listeners.get(type) ?? []) {
    listener({ type, button: 0, pointerId: 1, clientX, stopPropagation() {} });
  }
}
const track = { id: "apple-music:track:1", title: "Song", artist: "Artist", album: "Album", duration: 180, artUrl: "apple-art" };
beforeEach(() => {
  calls.length = 0;
  Music.state = { ...IDLE_MEDIA, running: true, installed: true, track, playing: true };
  Music.artwork = null;
  Spotify.state = { ...IDLE_MEDIA };
  Spotify.artwork = null;
  State.os = "windows";
  State.settings = { ...DEFAULT_SETTINGS, activeIntegrations: [MUSIC_ID] };
  State.tasks = [];
  State.mode = "compact";
});

test("Apple Music controls and artwork never target Spotify", () => {
  const card = buildAppleMusicCard();
  card.sync();
  assert.equal(card.el.querySelector(".np-title").textContent, "Song");
  card.el.querySelector(".np-play").fire("click");
  assert.deepEqual(sent("apple_music_control"), [{ action: "playPause", value: null }]);
  assert.deepEqual(sent("spotify_control"), []);
  assert.equal(Spotify.state.playing, false);
  Spotify.artwork = { artUrl: "apple-art", dataUrl: "wrong-player" };
  assert.equal(playerArtwork(appleMusicPlayer), null);
  Music.artwork = { artUrl: "apple-art", dataUrl: "data:image/png;base64,a" };
  assert.equal(playerArtwork(appleMusicPlayer), "data:image/png;base64,a");
});

test("Apple Music events name only their pill and drive the shared dance", async () => {
  const task = { id: MUSIC_ID, name: "Apple Music", color: "#FA2D48", state: "idle", steps: [] };
  State.tasks = [task];
  let reveals = 0;
  Music.state = { ...IDLE_MEDIA };
  State.mode = "hidden";
  registerMusicHandlers({ revealSilently() { reveals++; } });
  await new Promise(resolve => setTimeout(resolve, 0));
  emit("apple-music", { ...IDLE_MEDIA, running: true, installed: true, playing: true, track });
  assert.equal(task.name, "Song");
  assert.equal(reveals, 1);
  assert.equal(State.musicPlaying, true);
  assert.equal(State.spotifyPlaying, false);
  assert.equal(islandDances({ music: true, state: "idle", mode: "expanded", view: "overview", focusId: MUSIC_ID }), true);
  const pill = buildAppleMusicPill(task, () => {});
  pill.el.find(".np-pill-btn")[1].fire("click");
  assert.deepEqual(sent("apple_music_control").at(-1), { action: "next", value: null });
});

test("an unsupported seek stays read-only and does not change the playback position", () => {
  Music.state = { ...Music.state, canSeek: false, playing: false, position: 12, positionAt: Date.now() };
  const card = buildAppleMusicCard();
  card.sync();
  const progress = card.el.querySelector(".np-progress").querySelector(".np-bar");
  point(progress, "pointerdown", 1);
  point(progress, "pointerup", 1);
  assert.deepEqual(sent("apple_music_control"), []);
  assert.equal(Music.state.position, 12);
  assert.equal(progress.getAttribute("aria-disabled"), "true");
});

test("seeking becomes available when the selected player advertises it", () => {
  Music.state = { ...Music.state, canSeek: true, playing: false };
  const card = buildAppleMusicCard();
  card.sync();
  const progress = card.el.querySelector(".np-progress").querySelector(".np-bar");
  point(progress, "pointerdown", 0.5);
  point(progress, "pointerup", 0.5);
  assert.deepEqual(sent("apple_music_control"), [{ action: "seek", value: 90 }]);
  assert.deepEqual(sent("spotify_control"), []);
  assert.equal(progress.getAttribute("aria-disabled"), "false");
});
