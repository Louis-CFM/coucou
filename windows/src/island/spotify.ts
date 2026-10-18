import { MusicAssistant } from "../core/music-assistant";
// Spotify's reports → the page (src-tauri/src/spotify.rs). The parts of
// SpotifyController.swift that touch the app: the pill wears the track's
// title, music starting shows the compact island without a sound, and the
// card reads the player again whenever it comes on screen (seeks made in
// Spotify's own window are never signalled).

import { Bridge, emitToWindow, onEvent } from "../core/bridge";
import { pillDefinition } from "../core/pills";
import { SPOTIFY_ID, Spotify, isAd, recentMusic, type SpotifyState } from "../core/spotify";
import { State } from "../core/state";
import { t } from "../i18n/i18n";

export interface SpotifyHost {
  /** Compact island from hidden, no peek sound. */
  revealSilently(): void;
}

export function registerSpotifyHandlers(island: SpotifyHost) {
  void onEvent<SpotifyState>("spotify", (s) => applySpotify(island, s));
  void onEvent<{ artUrl: string; dataUrl: string }>("spotify-artwork", (art) => {
    Spotify.artwork = art;
    State.notify();
  });
  State.subscribe(() => {
    syncPillName();
    refreshWhenShown();
  });
}

const assistant = new MusicAssistant();
let healthTimer: number | null = null;
let noticeSequence=0;
function musicAssist(s: SpotifyState) {
  const result=assistant.update(s,Date.now(),State.settings.spotifyQuietAds);
  if(result.volume!=null) void Bridge.spotifyControl("volume",result.volume);
  if(result.notice && State.settings.companionMode && !State.paused) void emitToWindow("companions","companions-notice",{
    key:`spotify:${++noticeSequence}`,pet:SPOTIFY_ID,text:result.notice,urgent:false,view:"overview",
  });
  const watch=s.running && s.playing && State.tasks.some(t=>t.id===SPOTIFY_ID);
  if(watch && healthTimer==null) healthTimer=window.setTimeout(()=>{
    healthTimer=null;void Bridge.spotifyRefresh();
  },30000);
  else if(!watch && healthTimer!=null){window.clearTimeout(healthTimer);healthTimer=null;}
}

/** A report from Rust (or the answer to a refresh). */
export function applySpotify(island: SpotifyHost, next: SpotifyState) {
  const wasPlaying = State.spotifyPlaying;
  Spotify.state = next;
  recentMusic.observe(next.track);
  musicAssist(next);
  syncPillName();
  // Only on not playing → playing (SpotifyController.setPlaying).
  if (!State.settings.companionMode && !wasPlaying && State.spotifyPlaying && !State.paused && State.mode === "hidden") {
    island.revealSilently();
  }
  State.notify();
}

/** SpotifyController.syncTaskName: the track's title, else the pill's name. */
export function syncPillName() {
  const task = State.tasks.find((x) => x.id === SPOTIFY_ID);
  if (!task) return;
  const track = Spotify.state.track;
  const title = isAd(track) ? t("Advertisement") : (track?.title ?? "");
  const name = title || (pillDefinition(SPOTIFY_ID)?.name ?? "Spotify");
  if (task.name !== name) task.name = name;
}

let shown = false;

function refreshWhenShown() {
  const now = State.mode === "expanded" && State.view === "overview" && State.focusTask?.id === SPOTIFY_ID;
  if (now && !shown) void Bridge.spotifyRefresh();
  shown = now;
}
