// Spotify's reports → the page (src-tauri/src/spotify.rs, Linux). The parts of
// SpotifyController.swift that touch the app: the pill wears the track's
// title, music starting shows the compact island without a sound, and the
// card reads the player again whenever it comes on screen (seeks made in
// Spotify's own window are never signalled).

import { Bridge, onEvent } from "../core/bridge";
import { pillDefinition } from "../core/pills";
import { Spotify, YouTubeMusic, isAd, type MusicPlayer, type SpotifyState } from "../core/spotify";
import { State } from "../core/state";
import { t } from "../i18n/i18n";

export interface SpotifyHost {
  /** Compact island from hidden, no peek sound. */
  revealSilently(): void;
}

export function registerSpotifyHandlers(island: SpotifyHost) {
  void onEvent<SpotifyState>("spotify", (s) => applySpotify(island, s));
  void onEvent<{ artUrl: string; dataUrl: string }>("spotify-artwork", (art) => {
    Spotify.artwork = art;
    State.notify();
  });
  // YouTube Music in a browser (src-tauri/src/youtube_music.rs): the same, on its own pill.
  void onEvent<SpotifyState>("youtube-music", (s) => applyYouTubeMusic(island, s));
  void onEvent<{ artUrl: string; dataUrl: string }>("youtube-music-artwork", (art) => {
    YouTubeMusic.artwork = art;
    State.notify();
  });
  State.subscribe(() => {
    syncPillName();
    refreshWhenShown();
  });
}

/** A report from Rust (or the answer to a refresh). */
export function applySpotify(island: SpotifyHost, next: SpotifyState) {
  apply(island, Spotify, next);
}

export function applyYouTubeMusic(island: SpotifyHost, next: SpotifyState) {
  apply(island, YouTubeMusic, next);
}

function apply(island: SpotifyHost, player: MusicPlayer, next: SpotifyState) {
  const wasPlaying = State.musicPlaying;
  player.state = next;
  syncPillName();
  // Only on not playing → playing (SpotifyController.setPlaying).
  if (!wasPlaying && State.musicPlaying && !State.paused && State.mode === "hidden") {
    island.revealSilently();
  }
  State.notify();
}

/** SpotifyController.syncTaskName: the track's title, else the pill's name. */
export function syncPillName() {
  for (const player of [Spotify, YouTubeMusic]) {
    const task = State.tasks.find((x) => x.id === player.id);
    if (!task) continue;
    const track = player.state.track;
    const title = isAd(track) ? t("Advertisement") : (track?.title ?? "");
    const name = title || (pillDefinition(player.id)?.name ?? player.name);
    if (task.name !== name) task.name = name;
  }
}

let shown: string | null = null;

function refreshWhenShown() {
  const id = State.focusTask?.id;
  const now = State.mode === "expanded" && State.view === "overview" && (id === Spotify.id || id === YouTubeMusic.id)
    ? id : null;
  if (now && now !== shown) void (now === Spotify.id ? Bridge.spotifyRefresh() : Bridge.youtubeMusicRefresh());
  shown = now;
}
