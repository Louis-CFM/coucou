// Deezer's reports → the page (src-tauri/src/deezer.rs): the pill wears the
// track's title, music starting shows the compact island without a sound, and
// the card reads the player again whenever it comes on screen.

import { onEvent } from "../core/bridge";
import { DeezerBridge } from "../core/deezer-bridge";
import { pillDefinition } from "../core/pills";
import { DEEZER_ID, Deezer, type DeezerState } from "../core/deezer";
import { State } from "../core/state";

export interface DeezerHost {
  /** Compact island from hidden, no peek sound. */
  revealSilently(): void;
}

/** Deezer plays on a declared pill. */
export function deezerPlaying(): boolean {
  return State.deezerPlaying;
}

export function registerDeezerHandlers(island: DeezerHost) {
  void onEvent<DeezerState>("deezer", (s) => applyDeezer(island, s));
  void onEvent<{ artUrl: string; dataUrl: string }>("deezer-artwork", (art) => {
    Deezer.artwork = art;
    State.notify();
  });
  State.subscribe(() => {
    syncPillName();
    refreshWhenShown();
  });
}

export function applyDeezer(island: DeezerHost, next: DeezerState) {
  const wasPlaying = deezerPlaying();
  Deezer.state = next;
  syncPillName();
  if (!wasPlaying && deezerPlaying() && !State.paused && State.mode === "hidden") {
    island.revealSilently();
  }
  State.notify();
}

/** The track's title, else the pill's name. */
export function syncPillName() {
  const task = State.tasks.find((x) => x.id === DEEZER_ID);
  if (!task) return;
  const name = Deezer.state.track?.title || (pillDefinition(DEEZER_ID)?.name ?? "Deezer");
  if (task.name !== name) task.name = name;
}

let shown = false;

function refreshWhenShown() {
  const now = State.mode === "expanded" && State.view === "overview" && State.focusTask?.id === DEEZER_ID;
  if (now && !shown) void DeezerBridge.refresh();
  shown = now;
}
