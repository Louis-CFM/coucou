import { IDLE_SPOTIFY, type SpotifyState } from "./spotify";
export const APPLE_MUSIC_ID = "integration_music";
export const AppleMusic = {
  state: {...IDLE_SPOTIFY} as SpotifyState,
  artwork: null as {artUrl:string;dataUrl:string} | null,
};
