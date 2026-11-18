// The Deezer pill on the page: what src-tauri/src/deezer.rs reports (the
// system media controls on Windows), and the pure rules the views follow.
// Self-contained: nothing here imports the Spotify module.

export const DEEZER_ID = "integration_deezer";
export const DEEZER_PURPLE = "#A238FF";

export interface DeezerTrack {
  /** deezer:track:<hash> */
  id: string;
  title: string;
  artist: string;
  /** Always empty: the Deezer session doesn't report it. */
  album: string;
  /** Seconds. */
  duration: number;
  artUrl: string | null;
}

export interface DeezerState {
  running: boolean;
  installed: boolean;
  track: DeezerTrack | null;
  playing: boolean;
  /** Seconds at `positionAt` (Unix ms); while playing it runs on from there. */
  position: number;
  positionAt: number;
  /** Not reported by Deezer. */
  shuffle: boolean;
  repeat: boolean;
  /** 0…100. */
  volume: number;
}

export const IDLE_DEEZER: DeezerState = {
  running: false, installed: false, track: null, playing: false,
  position: 0, positionAt: 0, shuffle: false, repeat: false, volume: 50,
};

/** The page's copy of the player, and the cover of the track that has one. */
export const Deezer = {
  state: { ...IDLE_DEEZER } as DeezerState,
  artwork: null as { artUrl: string; dataUrl: string } | null,
};

export function currentArtwork(s: DeezerState = Deezer.state): string | null {
  const art = Deezer.artwork;
  return art && s.track?.artUrl && art.artUrl === s.track.artUrl ? art.dataUrl : null;
}

/** Extrapolated while playing, capped at the end. */
export function deezerPosition(s: DeezerState, nowMs: number): number {
  const elapsed = s.playing ? Math.max(0, (nowMs - s.positionAt) / 1000) : 0;
  const p = s.position + elapsed;
  const d = s.track?.duration ?? 0;
  return d > 0 ? Math.min(p, d) : p;
}

/** The clock frozen or restarted where it is now, before Deezer confirms a click. */
export function withPlaying(s: DeezerState, playing: boolean, nowMs: number): DeezerState {
  if (s.playing === playing) return s;
  return { ...s, position: deezerPosition(s, nowMs), positionAt: nowMs, playing };
}

/** Music is playing on a declared Deezer pill. */
export function musicPlaying(s: DeezerState, activeIntegrations: readonly string[]): boolean {
  return s.playing && s.track != null && activeIntegrations.includes(DEEZER_ID);
}

/** m:ss, or h:mm:ss past an hour. */
export function formatTime(seconds: number): string {
  const s = Math.max(0, Math.floor(Number.isFinite(seconds) ? seconds : 0));
  const pad = (n: number) => String(n).padStart(2, "0");
  return s >= 3600
    ? `${Math.floor(s / 3600)}:${pad(Math.floor((s % 3600) / 60))}:${pad(s % 60)}`
    : `${Math.floor(s / 60)}:${pad(s % 60)}`;
}

/** 0 = muted, then one, two or three waves. */
export function volumeLevel(volume: number): 0 | 1 | 2 | 3 {
  if (volume <= 0) return 0;
  if (volume < 34) return 1;
  if (volume < 67) return 2;
  return 3;
}
