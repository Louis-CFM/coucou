"use client";

import type { CSSProperties, ReactNode } from "react";

import { continuousRectPath, islandMetrics } from "@/lib/island";

import { Avatar } from "./avatar";
import { Glyph, type GlyphIcon } from "./glyph";
import { ArrowUpGlyph, CheckGlyph } from "./glyphs";
import { IslandRoundButton } from "./island-button";
import { ExpandedSubtitle, ExpandedTitle, NumberText, tabularFigures } from "./island-text";
import { ProgressRing } from "./progress-ring";
import { continuousCorner, islandFont, islandInk, tint } from "./theme";

/*
 * The parts the upload and the nearby transfer share: a photo thumbnail, and the one-row expanded
 * view that a sharing activity uses, a picture on the leading side, two lines of text, and a large
 * ring on the trailing side (a posting app's upload ring, a nearby share's ring with its stop).
 */

const expanded = islandMetrics.expanded;
const trailingPad = expanded.padding.trailing ?? expanded.padding.side;

/**
 * The one-row expanded view, measured on a phone's incoming call (84 pt island) and a nearby
 * share's banner, which has the same height and the same leading picture. Insets are in pt from
 * the island's edges, rows from its top.
 */
export const mediaRow = {
  /** The island stays at its shortest, 84 pt: the row must fit the content box (84 less 36.53). */
  row: 47,
  /** The leading picture: 50 pt, 16.3 from the leading edge, centred 41.8 below the top. */
  lead: 50,
  leadInset: 16.3,
  /**
   * A photo there is 44 pt, centred in the 50 pt slot, with 16 pt continuous corners: concentric
   * enough with the island's corner that the engine's content clip (an arc 34.4 pt from the corner's
   * centre) leaves it whole. A 50 pt square with 12 pt corners reached 39 pt and lost its corners,
   * which is why a call's photo there is a circle.
   */
  photo: 44,
  photoRadius: 16,
  /** The trailing ring: 48 pt (a nearby share's ring), its centre where a call's accept button has its own. */
  ring: 48,
  ringThickness: 4,
  ringInset: 17.1,
  /** The percentage in the large ring: 17 pt semibold, as a posting app's lock screen ring sets it. */
  ringFigure: 17,
  /** The stop square in the large ring, in the ring's accent. */
  stop: 15,
  stopRadius: 3.5,
  /**
   * The text: a 14 pt grey line over a 17 pt white one, both starting 10 pt after the picture, at
   * the call's measured baselines (47.7 and 66.2 below the top). The grey line goes first because
   * the sensor's bottom edge is 36.9 below the top: a 17 pt line there would run its ascenders
   * under the sensor.
   */
  lineSize: 14,
  lineHeight: 18,
  lineLift: -4.5,
  titleLift: -2,
  textInset: -1.4,
  /** The center column's box: the text overflows it downward without making the island taller. */
  textBox: 27,
} as const satisfies Record<string, number>;

/**
 * The compact pair, measured on a posting app's compact island (3x capture): a 24 pt thumbnail
 * (23.7 measured, 6.3 from the pill's top and bottom) with corners of about 5, and a ring about
 * 20 pt across, 3 pt thick, with the percentage inside it in 9 pt figures.
 */
export const mediaCompact = {
  thumb: 24,
  thumbRadius: 5.5,
  /** In the split's bubble: the bubble leaves about 20 pt after a 22 pt leading picture. */
  bubbleThumb: 22,
  ring: 20,
  ringThickness: 2.6,
  figure: 9,
} as const satisfies Record<string, number>;

/** Lets the text take the whole center column, so it starts beside the picture (the engine centres narrower content). */
const fillCenter = { width: 640, maxWidth: "100%" } as const satisfies CSSProperties;

export interface ThumbnailProps {
  /** The photo. Without one, the tile shows `fallback` on a tint of the accent. Defaults to none. */
  src?: string;
  /** Size in pt. Defaults to 24, the compact thumbnail. */
  size?: number;
  /** Corner radius in pt. Defaults to about a fifth of the size. */
  radius?: number;
  /** The glyph a tile without a photo shows. Required. */
  fallback: GlyphIcon;
  /** Tint and glyph colour of a tile without a photo. Required. */
  accent: string;
}

/**
 * A photo thumbnail with continuous corners and a hairline keyline, as a sharing activity shows
 * what is being sent. Without a photo (or while it loads) it is a tile of the accent with a glyph.
 */
export const Thumbnail = ({ src, size = mediaCompact.thumb, radius = Math.round(size * 0.22 * 2) / 2, fallback, accent }: ThumbnailProps) => {
  const outline = continuousRectPath(0, 0, size, size, radius, islandMetrics.corner.smoothing);
  return (
    <span
      aria-hidden
      style={{ display: "grid", placeItems: "center", position: "relative", width: size, height: size, flex: "none", clipPath: continuousCorner(size, size, radius), background: tint(accent, 0.2) }}
    >
      <Glyph icon={fallback} color={accent} size={Math.round(size * 0.55)} />
      {src ? <span style={{ position: "absolute", inset: 0, background: `center / cover no-repeat url(${JSON.stringify(src)})` }} /> : null}
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={{ position: "absolute", inset: 0, display: "block" }}>
        <path d={outline} fill="none" stroke="rgba(255, 255, 0.14)" strokeWidth={1} />
      </svg>
    </span>
  );
};

export interface MediaLeadProps {
  /** The picture: a 44 pt photo, or a 50 pt avatar or device. Required. */
  children: ReactNode;
}

/** The leading side of the one-row view: a 50 pt slot out toward the corner, its picture centred in it and on the row. */
export const MediaLead = ({ children }: MediaLeadProps) => (
  <div style={{ display: "flex", alignItems: "center", justifyContent: "center", width: mediaRow.lead, height: mediaRow.row, marginLeft: mediaRow.leadInset - expanded.padding.side }}>
    {children}
  </div>
);

export interface MediaTextProps {
  /** The 14 pt grey line on top, such as a file name. Required. */
  line: ReactNode;
  /** The 17 pt white line under it, such as "Uploading to Family album". Required. */
  title: ReactNode;
}

/**
 * The text of the one-row view: a grey line (what it is) over a white one (what is happening),
 * in a box that ends inside the row so the second line doesn't make the island taller.
 */
export const MediaText = ({ line, title }: MediaTextProps) => (
  <div style={{ ...fillCenter, height: mediaRow.textBox, minWidth: 0, textAlign: "left", marginLeft: mediaRow.textInset }}>
    <ExpandedSubtitle style={{ fontSize: mediaRow.lineSize, lineHeight: `${mediaRow.lineHeight}px`, marginTop: mediaRow.lineLift }}>{line}</ExpandedSubtitle>
    <ExpandedTitle style={{ marginTop: mediaRow.titleLift }}>{title}</ExpandedTitle>
  </div>
);

export interface MediaTrailProps {
  /** A `mediaRow.ring` pt ring, button or check. Required. */
  children: ReactNode;
}

/** The trailing side of the one-row view: the large ring, centred on the row. */
export const MediaTrail = ({ children }: MediaTrailProps) => <div style={{ display: "flex", alignItems: "center", height: mediaRow.row, marginRight: mediaRow.ringInset - trailingPad }}>{children}</div>;

const figureStyle = (size: number): CSSProperties => ({
  display: "block",
  fontFamily: islandFont,
  fontSize: size,
  fontWeight: 600,
  lineHeight: 1,
  color: islandInk.primary,
  WebkitFontSmoothing: "antialiased",
});

export interface CountRingProps {
  /** Progress from 0 to 1. Required. */
  value: number;
  /** Ring colour. Required. */
  accent: string;
  /** Outer size in pt. Defaults to 20, the compact ring. */
  size?: number;
}

/**
 * A ring with the percentage inside it, as a posting app draws its upload: about 20 pt in
 * compact with 9 pt figures, 48 pt in the expanded view with 17 pt ones.
 */
export const CountRing = ({ value, accent, size = mediaCompact.ring }: CountRingProps) => {
  const large = size > 30;
  const percent = Math.floor(Math.min(1, Math.max(0, value)) * 100);
  return (
    <ProgressRing value={value} color={accent} track={tint(accent, 0.22)} size={size} thickness={large ? mediaRow.ringThickness : mediaCompact.ringThickness}>
      <NumberText value={percent} motion={large ? "steady" : "none"} style={figureStyle(large ? mediaRow.ringFigure : mediaCompact.figure)} />
    </ProgressRing>
  );
};

export interface DoneDiscProps {
  /** Disc colour. Required. */
  accent: string;
  /** Size in pt. Defaults to 20, the compact ring. */
  size?: number;
}

/** The finished state: a disc of the accent with a white check, where the ring was, so the activity reads as done. */
export const DoneDisc = ({ accent, size = mediaCompact.ring }: DoneDiscProps) => (
  <span aria-hidden style={{ display: "grid", placeItems: "center", width: size, height: size, flex: "none", borderRadius: "50%", background: accent }}>
    <Glyph icon={CheckGlyph} color={islandInk.primary} size={Math.round(size * 0.62)} />
  </span>
);

export interface StopSquareProps {
  /** Square colour. Required. */
  accent: string;
  /** Side in pt. Defaults to 15. */
  size?: number;
}

/** The stop square a nearby share puts in its ring, in the ring's accent. */
export const StopSquare = ({ accent, size = mediaRow.stop }: StopSquareProps) => <span aria-hidden style={{ display: "block", width: size, height: size, borderRadius: mediaRow.stopRadius, background: accent }} />;

export interface MediaLineProps {
  /** The file or item name. Required. */
  name: string;
  /** What follows it after a dot. Defaults to none (the name alone). */
  detail?: string;
}

/**
 * The grey line's two parts: a name that gives way first, with an ellipsis, and a detail after it
 * ("2.5 of 6 MB", "42%") that always shows whole.
 */
export const MediaLine = ({ name, detail }: MediaLineProps) =>
  detail === undefined || detail === "" ? (
    name
  ) : (
    <span style={{ display: "flex", minWidth: 0 }}>
      <span style={{ minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{name}</span>
      <span style={{ ...tabularFigures, flex: "none", whiteSpace: "pre" }}>{` · ${detail}`}</span>
    </span>
  );

/**
 * What the ring holds while it runs: the percentage (a posting app's upload), a stop square (a
 * nearby share that can be cancelled), an arrow for the direction, or nothing. In compact only
 * "count" draws inside the ring; the others are a plain ring there, as a nearby share's is.
 */
export type ShareMark = "count" | "stop" | "up" | "down" | "none";

/** The arrow in the large ring: 20 pt in the ring's accent. */
const arrowSize = 20;

export interface ShareRingProps {
  /** Progress from 0 to 1. At 1 it shows the check. Required. */
  value: number;
  /** Ring, mark and check colour. Required. */
  accent: string;
  /** What the ring holds while it runs. Defaults to "none". */
  mark?: ShareMark;
  /** Outer size in pt: 20 in compact, `mediaRow.ring` (48) beside the sensor. Defaults to 20. */
  size?: number;
  /** With mark "stop", what pressing the ring does. Without it the square is only drawn. Defaults to none. */
  onStop?: () => void;
  /** Spoken name of the stop button. Defaults to "Stop". */
  stopLabel?: string;
}

/**
 * A sharing activity's ring, 20 pt in compact and 48 pt in the expanded view: it fills with the
 * progress and turns into a disc with a check at 1, so the activity reads as finished.
 */
export const ShareRing = ({ value, accent, mark = "none", size = mediaCompact.ring, onStop, stopLabel = "Stop" }: ShareRingProps) => {
  if (value >= 1) return <DoneDisc accent={accent} size={size} />;
  const large = size > 30;
  if (mark === "count") return <CountRing value={value} accent={accent} size={size} />;
  const inside =
    !large || mark === "none" ? null : mark === "stop" ? (
      <StopSquare accent={accent} />
    ) : (
      <span style={{ display: "grid", transform: mark === "down" ? "rotate(180deg)" : undefined }}>
        <ArrowUpGlyph size={arrowSize} color={accent} />
      </span>
    );
  const ring = (
    <ProgressRing value={value} color={accent} track={tint(accent, 0.22)} size={size} thickness={large ? mediaRow.ringThickness : mediaCompact.ringThickness}>
      {inside}
    </ProgressRing>
  );
  if (mark !== "stop" || onStop === undefined) return ring;
  return (
    <IslandRoundButton label={stopLabel} color="transparent" size={size} onPress={onStop}>
      {ring}
    </IslandRoundButton>
  );
};

/**
 * The badge on a share's picture, as a nearby share draws its banner: what is being sent on the
 * picture's lower trailing corner, cut out of it by a ring of the island's black.
 */
const badge = {
  size: 26,
  radius: 6.5,
  /** How far the badge hangs past the picture's edge, to the right and down. */
  overhang: 3,
  /** The black ring that separates the badge from the picture under it. */
  keyline: 2,
} as const satisfies Record<string, number>;

export interface SharePictureProps {
  /** The device's glyph, shown when there is no `person` photo. Required. */
  icon: GlyphIcon;
  /** The disc's colour. Required. */
  accent: string;
  /** Size in pt: 22 in compact, `mediaRow.lead` (50) beside the sensor. Defaults to 22. */
  size?: number;
  /** A thumbnail of what is being sent, for the badge. Defaults to none (no badge). */
  src?: string;
  /** The other person, drawn in place of the device. Defaults to none. */
  person?: { name: string; src?: string };
}

/**
 * Who a share goes to (or comes from): their photo, or a device's glyph in the accent.
 * At the expanded size (from 30 pt) a `src` sets what is being sent on its corner as a badge.
 */
export const SharePicture = ({ icon, accent, size = mediaCompact.bubbleThumb, src, person }: SharePictureProps) => {
  // The device as a nearby share draws it: the glyph in the accent, on a faint disc of it beside
  // the sensor and bare in compact, where it is the size of any compact glyph. A filled tile would
  // read as an app's icon.
  const device =
    size <= 30 ? (
      <Glyph icon={icon} color={accent} size={size} />
    ) : (
      <span style={{ display: "grid", placeItems: "center", width: size, height: size, borderRadius: "50%", background: tint(accent, 0.2) }}>
        <Glyph icon={icon} color={accent} size={Math.round(size * 0.52)} />
      </span>
    );
  const picture = person === undefined ? device : <Avatar name={person.name} src={person.src} size={size} />;
  if (size <= 30 || src === undefined) return picture;
  return (
    <span style={{ position: "relative", display: "block", width: size, height: size }}>
      {picture}
      <span
        style={{
          position: "absolute",
          right: -badge.overhang - badge.keyline,
          bottom: -badge.overhang - badge.keyline,
          padding: badge.keyline,
          background: "#000",
          borderRadius: badge.radius + badge.keyline,
        }}
      >
        <Thumbnail src={src} size={badge.size} radius={badge.radius} fallback={icon} accent={accent} />
      </span>
    </span>
  );
};
