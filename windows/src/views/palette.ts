// The island's colours by what they say, for the code that picks a colour from
// data — a build's state, a kind of activity, a file's language — where a
// style sheet can't. The same values as :root in style.css and as Mochi's
// states in mochi/engine.ts: a colour is written once on this side, here.

export const COLOR = {
  /** An error, a failure; GitHub's own dot. */
  red: "#F4505E",
  /** Finished: merged, approved, added. */
  green: "#34D399",
  /** Passed, live: the green of the pills' badges. */
  pass: "#22C55E",
  /** Waiting or under way; a change asked for. */
  amber: "#F5A524",
  /** Searching; a pull request that is open. */
  indigo: "#6366F1",
  /** Working; a commit. */
  blue: "#3B9EFF",
  /** A question: a review, a comment, a release. */
  cyan: "#22D3EE",
  /** Mochi at rest. */
  idle: "#E6E9EE",
  /** Mochi asleep. */
  asleep: "#94A2B8",
  /** Present but quiet: a draft, a neutral mark, a creation. */
  dim: "#9398A1",
  /** Nothing to say: stopped, closed, not granted. */
  grey: "#6B7079",
  /** No colour given: a language GitHub has none for. */
  blank: "#4B5563",
} as const;

/** How much of a colour the ground under a tinted mark takes: 15 %, as two hex digits. */
const TINT_ALPHA = "26";

/**
 * Dresses a tinted mark — a round icon, a chip, a badge — in `color`: the
 * colour itself for what is drawn, and a wash of it for the ground under it.
 */
export function wear(el: HTMLElement, color: string) {
  el.style.setProperty("--c", color);
  el.style.setProperty("--tint", `${color}${TINT_ALPHA}`);
}

/** How bright a colour is, 0 (black) to 1 (white): its relative luminance. */
function brightness(hex: string): number {
  const value = parseInt(hex.slice(1), 16);
  const linear = [16, 8, 0].map((shift) => {
    const c = ((value >> shift) & 255) / 255;
    return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

/** Past this, white letters are lost on a colour and dark ones read. */
const LIGHT_FROM = 0.32;

/** True for a colour light enough that what is written on it must be dark. */
export const isLight = (hex: string) => brightness(hex) >= LIGHT_FROM;
