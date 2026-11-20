import type { CSSProperties, ReactNode } from "react";

import { islandMetrics } from "@/lib/island";

import { islandBaseline, islandFont, islandLine, islandRow, islandSafe, islandSize } from "./theme";

interface ExpandedBottomProps {
  children: ReactNode;
  /**
   * What reaches the island's bottom corners. "none": nothing does (a centred row, or a bar the
   * arc may cut as on the reference phone). "inset": a row with marks at both ends (a route, a meter, a bar and a
   * caption), pulled in from the sides until its bottom corners clear the arc, so it stays on the
   * bottom line instead of rising. "lift": a full-width row of text, raised until its corners
   * clear the arc. "action": a row of 44 pt controls (capsules or circles); the whole region is
   * inset so their ends are concentric with the corners, and rows above share that left edge.
   * Defaults to "none".
   */
  reach?: "none" | "inset" | "lift" | "action";
  /** Space between rows in pt. Defaults to 8. */
  gap?: number;
  /** Extra styles, merged last. Defaults to none. */
  style?: CSSProperties;
}

const expanded = islandMetrics.expanded;
/** The island's bottom corner centres, measured from the expanded content box's bottom corners. */
const corner = {
  leading: expanded.radius - expanded.padding.side,
  trailing: expanded.radius - (expanded.padding.trailing ?? expanded.padding.side),
  y: expanded.radius - expanded.padding.bottom,
};
/** The content clip's corner arc, less 1 pt so sub-pixel layout never touches it (as `islandSafe`). */
const clipReach = islandMetrics.contentClip.radius - 1;
/** Half the arc's chord on the content box's bottom line: how far in from a corner centre a box corner may sit there. */
const bottomChord = Math.sqrt(Math.max(0, clipReach ** 2 - corner.y ** 2));

/**
 * Side insets that keep a bottom row's lower corners inside the clip arc while the row sits on the
 * content box's bottom edge (13.8 on the leading side, 14.5 on the trailing one). Lifting the row
 * clear instead costs 13.7 pt of height, a whole extra line on a 104 pt island.
 */
export const bottomInset = {
  leading: Math.max(0, corner.leading - bottomChord),
  trailing: Math.max(0, corner.trailing - bottomChord),
} as const;

/**
 * How far to move a round control of `size` pt in from the trailing side and up from the bottom
 * (the same amount both ways) so the whole circle stays inside the bottom-trailing corner's clip
 * arc. A 36 pt button needs 1 pt and a 22 pt one 3; a 44 pt one, nearly concentric with the corner, none.
 */
export const cornerClearance = (size: number): number => {
  const a = corner.trailing - size / 2;
  const b = corner.y - size / 2;
  const reach = clipReach - size / 2;
  if (a * a + b * b <= reach * reach) return 0;
  // Smallest t with (a - t)^2 + (b - t)^2 <= reach^2: move the centre along the diagonal.
  const sum = a + b;
  return Math.ceil(((sum - Math.sqrt(Math.max(0, sum * sum - 2 * (a * a + b * b - reach * reach)))) / 2) * 10) / 10;
};

/**
 * How far to move a round control of `size` pt in from the trailing side, with its foot left on the
 * bottom line (18.35 pt from the island's edge), so the whole circle stays inside the corner's clip
 * arc. A 26 pt button needs about 5.2. Moving only sideways keeps the bottom row on the same line as
 * every other expanded view, where `cornerClearance` lifts it and leaves more space below than above.
 */
export const cornerSideClearance = (size: number): number => {
  const a = corner.trailing - size / 2;
  const b = Math.max(0, corner.y - size / 2);
  const reach = clipReach - size / 2;
  return Math.max(0, Math.ceil((a - Math.sqrt(Math.max(0, reach * reach - b * b))) * 10) / 10);
};

const reachPadding = {
  none: {},
  inset: { paddingLeft: bottomInset.leading, paddingRight: bottomInset.trailing },
  lift: { paddingBottom: islandSafe.lift, paddingRight: islandSafe.mirror },
  action: { paddingLeft: islandSafe.action.leading, paddingRight: islandSafe.action.trailing, paddingBottom: islandSafe.action.bottom },
} as const satisfies Record<NonNullable<ExpandedBottomProps["reach"]>, CSSProperties>;

/**
 * The root of an expanded view's `bottom` region. The region spans the island's full width, but
 * its content would also widen the side columns of the row above (a long meter or a row of
 * buttons squeezes the title to a few letters), so it takes no say in their width.
 *
 * Its one column is `minmax(0, 1fr)`: an implicit grid column grows to its rows' min-content
 * width, so on a narrow phone a row of a meter and two buttons would run past the island's edge
 * and push the last button out of the clip. Rows get exactly the island's width instead.
 */
export const ExpandedBottom = ({ children, reach = "none", gap = 8, style }: ExpandedBottomProps) => (
  <div style={{ display: "grid", gridTemplateColumns: "minmax(0, 1fr)", gap, minWidth: 0, contain: "inline-size", ...reachPadding[reach], ...style }}>
    {children}
  </div>
);

interface ExpandedSideProps {
  children: ReactNode;
  /**
   * Height of the frame in pt: the content's own height (48 for an avatar or a round button, 34 for
   * a big value), or more for content of mixed heights. The content is centred in it. Defaults to
   * `islandSize.expandedTile` (52), so anything up to a tile's height centres on `line`.
   */
  height?: number;
  /**
   * The row line, in pt below the content top, that the frame's centre sits on. The expanded row is
   * top-aligned, so without a frame leading and trailing content starts at the top while a title
   * starts below the sensor. Use `islandRow.stackLine` beside a title and subtitle,
   * `islandRow.titleLine` beside a one-line title, or half a neighbour's height (24 beside 48 pt
   * buttons). A frame never starts above the content top. Defaults to none: the frame starts at the
   * content top, beside the sensor, the way the system lays out an expanded island's side regions
   * (Leo, 2026-11-08: no empty band above the leading and trailing content).
   */
  line?: number;
  /** Which side of the sensor it sits on, so narrow content keeps to the outer edge. Defaults to "start". */
  align?: "start" | "end";
}

interface ValueStackProps {
  /** The big value, usually `ExpandedValue`. */
  value: ReactNode;
  /** A short line under it, usually a `Caption` such as "20 of 48 MB". Defaults to none. */
  caption?: ReactNode;
  /**
   * Nothing sits below the top row (no bottom region). The island is then one row tall, the
   * caption's line falls below the bottom corner's centre, and the arc would cut its last letters,
   * so the caption moves in just far enough to clear it. Defaults to false.
   */
  alone?: boolean;
  /**
   * With no caption, the row line the value centres on (see `ExpandedSide`). Defaults to none: the
   * value starts at the content top.
   */
  line?: number;
}

/*
 * With a caption the stack lines up with a `TitleStack` beside it by baseline: the value's
 * baseline on the title's (37.07) and the caption's on the subtitle's (59.07), as a live status activity's
 * trailing figure and its detail read across the row.
 */
const valueTop = islandRow.titleBaseline - islandBaseline.value;
const captionTop = islandRow.subtitleBaseline - islandBaseline.caption;
const captionGap = captionTop - (valueTop + islandSize.expandedValue);

/**
 * How far a caption on the subtitle's line moves in from the trailing edge on a one-row island
 * (about 12 pt): its bottom corner then sits on the clip arc's inner edge, 1 pt inside it. The row is
 * as tall as a tile centred on the title stack beside it.
 */
const aloneCaptionInset = (() => {
  const row = Math.max(islandRow.titleStack, islandRow.stackLine + islandSize.expandedTile / 2);
  const height = expanded.padding.top + row + expanded.padding.bottom;
  const cornerY = height - expanded.radius - expanded.padding.top;
  const dy = captionTop + islandLine.caption - cornerY;
  return Math.max(0, Math.ceil((corner.trailing - Math.sqrt(Math.max(0, clipReach ** 2 - dy ** 2))) * 10) / 10);
})();

/** The top margin that puts a frame of `height` centred on `line`, never above the content top. */
const rowOffset = (line: number, height: number) => Math.max(0, Math.round((line - height / 2) * 100) / 100);

/**
 * The trailing region's big value with a caption under it. The value's baseline sits on the title's
 * and the caption's on the subtitle's line of a `TitleStack` beside it, so a detail that would
 * otherwise need its own row under the bar shares the top row, as live status activities pack it. With no
 * caption the value centres on `line`, level with the tile and the title stack beside it.
 */
export const ValueStack = ({ value, caption, alone = false, line }: ValueStackProps) =>
  caption === undefined ? (
    <ExpandedSide height={islandSize.expandedValue} line={line} align="end">
      {value}
    </ExpandedSide>
  ) : (
    <div
      style={{
        display: "grid",
        justifyItems: "end",
        // The value starts at the content top beside the sensor, like the leading side; the caption follows it.
        rowGap: captionGap,
        minWidth: 0,
        textAlign: "right",
      }}
    >
      {value}
      <span style={{ display: "block", minWidth: 0, paddingRight: alone ? aloneCaptionInset : 0 }}>{caption}</span>
    </div>
  );

interface CaptionButtonProps {
  /** The word, such as "Cancel". */
  children: ReactNode;
  /** Accessible name when the word alone isn't enough, such as "Cancel transfer to Maya's Laptop". Defaults to the word. */
  label?: string;
  /** Text colour, usually the activity's accent. Required. */
  color: string;
  /** Called on click, tap, Enter or Space. */
  onPress: () => void;
}

/** How far the touch area reaches past the 16 pt caption line on each side, so it is 44 pt tall. */
const captionHit = { y: (islandSize.button - islandLine.caption) / 2, x: 12 } as const;

/**
 * A one-word action on a caption line, such as Cancel under a percentage in `ValueStack`. It reads
 * as a caption in the accent and needs no row of its own; its touch area reaches 14 pt above and
 * below the line (44 pt in all) and 12 pt to each side, past what it draws.
 */
export const CaptionButton = ({ children, label, color, onPress }: CaptionButtonProps) => (
  <button
    type="button"
    aria-label={label}
    // Presses inside island content must not reach the island's own long-press handling.
    onPointerDown={(event) => event.stopPropagation()}
    onClick={(event) => {
      event.stopPropagation();
      onPress();
    }}
    style={{
      position: "relative",
      appearance: "none",
      border: 0,
      margin: 0,
      padding: 0,
      background: "none",
      color,
      font: `600 ${islandSize.caption}px/${islandLine.caption}px ${islandFont}`,
      cursor: "pointer",
      WebkitTapHighlightColor: "transparent",
    }}
  >
    <span aria-hidden style={{ position: "absolute", inset: `${-captionHit.y}px ${-captionHit.x}px` }} />
    {children}
  </button>
);

/**
 * A fixed-height frame for the expanded view's leading or trailing region, centred on a row line
 * (`line`), so side content sits level with the title beside it and with the other side.
 */
export const ExpandedSide = ({ children, height = islandSize.expandedTile, line, align = "start" }: ExpandedSideProps) => (
  <div style={{ display: "flex", alignItems: "center", justifyContent: align === "end" ? "flex-end" : "flex-start", height, marginTop: line === undefined ? 0 : rowOffset(line, height) }}>
    {children}
  </div>
);

/**
 * A glyph and a short label for the leading or trailing region of the expanded view, which sit
 * beside the sensor. The label ends in an ellipsis before it can slide under the sensor.
 */
export const SensorSide = ({ glyph, children, color, align = "start", inset = false }: {
  /** A 22 pt glyph before the label. Defaults to none. */
  glyph?: ReactNode;
  /** The label, usually `CompactText`. */
  children?: ReactNode;
  /** Label colour, passed through `color`. Defaults to inheriting. */
  color?: string;
  /** Which side of the sensor it sits on. Defaults to "start". */
  align?: "start" | "end";
  /** Line up with an `ExpandedBottom reach="action"` below it, and keep clear of the top corner's arc. Defaults to false. */
  inset?: boolean;
}) => (
  <span
    style={{
      display: "flex",
      alignItems: "center",
      justifyContent: align === "end" ? "flex-end" : "flex-start",
      gap: 7,
      maxWidth: islandSafe.besideSensor - (inset ? islandSafe.action[align === "end" ? "trailing" : "leading"] : 0),
      minWidth: 0,
      marginLeft: inset && align === "start" ? islandSafe.action.leading : 0,
      marginRight: inset && align === "end" ? islandSafe.action.trailing : 0,
      paddingTop: inset ? islandSafe.drop : 0,
      color,
    }}
  >
    {glyph}
    {children === undefined ? null : <span style={{ minWidth: 0, overflow: "hidden" }}>{children}</span>}
  </span>
);

/** The label row beside the sensor in the label-led views, as tall as their 26 pt cancel button. */
export const sensorRowHeight = 26;

/**
 * The row beside the sensor in a label-led view (upload, transfer, battery, ride): a glyph and a
 * `ContextLabel` on the leading side, a small control or a time on the trailing one. One height
 * whether or not a control is there, and both sides centred on it, so a cancel button sits level
 * with the label instead of hanging below it. The trailing side keeps clear of the top corner's arc
 * by moving in, never down.
 */
export const SensorRow = ({ children, glyph, align = "start" }: {
  /** The label, a control or a time. */
  children: ReactNode;
  /** A glyph before the label, about 18 pt. Defaults to none. */
  glyph?: ReactNode;
  /** Which side of the sensor it sits on. Defaults to "start". */
  align?: "start" | "end";
}) => (
  <div
    style={{
      display: "flex",
      alignItems: "center",
      justifyContent: align === "end" ? "flex-end" : "flex-start",
      gap: 7,
      height: sensorRowHeight,
      maxWidth: islandSafe.besideSensor,
      minWidth: 0,
      paddingRight: align === "end" ? islandSafe.action.trailing : 0,
    }}
  >
    {glyph}
    {/* No clipping here: a 26 pt button's 44 pt touch area and its focus ring reach past it. A label truncates itself. */}
    <span style={{ display: "flex", minWidth: 0 }}>{children}</span>
  </div>
);

/**
 * The bar at the foot of a label-led view, pulled in at both ends just far enough that the bottom
 * corners' arcs leave its round ends whole, so the view keeps the engine's own bottom padding
 * instead of lifting every row to clear them.
 */
export const BottomBar = ({ children }: { children: ReactNode }) => (
  <div style={{ paddingLeft: bottomInset.leading, paddingRight: bottomInset.trailing, paddingTop: 4 }}>{children}</div>
);

