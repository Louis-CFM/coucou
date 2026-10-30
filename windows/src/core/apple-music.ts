// Apple Music owns its state, artwork and command routing, independently of Spotify.
import { Bridge } from "./bridge";
import { IDLE_MEDIA, type MediaState } from "./media-state";
import type { MediaPlayer } from "./media";

export const MUSIC_ID = "integration_music";
export const Music = {
  state: { ...IDLE_MEDIA } as MediaState,
  artwork: null as { artUrl: string; dataUrl: string } | null,
};
export const appleMusicPlayer: MediaPlayer = {
  id: MUSIC_ID, name: "Apple Music", color: "#FA2D48", store: Music,
  control: Bridge.appleMusicControl, open: Bridge.appleMusicOpen, refresh: Bridge.appleMusicRefresh,
};
