"use client";

import type { ReactNode } from "react";

import { useIslandReducedMotion } from "@/lib/island";

import type { GlyphIcon } from "./glyph";
import { IslandStyle } from "./island-style";
import { islandAccent, islandInk, tint } from "./theme";

interface ProgressRingProps {
  /** Progress from 0 to 1. Values outside are clamped. */
  value: number;
  /** Ring colour. Defaults to blue. */
  color?: string;
  /** Unfilled ring colour. Defaults to a faint white. */
  track?: string;
  /** Outer size in pt. Defaults to 22, the compact glyph size. */
  size?: number;
  /** Stroke width in pt. Defaults to 3 (about size / 7). */
  thickness?: number;
  /** Drawn in the middle of the ring, such as an icon. Defaults to nothing. */
  children?: ReactNode;
  /** Accessible name. When set, the ring is a progressbar; without it, it's decoration. Defaults to none. */
  label?: string;
}

const css = `
.icn-ring-fill { transition: stroke-dashoffset 420ms cubic-bezier(0.22, 1, 0.36, 1); }
@media (prefers-reduced-motion: reduce) { .icn-ring-fill { transition: none; } }
`;

/** A circular progress ring with round caps that starts at 12 o'clock, like the system's. */
export const ProgressRing = ({
  value,
  color = islandAccent.blue,
  track = islandInk.track,
  size = 22,
  thickness = 3,
  children,
  label,
}: ProgressRingProps) => {
  const reduced = useIslandReducedMotion();
  const clamped = Math.min(1, Math.max(0, Number.isFinite(value) ? value : 0));
  const radius = (size - thickness) / 2;
  const circumference = 2 * Math.PI * radius;
  const a11y = label
    ? { role: "progressbar" as const, "aria-label": label, "aria-valuemin": 0, "aria-valuemax": 100, "aria-valuenow": Math.round(clamped * 100) }
    : { "aria-hidden": true };
  return (
    <span {...a11y} style={{ position: "relative", display: "grid", placeItems: "center", width: size, height: size, flex: "none" }}>
      <IslandStyle id="ring" css={css} />
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={{ position: "absolute", inset: 0, transform: "rotate(-90deg)" }}>
        <circle cx={size / 2} cy={size / 2} r={radius} fill="none" stroke={track} strokeWidth={thickness} />
        <circle
          className={reduced ? undefined : "icn-ring-fill"}
          cx={size / 2}
          cy={size / 2}
          r={radius}
          fill="none"
          stroke={color}
          strokeWidth={thickness}
          strokeLinecap="round"
          strokeDasharray={circumference}
          // A hair of arc stays visible at 0 would look like a dot; hide the cap until there's progress.
          strokeDashoffset={circumference * (1 - clamped)}
          opacity={clamped > 0 ? 1 : 0}
        />
      </svg>
      {children === undefined ? null : <span style={{ position: "relative", display: "grid", placeItems: "center" }}>{children}</span>}
    </span>
  );
};

interface IconRingProps {
  /** The icon in the middle: an islandcn glyph, or an icon from another set. */
  icon: GlyphIcon;
  /** Progress from 0 to 1. */
  value: number;
  /** Ring, disc and icon colour. */
  accent: string;
  /** Outer size in pt: 22 in compact, 52 beside the sensor in the expanded view. Defaults to 22. */
  size?: number;
}

/**
 * An icon in a ring that fills: a device a transfer goes to, a car on its way. From 30 pt up the
 * icon sits on a disc tinted with the accent, as a live status activity's leading tile does.
 */
export const IconRing = ({ icon: Icon, value, accent, size = 22 }: IconRingProps) => {
  const large = size > 30;
  return (
    <ProgressRing value={value} color={accent} track={tint(accent, 0.22)} size={size} thickness={large ? 3.5 : 2.5}>
      <span style={{ display: "grid", placeItems: "center", width: size - 10, height: size - 10, borderRadius: "50%", background: large ? tint(accent, 0.18) : "transparent", color: accent }}>
        <Icon size={Math.round(size * (large ? 0.42 : 0.5))} />
      </span>
    </ProgressRing>
  );
};
