// Yandex Music's reports → the page (src-tauri/src/yandex_music.rs). The parts
// of YandexMusicController.swift that touch the app, as island/spotify.ts does
// for Spotify: the pill wears the track's title, music starting shows the
// compact island without a sound, and the card reads the player again whenever
// it comes on screen.

import { Bridge, onEvent } from "../core/bridge";
import { pillDefinition } from "../core/pills";
import { YANDEX_MUSIC_ID, YandexMusic, type YandexMusicState } from "../core/yandex-music";
import { State } from "../core/state";
import { N_ } from "../i18n/i18n";

export interface YandexMusicHost {
  /** Compact island from hidden, no peek sound. */
  revealSilently(): void;
}

export function registerYandexMusicHandlers(island: YandexMusicHost) {
  void onEvent<YandexMusicState>("yandex-music", (s) => applyYandexMusic(island, s));
  void onEvent<{ artUrl: string; dataUrl: string }>("yandex-music-artwork", (art) => {
    YandexMusic.artwork = art;
    State.notify();
  });
  State.subscribe(() => {
    syncPillName();
    refreshWhenShown();
  });
}

/** A report from Rust (or the answer to a refresh). */
export function applyYandexMusic(island: YandexMusicHost, next: YandexMusicState) {
  const wasPlaying = State.yandexMusicPlaying;
  YandexMusic.state = next;
  syncPillName();
  // Only on not playing → playing (YandexMusicController.setPlaying).
  if (!wasPlaying && State.yandexMusicPlaying && !State.paused && State.mode === "hidden") {
    island.revealSilently();
  }
  State.notify();
}

/** YandexMusicController.syncTaskName: the track's title, else the pill's name. */
export function syncPillName() {
  const task = State.tasks.find((x) => x.id === YANDEX_MUSIC_ID);
  if (!task) return;
  const name = YandexMusic.state.track?.title || (pillDefinition(YANDEX_MUSIC_ID)?.name ?? N_("Yandex Music"));
  if (task.name !== name) task.name = name;
}

let shown = false;

function refreshWhenShown() {
  const now = State.mode === "expanded" && State.view === "overview" && State.focusTask?.id === YANDEX_MUSIC_ID;
  if (now && !shown) void Bridge.yandexMusicRefresh();
  shown = now;
}
