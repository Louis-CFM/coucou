// Synced lyrics on the music cards — the page's side of src-tauri/src/lyrics.rs
// (port of the Mac branch's SyncedLyrics.swift). Rust fetches the LRC text from
// LRCLIB once the user turned lyrics on; the page reads it and picks the line
// being sung from the card's own clock.

import type { SpotifyTrack } from "./spotify";

export interface LyricLine {
  /** Seconds. */
  time: number;
  /** Empty for an instrumental break. */
  text: string;
}

/** "mm:ss", "mm:ss.xx" or "mm:ss:xx" → seconds. */
function seconds(tag: string): number | null {
  const parts = tag.split(":");
  if (parts.length !== 2 && parts.length !== 3) return null;
  if (!/^\d+$/.test(parts[0])) return null;
  const secText = parts.length === 3 ? `${parts[1]}.${parts[2]}` : parts[1];
  if (!/^\d+(\.\d+)?$/.test(secText)) return null;
  const s = Number(secText);
  if (s >= 60) return null;
  return Number(parts[0]) * 60 + s;
}

/**
 * LRC text → its timed lines, sorted; null when nothing in it is timed.
 * Metadata tags ([ar:…]) are skipped, a line with several timestamps appears
 * at each, and a lone "♪" is a break like an empty line.
 */
export function parseLrc(lrc: string): LyricLine[] | null {
  const out: LyricLine[] = [];
  for (const raw of lrc.split(/\r?\n|\r/)) {
    let rest = raw.trim();
    const times: number[] = [];
    for (;;) {
      const m = /^\[([^\]]*)\]/.exec(rest);
      if (!m) break;
      const t = seconds(m[1]);
      if (t == null) break;
      times.push(t);
      rest = rest.slice(m[0].length);
    }
    if (times.length === 0) continue;
    let text = rest.trim();
    if (/^[♪♫♬\s]*$/.test(text)) text = "";
    for (const time of times) out.push({ time, text });
  }
  if (out.length === 0) return null;
  return out.sort((a, b) => a.time - b.time);
}

/** The line being sung at `position` (seconds): null before the first and during breaks. */
export function lineAt(lines: readonly LyricLine[], position: number): string | null {
  let low = 0;
  let high = lines.length;
  while (low < high) {
    const mid = (low + high) >> 1;
    if (lines[mid].time <= position) low = mid + 1;
    else high = mid;
  }
  if (low === 0) return null;
  return lines[low - 1].text || null;
}

export interface LyricsQuery {
  title: string;
  artist: string;
  album: string;
  duration: number;
}

/** "(Lyrics)", "[Official Video]", "(HD)"… at the end of a video's title. */
function trimTags(s: string): string {
  let out = s.trim();
  for (;;) {
    const next = out.replace(/\s*[([][^()[\]]*[)\]]\s*$/, "").trim();
    if (next === out || !next) return out;
    out = next;
  }
}

/**
 * What to look a track up by. Spotify's tags are the song's. Another app's —
 * often a video, "Coldplay - Hymn For The Weekend (Lyrics)" on a channel — is
 * read as "Artist - Song" when it has the dash, with its tags trimmed.
 * Null for an ad or a track with nothing to search by.
 */
export function lyricsQuery(track: SpotifyTrack, spotify: boolean): LyricsQuery | null {
  if (track.id.startsWith("spotify:ad:")) return null;
  let title = track.title.trim();
  let artist = track.artist.trim();
  let album = track.album.trim();
  if (!spotify) {
    const dash = title.indexOf(" - ");
    if (dash > 0) {
      artist = title.slice(0, dash).trim();
      title = title.slice(dash + 3);
      album = "";
    }
    title = trimTags(title);
  }
  if (!title || !artist) return null;
  return { title, artist, album, duration: track.duration };
}

/** Track id → its lines, or null when there are none to show. */
export const Lyrics = {
  byTrack: new Map<string, LyricLine[] | null>(),
  asked: new Set<string>(),
};

/** Remembers a track's lyrics, keeping the newest 30. */
export function rememberLyrics(trackId: string, lines: LyricLine[] | null) {
  Lyrics.byTrack.delete(trackId);
  Lyrics.byTrack.set(trackId, lines);
  while (Lyrics.byTrack.size > 30) {
    const oldest = Lyrics.byTrack.keys().next().value;
    if (oldest === undefined) break;
    Lyrics.byTrack.delete(oldest);
    Lyrics.asked.delete(oldest);
  }
}
