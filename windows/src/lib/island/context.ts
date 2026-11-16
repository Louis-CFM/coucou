"use client";

import { createContext, useContext, useSyncExternalStore } from "react";

import type { IslandClock } from "./clock";
import { type IslandMetrics, type KeylineFadePoint, keylineFade } from "./metrics";
import type { IslandMotion } from "./motion";
import type { FrameRecorder } from "./perf";
import type { IslandStore } from "./store";
import type { ReducedMotionSetting } from "./types";

export interface IslandContextValue {
  store: IslandStore;
  clock: IslandClock;
  metrics: IslandMetrics;
  motion: IslandMotion;
  reducedMotion: ReducedMotionSetting;
  /** Records frame timings when devtools are on. */
  recorder: FrameRecorder | null;
}

export const IslandContext = createContext<IslandContextValue | null>(null);

export const useIslandContext = (): IslandContextValue | null => useContext(IslandContext);

const reducedQuery = "(prefers-reduced-motion: reduce)";

const subscribeReduced = (onChange: () => void) => {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") return () => undefined;
  const media = window.matchMedia(reducedQuery);
  media.addEventListener("change", onChange);
  return () => media.removeEventListener("change", onChange);
};

const readReduced = () =>
  typeof window !== "undefined" && typeof window.matchMedia === "function" && window.matchMedia(reducedQuery).matches;

/** Whether to swap springs for short crossfades. "user" follows the system setting. */
export const useReducedMotion = (setting: ReducedMotionSetting): boolean => {
  const system = useSyncExternalStore(subscribeReduced, readReduced, () => false);
  if (setting === "always") return true;
  if (setting === "never") return false;
  return system;
};

/** Keyline: "auto" draws it on dark pages, "on" always, "off" never. */
export type KeylineSetting = "auto" | "on" | "off";

const darkQuery = "(prefers-color-scheme: dark)";

const subscribeDark = (onChange: () => void) => {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") return () => undefined;
  const media = window.matchMedia(darkQuery);
  media.addEventListener("change", onChange);
  return () => media.removeEventListener("change", onChange);
};

const readDark = () => typeof window !== "undefined" && typeof window.matchMedia === "function" && window.matchMedia(darkQuery).matches;

/**
 * Gamma-encoded Rec. 709 luma (0 to 1) of a CSS colour in hex or rgb() form, the scale the
 * simulator's keyline was measured on. Null for anything else (named colours, gradients).
 */
export const colourLuma = (colour: string): number | null => {
  const value = colour.trim().toLowerCase();
  let rgb: [number, number, number] | null = null;
  const hex = /^#([0-9a-f]{3}|[0-9a-f]{6})([0-9a-f]{2})?$/.exec(value);
  if (hex?.[1]) {
    const digits = hex[1].length === 3 ? [...hex[1]].map((d) => d + d) : (hex[1].match(/../g) ?? []);
    const [r, g, b] = digits.map((d) => Number.parseInt(d, 16));
    if (r !== undefined && g !== undefined && b !== undefined) rgb = [r, g, b];
  }
  const fn = /^rgba?\(\s*(\d+(?:\.\d+)?)[\s,]+(\d+(?:\.\d+)?)[\s,]+(\d+(?:\.\d+)?)/.exec(value);
  if (fn) rgb = [Number(fn[1]), Number(fn[2]), Number(fn[3])];
  if (!rgb) return null;
  return (0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]) / 255;
};

/**
 * Keyline alpha over a page of this luma, from the simulator's table: full up to `fullUntil`, then
 * log-linear between the measured points in `keylineFade`, then straight down to none at `noneFrom`.
 */
export const keylineAlphaFor = (luma: number, metrics: IslandMetrics): number => {
  const k = metrics.keyline;
  // A luma that isn't a number says nothing about the page: draw no band rather than a NaN shadow.
  if (Number.isNaN(luma)) return 0;
  if (luma >= k.noneFrom) return 0;
  if (luma <= k.fullUntil) return k.alpha;
  let from: KeylineFadePoint = { luma: k.fullUntil, share: 1 };
  for (const point of keylineFade) {
    // With `fullUntil` or `noneFrom` overridden past a point, that point would bend the fade backwards.
    if (point.luma <= from.luma || point.luma >= k.noneFrom) continue;
    if (luma <= point.luma) {
      const t = (luma - from.luma) / (point.luma - from.luma);
      return k.alpha * from.share * (point.share / from.share) ** t;
    }
    from = point;
  }
  // Log space never reaches zero, so the last stretch to `noneFrom` is a straight line.
  return k.alpha * from.share * (1 - (luma - from.luma) / (k.noneFrom - from.luma));
};

/**
 * Resolved keyline alpha. With a `backdrop` colour the strength follows the page's luma; without
 * one, "auto" assumes a near-black page in dark mode and draws nothing in light mode.
 */
export const useKeyline = (setting: KeylineSetting, backdrop: string | undefined, metrics: IslandMetrics): number => {
  const dark = useSyncExternalStore(subscribeDark, readDark, () => false);
  if (setting === "off") return 0;
  const luma = backdrop === undefined ? null : colourLuma(backdrop);
  if (luma !== null) return keylineAlphaFor(luma, metrics);
  if (setting === "on" || dark) return metrics.keyline.alpha;
  return 0;
};
