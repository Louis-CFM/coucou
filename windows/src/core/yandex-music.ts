// The Yandex Music pill on the page: what src-tauri/src/yandex_music.rs reports
// (the Windows system media controls) has the Spotify state's shape, so the
// position maths, formatting and dance rules are Spotify's own
// (src/core/spotify.ts). Only the identity, the colour and the "declared" test
// are Yandex Music's.

import type { BotStateName, IslandMode, IslandViewName } from "./layout";
import { IDLE_SPOTIFY, SPOTIFY_ID, islandDances, type SpotifyState } from "./spotify";

export const YANDEX_MUSIC_ID = "integration_yandex_music";
/** YandexMusicController.yellow. */
export const YANDEX_MUSIC_YELLOW = "#FFEE00";

/** Same JSON as Spotify's: `shuffle` and `repeat` are always false, the id is `yandex:track:…`. */
export type YandexMusicState = SpotifyState;

export const IDLE_YANDEX_MUSIC: YandexMusicState = { ...IDLE_SPOTIFY };

/** The page's copy of the player, and the cover of the track that has one. */
export const YandexMusic = {
  state: { ...IDLE_YANDEX_MUSIC } as YandexMusicState,
  artwork: null as { artUrl: string; dataUrl: string } | null,
};

/** The cover to show for the current track, if it has arrived. */
export function currentYandexArtwork(s: YandexMusicState = YandexMusic.state): string | null {
  const art = YandexMusic.artwork;
  return art && s.track?.artUrl && art.artUrl === s.track.artUrl ? art.dataUrl : null;
}

/** Music is playing on a declared Yandex Music pill. */
export function yandexMusicPlaying(s: YandexMusicState, activeIntegrations: readonly string[]): boolean {
  return s.playing && s.track != null && activeIntegrations.includes(YANDEX_MUSIC_ID);
}

/**
 * The island's Mochi: Spotify's rules (islandDances), with the Yandex Music
 * pill as the one that must be in front when expanded.
 */
export function yandexIslandDances(o: {
  music: boolean;
  state: BotStateName;
  mode: IslandMode;
  view: IslandViewName;
  focusId: string | null | undefined;
}): boolean {
  // islandDances compares the focus with Spotify's id: hand it that id exactly
  // when Yandex Music is in front, and never when Spotify is.
  return islandDances({ ...o, focusId: o.focusId === YANDEX_MUSIC_ID ? SPOTIFY_ID : null });
}
