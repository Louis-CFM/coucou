// Synced lyrics for the song that plays (the music page, views/music.ts).
// They come from LRCLIB (lrclib.net, a free community library) through
// src-tauri/src/lyrics.rs: only the title, artist, album and length are sent.
// This reads the LRC text and says which line is being sung.

export interface LyricLine {
  /** Seconds from the start of the song. */
  at: number;
  text: string;
}

export interface Lyrics {
  /** Timed lines, in order; empty when only plain lyrics exist. */
  lines: LyricLine[];
  /** The words without times, when no synced version exists. */
  plain: string | null;
  instrumental: boolean;
}

/** "[01:02.50] words" (several stamps on one line allowed) → timed lines, sorted. */
export function parseLrc(lrc: string): LyricLine[] {
  const out: LyricLine[] = [];
  const stamp = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g;
  for (const raw of lrc.split(/\r?\n/)) {
    const stamps: number[] = [];
    let m: RegExpExecArray | null;
    stamp.lastIndex = 0;
    let end = 0;
    while ((m = stamp.exec(raw)) && m.index === end) {
      const frac = m[3] ? Number(m[3]) / 10 ** m[3].length : 0;
      stamps.push(Number(m[1]) * 60 + Number(m[2]) + frac);
      end = stamp.lastIndex;
    }
    if (!stamps.length) continue;
    const text = raw.slice(end).trim();
    for (const at of stamps) out.push({ at, text });
  }
  return out.sort((a, b) => a.at - b.at);
}

/** The line being sung at `seconds` (-1 before the first). */
export function lineAt(lines: LyricLine[], seconds: number): number {
  let lo = 0;
  let hi = lines.length - 1;
  let found = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (lines[mid].at <= seconds + 0.15) {
      found = mid;
      lo = mid + 1;
    } else hi = mid - 1;
  }
  return found;
}

/** What lyrics.rs answered, made into Lyrics (null: none found). */
export function fromAnswer(a: { synced?: string | null; plain?: string | null; instrumental?: boolean } | null): Lyrics | null {
  if (!a) return null;
  const lines = a.synced ? parseLrc(a.synced) : [];
  const plain = a.plain?.trim() ? a.plain.trim() : null;
  if (!lines.length && !plain && !a.instrumental) return null;
  return { lines, plain, instrumental: a.instrumental === true };
}
