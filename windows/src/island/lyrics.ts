// Synced lyrics → the page. Once lyrics are on (Settings → General), each new
// track of a declared player pill — Spotify or Now Playing — is looked up once
// (src-tauri/src/lyrics.rs); the card picks the line being sung
// (views/spotify.ts). Nothing is asked while lyrics are off.

import { Bridge } from "../core/bridge";
import { Lyrics, lyricsQuery, parseLrc, rememberLyrics } from "../core/lyrics";
import { PLAYERS } from "../core/spotify";
import { State } from "../core/state";

export function registerLyricsHandlers() {
  State.subscribe(fetchLyrics);
}

/** Asks for the lyrics of every playing track not asked about yet. */
export function fetchLyrics() {
  if (!State.settings.lyricsEnabled) return;
  for (const player of PLAYERS) {
    const track = player.state.track;
    if (!track || !State.settings.activeIntegrations.includes(player.pillId)) continue;
    if (Lyrics.asked.has(track.id)) continue;
    // Asked once per track: none found, or offline, it waits for the next one.
    Lyrics.asked.add(track.id);
    const query = lyricsQuery(track, player.kind === "spotify");
    if (!query) {
      rememberLyrics(track.id, null);
      continue;
    }
    void Bridge.lyricsGet(track.id, query.title, query.artist, query.album, query.duration).then((lrc) => {
      rememberLyrics(track.id, lrc ? parseLrc(lrc) : null);
      if (lrc) State.notify();
    });
  }
}
