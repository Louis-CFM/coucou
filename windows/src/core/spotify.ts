// Spotify's independent state and native commands.
import { Bridge } from "./bridge";
import { IDLE_MEDIA, type MediaState } from "./media-state";
import type { MediaPlayer } from "./media";

export const SPOTIFY_ID = "integration_spotify";
export const SPOTIFY_GREEN = "#1DB954";
export const Spotify = {
  state: { ...IDLE_MEDIA } as MediaState,
  artwork: null as { artUrl: string; dataUrl: string } | null,
};
export const spotifyPlayer: MediaPlayer = {
  id: SPOTIFY_ID, name: "Spotify", color: SPOTIFY_GREEN, store: Spotify,
  control: Bridge.spotifyControl, open: Bridge.spotifyOpen, refresh: Bridge.spotifyRefresh,
};
export function currentArtwork(s: MediaState = Spotify.state): string | null {
  const art = Spotify.artwork;
  return art && s.track?.artUrl && art.artUrl === s.track.artUrl ? art.dataUrl : null;
}
export function musicPlaying(s: MediaState, activeIntegrations: readonly string[]): boolean {
  return s.playing && s.track != null && activeIntegrations.includes(SPOTIFY_ID);
}
