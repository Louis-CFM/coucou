import type { MediaState } from "./media-state";

export interface MediaPlayer {
  id: string;
  name: string;
  color: string;
  store: { state: MediaState; artwork: { artUrl: string; dataUrl: string } | null };
  control(action: string, value?: number): Promise<boolean | null>;
  open(): Promise<boolean | null>;
  refresh(): Promise<MediaState | null>;
}

export function playerArtwork(player: MediaPlayer): string | null {
  const art = player.store.artwork;
  return art && player.store.state.track?.artUrl === art.artUrl ? art.dataUrl : null;
}
