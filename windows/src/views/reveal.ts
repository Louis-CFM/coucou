// Plays the live-edit reveal (core/reveal.ts) on rows that are already in the
// page. A frame is requested only while it runs: once it is done, the rows are
// gone or another one starts, nothing is left to wake the CPU.

import { REVEAL_CARET, REVEAL_MAX_LINES, revealAt, revealDuration } from "../core/reveal";
import { h } from "./dom";

export interface RevealRow {
  el: HTMLElement;
  typed: boolean;
  /** Characters in the line. */
  length: number;
  /** Shows the first `characters` of the line, with the caret at its end when asked. */
  paint(characters: number, caret: boolean): void;
}

export interface RevealRun {
  stop(): void;
  /** Seconds played so far. */
  elapsed(): number;
  readonly done: boolean;
}

/** The caret a typed line wears while it is being typed. */
export function caret(): HTMLElement {
  return h("span", { class: "reveal-caret", text: REVEAL_CARET });
}

/** False when the system asks for less motion, or the diff is too big to be worth it. */
export function revealWanted(lines: number): boolean {
  if (lines === 0 || lines > REVEAL_MAX_LINES) return false;
  const query = (globalThis as { matchMedia?: (q: string) => { matches: boolean } }).matchMedia;
  return !query?.("(prefers-reduced-motion: reduce)").matches;
}

/**
 * Starts the reveal `from` seconds in (a rebuilt view carries on where the one
 * it replaces was). Stops by itself when it is over or its rows leave the page.
 */
export function playReveal(rows: RevealRow[], opts: { from?: number; scroll?: HTMLElement | null } = {}): RevealRun {
  const specs = rows.map((r) => ({ typed: r.typed, length: r.length }));
  const total = revealDuration(specs);
  const from = opts.from ?? 0;
  const shown = rows.map(() => -1);
  let origin: number | null = null;
  let frame: number | null = null;
  let at = from;
  let done = false;
  let followed = -1;

  const run: RevealRun = {
    stop() {
      if (frame != null) cancelAnimationFrame(frame);
      frame = null;
    },
    elapsed: () => at,
    get done() {
      return done;
    },
  };

  const paint = (r: RevealRow, i: number, characters: number, typing: boolean) => {
    // Only when something changed: the caret counts as one more state.
    const mark = characters * 2 + (typing ? 1 : 0);
    if (shown[i] === mark) return;
    shown[i] = mark;
    r.paint(characters, typing);
  };

  const finish = () => {
    done = true;
    rows.forEach((r, i) => {
      r.el.style.opacity = "";
      if (r.typed) paint(r, i, r.length, false);
    });
  };

  const apply = (t: number) => {
    let latest = -1;
    revealAt(specs, t).forEach((s, i) => {
      const r = rows[i];
      r.el.style.opacity = String(s.opacity);
      if (r.typed) paint(r, i, s.characters, s.typing);
      if (s.started) latest = i;
    });
    const box = opts.scroll;
    const row = latest >= 0 ? rows[latest].el : null;
    if (!box || !row || latest === followed) return;
    followed = latest;
    // Keep the line being typed in view.
    const bottom = row.offsetTop + row.offsetHeight;
    if (bottom > box.scrollTop + box.clientHeight) box.scrollTop = bottom - box.clientHeight;
  };

  const tick = (now?: number) => {
    frame = null;
    if (rows[0].el.isConnected === false) return;
    const ts = now ?? performance.now();
    origin ??= ts - from * 1000;
    at = (ts - origin) / 1000;
    if (at >= total) {
      finish();
      return;
    }
    apply(at);
    frame = requestAnimationFrame(tick);
  };

  if (rows.length === 0 || from >= total) {
    finish();
    return run;
  }
  apply(from);
  frame = requestAnimationFrame(tick);
  return run;
}
