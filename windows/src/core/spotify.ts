// The Spotify pill on the page: what src-tauri/src/spotify.rs reports (Linux,
// through MPRIS), and the pure rules the views and Mochi follow — ports of
// SpotifyController.swift, NowPlayingViews.swift and the Mac's dance rules
// (BotCanvasView, DesktopMochi.swift).
//
// On Windows the same state comes from the system media controls
// (media_win.rs) for three pills: Apple Music, Spotify and Now Playing (any
// app). `source` says which pill the player belongs to.

import type { BotStateName, IslandMode, IslandViewName } from "./layout";

export const SPOTIFY_ID = "integration_spotify";
export const APPLE_MUSIC_ID = "integration_music";
export const NOW_PLAYING_ID = "integration_media";
/** The pills the music card and pill stand for. */
export const MUSIC_IDS: readonly string[] = [SPOTIFY_ID, APPLE_MUSIC_ID, NOW_PLAYING_ID];

export function isMusicPill(id: string | null | undefined): boolean {
  return id != null && MUSIC_IDS.includes(id);
}
/** SpotifyController.green. */
export const SPOTIFY_GREEN = "#1DB954";

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
  /** The pill this player shows on (one of MUSIC_IDS). */
  source: string;
  /** The player's name on Windows ("Apple Music", "Edge"…), "" on Linux. */
  app: string;
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
}

export const IDLE_SPOTIFY: SpotifyState = {
  source: SPOTIFY_ID, app: "", running: false, installed: false, track: null, playing: false,
  position: 0, positionAt: 0, shuffle: false, repeat: false, volume: 50,
};

/** The page's copy of the player, and the cover of the track that has one. */
export const Spotify = {
  state: { ...IDLE_SPOTIFY } as SpotifyState,
  artwork: null as { artUrl: string; dataUrl: string } | null,
};

/** The cover to show for the current track, if it has arrived. */
export function currentArtwork(s: SpotifyState = Spotify.state): string | null {
  const art = Spotify.artwork;
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

/** Music is playing on a declared music pill. */
export function musicPlaying(s: SpotifyState, activeIntegrations: readonly string[]): boolean {
  return s.playing && s.track != null && activeIntegrations.includes(s.source ?? SPOTIFY_ID);
}

/** The colour the card and its controls wear: the playing pill's. */
export const MUSIC_COLORS: Record<string, string> = {
  [SPOTIFY_ID]: SPOTIFY_GREEN, [APPLE_MUSIC_ID]: "#FA2D48", [NOW_PLAYING_ID]: "#A78BFA",
};

export function musicAccent(s: SpotifyState = Spotify.state): string {
  return MUSIC_COLORS[s.source] ?? SPOTIFY_GREEN;
}

/** "Spotify", "Apple Music", or the app that plays ("Edge"). */
export function playerName(s: SpotifyState = Spotify.state): string {
  if (s.app) return s.app;
  return s.source === APPLE_MUSIC_ID ? "Apple Music" : s.source === NOW_PLAYING_ID ? "Now Playing" : "Spotify";
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
  return o.mode === "expanded" && o.view === "overview" && isMusicPill(o.focusId);
}

/** Mochi on the desktop: the compact island's rules (DesktopMochi.swift). */
export function desktopDances(music: boolean, state: BotStateName): boolean {
  return music && DANCE_STATES.has(state);
}
