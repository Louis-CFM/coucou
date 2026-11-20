"use client";

import { useEffect, useState } from "react";

import { IslandProgress, useIslandReducedMotion } from "@/lib/island";

import { islandAccent, islandInk } from "./theme";

interface LinearProgressProps {
  /** Progress from 0 to 1. Values outside are clamped. */
  value: number;
  /** Fill colour. Defaults to blue. */
  color?: string;
  /** Unfilled colour. Defaults to a faint white. */
  track?: string;
  /** Bar height in pt. Defaults to 6. */
  height?: number;
  /** Accessible name. When set, the bar is a progressbar; without it, it's decoration. Defaults to none. */
  label?: string;
  /**
   * "round" fills with a capsule (the engine's bar); "square" cuts the fill straight inside the
   * round track, as a media scrubber's playhead edge is. Defaults to "round".
   */
  ends?: "round" | "square";
  /** With `ends="square"`, how long the fill takes to reach a new value (ms): match the feed's interval. Defaults to 500. */
  glide?: number;
}

/**
 * A capsule progress bar. The fill eases to each new value on the island's clock, as a Live
 * Activity's bar does (the engine's `IslandProgress`). With reduced motion it jumps.
 */
export const LinearProgress = ({ value, color = islandAccent.blue, track = islandInk.track, height = 6, label, ends = "round", glide = 500 }: LinearProgressProps) => {
  const reduced = useIslandReducedMotion();
  const clamped = Math.min(1, Math.max(0, Number.isFinite(value) ? value : 0));
  const a11y = label
    ? { role: "progressbar" as const, "aria-label": label, "aria-valuemin": 0, "aria-valuemax": 100, "aria-valuenow": Math.round(clamped * 100) }
    : { "aria-hidden": true };
  return (
    <span {...a11y} style={{ display: "block", width: "100%" }}>
      {ends === "square" ? (
        // The track clips a full-width fill that slides in from the left, so its leading edge stays straight.
        <span style={{ display: "block", height, borderRadius: height / 2, background: track, overflow: "hidden" }}>
          <span
            style={{
              display: "block",
              height: "100%",
              background: color,
              transform: `translateX(${(clamped - 1) * 100}%)`,
              transition: reduced ? "none" : `transform ${glide}ms linear`,
            }}
          />
        </span>
      ) : reduced ? (
        <span style={{ display: "block", height, borderRadius: height / 2, background: track, overflow: "hidden" }}>
          <span style={{ display: "block", height: "100%", width: `${clamped * 100}%`, borderRadius: height / 2, background: color }} />
        </span>
      ) : (
        // The engine's bar announces itself too; the wrapper above owns the name, so hide it.
        <span aria-hidden style={{ display: "block" }}>
          <IslandProgress value={clamped} color={color} track={track} height={height} />
        </span>
      )}
    </span>
  );
};

/** Where a `TimeProgress` playhead is: moving since a moment (epoch ms), or held at a position (ms). */
export type PlayheadSource = { kind: "elapsed"; since: number } | { kind: "fixed"; ms: number };

const playheadAt = (source: PlayheadSource, duration: number) =>
  Math.min(duration, Math.max(0, source.kind === "elapsed" ? Date.now() - source.since : source.ms));

interface TimeProgressProps {
  /** Where the playhead is. */
  source: PlayheadSource;
  /** The whole length in ms. */
  duration: number;
  /** Fill colour. Defaults to blue. */
  color?: string;
  /** Unfilled colour. Defaults to a faint white. */
  track?: string;
  /** Bar height in pt. Defaults to 6. */
  height?: number;
  /** Accessible name. Defaults to none (decoration). */
  label?: string;
  /** How the fill ends, as `LinearProgress`'s `ends`. Defaults to "round". */
  ends?: "round" | "square";
}

/**
 * A bar that fills with time, such as a track's scrubber. It moves on its own every half second
 * while the source is moving, and only it re-renders.
 */
export const TimeProgress = ({ source, duration, color, track, height, label, ends = "round" }: TimeProgressProps) => {
  const [position, setPosition] = useState(() => playheadAt(source, duration));
  const key = source.kind === "elapsed" ? `e${source.since}` : `f${source.ms}`;
  useEffect(() => {
    setPosition(playheadAt(source, duration));
    if (source.kind !== "elapsed") return;
    const timer = window.setInterval(() => setPosition(playheadAt(source, duration)), 500);
    return () => window.clearInterval(timer);
    // `key` holds every field of `source` that matters.
  }, [key, duration]);
  return <LinearProgress value={duration > 0 ? position / duration : 0} color={color} track={track} height={height} label={label} ends={ends} />;
};
