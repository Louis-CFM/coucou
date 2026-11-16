import type { IslandMetrics } from "./metrics";
import type { ShapeTransition } from "./motion";
import type { PresentationKind } from "./types";

/**
 * Where the shape is heading. x values are offsets from the screen's centre line, so the
 * sensor area always sits at 0; y values are from the top of the screen.
 */
export interface ShapeTarget {
  left: number;
  right: number;
  top: number;
  height: number;
  radius: number;
  /** Detached capsule edges. When there is none they sit inside the pill's trailing end. */
  bubbleLeft: number;
  bubbleRight: number;
  /** Detached capsule height. 0 when there is no second activity. */
  bubbleHeight: number;
}

/** Natural content widths the shape has to fit, measured from the DOM. */
export interface ContentMeasure {
  leading: number;
  trailing: number;
  /** Minimal content shown in the attached pill (the fallback split). */
  attached: number;
  /** Minimal content shown in the detached capsule (the fallback split). */
  detached: number;
  /** The iOS 27 split: compact content of the attached and the detached activity. */
  split: { attached: SlotPair; detached: SlotPair } | null;
  /** Height of the expanded regions laid out at the expanded width, without padding. */
  expandedHeight: number;
}

export interface SlotPair {
  leading: number;
  trailing: number;
}

export const emptyMeasure: ContentMeasure = { leading: 0, trailing: 0, attached: 0, detached: 0, split: null, expandedHeight: 0 };

const clamp = (value: number, min: number, max: number) => Math.min(max, Math.max(min, value));

/** The width the island lays out against: the container, but never wider than a phone. */
export const islandScreenWidth = (containerWidth: number, metrics: IslandMetrics) =>
  containerWidth > 0 ? Math.min(containerWidth, metrics.screen.width) : metrics.screen.width;

/** Width the expanded regions are laid out at. */
export const expandedWidth = (screenWidth: number, metrics: IslandMetrics) =>
  screenWidth - 2 * metrics.expanded.sideInset;

const hiddenBubble = (right: number, height: number) => ({ bubbleLeft: right - height, bubbleRight: right, bubbleHeight: 0 });

/** The two pills of the compact split, or null when the content is too wide and `minimal` takes over. */
export const splitLayout = (measure: ContentMeasure, metrics: IslandMetrics) => {
  if (!measure.split) return null;
  const s = metrics.split;
  const sensor = metrics.compact.sensorWidth / 2;
  const { attached, detached } = measure.split;
  const pair = (slots: SlotPair, gap: number) => slots.leading + slots.trailing + (slots.leading > 0 && slots.trailing > 0 ? gap : 0);
  const attachedWidth = s.attached.outerPadding + pair(attached, s.attached.gap) + s.attached.innerPadding;
  const bubbleWidth =
    s.detached.width > 0 && detached.trailing > 0
      ? s.detached.width
      : Math.max(
          metrics.minimal.detached.minWidth,
          s.detached.outerPadding + pair(detached, s.detached.gap) + (detached.trailing > 0 ? s.detached.trailingPadding : s.detached.outerPadding),
        );
  const left = -(sensor + attachedWidth);
  const bubbleLeft = sensor + metrics.minimal.gap;
  const bubbleRight = bubbleLeft + bubbleWidth;
  if (bubbleRight - left > s.maxSpan) return null;
  return { left, right: sensor, bubbleLeft, bubbleRight };
};

/**
 * The bubble's trailing slot at rest: its drawn width (the content, cut to the room it has) and
 * where its centre sits, measured from the bubble's right edge so the content rides that edge
 * while the bubble springs out of the pill.
 */
export const bubbleTrailing = (detached: SlotPair, bubbleWidth: number, metrics: IslandMetrics) => {
  const d = metrics.split.detached;
  if (d.width <= 0) return { width: detached.trailing, fromRight: d.trailingPadding + detached.trailing / 2, room: Number.POSITIVE_INFINITY };
  const start = d.outerPadding + detached.leading + d.slotGap;
  const end = bubbleWidth - d.slotEnd;
  const room = Math.max(0, end - start);
  return { width: Math.min(detached.trailing, room), fromRight: bubbleWidth - (start + end) / 2, room };
};

/** Extents of the compact pill beyond the sensor on each side, `balance` applied (0 for an empty side). */
export const compactSides = (measure: Pick<ContentMeasure, "leading" | "trailing">, metrics: IslandMetrics) => {
  const c = metrics.compact;
  const side = (slot: number, inner: number) => (slot > 0 ? inner + Math.min(slot, c.maxSlotWidth) + c.edgePadding : 0);
  const leading = side(measure.leading, c.innerPadding.leading);
  const trailing = side(measure.trailing, c.innerPadding.trailing);
  // A side with nothing in it stays at the sensor: the rule is about two sides of content.
  if (leading <= 0 || trailing <= 0 || c.balance <= 0) return { leading, trailing };
  return { leading: Math.max(leading, trailing * c.balance), trailing: Math.max(trailing, leading * c.balance) };
};

export const shapeTarget = (
  kind: PresentationKind,
  measure: ContentMeasure,
  screenWidth: number,
  metrics: IslandMetrics,
): ShapeTarget => {
  const top = metrics.top;
  switch (kind) {
    case "idle": {
      const { width, height } = metrics.idle;
      return { left: -width / 2, right: width / 2, top, height, radius: height / 2, ...hiddenBubble(width / 2, height) };
    }
    case "compact": {
      const c = metrics.compact;
      const sensor = c.sensorWidth / 2;
      // Each side fits its own content (the simulator's compact pill is off centre by half the
      // difference between leading and trailing widths), within `compact.balance` of the other.
      const sides = compactSides(measure, metrics);
      const left = -Math.min(sensor + sides.leading, c.maxWidth / 2);
      const right = Math.min(sensor + sides.trailing, c.maxWidth / 2);
      return { left, right, top, height: c.height, radius: c.height / 2, ...hiddenBubble(right, c.height) };
    }
    case "minimal": {
      const m = metrics.minimal;
      const sensor = metrics.compact.sensorWidth / 2;
      const split = splitLayout(measure, metrics);
      if (split) return { ...split, top, height: m.height, radius: m.height / 2, bubbleHeight: m.height };
      // Fallback: the attached pill keeps the sensor's trailing end and grows to the left to fit its content.
      const left = measure.attached > 0 ? -(sensor + m.attached.innerPadding + measure.attached + m.attached.outerPadding) : -sensor;
      const right = sensor;
      const bubbleWidth = Math.max(m.detached.minWidth, measure.detached + 2 * m.detached.padding);
      return {
        left,
        right,
        top,
        height: m.height,
        radius: m.height / 2,
        bubbleLeft: right + m.gap,
        bubbleRight: right + m.gap + bubbleWidth,
        bubbleHeight: m.height,
      };
    }
    case "expanded": {
      const e = metrics.expanded;
      const half = expandedWidth(screenWidth, metrics) / 2;
      const height = clamp(measure.expandedHeight + e.padding.top + e.padding.bottom, e.minHeight, e.maxHeight);
      return { left: -half, right: half, top: e.top, height, radius: e.radius, ...hiddenBubble(half, metrics.compact.height) };
    }
    default: {
      const exhaustive: never = kind;
      return exhaustive;
    }
  }
};

/**
 * Picks the motion for a change between presentations. `swap` is true when the activity on show
 * changes (compact A to expanded B), which passes through the idle shape. `alert` is true when the
 * expanded view being left was an alert, whose return differs a little from a press outside.
 */
export const shapeTransition = (
  from: PresentationKind,
  to: PresentationKind,
  options: { swap: boolean; swelling: boolean; alert: boolean },
): ShapeTransition => {
  if (from === to) return "resize";
  if (to === "expanded") {
    if (from === "idle") return "appearExpand";
    if (from === "minimal" || options.swap) return "swap";
    return options.swelling ? "pressExpand" : "expand";
  }
  if (from === "expanded") {
    if (to === "minimal") return "collapseSplit";
    if (to === "idle") return "dismiss";
    return options.alert ? "alertCollapse" : "collapse";
  }
  if (to === "idle") return "dismiss";
  if (from === "idle") return "appear";
  if (to === "minimal") return "split";
  return "unsplit";
};
