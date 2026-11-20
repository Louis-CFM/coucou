"use client";

import type { CSSProperties, ReactNode } from "react";

import { type CompactContent, IslandNumber, useIslandReducedMotion } from "@/lib/island";

import { IslandStyle } from "./island-style";
import { SteadyNumber } from "./steady-number";
import { islandFont, islandInk, islandLine, islandSize, trackingFor } from "./theme";

interface TextProps {
  children: ReactNode;
  /** Text colour. Defaults to white (secondary grey for `ExpandedSubtitle` and `Caption`). */
  color?: string;
  /** Extra styles, merged last. Defaults to none. */
  style?: CSSProperties;
}

const base: CSSProperties = {
  fontFamily: islandFont,
  margin: 0,
  whiteSpace: "nowrap",
  overflow: "hidden",
  textOverflow: "ellipsis",
  // Proportional figures: titles and file names keep their own spacing. Tabular figures widen a
  // hyphen to a digit's width in the fallback fonts ("launch - cut - v3.mov"), so only values that
  // change (`NumberText`, `TickingTime`, `tabularFigures`) turn them on.
  WebkitFontSmoothing: "antialiased",
};

/**
 * One line that ends in an ellipsis when it runs out of room, cut at a word: `text-overflow` cuts
 * at any character, and a cut that lands on a space set "to your …" with a gap before the dots. A
 * one-line clamp breaks the line between words, so the dots follow the last whole word ("to
 * your…"); a single word longer than the line still breaks inside itself.
 */
const oneLine: CSSProperties = {
  whiteSpace: "normal",
  overflowWrap: "break-word",
  display: "-webkit-box",
  WebkitLineClamp: 1,
  WebkitBoxOrient: "vertical",
};

/**
 * Seconds a changed digit takes to turn over in a value fed about once a second: a clock, or a
 * percentage that follows a transfer. A live status number turns in about 0.48 s, which suits
 * a value that changes now and then; fed every second it would be blurred half the time.
 */
export const feedTurn = 0.25;

/** Tabular figures, for a value whose digits change in place: it keeps its width as they turn. */
export const tabularFigures = { fontVariantNumeric: "tabular-nums" } as const satisfies CSSProperties;

/**
 * How a value's changed digits move. "live" (the default) is the engine's `IslandNumber`: the old
 * digit shrinks, blurs and fades, then the new one comes in, as a live status number does.
 * "steady" is `SteadyNumber`: the two overlap so one always reads, with a hair of blur, for a value
 * fed every second (a clock, a percentage) that a glance would otherwise catch half gone.
 * "none" replaces the text in place on each change.
 */
export type NumberMotion = "live" | "steady" | "none";

/**
 * A value whose changed digits turn over when it updates, like a live status activity's numbers, in
 * tabular figures so it keeps its width. With reduced motion it changes in place.
 */
export const NumberText = ({ value, style, turn, motion = "live" }: {
  /** The number, or text such as "4:07". Write a negative value with a minus sign (U+2212), not a hyphen. */
  value: number | string;
  /** Styles on the text. Defaults to none. */
  style?: CSSProperties;
  /** Seconds a changed digit takes to turn over in the "live" motion. Defaults to the measured turn (0.48 s). */
  turn?: number;
  /** How changed digits move. Defaults to "live". */
  motion?: NumberMotion;
}) => {
  const reduced = useIslandReducedMotion();
  const figures = { ...tabularFigures, ...style };
  // "none": a clock that simply changes, as the system's recorder does; any crossing showed two digits at once.
  if (reduced || motion === "none") return <span style={figures}>{value}</span>;
  return motion === "steady" ? <SteadyNumber value={value} style={figures} /> : <IslandNumber value={value} style={figures} turn={turn} />;
};

/** 15 pt semibold, the trailing text in compact and minimal. */
export const CompactText = ({ children, color = islandInk.primary, style }: TextProps) => (
  <span style={{ ...base, display: "block", fontSize: islandSize.compactText, fontWeight: 600, lineHeight: `${islandLine.compact}px`, color, ...style }}>
    {children}
  </span>
);

/**
 * Space between a value and its unit (px). A sign sits against the figure, as the reference phone
 * sets "42%"; a word keeps a narrow gap, as in "8 min". The 3 px a sign used to get, on top of the
 * figure's own side bearing, read as "42 %".
 */
const unitGap = (unit: ReactNode) => (typeof unit === "string" && !/\p{L}/u.test(unit) ? 0 : 3);

/** A unit that is a sign ("%", "°"), not a word: it sets at the figure's size, as "42%" does on the reference phone. */
const isSign = (unit: ReactNode) => typeof unit === "string" && !/\p{L}/u.test(unit);

/**
 * 34 pt bold, the big number in the expanded view. A word `unit` ("min") follows it in 17 pt
 * semibold; a sign ("%") is set at the figure's own size and weight, since a small sign beside a
 * large figure read as a footnote.
 */
export const ExpandedValue = ({ children, unit, color = islandInk.primary, style }: TextProps & {
  /** Smaller text after the number, such as "min". Defaults to none. */
  unit?: ReactNode;
}) => (
  <span
    style={{
      ...base,
      display: "block",
      fontSize: islandSize.expandedValue,
      fontWeight: 700,
      lineHeight: 1,
      // Clipped across only: a 34 pt figure's ink rises a little above its 1.0 line box.
      overflow: "clip visible",
      letterSpacing: trackingFor(islandSize.expandedValue),
      color,
      ...style,
    }}
  >
    {children}
    {unit === undefined ? null : isSign(unit) ? (
      <span style={{ marginLeft: "-0.04em" }}>{unit}</span>
    ) : (
      <span style={{ fontSize: islandSize.title, fontWeight: 600, letterSpacing: trackingFor(islandSize.title), marginLeft: unitGap(unit) }}>{unit}</span>
    )}
  </span>
);

/** 17 pt semibold, the expanded view's title. */
export const ExpandedTitle = ({ children, color = islandInk.primary, style }: TextProps) => (
  <span style={{ ...base, ...oneLine, fontSize: islandSize.title, fontWeight: 600, lineHeight: `${islandLine.title}px`, letterSpacing: trackingFor(islandSize.title), color, ...style }}>
    {children}
  </span>
);

/**
 * 15 pt medium in secondary grey: what a label-led view is doing ("Uploading", "Pickup"), beside
 * the sensor. A step lighter than the file or the person it is about, so it reads as context.
 */
export const ContextLabel = ({ children, color = islandInk.secondary, style }: TextProps) => (
  <span style={{ ...base, display: "block", minWidth: 0, fontSize: islandSize.subtitle, fontWeight: 500, lineHeight: `${islandLine.subtitle}px`, color, ...style }}>
    {children}
  </span>
);

/** 15 pt regular in secondary grey, under the title. */
export const ExpandedSubtitle = ({ children, color = islandInk.secondary, style }: TextProps) => (
  <span style={{ ...base, ...oneLine, fontSize: islandSize.subtitle, fontWeight: 400, lineHeight: `${islandLine.subtitle}px`, color, ...style }}>
    {children}
  </span>
);

/** 13 pt medium in secondary grey, for times and labels under bars. */
export const Caption = ({ children, color = islandInk.secondary, style }: TextProps) => (
  <span style={{ ...base, display: "block", fontSize: islandSize.caption, fontWeight: 500, lineHeight: `${islandLine.caption}px`, color, ...style }}>
    {children}
  </span>
);

/** Stacks a title and subtitle with the tight leading live status activities use. */
export const TitleStack = ({
  title,
  subtitle,
  align = "start",
  subtitleLines = 1,
  style,
}: {
  /** Main line. */
  title: ReactNode;
  /** Second line in grey. Defaults to none. */
  subtitle?: ReactNode;
  /** Horizontal alignment. Defaults to "start". */
  align?: "start" | "center";
  /** Lines the subtitle may wrap to before it truncates. Defaults to 1. */
  subtitleLines?: number;
  /** Extra styles. Defaults to none. */
  style?: CSSProperties;
}) => (
  <div style={{ display: "grid", gap: islandLine.stackGap, minWidth: 0, textAlign: align === "center" ? "center" : "left", ...style }}>
    <ExpandedTitle>{title}</ExpandedTitle>
    {subtitle === undefined ? null : (
      <ExpandedSubtitle
        style={subtitleLines > 1 ? { WebkitLineClamp: subtitleLines } : undefined}
      >
        {subtitle}
      </ExpandedSubtitle>
    )}
  </div>
);

/**
 * A glyph and a short value side by side, for `minimal`. On the reference phone the split shows each
 * activity's compact pair in its own capsule (measured: a 22 pt circle, then the value 7 pt after it).
 */
export const MinimalPair = ({ leading, trailing }: {
  /** The glyph, ring or art. */
  leading: ReactNode;
  /** A short value, three to five characters. */
  trailing: ReactNode;
}) => (
  <span style={{ display: "flex", alignItems: "center", gap: 7 }}>
    {leading}
    {trailing}
  </span>
);

const bubbleCss = `
.icn-in-pill { display: contents; }
.icn-in-bubble { display: none; }
[data-slot="splitDetachedLeading"] .icn-in-pill, [data-slot="splitDetachedTrailing"] .icn-in-pill { display: none; }
[data-slot="splitDetachedLeading"] .icn-in-bubble, [data-slot="splitDetachedTrailing"] .icn-in-bubble { display: contents; }
`;

/**
 * Compact content with another form for the split's bubble. When two activities run, the second
 * one's compact pair moves into a 62 pt capsule beside the pill, which cuts anything wider than
 * about 20 pt after the leading glyph: a countdown "4:31" reads "4…". `bubble` is what this slot
 * shows there instead (a ring, a glyph, a value that fits, or nothing); everywhere else, the pill
 * included, it shows `children`. An empty trailing slot gives a round bubble sized to the leading
 * content, the way a minimal view sits in its own circle.
 */
export const BubbleForm = ({ bubble, children }: {
  /** What the slot shows in the split's bubble. `null` leaves it empty there. */
  bubble: ReactNode;
  /** What it shows everywhere else. */
  children: ReactNode;
}) => (
  <>
    <IslandStyle id="bubble-form" css={bubbleCss} />
    <span className="icn-in-pill">{children}</span>
    <span className="icn-in-bubble">{bubble}</span>
  </>
);

/**
 * A compact pair whose split bubble shows `bubble` alone: the leading slot swaps to it and the
 * trailing one empties, so a long value never ends in an ellipsis there. Use the same node as the
 * activity's `minimal`, which the engine shows when the split doesn't fit at all.
 */
export const withBubble = (compact: CompactContent, bubble: ReactNode): CompactContent => ({
  leading: <BubbleForm bubble={bubble}>{compact.leading}</BubbleForm>,
  trailing: compact.trailing === undefined || compact.trailing === null ? compact.trailing : <BubbleForm bubble={null}>{compact.trailing}</BubbleForm>,
});

const swapCss = `
@keyframes icn-swap-in { from { opacity: 0; filter: blur(4px); transform: scale(0.9); } }
.icn-swap { display: inline-flex; animation: icn-swap-in 260ms cubic-bezier(0.2, 0, 0, 1); }
@media (prefers-reduced-motion: reduce) { .icn-swap { animation: none; } }
`;

/**
 * Blurs content in when `id` changes, inside one slot. For a whole new state, prefer the engine's
 * `update({ ..., transition: "crossfade" })`, which crossfades every slot with the island's own
 * timing; `Swap` is for one piece of content that changes while the rest stays. The old content
 * leaves at once, which reads as one morph. With reduced motion it swaps instantly.
 */
export const Swap = ({ id, children }: {
  /** Change it to play the swap. */
  id: string;
  children: ReactNode;
}) => {
  const reduced = useIslandReducedMotion();
  return (
    <span key={id} className={reduced ? undefined : "icn-swap"} style={reduced ? { display: "inline-flex" } : undefined}>
      <IslandStyle id="swap" css={swapCss} />
      {children}
    </span>
  );
};
