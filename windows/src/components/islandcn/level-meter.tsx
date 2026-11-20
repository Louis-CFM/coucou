"use client";

import type { CSSProperties } from "react";

import { useIslandReducedMotion } from "@/lib/island";

import { IslandStyle } from "./island-style";
import { islandInk } from "./theme";

interface LevelMeterProps {
  /** Number of bars. Defaults to 4, which fits the compact trailing slot. */
  bars?: number;
  /** Bar colour. Defaults to white. */
  color?: string;
  /** A colour per bar, in order, over `color` for the bars it covers: a two-tone meter. Defaults to none. */
  colors?: readonly string[];
  /**
   * A lighter core inside every bar, 45% of its length and centred, that grows and shrinks with
   * it, as a call's meter draws the near voice inside the far one. Defaults to none.
   */
  core?: string;
  /** Height of the meter in pt. Defaults to 16. */
  height?: number;
  /** Bar width in pt. Defaults to 3. */
  barWidth?: number;
  /** Space between bars in pt. Defaults to 2. */
  gap?: number;
  /** Bars move while active and rest low while not. Defaults to true. */
  active?: boolean;
  /**
   * Live levels from 0 to 1, one per bar (for example from an AnalyserNode). When given, the
   * bars follow them instead of the built-in loop. Defaults to none.
   */
  levels?: readonly number[];
  /**
   * Each bar's peak, 0 to 1, in order: the shape the meter keeps while it moves (a voice's two
   * lobes, a song's peak). Each bar swings between under half its peak and its peak. Defaults to
   * none: every bar's peak is its own pseudo-random height, which reads as a row of even dashes.
   */
  envelope?: readonly number[];
  /**
   * Take the width the row gives it and show as many whole bars as fit (up to `bars`), instead of a fixed width
   * from `bars`. For a meter that shares a row with buttons on screens of any width. Defaults to false.
   */
  fill?: boolean;
}

const css = `
@keyframes icn-level { 0%, 100% { transform: scaleY(var(--icn-lo)); } 50% { transform: scaleY(var(--icn-hi)); } }
.icn-level-bar { transform-origin: 50% 50%; transition: transform 160ms ease-out; }
.icn-level-bar[data-active] { animation: icn-level var(--icn-dur) ease-in-out var(--icn-delay) infinite; }
@media (prefers-reduced-motion: reduce) { .icn-level-bar[data-active] { animation: none; transform: scaleY(var(--icn-hi)); } }
`;

// A cheap, stable pseudo-random number per bar, so every meter moves the same way on every render.
const hash = (n: number) => {
  const x = Math.sin(n * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
};

/**
 * Animated level bars for audio: the now-playing equaliser and the recording meter. Each bar
 * pulses on its own period, so the pattern never visibly repeats. With reduced motion the bars
 * hold a fixed pattern (live `levels` still update them, without easing).
 */
export const LevelMeter = ({
  bars = 4,
  color = islandInk.primary,
  colors,
  core,
  height = 16,
  barWidth = 3,
  gap = 2,
  active = true,
  levels,
  envelope,
  fill = false,
}: LevelMeterProps) => {
  const reduced = useIslandReducedMotion();
  // Filling, the bars wrap onto lines below the first, which the meter's own height hides, so the
  // last bar shown is never cut in half.
  const box: CSSProperties = fill
    ? { display: "flex", flexWrap: "wrap", alignItems: "center", alignContent: "flex-start", columnGap: gap, rowGap: height, height, flex: "1 0", minWidth: 0, overflow: "hidden" }
    : { display: "flex", alignItems: "center", gap, height, flex: "none" };
  return (
    <span aria-hidden style={box}>
      <IslandStyle id="level" css={css} />
      {Array.from({ length: bars }, (_, index) => {
        const live = levels?.[index];
        const peak = envelope?.[index];
        const hi = peak === undefined ? 0.55 + hash(index + 17) * 0.45 : Math.max(0.12, Math.min(1, peak));
        const lo = peak === undefined ? 0.22 + hash(index) * 0.12 : Math.max(0.1, hi * (0.4 + hash(index) * 0.1));
        const style = {
          display: "block",
          position: "relative",
          width: barWidth,
          height,
          borderRadius: barWidth,
          background: colors?.[index] ?? color,
          transform: `scaleY(${live === undefined ? (active ? (reduced ? hi : lo) : 0.2) : Math.max(0.12, Math.min(1, live))})`,
          transition: reduced ? "none" : undefined,
          "--icn-lo": lo,
          "--icn-hi": hi,
          "--icn-dur": `${(0.42 + hash(index + 5) * 0.5).toFixed(2)}s`,
          "--icn-delay": `${(-hash(index + 9) * 0.8).toFixed(2)}s`,
        } as const satisfies CSSProperties & Record<`--icn-${string}`, string | number>;
        return (
          <span key={index} className="icn-level-bar" data-active={active && live === undefined && !reduced ? "" : undefined} style={style}>
            {/* Inside the bar, so the bar's own scale moves it too and it never outgrows the bar. */}
            {core === undefined ? null : <span style={{ position: "absolute", left: 0, right: 0, top: "27.5%", bottom: "27.5%", borderRadius: barWidth, background: core }} />}
          </span>
        );
      })}
    </span>
  );
};
