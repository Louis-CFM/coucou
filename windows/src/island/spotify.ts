// Spotify's reports → the page (src-tauri/src/spotify.rs). The parts of
// SpotifyController.swift that touch the app: the pill wears the track's
// title, music starting shows the compact island without a sound, and the
// card reads the player again whenever it comes on screen (seeks made in
// Spotify's own window are never signalled). Now Playing (any app's media
// session, Windows) gets the same, on its own events and pill.

import { Bridge, onEvent } from "../core/bridge";
import { pillDefinition } from "../core/pills";
import { NowPlaying, PLAYERS, Spotify, isAd, type Player, type SpotifyState } from "../core/spotify";
import { State } from "../core/state";
import { t } from "../i18n/i18n";

export interface SpotifyHost {
  /** Compact island from hidden, no peek sound. */
  revealSilently(): void;
}

/** Each player's events: its state, and a track's cover. */
const EVENTS: ReadonlyArray<[Player, string, string]> = [
  [Spotify, "spotify", "spotify-artwork"],
  [NowPlaying, "nowplaying", "nowplaying-artwork"],
];

export function registerSpotifyHandlers(island: SpotifyHost) {
  for (const [player, state, artwork] of EVENTS) {
    void onEvent<SpotifyState>(state, (s) => applySpotify(island, s, player));
    void onEvent<{ artUrl: string; dataUrl: string }>(artwork, (art) => {
      player.artwork = art;
      State.notify();
    });
  }
  State.subscribe(() => {
    for (const player of PLAYERS) {
      syncPillName(player);
      refreshWhenShown(player);
    }
  });
}

/** A report from Rust (or the answer to a refresh). */
export function applySpotify(island: SpotifyHost, next: SpotifyState, player: Player = Spotify) {
  const wasPlaying = State.spotifyPlaying;
  player.state = next;
  syncPillName(player);
  // Only on not playing → playing (SpotifyController.setPlaying).
  if (!wasPlaying && State.spotifyPlaying && !State.paused && State.mode === "hidden") {
    island.revealSilently();
  }
  State.notify();
}

/** SpotifyController.syncTaskName: the track's title, else the pill's name. */
export function syncPillName(player: Player = Spotify) {
  const task = State.tasks.find((x) => x.id === player.pillId);
  if (!task) return;
  const track = player.state.track;
  const title = isAd(track) ? t("Advertisement") : (track?.title ?? "");
  const name = title || (pillDefinition(player.pillId)?.name ?? "Spotify");
  if (task.name !== name) task.name = name;
}

const shown = new Map<Player, boolean>();

function refreshWhenShown(player: Player) {
  const now = State.mode === "expanded" && State.view === "overview" && State.focusTask?.id === player.pillId;
  if (now && !shown.get(player)) void (player.kind === "spotify" ? Bridge.spotifyRefresh() : Bridge.nowPlayingRefresh());
  shown.set(player, now);
}
