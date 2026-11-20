import { continuousRectPath, islandMetrics } from "@/lib/island";

/** System font first, so each platform gets its own UI font; Inter or Geist elsewhere. */
export const islandFont = '-apple-system, BlinkMacSystemFont, "Inter", "Geist", system-ui, sans-serif';

/** For commands and paths in the agent preset. */
export const islandMono = 'ui-monospace, "Geist Mono", "JetBrains Menlo, Consolas, monospace';

/**
 * One accent per activity. These are tuned to read on the black island (high chroma, light
 * enough for 15 pt text at AA contrast on #000).
 */
export const islandAccent = {
  /** islandcn's own colour, used by the agent preset. */
  lagoon: "#46f0c6",
  green: "#32d74b",
  red: "#ff453a",
  orange: "#ff9f0a",
  yellow: "#ffd60a",
  blue: "#0a84ff",
  sky: "#64d2ff",
  pink: "#ff375f",
  purple: "#bf5af2",
} as const satisfies Record<string, string>;

export type IslandAccentName = keyof typeof islandAccent;

/** Neutral ink on the black island. */
export const islandInk = {
  primary: "#ffffff",
  /** Subtitles and units. */
  secondary: "rgba(235, 235, 245, 0.62)",
  /** Hints and disabled text. */
  tertiary: "rgba(235, 235, 245, 0.36)",
  /** Unfilled part of rings and bars. */
  track: "rgba(255, 255, 0.16)",
  /** Background of neutral buttons. */
  fill: "rgba(255, 255, 0.14)",
  /** Background of neutral buttons while pressed. */
  fillPressed: "rgba(255, 255, 0.24)",
} as const satisfies Record<string, string>;

export const islandSize = {
  /** Leading glyph in compact and minimal: concentric with the pill ends (7.33 pt inset). */
  compactGlyph: 22,
  /** Trailing text in compact. */
  compactText: 15,
  /** Leading tile in the expanded view. */
  expandedTile: 52,
  /** Corner of the expanded tile. */
  expandedTileRadius: 12,
  /** Big trailing numbers in the expanded view. */
  expandedValue: 34,
  /** Expanded title. */
  title: 17,
  /** Expanded subtitle. */
  subtitle: 15,
  /** Small captions under bars. */
  caption: 13,
  /** Pill buttons in the expanded view. */
  button: 44,
} as const satisfies Record<string, number>;

/** Line heights of the text styles in `island-text.tsx`, so layouts can add up a row's height. */
export const islandLine = {
  compact: 20,
  title: 22,
  subtitle: 20,
  caption: 16,
  /** Gap between a title and its subtitle in `TitleStack`. */
  stackGap: 1,
} as const satisfies Record<string, number>;

const expanded = islandMetrics.expanded;
/**
 * Where the expanded view's center region starts, below the content top (20.07). The engine puts
 * it under the sensor's bottom edge, as ActivityKit does, while leading and trailing start at the
 * top: the same sum as the engine's layout.
 */
const centerTop =
  Math.max(0, islandMetrics.top + islandMetrics.idle.height - (expanded.top + expanded.padding.top)) + expanded.centerTop;

/**
 * Where each text style's baseline sits below the top of its line box, in pt. Measured in Chrome
 * on macOS with the system font (a zero-size inline marker on the baseline, and canvas metrics:
 * ascent 33 and descent 7 at 34 pt, so a 1.0 line box puts the 34 pt baseline at 30).
 */
export const islandBaseline = {
  title: 17,
  subtitle: 16,
  value: 30,
  caption: 13,
} as const satisfies Record<string, number>;

/**
 * Lines and depths in the expanded view's top row, in pt below the content top. The row is
 * top-aligned (leading and trailing start at the top, the center region below the sensor), so
 * leading and trailing content sits level with the center through an `ExpandedSide` frame centred
 * on one of these lines, as reference 2's tile and value share a centre with its title.
 */
export const islandRow = {
  /** Down to the bottom of a two-line `TitleStack` in the center region (63.07). */
  titleStack: centerTop + islandLine.title + islandLine.stackGap + islandLine.subtitle,
  /** Down to the bottom of a one-line `ExpandedSubtitle` in the center region (40.07). */
  subtitle: centerTop + islandLine.subtitle,
  /** Where the center region starts below the content top (20.07). */
  centerTop,
  /**
   * The centre of a title and subtitle in the center region (41.57). On the Mac the stack's ink, from
   * the title's cap top to the subtitle's baseline, centres within 0.3 pt of it.
   */
  stackLine: centerTop + (islandLine.title + islandLine.stackGap + islandLine.subtitle) / 2,
  /** The centre of a one-line title in the center region (31.07). */
  titleLine: centerTop + islandLine.title / 2,
  /** The centre of a one-line subtitle in the center region (30.07). */
  subtitleLine: centerTop + islandLine.subtitle / 2,
  /** The title's baseline (37.07): a big value with a caption under it sits its own baseline here. */
  titleBaseline: centerTop + islandBaseline.title,
  /** The subtitle's baseline under a title (59.07): the caption under a big value sits on it. */
  subtitleBaseline: centerTop + islandLine.title + islandLine.stackGap + islandBaseline.subtitle,
} as const satisfies Record<string, number>;
/**
 * The expanded content frame's side insets. The engine insets it 18.5 pt on the leading side and
 * 17.81 on the trailing one, as the simulator does (`padding.trailing` falls back to `side`).
 */
const leadingPad = expanded.padding.side;
const trailingPad = expanded.padding.trailing ?? expanded.padding.side;
/** The island's corner centres, measured from the expanded content box's bottom corners. */
const cornerFromContent = {
  leading: expanded.radius - leadingPad,
  trailing: expanded.radius - trailingPad,
  y: expanded.radius - expanded.padding.bottom,
};
/** Clearance kept between a box corner and the clip arc, so sub-pixel layout never touches it. */
const clearance = 1;
const clipReach = islandMetrics.contentClip.radius - clearance;

/**
 * Where expanded content can sit without the island's corner cutting it. The engine clips content
 * to an arc of `contentClip.radius` (34.4) about each corner centre, as the simulator does, so
 * anything that reaches a bottom corner at the standard padding loses its corner. These insets are
 * derived from `islandMetrics`, so they follow the engine's geometry.
 */
export const islandSafe = {
  /**
   * Insets of a bottom row of 44 pt controls from the content box: 7.4 on the leading side, 8.09
   * on the trailing one (the content frame is 0.69 nearer the trailing edge), and 7.85 up. The
   * capsule ends then share their centre with the island's corner arcs, so their gap to the
   * island edge is the same all the way round (47.9 - 22 = 25.9).
   */
  action: {
    leading: cornerFromContent.leading - islandSize.button / 2,
    trailing: cornerFromContent.trailing - islandSize.button / 2,
    bottom: cornerFromContent.y - islandSize.button / 2,
  },
  /**
   * How far to lift a full-width bottom row (13.7) so its square corners clear the clip arc while
   * its left edge stays aligned with the content above it. The row also takes `mirror` on its
   * trailing side, so both its corners sit the same way in theirs.
   */
  lift: cornerFromContent.y - Math.sqrt(clipReach ** 2 - cornerFromContent.leading ** 2),
  /** Extra trailing padding (0.69) that gives a row the leading side's inset on both sides. */
  mirror: leadingPad - trailingPad,
  /**
   * How far below the content top a row beside the sensor starts when it is inset by
   * `action.leading` or `action.trailing` (4), so its square corners clear the top corners' arcs.
   * The same on both sides: each inset puts the row's corner 22 from its corner centre.
   */
  drop: Math.ceil(expanded.radius - expanded.padding.top - Math.sqrt(clipReach ** 2 - (islandSize.button / 2) ** 2)),
  /**
   * Widest leading or trailing content that stays clear of the sensor beside it on the narrowest
   * common phone (375 pt): half the expanded width, less the sensor's half and the wider (leading)
   * padding.
   */
  besideSensor: Math.floor((375 - 2 * expanded.sideInset - islandMetrics.idle.width) / 2 - Math.max(leadingPad, trailingPad)) - 4,
} as const;

/**
 * Letter spacing in pt for system-font text at the sizes the island uses. The simulator's text
 * runs a little tighter than a browser's at 17, 20 and 34 pt (measured on the reference app's
 * title, wide time and big number); 13 and 15 pt match as they are.
 */
export const islandTracking = {
  13: 0,
  15: 0,
  17: -0.045,
  20: -0.11,
  34: -0.09,
} as const satisfies Record<number, number>;

const trackingTable: Readonly<Record<number, number | undefined>> = islandTracking;

/** `islandTracking` for a font size in pt, 0 for sizes it doesn't list. */
export const trackingFor = (size: number): number => trackingTable[size] ?? 0;

/**
 * A `clip-path` that cuts a `width` by `height` box to the island's continuous corner (radius
 * `radius`, the island's own smoothing), the shape the reference phone gives its rounded squares. A plain
 * `border-radius` draws a circular corner, which reads rounder at the shoulders.
 */
export const continuousCorner = (width: number, height: number, radius: number): string =>
  `path("${continuousRectPath(0, 0, width, height, radius, islandMetrics.corner.smoothing)}")`;

/** Mixes an accent with transparency: `tint("#ff9f0a", 0.2)`. Accepts #rgb and #rrggbb. */
export const tint = (hex: string, alpha: number): string => {
  const match = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(hex);
  if (!match?.[1]) return hex;
  const digits = match[1].length === 3 ? [...match[1]].map((d) => d + d).join("") : match[1];
  const value = Number.parseInt(digits, 16);
  const r = (value >> 16) & 255;
  const g = (value >> 8) & 255;
  const b = value & 255;
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
};
