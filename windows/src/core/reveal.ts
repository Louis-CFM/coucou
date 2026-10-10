// Timing of the live-edit reveal: the lines of an edit appear one after another,
// added ones typed in. Pure, so the views only apply what it answers.
// The numbers are the macOS app's (same spec): keep them in step.

/** Typing speed of an added line. */
export const REVEAL_CHARS_PER_SECOND = 90;
/** Gap before the next context or removed line. */
export const REVEAL_STAGGER_S = 0.04;
/** One line's fade-in. */
export const REVEAL_FADE_S = 0.15;
export const REVEAL_SLIDE_PX = 4;
/** The whole sequence is scaled down to fit this. */
export const REVEAL_MAX_S = 1.6;
/** A bigger diff is shown at once. */
export const REVEAL_MAX_LINES = 60;
export const REVEAL_CARET = "▍";

/** The card's entrance (CSS in style.css uses the same numbers). */
export const CARD_ENTER_MS = 220;
export const CARD_ENTER_SLIDE_PX = 6;
/** A second live edit replacing the shown one: the content cross-fades. */
export const CARD_SWAP_MS = 160;

export interface RevealLine {
  /** Added lines are typed; the others just fade in. */
  typed: boolean;
  /** Characters in the line. */
  length: number;
}

export interface RevealState {
  started: boolean;
  /** 0 to 1. */
  opacity: number;
  /** How much of the line is shown. */
  characters: number;
  /** The caret belongs at its end. */
  typing: boolean;
}

/** Rounding noise from the sums: a value this close to 1 is 1. */
const EPSILON = 1e-9;

const clamp01 = (v: number) => (v >= 1 - EPSILON ? 1 : Math.max(0, v));

/** Natural seconds a line takes before the next one starts. */
function naturalSeconds(l: RevealLine): number {
  return Math.max(REVEAL_STAGGER_S, l.typed ? l.length / REVEAL_CHARS_PER_SECOND : 0);
}

/** The factor that makes the sequence fit REVEAL_MAX_S, the fade itself staying as long as it is. */
function scaleOf(lines: RevealLine[]): number {
  if (lines.length === 0) return 1;
  const last = lines[lines.length - 1];
  const before = lines.slice(0, -1).reduce((s, l) => s + naturalSeconds(l), 0);
  const d = naturalSeconds(last);
  if (before + Math.max(d, REVEAL_FADE_S) <= REVEAL_MAX_S) return 1;
  const whole = REVEAL_MAX_S / (before + d);
  if (d * whole >= REVEAL_FADE_S) return whole;
  // The last line's own time is shorter than its fade: only what comes before shrinks.
  return (REVEAL_MAX_S - REVEAL_FADE_S) / before;
}

/** Seconds from the first line starting until the last has finished fading in. */
export function revealDuration(lines: RevealLine[]): number {
  if (lines.length === 0) return 0;
  const k = scaleOf(lines);
  let start = 0;
  let end = 0;
  for (const l of lines) {
    const d = naturalSeconds(l) * k;
    end = Math.max(end, start + Math.max(d, REVEAL_FADE_S));
    start += d;
  }
  return end;
}

/** What each line looks like `t` seconds into the reveal. */
export function revealAt(lines: RevealLine[], t: number): RevealState[] {
  const k = scaleOf(lines);
  let start = 0;
  return lines.map((l) => {
    const d = naturalSeconds(l) * k;
    const s = start;
    start += d;
    const started = t >= s;
    const opacity = started ? clamp01((t - s) / REVEAL_FADE_S) : 0;
    let characters = l.length;
    if (l.typed) {
      characters = Math.floor(clamp01((t - s) / d) * l.length);
    }
    return { started, opacity, characters, typing: l.typed && started && characters < l.length };
  });
}
