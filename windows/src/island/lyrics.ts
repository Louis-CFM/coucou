// Synced lyrics → the page. Once lyrics are on (Settings → General), each new
// track of a declared player pill — Spotify or Now Playing — is looked up once
// (src-tauri/src/lyrics.rs); the card picks the line being sung
// (views/spotify.ts). Nothing is asked while lyrics are off.

import { Bridge } from "../core/bridge";
import { Lyrics, lyricsQuery, parseLrc, rememberLyrics } from "../core/lyrics";
import { PLAYERS } from "../core/spotify";
import { State } from "../core/state";

/** LRCLIB unreachable: ask again a minute later, three times at most, while the track plays. */
export const RETRY_MS = 60_000;
export const MAX_TRIES = 3;
const tries = new Map<string, number>();

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
    // Asked once per track; again later only when LRCLIB could not be reached.
    Lyrics.asked.add(track.id);
    const query = lyricsQuery(track, player.kind === "spotify");
    if (!query) {
      rememberLyrics(track.id, null);
      continue;
    }
    const id = track.id;
    void Bridge.lyricsGet(id, query.title, query.artist, query.album, query.duration).then((answer) => {
      if (answer?.retry) {
        const n = (tries.get(id) ?? 0) + 1;
        tries.set(id, n);
        if (n < MAX_TRIES) {
          setTimeout(() => {
            Lyrics.asked.delete(id);
            State.notify();
          }, RETRY_MS);
        }
        return;
      }
      tries.delete(id);
      const lrc = answer?.lrc ?? null;
      rememberLyrics(id, lrc ? parseLrc(lrc) : null);
      if (lrc) State.notify();
    });
  }
}
