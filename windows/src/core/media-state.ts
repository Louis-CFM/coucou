// Common now-playing values and display behavior. Each music service owns its store.
import type { BotStateName, IslandMode, IslandViewName } from "./layout";

export interface MediaTrack {
  /** spotify:track:…, spotify:episode:…, spotify:ad:… */
  id: string;
  title: string;
  artist: string;
  album: string;
  /** Seconds. */
  duration: number;
  artUrl: string | null;
}

export interface MediaState {
  /** The selected music service is running. */
  running: boolean;
  /** The selected music service is installed. */
  installed: boolean;
  track: MediaTrack | null;
  playing: boolean;
  /** Whether the native player currently supports seeking. */
  canSeek: boolean;
  /** Seconds at `positionAt` (Unix ms); while playing it runs on from there. */
  position: number;
  positionAt: number;
  shuffle: boolean;
  repeat: boolean;
  /** 0…100. */
  volume: number;
}

export const IDLE_MEDIA: MediaState = {
  running: false, installed: false, track: null, playing: false, canSeek: false,
  position: 0, positionAt: 0, shuffle: false, repeat: false, volume: 50,
};

/** SpotifyController.position(at:): extrapolated while playing, capped at the end. */
export function mediaPosition(s: MediaState, nowMs: number): number {
  const elapsed = s.playing ? Math.max(0, (nowMs - s.positionAt) / 1000) : 0;
  const p = s.position + elapsed;
  const d = s.track?.duration ?? 0;
  return d > 0 ? Math.min(p, d) : p;
}

/**
 * The clock frozen or restarted where it is now — what a play/pause click
 * does at once, before Spotify confirms it (SpotifyController.setPlaying).
 */
export function withPlaying(s: MediaState, playing: boolean, nowMs: number): MediaState {
  if (s.playing === playing) return s;
  return { ...s, position: mediaPosition(s, nowMs), positionAt: nowMs, playing };
}

export function isAd(track: MediaTrack | null | undefined): boolean {
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
  return o.mode === "expanded" && o.view === "overview" && (o.focusId === "integration_spotify" || o.focusId === "integration_music");
}

/** Mochi on the desktop: the compact island's rules (DesktopMochi.swift). */
export function desktopDances(music: boolean, state: BotStateName): boolean {
  return music && DANCE_STATES.has(state);
}
