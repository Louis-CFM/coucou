// Spotify's reports → the page (src-tauri/src/spotify.rs). The parts of
// SpotifyController.swift that touch the app: the pill wears the track's
// title, music starting shows the compact island without a sound, and the
// card reads the player again whenever it comes on screen (seeks made in
// Spotify's own window are never signalled). One thing the Mac does not do:
// a new song can open the island on its card for a moment (announceSong).

import { Bridge, onEvent } from "../core/bridge";
import { pillDefinition } from "../core/pills";
import { ANNOUNCE_SECONDS, SPOTIFY_ID, Spotify, isAd, isNewSong, type SpotifyState } from "../core/spotify";
import { State } from "../core/state";
import { t } from "../i18n/i18n";

export interface SpotifyHost {
  /** Compact island from hidden, no peek sound. */
  revealSilently(): void;
  /**
   * Opens on the overview for a moment, without a sound, and folds back; false
   * when the island is not free to. `done(untouched)` says how it ended.
   */
  glance(seconds: number, done: (untouched: boolean) => void): boolean;
}

export function registerSpotifyHandlers(island: SpotifyHost) {
  void onEvent<SpotifyState>("spotify", (s) => applySpotify(island, s));
  void onEvent<{ artUrl: string; dataUrl: string }>("spotify-artwork", (art) => {
    Spotify.artwork = art;
    State.notify();
  });
  State.subscribe(() => {
    syncPillName();
    refreshWhenShown();
  });
}

/** A report from Rust (or the answer to a refresh). */
export function applySpotify(island: SpotifyHost, next: SpotifyState) {
  const wasPlaying = State.spotifyPlaying;
  Spotify.state = next;
  syncPillName();
  // Only on not playing → playing (SpotifyController.setPlaying).
  if (!wasPlaying && State.spotifyPlaying && !State.paused && State.mode === "hidden") {
    island.revealSilently();
  }
  const fresh = isNewSong(Spotify.heard, next);
  if (!next.running) Spotify.heard = null;
  else if (next.playing && next.track) Spotify.heard = next.track.id;
  if (fresh) announceSong(island);
  State.notify();
}

/** How long the island takes to fold: the front is handed back once it has. */
const FOLD_MS = 450;
/** The pill that had the front before a song took it. */
let frontBefore: string | null = null;
let handBack: number | null = null;
let songs = 0;

/**
 * A new song (Settings → Integrations → Spotify, off by default): the island
 * opens on Spotify's card for a moment and folds back, the front going back to
 * the pill that had it. The card wears a light meanwhile, in Mochi's colour,
 * so it reads as news and not as an island that opened by accident. No sound:
 * music is playing.
 */
function announceSong(island: SpotifyHost) {
  if (!State.settings.announceSongs || State.paused || !State.spotifyPlaying) return;
  if (!island.glance(ANNOUNCE_SECONDS, songAnnounced)) return;
  // The song before was still being put away: this one takes over from it.
  if (handBack != null) window.clearTimeout(handBack);
  handBack = null;
  if (State.focusId !== SPOTIFY_ID) frontBefore = State.focusId;
  Spotify.announcing = ++songs;
  State.setFocus(SPOTIFY_ID);
}

function songAnnounced(untouched: boolean) {
  Spotify.announcing = 0;
  if (!untouched) {
    // Somebody took it from there (the mouse, a key, an alert): it is theirs.
    frontBefore = null;
    State.notify();
    return;
  }
  // The card folds away with the island; only then does the front go back.
  handBack = window.setTimeout(() => {
    handBack = null;
    const previous = frontBefore;
    frontBefore = null;
    const stillOurs = State.focusId === SPOTIFY_ID && State.mode !== "expanded";
    if (previous && stillOurs && State.tasks.some((t) => t.id === previous)) {
      State.focusId = previous;
      State.notify();
    }
  }, FOLD_MS);
}

/** SpotifyController.syncTaskName: the track's title, else the pill's name. */
export function syncPillName() {
  const task = State.tasks.find((x) => x.id === SPOTIFY_ID);
  if (!task) return;
  const track = Spotify.state.track;
  const title = isAd(track) ? t("Advertisement") : (track?.title ?? "");
  const name = title || (pillDefinition(SPOTIFY_ID)?.name ?? "Spotify");
  if (task.name !== name) task.name = name;
}

let shown = false;

function refreshWhenShown() {
  const now = State.mode === "expanded" && State.view === "overview" && State.focusTask?.id === SPOTIFY_ID;
  if (now && !shown) void Bridge.spotifyRefresh();
  shown = now;
}
