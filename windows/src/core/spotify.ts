// The Spotify pill on the page: what src-tauri/src/spotify.rs reports (MPRIS
// on Linux, the system media controls on Windows), and the pure rules the views and Mochi follow — ports of
// SpotifyController.swift, NowPlayingViews.swift and the Mac's dance rules
// (BotCanvasView, DesktopMochi.swift).

import type { BotStateName, IslandMode, IslandViewName } from "./layout";

export const SPOTIFY_ID = "integration_spotify";
/** SpotifyController.green. */
export const SPOTIFY_GREEN = "#1DB954";
/** Now Playing (Windows): whatever app plays, through the same system media controls. */
export const NOWPLAYING_ID = "integration_nowplaying";
export const NOWPLAYING_COLOR = "#22D3EE";

export interface SpotifyTrack {
  /** spotify:track:…, spotify:episode:…, spotify:ad:… */
  id: string;
  title: string;
  artist: string;
  album: string;
  /** Seconds. */
  duration: number;
  artUrl: string | null;
}

export interface SpotifyState {
  /** Spotify is running. */
  running: boolean;
  /** There is a Spotify to launch. */
  installed: boolean;
  track: SpotifyTrack | null;
  playing: boolean;
  /** Seconds at `positionAt` (Unix ms); while playing it runs on from there. */
  position: number;
  positionAt: number;
  shuffle: boolean;
  repeat: boolean;
  /** 0…100. */
  volume: number;
  /** Now Playing: the app that plays ("Chrome", "Apple Music"). */
  app?: string;
  /** What the player takes (Now Playing says per app); missing means yes, as on Spotify. */
  canSeek?: boolean;
  canSkip?: boolean;
  canShuffle?: boolean;
  canRepeat?: boolean;
  hasVolume?: boolean;
}

export const IDLE_SPOTIFY: SpotifyState = {
  running: false, installed: false, track: null, playing: false,
  position: 0, positionAt: 0, shuffle: false, repeat: false, volume: 50,
};

/** Now Playing before any app plays: nothing to install, no volume of its own. */
export const IDLE_NOW_PLAYING: SpotifyState = { ...IDLE_SPOTIFY, installed: true, hasVolume: false };

/** A player pill: the page's copy of its player, and the cover of the track that has one. */
export interface Player {
  readonly pillId: string;
  readonly color: string;
  /** "spotify": the Spotify pill. "any": Now Playing, whatever app plays. */
  readonly kind: "spotify" | "any";
  state: SpotifyState;
  artwork: { artUrl: string; dataUrl: string } | null;
}

export const Spotify: Player = {
  pillId: SPOTIFY_ID, color: SPOTIFY_GREEN, kind: "spotify", state: { ...IDLE_SPOTIFY }, artwork: null,
};

export const NowPlaying: Player = {
  pillId: NOWPLAYING_ID, color: NOWPLAYING_COLOR, kind: "any", state: { ...IDLE_NOW_PLAYING }, artwork: null,
};

export const PLAYERS: readonly Player[] = [Spotify, NowPlaying];

/** Whether the player takes a control; Spotify takes them all. */
export function takes(s: SpotifyState, what: "canSeek" | "canSkip" | "canShuffle" | "canRepeat" | "hasVolume"): boolean {
  return s[what] !== false;
}

/** The cover to show for the current track, if it has arrived. */
export function currentArtwork(s: SpotifyState = Spotify.state, player: Player = Spotify): string | null {
  const art = player.artwork;
  return art && s.track?.artUrl && art.artUrl === s.track.artUrl ? art.dataUrl : null;
}

/** SpotifyController.position(at:): extrapolated while playing, capped at the end. */
export function spotifyPosition(s: SpotifyState, nowMs: number): number {
  const elapsed = s.playing ? Math.max(0, (nowMs - s.positionAt) / 1000) : 0;
  const p = s.position + elapsed;
  const d = s.track?.duration ?? 0;
  return d > 0 ? Math.min(p, d) : p;
}

/**
 * The clock frozen or restarted where it is now — what a play/pause click
 * does at once, before Spotify confirms it (SpotifyController.setPlaying).
 */
export function withPlaying(s: SpotifyState, playing: boolean, nowMs: number): SpotifyState {
  if (s.playing === playing) return s;
  return { ...s, position: spotifyPosition(s, nowMs), positionAt: nowMs, playing };
}

export function isAd(track: SpotifyTrack | null | undefined): boolean {
  return track?.id.startsWith("spotify:ad:") ?? false;
}

/** NowPlayingProgress.format: m:ss, or h:mm:ss past an hour. */
export function formatTime(seconds: number): string {
  const s = Math.max(0, Math.floor(Number.isFinite(seconds) ? seconds : 0));
  const pad = (n: number) => String(n).padStart(2, "0");
  return s >= 3600
    ? `${Math.floor(s / 3600)}:${pad(Math.floor((s % 3600) / 60))}:${pad(s % 60)}`
    : `${Math.floor(s / 60)}:${pad(s % 60)}`;
}

/** NowPlayingVolume.icon: 0 = muted, then one, two or three waves. */
export function volumeLevel(volume: number): 0 | 1 | 2 | 3 {
  if (volume <= 0) return 0;
  if (volume < 34) return 1;
  if (volume < 67) return 2;
  return 3;
}

/** Music is playing on a declared player pill (Spotify's unless said). */
export function musicPlaying(s: SpotifyState, activeIntegrations: readonly string[], pillId: string = SPOTIFY_ID): boolean {
  return s.playing && s.track != null && activeIntegrations.includes(pillId);
}

/** The states Mochi dances in; the rest (an alert, an error, sleep) win. */
const DANCE_STATES: ReadonlySet<BotStateName> = new Set(["idle", "working", "thinking", "searching", "finished"]);

/**
 * The island's Mochi (BotCanvasView, macOS): in the compact island whenever
 * music plays, expanded only on the overview with the music pill in front.
 */
export function islandDances(o: {
  music: boolean;
  state: BotStateName;
  mode: IslandMode;
  view: IslandViewName;
  focusId: string | null | undefined;
}): boolean {
  if (!o.music || !DANCE_STATES.has(o.state)) return false;
  if (o.mode === "compact") return true;
  return o.mode === "expanded" && o.view === "overview" && (o.focusId === SPOTIFY_ID || o.focusId === NOWPLAYING_ID);
}

/** Mochi on the desktop: the compact island's rules (DesktopMochi.swift). */
export function desktopDances(music: boolean, state: BotStateName): boolean {
  return music && DANCE_STATES.has(state);
}
