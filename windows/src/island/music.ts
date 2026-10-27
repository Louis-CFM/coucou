// Apple Music's reports → the page (src-tauri/src/apple_music.rs).
// Syncs pill name, updates player state, reveals the compact island on playback start.

import { Bridge, onEvent } from "../core/bridge";
import { pillDefinition } from "../core/pills";
import { MUSIC_ID, Music, type MusicState } from "../core/music";
import { State } from "../core/state";

export interface MusicHost {
  /** Compact island from hidden, no peek sound. */
  revealSilently(): void;
}

export function registerMusicHandlers(island: MusicHost) {
  void onEvent<MusicState>("music", (s) => applyMusic(island, s));
  void onEvent<{ artUrl: string; dataUrl: string }>("music-artwork", (art) => {
    Music.artwork = art;
    State.notify();
  });
  State.subscribe(() => {
    syncPillName();
    refreshWhenShown();
  });
}

/** A report from Rust (or the answer to a refresh). */
export function applyMusic(island: MusicHost, next: MusicState) {
  const wasPlaying = State.appleMusicPlaying;
  Music.state = next;
  syncPillName();
  if (!wasPlaying && State.appleMusicPlaying && !State.paused && State.mode === "hidden") {
    island.revealSilently();
  }
  State.notify();
}

/** syncTaskName: the track's title, else the pill's name. */
export function syncPillName() {
  const task = State.tasks.find((x) => x.id === MUSIC_ID);
  if (!task) return;
  const track = Music.state.track;
  const title = track?.title ?? "";
  const name = title || (pillDefinition(MUSIC_ID)?.name ?? "Apple Music");
  if (task.name !== name) task.name = name;
}

let shown = false;

function refreshWhenShown() {
  const now = State.mode === "expanded" && State.view === "overview" && State.focusTask?.id === MUSIC_ID;
  if (now && !shown) void Bridge.musicRefresh();
  shown = now;
}
