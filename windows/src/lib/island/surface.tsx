"use client";

import {
  type CSSProperties,
  type KeyboardEvent,
  type PointerEvent,
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
} from "react";

import { absorbsBubble, contentMotion, leadJoin, type MotionMode, retargetPress, retargetShape } from "./choreography";
import type { IslandClock } from "./clock";
import { bubblePose, createShapeAnimation, followingClip, type FrameGeometry, frameAt, shapeAtRest, type ShapeAnimation } from "./frame";
import {
  type ContentMeasure,
  emptyMeasure,
  expandedWidth as expandedWidthFor,
  islandScreenWidth,
  shapeTarget,
  shapeTransition,
  type ShapeTarget,
  bubbleTrailing,
  splitLayout,
} from "./geometry";
import { IslandLayer, type SlotName } from "./layer";
import { continuousRectPath } from "./path";
import { isAppleWebKit, writeBlur } from "./platform";
import { Skirts, skirtBlur, skirtDim, skirtWeight } from "./skirt";
import type { IslandMetrics } from "./metrics";
import type { ContentMotion, DelayedSpring, ExpandedRegion, IslandMotion, RegionLag } from "./motion";
import type { FrameRecorder } from "./perf";
import { AnimatedValue, type SpringConfig, type Transition } from "./spring";
import type { PressTarget } from "./store";
import type { IslandPresentation, PresentationKind } from "./types";

/** Wiring for the pressable pill. Left out for display-only islands. */
export interface SurfaceInteraction {
  /** Accessible name of the pill button. Null on an idle island: it swells under a press but isn't a control. */
  pillLabel: string | null;
  /** Accessible name of the detached bubble button, when there is one. */
  bubbleLabel: string | null;
  expanded: boolean;
  onPressStart(target: PressTarget, event: PointerEvent<HTMLButtonElement>): void;
  onPressEnd(event: PointerEvent<HTMLButtonElement>): void;
  onPressCancel(): void;
  /** Keyboard activation (Enter or Space). */
  onActivate(target: PressTarget): void;
}

export interface IslandSurfaceProps {
  presentation: IslandPresentation;
  /** Same key updates content in place; a new key crossfades. */
  contentKey: string;
  /**
   * The latest change to what is shown: a counter, the clock time (ms) it happened, and whether it
   * snaps. Springs start at `at`, so replays are exact. Null starts springs at commit time.
   */
  change: SurfaceChange | null;
  pressed: PressTarget | null;
  /**
   * Clock time (ms) a long-pressed bubble will join the pill, once the press is decided. Its
   * content is cut ahead of it by the join's `bubbleExit.delay` when that is negative. Defaults to null.
   */
  joining?: number | null;
  /** "swell" for the stack's long-press (grows, then expands), "squish" for a controlled hold. */
  pressStyle: "swell" | "squish";
  /** The activity on show, so a change of activity can pass through the idle shape. Null for controlled views. */
  activityId: string | null;
  /** Whether the expanded view on show is an alert (it returns on its own, with a slightly different motion). */
  alerting: boolean;
  /**
   * Whether a group's handoff is under way: the shown activity has gone to idle and another of its
   * group expands next. The expansion that ends it may bring its content in on `afterHandoff`.
   * Defaults to false.
   */
  handingOff?: boolean;
  placement: "container" | "viewport";
  regionLabel: string;
  liveLabel: string;
  clock: IslandClock;
  metrics: IslandMetrics;
  motion: IslandMotion;
  reduced: boolean;
  /** Keyline strength (white alpha) for the page behind the island; 0 draws none. */
  keyline: number;
  recorder: FrameRecorder | null;
  interaction: SurfaceInteraction | null;
  className?: string;
  style?: CSSProperties;
  /** Receives the root element (the region), for outside-press checks. */
  rootRef?: (element: HTMLDivElement | null) => void;
}

export interface SurfaceChange {
  id: number;
  at: number;
  instant: boolean;
}

interface Layer {
  key: string;
  presentation: IslandPresentation;
}

type SlotMap = Partial<Record<SlotName, HTMLElement>>;

/** Measured content widths of one layer, and whether its split fits (else `minimal` shows). */
interface LayerSize {
  leading: number;
  trailing: number;
  attached: number;
  detached: number;
  split: ContentMeasure["split"];
  useSplit: boolean;
  /** Centres of the expanded regions in the expanded slot, at rest (layout, not transforms). */
  regions: Record<ExpandedRegion, { x: number; y: number } | null>;
}


const noRegions: LayerSize["regions"] = { leading: null, center: null, trailing: null, bottom: null };

const regionSlots = [
  ["expandedLeading", "leading"],
  ["expandedCenter", "center"],
  ["expandedTrailing", "trailing"],
  ["expandedBottom", "bottom"],
] as const satisfies readonly (readonly [SlotName, ExpandedRegion])[];

const emptySize: LayerSize = { leading: 0, trailing: 0, attached: 0, detached: 0, split: null, useSplit: false, regions: noRegions };

/** How a layer blurs, scales and fades while it is out, set by the transition that brought it or took it. */
type LayerLook = Pick<ContentMotion, "blur" | "enterBlur" | "scale" | "fade" | "exitFade" | "bubbleDelay" | "trailingDelay" | "trailingExitPower" | "anchor" | "sharpen" | "leadingFade" | "bubbleScale" | "bubbleSpread" | "bubbleBlur" | "bubbleSharpen" | "centerDelay"> & {
  bubbleStretch: number;
  bubbleStretchPower: number;
  /** A factor on the blur's wide part (`ContentMotion.skirt`). */
  skirt: number;
  bubbleBlurMax: number | null;
  /** `ContentMotion.bubbleLead` in seconds (0: none), and the points it grows in over (`bubbleLeadRamp`, 0: at once). */
  bubbleLead: number;
  bubbleLeadRamp: number;
  bubbleLeadPower: number;
  /** `ContentMotion.bubbleExitSlide` in points (0: none) and its power. */
  bubbleExitSlide: number;
  bubbleExitSlidePower: number;
  bubbleOrigin: number | null;
  bubbleHold: number;
  bubbleResolve: number | null;
  bubbleFade: number | null;
  exitScale: number | null;
  exitTravel: number | null;
  exitLeadingFade: number;
  enterScale: number | null;
  enterSqueeze: number;
  enterSqueezeOrigin: number;
  enterNarrow: number;
  trailingSlide: number;
  trailingSlidePower: number;
  enterClear: number;
  trailingEnterClear: number;
  clipFollow: number;
  exitBlur: number | null;
  bubbleExitBlur: number | null;
  exitSharpen: number;
  rowAnchor: number;
  bubbleCap: number;
  bubbleTrailingFade: number;
  bubbleTrailingSlide: { by: number; power: number } | null;
  bubbleTrailingBlur: { by: number; power: number } | null;
  /** `bubbleSettle`'s depth: the share the incoming bubble's accent starts smaller (0: none). */
  bubbleSettle: number;
  trailingEnterBlur: number | null;
  /** The incoming compact trailing slot's own start scale (`trailingScale`), or null for `scale`. */
  trailingScale: number | null;
  enterGlow: number;
  bottomAnchor: number;
  trailingRide: { by: number; max: number } | null;
  trailingExitAnchor: number | null;
  follow: number | null;
  partStep: { at: number; by: number; spring: SpringConfig } | null;
  bubbleExitAccent: boolean;
  regions: Partial<Record<ExpandedRegion, RegionLag>>;
  regionExitFade: Partial<Record<ExpandedRegion, number>>;
  regionBottomAnchor: Partial<Record<ExpandedRegion, number>>;
};

const defaultLook = (m: IslandMetrics): LayerLook => ({
  blur: m.content.blur,
  enterBlur: m.content.blur,
  scale: m.content.scale,
  fade: 1,
  exitFade: 1,
  bubbleDelay: 0,
  trailingDelay: 0,
  trailingExitPower: 1,
  anchor: 0,
  sharpen: 1,
  leadingFade: 1,
  bubbleScale: m.content.scale,
  bubbleSpread: 0,
  bubbleStretch: 0,
  bubbleStretchPower: 1,
  skirt: 1,
  bubbleBlurMax: null,
  bubbleLead: 0,
  bubbleLeadRamp: 0,
  bubbleLeadPower: 2,
  bubbleExitSlide: 0,
  bubbleExitSlidePower: 1,
  bubbleOrigin: null,
  bubbleHold: 0,
  bubbleResolve: null,
  bubbleFade: null,
  exitScale: null,
  exitTravel: null,
  exitLeadingFade: 1,
  enterScale: null,
  enterSqueeze: 0,
  enterSqueezeOrigin: 0,
  enterNarrow: 0,
  trailingSlide: 0,
  trailingSlidePower: 1,
  enterClear: 0,
  trailingEnterClear: 0,
  clipFollow: 0,
  exitBlur: null,
  bubbleExitBlur: null,
  rowAnchor: 0,
  bubbleCap: 0,
  bubbleTrailingFade: 0,
  bubbleTrailingSlide: null,
  bubbleTrailingBlur: null,
  bubbleSettle: 0,
  trailingEnterBlur: null,
  trailingScale: null,
  enterGlow: 0,
  bottomAnchor: 0,
  trailingRide: null,
  trailingExitAnchor: null,
  follow: null,
  partStep: null,
  bubbleExitAccent: false,
  exitSharpen: 1,
  bubbleBlur: m.content.blur,
  bubbleSharpen: 1,
  centerDelay: 0,
  regions: {},
  regionExitFade: {},
  regionBottomAnchor: {},
});

/**
 * One slot's drawn numbers before they are written. Unused fields stay 0: `lift` is an expanded
 * region's, `follow` the expanded clip's, the band fields a bubble slot's.
 */
interface SlotDraw {
  opacity: number;
  /** The filter's blur in px, before the slot's own scale. */
  blur: number;
  x: number;
  y: number;
  /** Scale across (with any stretch) and down. */
  sx: number;
  sy: number;
  /** How far an expanded region is drawn above its place (`RegionLag.lift`). */
  lift: number;
  /** How far the expanded clip follows the content (`clipFollow`). */
  follow: number;
  /** A bubble slot's band, top and bottom on screen, and its cap's centre (`bubbleCap`). */
  bandTop: number;
  bandBottom: number;
  cap: number;
  /**
   * The weight of the blur's wide part (`blurSkirt`): the slot draws at 1 - this and its copy at
   * this. Carried like the rest, so a change to a look with another skirt factor eases between them.
   */
  skirt: number;
}

const slotDrawFields = ["opacity", "blur", "x", "y", "sx", "sy", "lift", "follow", "bandTop", "bandBottom", "cap", "skirt"] as const satisfies readonly (keyof SlotDraw)[];

/**
 * A difference smaller than this (per field) is not carried: it is no jump anyone sees, and a
 * change from rest, whose drawn values match to rounding, then draws exactly as it did before.
 */
const carryFloor = {
  opacity: 5e-4,
  blur: 5e-3,
  x: 5e-3,
  y: 5e-3,
  sx: 1e-5,
  sy: 1e-5,
  lift: 5e-3,
  follow: 1e-4,
  bandTop: 5e-3,
  bandBottom: 5e-3,
  cap: 5e-3,
  skirt: 5e-4,
} as const satisfies Record<keyof SlotDraw, number>;

/**
 * What a layer drew the instant a change interrupted it, less what its new look draws at that
 * instant, per slot (`delta`), and the same for how fast each number was moving (`speed`, per
 * second). Each carried number resolves as a critically damped spring from that offset and speed:
 * `delta` times `weight` (1 to 0) plus `speed` times `lag` (`carryLag`). A drawn number is then
 * continuous across the change and keeps its speed. Carried from rest instead, a number moving
 * fast stopped dead at the change: its last frame read as a burst (seed 644: 4 px, then 0.8 px;
 * seed 1673: a blur 0.55 px down and back).
 */
interface Carry {
  weight: AnimatedValue;
  /** Clock time (s) of the change, and the spring's angular frequency (2π over its response). */
  at: number;
  omega: number;
  slots: Map<SlotName, SlotCarry>;
}

/**
 * One slot's carry. `ratio` is set on a layer going out that showed less than its new look draws:
 * its opacity is carried as a multiplier on what that look draws, from what it showed over that
 * (`ratio`, under 1) back to 1, with `speed.opacity` the multiplier's speed (`delta.opacity`
 * unused), so what is carried leaves with the exit's own curve. Added instead, a near-cut's fall
 * against a carry resolving on its 0.1 s floor clamped a card's 20% to nothing in half a frame
 * (seed 1539, and seed 1257 through the carried speed).
 */
interface SlotCarry {
  delta: SlotDraw;
  speed: SlotDraw | null;
  ratio: number | null;
}

/** How much of a carried speed is left `t` seconds on the clock: τ·e^(−ωτ), τ from the change. */
const carryLag = (carry: Carry, t: number) => {
  const tau = t - carry.at;
  return tau > 0 ? tau * Math.exp(-carry.omega * tau) : 0;
};

/**
 * `base` with `delta` added at `weight` (1 at the interruption, 0 once resolved) and `speed` at `lag`;
 * with a carried `ratio` the opacity is scaled by a multiplier that resolves the same way instead.
 */
const addCarry = (base: SlotDraw, carried: SlotCarry, weight: number, lag: number): SlotDraw => {
  const { delta, speed, ratio } = carried;
  const at = (field: keyof SlotDraw) => base[field] + delta[field] * weight + (speed ? speed[field] * lag : 0);
  return {
    opacity: clamp01(ratio === null ? at("opacity") : base.opacity * Math.max(0, 1 + (ratio - 1) * weight + (speed ? speed.opacity * lag : 0))),
    blur: Math.max(0, at("blur")),
    x: at("x"),
    y: at("y"),
    sx: at("sx"),
    sy: at("sy"),
    lift: at("lift"),
    follow: at("follow"),
    bandTop: at("bandTop"),
    bandBottom: at("bandBottom"),
    // A cap of 0 is no cap: it is only carried between two caps.
    cap: base.cap === 0 ? 0 : at("cap"),
    skirt: clamp01(at("skirt")),
  };
};

/** What `was` drew less what `now` draws, or null when no field differs past `carryFloor`. */
const carryOf = (was: SlotDraw, now: SlotDraw): SlotDraw | null => {
  const delta: SlotDraw = { opacity: 0, blur: 0, x: 0, y: 0, sx: 0, sy: 0, lift: 0, follow: 0, bandTop: 0, bandBottom: 0, cap: 0, skirt: 0 };
  let moved = false;
  for (const field of slotDrawFields) {
    // A band gaining or losing its cap has no distance between the two to carry.
    const value = field === "cap" && (was.cap === 0 || now.cap === 0) ? 0 : was[field] - now[field];
    delta[field] = value;
    if (Math.abs(value) > carryFloor[field]) moved = true;
  }
  return moved ? delta : null;
};

/**
 * The carry resolves on the response of the spring the layer's presence now follows (its enter or
 * exit), critically damped: an underdamped carry would push each value past where it is going.
 */
const carryDamping = 1;


/**
 * Seconds between the samples a carry's speed is measured from, on each side of the change. A
 * numerical sampling step for a finite difference, not a measurement or a piece of motion tuning,
 * so it lives here rather than in the motion table: any value small against the quickest spring
 * (0.03 s) gives the same speeds.
 */
const speedStep = 1e-3;

/**
 * How fast each field of a slot moves at a change, per second, from three samples `speedStep`
 * apart, `first` at the change: `sign` 1 for samples before it (going back), -1 after it. A field
 * whose two differences disagree by more than a fifth (plus `carryFloor` over a step) is not moving
 * smoothly there, a designed cut or snap among the samples, and gets no speed.
 */
const speedOf = (first: SlotDraw, second: SlotDraw, third: SlotDraw, sign: 1 | -1): SlotDraw => {
  const out: SlotDraw = { opacity: 0, blur: 0, x: 0, y: 0, sx: 0, sy: 0, lift: 0, follow: 0, bandTop: 0, bandBottom: 0, cap: 0, skirt: 0 };
  for (const field of slotDrawFields) {
    const near = (sign * (first[field] - second[field])) / speedStep;
    const far = (sign * (second[field] - third[field])) / speedStep;
    const smooth = Math.abs(near - far) <= 0.2 * Math.max(Math.abs(near), Math.abs(far)) + carryFloor[field] / speedStep;
    // Second order (the speed at `first`, not halfway to `second`): a first-order difference reads a
    // curved motion faster on one side of a change and slower on the other, and a near-cut curves
    // enough that a card whose cut ran on through a change was carried 3 opacity per second it
    // never had (seed 1197: 0.137 to 0.009 in half a frame, where the cut alone draws 0.033).
    out[field] = smooth ? 1.5 * near - 0.5 * far : 0;
  }
  return out;
};

/** What a layer draws, for a carry: whether it shows, its slots, and its band cap's travel (null: none). */
interface LayerDraw {
  shown: boolean;
  slots: Map<SlotName, SlotDraw>;
  capTravel: number | null;
}

/** Where `draw` puts a frame's numbers instead of writing them; `carried` adds the carries in force. */
interface DrawSink {
  carried: boolean;
  layers: Map<string, LayerDraw>;
}

/** The longest delay (s) by which a layer's slots or regions read its presence while it comes in. */
const lagOf = (look: LayerLook | undefined) =>
  look
    ? Math.max(
        0,
        look.bubbleDelay,
        look.trailingDelay,
        look.centerDelay,
        ...Object.values(look.regions).flatMap((lag) => (lag ? [lag.fade, lag.blur] : [])),
      )
    : 0;

/** The narrowest an incoming accent is drawn by `enterNarrow`, as a share of its width. */
const narrowFloor = 0.1;

/** How far the sensor occluder sits inside the idle outline, in points. */
const sensorInset = 0.5;

/** How far a bubble slot's band clip reaches past the slot on each side, in points on screen. */
const bandReach = 400;

const clamp01 = (value: number) => Math.min(1, Math.max(0, value));

/**
 * A value within `settled` of 1 draws as exactly 1. Springs reach their target only in the limit,
 * so content stepped frame by frame kept a presence (and a follow scale) a hair under 1, a
 * transform of scale(0.9999) that the browser resamples: every resting edge drew soft (round 20:
 * the square's edge ramp 1.63 px against iOS's 0.64; round 23: 9, 106, 161 where a still frame drew
 * 0, 161).
 */
const settled = 1e-3;
const full = (value: number) => (Math.abs(1 - value) < settled ? 1 : value);

/**
 * A layer's presence `delay` seconds from `t`, for a slot or region that lags it. A layer that came
 * back while it still showed (`rejoined`) has its way out in that past: read as it was, a lagging
 * region replayed it `delay` late, and a cut on the way out became a jump 0.1 s after the layer
 * came back (seed 34: the expanded center's opacity 0.48 to 0 in one frame). Such a layer's lagging
 * parts show no more than the layer does. One that came in from nothing reads its past as before.
 */
const lagged = (layer: AnimatedValue | undefined, t: number, delay: number, rejoined: boolean) => {
  if (!layer) return undefined;
  const behind = layer.valueAt(t - delay);
  return rejoined ? Math.min(behind, layer.valueAt(t)) : behind;
};

/**
 * An entering layer's trailing-slot presence at `t`: the slot's own value (`trailingEnter`), the
 * layer's held back by `delay` (`trailingDelay`, `lagged`), or the layer's. The frame
 * loop draws with it, and an interruption reads it to keep the slot's slide where it is (`leavingSlides`).
 */
const enteringTrailing = (layer: AnimatedValue | undefined, own: AnimatedValue | undefined, delay: number, t: number, rejoined: boolean) =>
  own ? full(clamp01(own.valueAt(t))) : full(clamp01((delay > 0 ? lagged(layer, t, delay, rejoined) : layer?.valueAt(t)) ?? 1));

/**
 * What is left of an entering layer's blur at presence `pres`, 1 to 0. With `clear` (`enterClear`)
 * it is measured to 1 - clear, so the blur is gone that much presence early; a clear of 1 or more
 * leaves no blur to come in with (it would divide 0 by 0).
 */
const blurLeft = (pres: number, clear: number) => {
  const p = clamp01(pres);
  if (clear <= 0) return 1 - p;
  return clear >= 1 ? 0 : Math.max(0, 1 - p - clear) / (1 - clear);
};

/**
 * How far (in device pixels) a resting slot may sit from the device-pixel grid and still be put
 * on it by the closing draw. The frame loop's last draw used to come one step before the springs
 * snapped to their targets, so every resting state kept a residual of up to 0.05 px: the
 * expanded view 0.013 px right, the compact circle 0.044 px left (round 33, `rest-probe.mjs`).
 * Anything further off is not at its resting layout and is left where it is.
 */
const gridSnap = 0.05;

/**
 * A moving slot is its own compositor layer; one fully in, at scale 1 and sharp is not, so the
 * browser draws it afresh where it rests. Kept as a layer, it went on showing a raster made
 * mid-motion, resampled: stepped frame by frame, the expanded square's edge read 140 of 161 at
 * rest where a still capture drew it whole (round 23).
 */
const layerHint = (still: boolean) => (still ? "auto" : "transform, opacity, filter");

/** Where a region's centre sits in the expanded slot, from layout offsets (transforms don't count). */
const regionCentre = (element: HTMLElement | undefined) =>
  element ? { x: element.offsetLeft + element.offsetWidth / 2, y: element.offsetTop + element.offsetHeight / 2 } : null;

/**
 * Keyline strength on this frame. `dipAt` is when the last collapse started (seconds), which dims
 * the band and brings it back, as on the simulator.
 */
const keylineAt = (
  frame: FrameGeometry,
  t: number,
  props: Pick<IslandSurfaceProps, "keyline" | "metrics" | "motion" | "presentation" | "reduced">,
  leaving: boolean,
  dipAt: number | null,
) => {
  const { keyline, metrics: m, motion } = props;
  if (keyline <= 0) return 0;
  if (props.presentation.kind === "idle" && !leaving) return 0;
  const grown = clamp01((frame.pill.width - m.idle.width) / Math.max(m.keyline.ramp, 0.01));
  const expanded = 1 - m.keyline.expandedDim * frame.expansion;
  let dip = 1;
  if (dipAt !== null && !props.reduced) {
    const d = motion.keyline;
    const since = t - dipAt;
    if (since >= 0 && since < d.dipAt) dip = 1 - (1 - d.dip) * (since / d.dipAt);
    else if (since >= d.dipAt && since < d.backAt) dip = d.dip + (1 - d.dip) * ((since - d.dipAt) / (d.backAt - d.dipAt));
  }
  return keyline * grown * expanded * dip;
};

const shadowBox: CSSProperties = { position: "absolute", top: 0, left: 0, display: "none", pointerEvents: "none" };

const srOnly: CSSProperties = {
  position: "absolute",
  width: 1,
  height: 1,
  margin: -1,
  padding: 0,
  overflow: "hidden",
  clip: "rect(0 0 0)",
  whiteSpace: "nowrap",
  border: 0,
};

const surfaceCss = `
[data-islandcn-hit]{position:absolute;top:0;left:0;margin:0;padding:0;border:0;background:transparent;cursor:pointer;-webkit-tap-highlight-color:transparent;touch-action:manipulation;user-select:none;-webkit-user-select:none}
[data-islandcn-hit]:focus{outline:none}
[data-islandcn-hit]:focus-visible{outline:2px solid #0a84ff;outline-offset:3px}
[data-islandcn-fit]{overflow-x:clip}
[data-islandcn-fit]>*{min-width:0;flex-shrink:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
`;

const sameTarget = (a: ShapeTarget | null, b: ShapeTarget) =>
  a !== null &&
  a.left === b.left &&
  a.right === b.right &&
  a.top === b.top &&
  a.height === b.height &&
  a.radius === b.radius &&
  a.bubbleLeft === b.bubbleLeft &&
  a.bubbleRight === b.bubbleRight &&
  a.bubbleHeight === b.bubbleHeight;

/**
 * Natural width of a slot's content, to the sub-pixel (offsetWidth rounds, and "42" and "43" differ
 * by 0.37 px). The slot's own scale is divided out. Zero for an empty slot, so the pill doesn't
 * reserve space for it.
 */
const contentWidth = (element: HTMLElement | undefined) => {
  if (!element || element.childNodes.length === 0) return 0;
  const transform = getComputedStyle(element).transform;
  const scale = transform && transform !== "none" && typeof DOMMatrixReadOnly !== "undefined" ? new DOMMatrixReadOnly(transform).a : 1;
  return element.getBoundingClientRect().width / (scale > 0.01 ? scale : 1);
};

/** An element's laid-out height to the sub-pixel, unaffected by any scale on it or its parents. */
const usedHeight = (element: HTMLElement | undefined) => (element ? Number.parseFloat(getComputedStyle(element).height) || 0 : 0);

/**
 * A layer's opacity at `presence` under reduced motion: the leaving layer is gone by halfway and the
 * coming one starts there, so the two states never show at once (a compact "4:57" over the expanded
 * one). Both run on the same tween, so their halfway points meet.
 */
const reducedOpacity = (presence: number) => Math.min(1, Math.max(0, presence * 2 - 1));

const fitAttribute = "data-islandcn-fit";

/** A slot's natural width even while it is cut to fit (`fitSlot`): the cut is lifted to measure. */
const naturalWidth = (element: HTMLElement | undefined) => {
  if (!element?.hasAttribute(fitAttribute)) return contentWidth(element);
  const cap = element.style.maxWidth;
  element.removeAttribute(fitAttribute);
  element.style.maxWidth = "";
  const width = contentWidth(element);
  element.setAttribute(fitAttribute, "");
  element.style.maxWidth = cap;
  return width;
};

/**
 * Cuts a slot to `room` when its content is wider: its text (or its child's) ends in an ellipsis,
 * anything else is clipped at that width. Content that fits is left alone.
 */
const fitSlot = (element: HTMLElement | undefined, natural: number, room: number) => {
  if (!element) return;
  if (natural > room + 0.25) {
    element.style.maxWidth = `${room}px`;
    element.setAttribute(fitAttribute, "");
  } else if (element.hasAttribute(fitAttribute)) {
    element.style.maxWidth = "";
    element.removeAttribute(fitAttribute);
  }
};

/**
 * How a bubble's content leaves on `bubbleExit`, from a moment (the change, or a known join):
 * `delay` later (negative: earlier), as a cut when `response` is 0, else on that spring.
 */
const bubbleCut = (exit: DelayedSpring): Transition =>
  exit.response <= 0 ? { kind: "tween", duration: 1e-4, delay: exit.delay } : { kind: "spring", spring: exit, delay: exit.delay };

/**
 * A shadow layer's blur as feGaussianBlur's "x y" standard deviations: `blur` is twice the vertical
 * one, as in CSS drop-shadow, and `aspect` widens or narrows it sideways.
 */
const blurDeviation = (layer: { blur: number; aspect: number }) => `${(layer.blur / 2) * layer.aspect} ${layer.blur / 2}`;

/**
 * The shadow as CSS box shadows, for Apple's WebKit (`platform.ts`): the key layer over the tail,
 * at this frame's alpha. CSS blur radius is twice the standard deviation, as `blur` is here; the
 * sideways `aspect` and the grain are left out (under a level at 3x).
 */
const boxShadow = (shadow: IslandMetrics["expanded"]["shadow"], alpha: number) =>
  `0 ${shadow.offsetY}px ${shadow.blur}px rgba(0,0,0,${alpha.toFixed(4)}), 0 ${shadow.tail.offsetY}px ${shadow.tail.blur}px rgba(0,0,0,${(alpha * shadow.tail.strength).toFixed(4)})`;

/**
 * The box a shadow is cast from: the drawn shape inset by one point. A circular corner inset that
 * far lies inside the continuous corner at every angle (checked on the expanded radius), so the
 * shadow, which CSS cuts away inside its box, is never cut where the black doesn't cover.
 */
const shadowInset = 1;

/** Places one shadow box, or hides it. */
const placeShadow = (element: HTMLDivElement | null, box: { x: number; y: number; width: number; height: number; radius: number; lead?: number }, css: string | null) => {
  if (!element) return;
  const show = css !== null && box.width > 2 * shadowInset && box.height > 2 * shadowInset;
  element.style.display = show ? "block" : "none";
  if (!show) return;
  element.style.transform = `translate(${box.x + shadowInset}px, ${box.y + shadowInset}px)`;
  element.style.width = `${box.width - 2 * shadowInset}px`;
  element.style.height = `${box.height - 2 * shadowInset}px`;
  const r = Math.max(0, box.radius - shadowInset);
  // Rounder left corners (`cornerLead`): top-left, top-right, bottom-right, bottom-left.
  const lead = box.lead === undefined || box.lead === box.radius ? r : Math.max(0, box.lead - shadowInset);
  element.style.borderRadius = lead === r ? `${r}px` : `${lead}px ${r}px ${r}px ${lead}px`;
  element.style.boxShadow = css;
};

const wallNow = () => (typeof performance === "undefined" ? Date.now() : performance.now());

/** Side of the shadow's grain tile in device pixels. Its repeat (about 11 pt at 3x) is far below sight at 1 level. */
const grainTileSize = 32;

/**
 * A grain tile for the shadow's dither: black pixels whose alpha is uniform noise from a fixed
 * seed (mulberry32), as a PNG data URL, so every island and every capture draws the same grain.
 * Null where there is no canvas (server render); the filter then leaves the grain out.
 */
const makeGrainTile = (): string | null => {
  if (typeof document === "undefined") return null;
  const canvas = document.createElement("canvas");
  canvas.width = grainTileSize;
  canvas.height = grainTileSize;
  const context = canvas.getContext("2d");
  if (!context) return null;
  const image = context.createImageData(grainTileSize, grainTileSize);
  let seed = 0x1c0de;
  for (let i = 3; i < image.data.length; i += 4) {
    seed = (seed + 0x6d2b79f5) | 0;
    let x = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x;
    image.data[i] = ((x ^ (x >>> 14)) >>> 0) % 256;
  }
  context.putImageData(image, 0, 0);
  return canvas.toDataURL("image/png");
};

/** Draws one island: the black shape, the content layers, and the pressable hit areas. */
export const IslandSurface = (props: IslandSurfaceProps) => {
  const { presentation, contentKey, metrics, interaction } = props;

  const [containerWidth, setContainerWidth] = useState(0);
  const stageWidth = islandScreenWidth(containerWidth, metrics);
  const stageHeight = Math.ceil(metrics.top + metrics.expanded.maxHeight * 1.3);
  const expandedWidth = expandedWidthFor(stageWidth, metrics);

  // Layers: the current presentation plus any that are still fading out. Adjusting state while
  // rendering (instead of in an effect) puts the leaving layer in the same commit as the new one.
  const [shown, setShown] = useState<Layer>({ key: contentKey, presentation });
  const [leaving, setLeaving] = useState<readonly Layer[]>([]);
  if (shown.key !== contentKey) {
    const previous = shown;
    setLeaving((list) => [...list.filter((layer) => layer.key !== contentKey && layer.key !== previous.key), previous]);
    setShown({ key: contentKey, presentation });
  } else if (shown.presentation !== presentation) {
    setShown({ key: contentKey, presentation });
  }
  const visibleLeaving = leaving.filter((layer) => layer.key !== contentKey);

  // Everything the frame loop touches lives in refs, so frames never re-render React.
  const live = useRef(props);
  live.current = props;
  const stageWidthRef = useRef(containerWidth);
  stageWidthRef.current = containerWidth;
  const shape = useRef<ShapeAnimation | null>(null);
  shape.current ??= createShapeAnimation(shapeTarget(presentation.kind, emptyMeasure, metrics.screen.width, metrics), metrics);
  const presence = useRef(new Map<string, AnimatedValue>());
  /**
   * A leaving layer's bubble content, when the change took it out on its own timing
   * (`ContentMotion.bubbleExit`). It never shows more than the layer's presence.
   */
  const bubbleExits = useRef(new Map<string, AnimatedValue>());
  // An entering bubble's own presence, when its transition gives it one (`bubbleEnter`).
  const bubbleEnters = useRef(new Map<string, AnimatedValue>());
  // The same for an entering trailing slot (`trailingEnter`).
  const trailingEnters = useRef(new Map<string, AnimatedValue>());
  // How far an entering bubble's accent has settled into its size (`bubbleSettle`), 0 to 1.
  const bubbleSettles = useRef(new Map<string, AnimatedValue>());
  /** Per incoming layer with `partStep`: 0 until the step, then 1 settling back to 0. */
  const partSteps = useRef(new Map<string, AnimatedValue>());
  /**
   * Per layer interrupted while its trailing slot was still sliding in (`trailingSlide`): the
   * slide's offset in px before the slot's `toward` sign, easing out to 0 from where it was drawn
   * and as fast as it was closing. Kept per unit of the leaving presence instead, it reversed
   * while that presence still rose for a few frames after the change (seed 1924: 1.4 px a frame
   * inward, then 1.0 outward); held, it stopped dead.
   */
  const leavingSlides = useRef(new Map<string, AnimatedValue>());
  /** Per layer interrupted while it showed: what it drew then, resolving to its new look (`Carry`). */
  const carries = useRef(new Map<string, Carry>());
  /** Layers that came back while they still showed: their lagging parts show no more than they do (`lagged`). */
  const rejoins = useRef(new Set<string>());
  /**
   * Layers going out on a near-cut (an exit quicker than `content.carryResponseMin`, as the expanded card's
   * into a split). A later change lets them finish it rather than easing what is left back in.
   */
  const cutting = useRef(new Set<string>());
  /**
   * Per layer interrupted while it showed: its bubble band's cap (`bubbleCap`) held at the travel
   * it had, or null for a layer that came back showing no cap (it takes none on its way in). The
   * band's form then never switches at a change; it lets go where the cap does, once the bubble is in.
   */
  const capHolds = useRef(new Map<string, number | null>());
  const looks = useRef(new Map<string, LayerLook>());
  const slots = useRef(new Map<string, SlotMap>());
  /** The copies that draw each blurred slot's wide part (`blurSkirt`, skirt.ts). */
  const skirts = useRef(new Skirts());
  const widths = useRef(new Map<string, LayerSize>());
  /** Resting shape of each layer: its content is laid out for it and mapped into the current shape. */
  const rests = useRef(new Map<string, ShapeTarget>());
  /** Clock time (s) of the last collapse, which dims the keyline for a moment. */
  const keylineDip = useRef<number | null>(null);
  const layerKinds = useRef(new Map<string, PresentationKind>());
  const leavingKeys = useRef<readonly string[]>([]);
  leavingKeys.current = visibleLeaving.map((layer) => layer.key);
  layerKinds.current.set(contentKey, presentation.kind);
  for (const layer of visibleLeaving) layerKinds.current.set(layer.key, layer.presentation.kind);

  const svg = useRef<SVGSVGElement>(null);
  // The shadow filter's id, unique per island and safe inside `url(#...)` (useId has colons).
  const filterId = `islandcn-shadow-${useId().replace(/[^\w-]/g, "")}`;
  const shadowId = useRef(filterId);
  shadowId.current = filterId;
  const shadowKey = useRef<SVGFEFuncAElement>(null);
  const shadowTail = useRef<SVGFEFuncAElement>(null);
  // The grain tile is drawn on a canvas once mounted, sized so one noise sample is one device pixel.
  const [grain, setGrain] = useState<{ href: string; size: number } | null>(null);
  useEffect(() => {
    const href = makeGrainTile();
    if (href) setGrain({ href, size: grainTileSize / (window.devicePixelRatio || 1) });
  }, []);
  const shadowPill = useRef<HTMLDivElement>(null);
  const shadowBubble = useRef<HTMLDivElement>(null);
  const svgPill = useRef<SVGPathElement>(null);
  const svgBubble = useRef<SVGPathElement>(null);
  const svgBridge = useRef<SVGPathElement>(null);
  const kPill = useRef<SVGPathElement>(null);
  const kBubble = useRef<SVGPathElement>(null);
  const kBridge = useRef<SVGPathElement>(null);
  const content = useRef<HTMLDivElement>(null);
  const pillHit = useRef<HTMLButtonElement>(null);
  const bubbleHit = useRef<HTMLButtonElement>(null);
  const root = useRef<HTMLDivElement | null>(null);
  const unsubscribe = useRef<(() => void) | null>(null);
  const removing = useRef(new Set<string>());

  const last = useRef<{
    key: string | null;
    kind: PresentationKind;
    changeId: number | null;
    width: number;
    target: ShapeTarget | null;
    pressed: PressTarget | null;
    joining: number | null;
    activityId: string | null;
    alerting: boolean;
    handingOff: boolean;
  }>({ key: null, kind: presentation.kind, changeId: null, width: 0, target: null, pressed: null, joining: null, activityId: null, alerting: false, handingOff: false });

  const register = useCallback((key: string, slot: SlotName, element: HTMLElement | null) => {
    const map = slots.current.get(key) ?? {};
    if (element) map[slot] = element;
    else delete map[slot];
    slots.current.set(key, map);
  }, []);

  /** The shape's own writes: outline paths, hit areas, shadow, keyline and the content's clip. */
  const drawShape = useCallback((frame: FrameGeometry, t: number, _clipPath: string) => {
    const { metrics: m, reduced } = live.current;
    const { pill, bubble, paths } = frame;

    svgPill.current?.setAttribute("d", paths.pill);
    svgBubble.current?.setAttribute("d", paths.bubble);
    svgBridge.current?.setAttribute("d", paths.bridge);
    // Content is clipped to the island with concentric corners, as on the simulator, so arriving
    // content is revealed by the shape. The island's outline cuts everything; the concentric clip
    // (`clipPath`) applies per layer: before the blur on expanded content, after it on the rest.
    if (content.current) content.current.style.clipPath = paths.pill ? `path("${paths.outline}")` : "none";

    const hit = pillHit.current;
    if (hit) {
      hit.style.transform = `translate(${pill.x}px, ${pill.y}px)`;
      hit.style.width = `${pill.width}px`;
      hit.style.height = `${pill.height}px`;
      hit.style.borderRadius = `${pill.radius}px`;
    }
    const bHit = bubbleHit.current;
    if (bHit) {
      bHit.style.display = bubble.height >= 1 ? "block" : "none";
      bHit.style.transform = `translate(${bubble.x}px, ${bubble.y}px)`;
      bHit.style.width = `${bubble.width}px`;
      bHit.style.height = `${bubble.height}px`;
      bHit.style.borderRadius = `${bubble.height / 2}px`;
    }
    if (svg.current) {
      // The expanded island casts a soft shadow whose strength follows the expansion: two layers
      // (`expanded.shadow` and its `tail`) in one SVG filter, their opacities written per frame.
      const shadow = m.expanded.shadow;
      const alpha = reduced ? (frame.expansion >= 1 ? shadow.opacity : 0) : shadow.opacity * frame.shadow;
      const on = alpha > 0.002;
      shadowKey.current?.setAttribute("slope", on ? alpha.toFixed(4) : "0");
      shadowTail.current?.setAttribute("slope", on ? (alpha * shadow.tail.strength).toFixed(4) : "0");
      // Apple's WebKit renders the SVG filter on the CPU every frame; it gets CSS shadows instead.
      const boxes = isAppleWebKit();
      svg.current.style.filter = on && !boxes ? `url(#${shadowId.current})` : "none";
      const css = on && boxes ? boxShadow(shadow, alpha) : null;
      placeShadow(shadowPill.current, frame.drawn, css);
      placeShadow(shadowBubble.current, { ...bubble, radius: bubble.height / 2 }, css);
    }

    // Keyline: a faint band outside the edge on dark pages. It belongs to the activity, so it
    // grows in over the first points beyond idle and is gone once only idle remains.
    const keylineAlpha = keylineAt(frame, t, live.current, leavingKeys.current.length > 0, keylineDip.current);
    for (const path of [kPill.current, kBubble.current, kBridge.current]) {
      if (path) path.style.strokeOpacity = keylineAlpha > 0.001 ? keylineAlpha.toFixed(3) : "0";
    }
    kPill.current?.setAttribute("d", paths.pill);
    kBubble.current?.setAttribute("d", paths.bubble);
    kBridge.current?.setAttribute("d", paths.bridge);
  }, []);

  /** Each content layer's slots for this frame, written, or put in `sink`. */
  const drawLayers = useCallback((frame: FrameGeometry, t: number, width: number, clipPath: string, still: boolean, sink: DrawSink | null) => {
    const { metrics: m, reduced } = live.current;
    // Reduced motion ends any carry for good, so turning it off again brings none back.
    if (reduced && carries.current.size > 0) carries.current.clear();
    const { pill, bubble, paths } = frame;
    const box = { x: pill.x, y: pill.y, w: pill.width, h: pill.height };
    // The wide part of each blurred slot's blur (`blurSkirt`): copies asked for this frame stay, the rest go.
    const skirt = reduced ? undefined : live.current.motion.blurSkirt;
    const echoes = skirts.current;
    // How much of its wide part's weight each slot gives up itself (`BlurSkirt.dim`).
    const dim = skirtDim(skirt);
    if (!sink) echoes.begin();
    // Resting content sits on whole device pixels, as the simulator's does (expand-t1 at rest: the
    // square's edges at 97 and 96 px, the compact circle's at 395 and 64, each one full pixel).
    // A slot's resting top-left can fall anywhere (the expanded island's left edge is 41.49 px at
    // 3x), and the browser then draws the content a fraction of a pixel off the grid, its edges
    // half-covered. Each slot is moved by the constant that puts its resting position on the grid:
    // at rest it is crisp, in motion it moves as before (round 23).
    const dpr = typeof window === "undefined" ? 1 : window.devicePixelRatio || 1;
    const toGrid = (v: number) => Math.round(v * dpr) / dpr - v;
    // At rest a slot's offset is put on the grid when it is within `gridSnap` of it (a region's
    // follow shift, then 0). In motion it is written as computed.
    const settle = (v: number) => {
      if (!still) return v;
      const on = Math.round(v * dpr);
      return Math.abs(v * dpr - on) < gridSnap ? on / dpr : v;
    };
    for (const [key, map] of slots.current) {
      const kind = layerKinds.current.get(key);
      if (!kind || !map.root) continue;
      const look = looks.current.get(key) ?? defaultLook(m);
      const value = presence.current.get(key);
      // A layer with no presence yet has not been drawn: there is nothing of it to carry.
      if (sink && !value) continue;
      const p = full(clamp01(value?.valueAt(t) ?? 1));
      const entering = (value?.target ?? 1) === 1;
      const rejoined = rejoins.current.has(key);
      const fade = entering ? look.fade : look.exitFade;
      // The bubble's content may come in later than the pill's (split: blue from +0.39 s), and may
      // leave sooner (`bubbleExit`: a long-pressed bubble goes black before it joins).
      const pBubbleLayer = entering && look.bubbleDelay !== 0 ? full(clamp01(lagged(value, t, look.bubbleDelay, rejoined) ?? 1)) : p;
      const bubbleOut = bubbleExits.current.get(key);
      const cut = (pres: number) => (bubbleOut ? Math.min(pres, clamp01(bubbleOut.valueAt(t))) : pres);
      // The bubble's accent may come in on a presence of its own (`bubbleEnter`); its text keeps
      // the layer's, whose sharpening is on time (round 23).
      const ownBubble = entering ? bubbleEnters.current.get(key) : undefined;
      // With `bubbleExitAccent` the cut takes the accent only; the text leaves with the layer.
      const pBubbleText = look.bubbleExitAccent ? pBubbleLayer : cut(pBubbleLayer);
      const pBubble = ownBubble ? cut(full(clamp01(ownBubble.valueAt(t)))) : cut(pBubbleLayer);
      // The compact trailing slot (text, usually) comes in after the leading one, and may leave sooner.
      const ownTrailing = entering ? trailingEnters.current.get(key) : undefined;
      const pTrailing = entering ? enteringTrailing(value, ownTrailing, look.trailingDelay, t, rejoined) : p ** look.trailingExitPower;
      // What this layer still carries from an interruption (`Carry`), and how much of it is left.
      // Reduced motion draws no carry, also when it turns on while one is still resolving: the
      // preference can change without a content change, so `carryOver` never sees it.
      const carry = (sink && !sink.carried) || reduced ? undefined : carries.current.get(key);
      const carryWeight = carry ? clamp01(carry.weight.valueAt(t)) : 0;
      const carrySpeed = carry ? carryLag(carry, t) : 0;
      // A layer hides at the presence it always did, unless what it carries still shows.
      let carriedOpacity = 0;
      if (carry && carryWeight > 0) {
        // A carried ratio's speed is the multiplier's: what it carries is told by the difference alone.
        for (const { delta, speed, ratio } of carry.slots.values()) {
          carriedOpacity = Math.max(carriedOpacity, Math.abs(delta.opacity * carryWeight + (speed && ratio === null ? speed.opacity * carrySpeed : 0)));
        }
      }
      const presenceGone = p <= 0.001 && Math.max(pBubble, pBubbleText) <= 0.001 && carriedOpacity <= 0.001;
      // The brightest opacity this layer's slots draw this frame, carries included (`blend`): a
      // layer coming in hides only while none of its slots shows. Its lagging parts and a carried
      // ratio can draw more than its presence says, and hiding those while it comes in revealed
      // them a frame later (seed 5573: the split's trailing text, held at 0.021 while the
      // presence passed 0.001, hidden for two frames and shown again).
      let drawnMax = 0;
      const drawn: LayerDraw | null = sink ? { shown: true, slots: new Map(), capTravel: null } : null;
      if (sink && drawn) sink.layers.set(key, drawn);
      /**
       * Adds the carry to a slot's numbers, or puts them in the sink. Returns null once they went
       * to the sink, else the numbers to write: `base` itself when nothing is carried.
       */
      const blend = (name: SlotName, base: SlotDraw): SlotDraw | null => {
        const carried = carryWeight > 0 ? carry?.slots.get(name) : undefined;
        const out = carried ? addCarry(base, carried, carryWeight, carrySpeed) : base;
        // The expanded root and clip write no opacity: their content's regions do.
        if (name !== "root" && name !== "expandedClip") drawnMax = Math.max(drawnMax, out.opacity);
        if (!drawn) return out;
        drawn.slots.set(name, out);
        return null;
      };
      if (!sink) {
        if (kind !== "expanded") {
          map.root.style.clipPath = clipPath;
          writeBlur(map.root, 0);
        }
      }
      const size = widths.current.get(key) ?? emptySize;
      // Content follows the container: laid out for its resting shape, mapped into the current one.
      const rest = rests.current.get(key);
      const restBox = rest ? { x: width / 2 + rest.left, y: rest.top, w: rest.right - rest.left, h: rest.height } : box;
      const sx = restBox.w > 0.5 ? box.w / restBox.w : 1;
      const sy = restBox.h > 0.5 ? box.h / restBox.h : 1;
      const c = m.content;
      // A transition may follow the container less, or not at all (`ContentMotion.follow`).
      const k = reduced ? 1 : full(Math.min(c.followMax, Math.max(c.followMin, (sx * sy) ** ((look.follow ?? c.follow) / 2))));
      /** Writes presence and position: `cx`, `cy` is where the slot's centre goes, `w`, `h` its own size. */
      // The leading slot may brighten ahead of the rest as it comes in (`leadingFade`).
      const leadFade = entering ? fade * look.leadingFade : fade * look.exitLeadingFade;
      // Coming in, blur may fall faster than presence rises (`sharpen`); going out it tracks it.
      const peakBlur = entering ? look.enterBlur : look.blur;
      const sharpen = entering ? look.sharpen : 1;
      // Coming in, the blur may clear before presence is full (`enterClear`): what is left of it is
      // measured to 1 - clear instead of 1, so the first frames keep their blur and the tail ends sooner.
      const remaining = (pres: number, clear: number) => blurLeft(pres, entering ? clear : 0);
      /** Blur in px at presence `pres`: the layer's curve, or the bubble's (`bubbleBlur`, capped at the peak). */
      const layerBlur = (pres: number) => remaining(pres, look.enterClear) ** sharpen * peakBlur;
      // A leaving accent (the leading slot) may keep its size and spread late on its own curve
      // (`exitScale`, `exitBlur`, `exitSharpen`); its text leaves on the layer's. An incoming accent
      // may grow from a size of its own (`enterScale`).
      const accentBlur = entering ? layerBlur : (pres: number) => (1 - pres) ** look.exitSharpen * (look.exitBlur ?? look.blur);
      const accentFrom = entering ? (look.enterScale ?? look.scale) : (look.exitScale ?? look.scale);
      const accentScale = (pres: number) => accentFrom + (1 - accentFrom) * pres;
      const bubbleBlur = (pres: number) =>
        entering ? Math.min(look.bubbleBlurMax ?? peakBlur, (1 - pres) ** look.bubbleSharpen * look.bubbleBlur) : layerBlur(pres);
      // A leaving bubble's accent may blur on a peak of its own (`bubbleExitBlur`); its text keeps the layer's.
      const bubbleAccentBlur = (pres: number) => (!entering && look.bubbleExitBlur !== null ? (1 - pres) * look.bubbleExitBlur : bubbleBlur(pres));
      // An incoming trailing slot of the compact pill or the split's attached pill may take a peak
      // blur of its own (`trailingEnterBlur`): split-t1, t2, t9's "42" shows crisp from first sight
      // (0.4 to 0.5 pt) while its orange is still soft (round 24).
      const trailingBlur = (pres: number) => remaining(pres, look.trailingEnterClear) ** sharpen * (entering && look.trailingEnterBlur !== null ? look.trailingEnterBlur : peakBlur);
      const put = (
        name: SlotName,
        cx: number,
        cy: number,
        w: number,
        h: number,
        pres: number,
        follow: number,
        power = fade,
        scaleAt: (pres: number) => number = (pres) => look.scale + (1 - look.scale) * pres,
        blurAt = layerBlur,
        stretch = 1,
        band: { top: number; bottom: number; cap?: number } | null = null,
        glow = 0,
        blurStretch = 1,
      ) => {
        const element = map[name];
        if (!element) return;
        const presenceScale = reduced ? 1 : scaleAt(pres);
        const s = follow * presenceScale;
        // Filters apply before the transform, so divide by the scale to blur by `blur` on screen.
        // A stretched slot (`bubbleStretch`) widens its blur with it, as a layer laid out wider would;
        // a squeezed one (`enterSqueeze`) divides by `blurStretch` too, so its blur stays nearer round.
        const blur = reduced ? 0 : blurAt(pres) / Math.max(s * blurStretch, 0.05);
        // The slot's blur on screen sets the weight of its wide part (`blurSkirt`); the slot gives that much up.
        const parent = element.parentElement;
        const copies = skirt !== undefined && parent !== null && Skirts.canCopy(element);
        const base: SlotDraw = {
          // A compact slot coming in may show a faint glow on the layer's presence first (`enterGlow`).
          opacity: reduced ? reducedOpacity(pres) : Math.max(pres ** power, glow * p),
          blur,
          x: settle(cx - w / 2),
          y: settle(cy - h / 2),
          sx: s * stretch,
          sy: s,
          lift: 0,
          follow: 0,
          bandTop: band?.top ?? 0,
          bandBottom: band?.bottom ?? 0,
          cap: band?.cap ?? 0,
          skirt: copies ? skirtWeight(skirt, reduced ? 0 : blurAt(pres), !entering) * look.skirt : 0,
        };
        const d = blend(name, base);
        if (!d) return;
        const wide = copies ? d.skirt : 0;
        element.style.opacity = `${wide > 0 ? d.opacity * (1 - wide * dim) : d.opacity}`;
        element.style.filter = d.blur > 0.01 ? `blur(${d.blur.toFixed(2)}px)` : "none";
        element.style.transform = `translate(${d.x}px, ${d.y}px) scale(${d.sx}, ${d.sy})`;
        element.style.willChange = layerHint(d === base && pres >= 1 && s === 1 && stretch === 1 && blur <= 0.01);
        const echo = skirt && parent && wide > 0 ? echoes.echo(element, parent, false, []) : null;
        if (skirt && echo) {
          // The copy draws where the slot does, under its band clip (copied below once written).
          echo.node.style.opacity = `${d.opacity * wide}`;
          echo.node.style.filter = `blur(${skirtBlur(skirt, d.sy).toFixed(2)}px)`;
          echo.node.style.transform = element.style.transform;
        }
        if (band) {
          // The clip applies after the blur, in the slot's own units (scaled about its centre), so
          // the blurred content is cut by a crisp line at the band's screen top and bottom. The
          // sides reach far out: the island's own outline and the sensor cut those. Carried, the
          // slot's centre moves with its carried place.
          const midX = d === base ? cx : cx + (d.x - base.x);
          const midY = d === base ? cy : cy + (d.y - base.y);
          const sy = Math.max(d.sy, 0.05);
          const top = h / 2 + (d.bandTop - midY) / sy;
          const bottom = h / 2 + (d.bandBottom - midY) / sy;
          const reach = (bandReach / sy).toFixed(1);
          const right = (w + bandReach / sy).toFixed(1);
          if (band.cap === undefined) {
            element.style.clipPath = `polygon(-${reach}px ${top.toFixed(2)}px, ${right}px ${top.toFixed(2)}px, ${right}px ${bottom.toFixed(2)}px, -${reach}px ${bottom.toFixed(2)}px)`;
          } else {
            // The band ends on the right in a half-circle of the band's half-height centred at
            // `cap` on screen (`bubbleCap`); a stretched slot draws it as an ellipse in its own units.
            const sx = Math.max(d.sx, 0.05);
            const capX = (w / 2 + (d.cap - midX) / sx).toFixed(2);
            const rx = ((d.bandBottom - d.bandTop) / 2 / sx).toFixed(2);
            const ry = ((bottom - top) / 2).toFixed(2);
            element.style.clipPath = `path("M -${reach} ${top.toFixed(2)} L ${capX} ${top.toFixed(2)} A ${rx} ${ry} 0 0 1 ${capX} ${bottom.toFixed(2)} L -${reach} ${bottom.toFixed(2)} Z")`;
          }
        }
        if (echo) echo.node.style.clipPath = element.style.clipPath;
      };
      const at = (fx: number, fy: number) => ({ x: box.x + fx * sx, y: box.y + fy * sy });
      // An incoming accent may be drawn narrower while the pill is narrower than at rest
      // (`enterSqueeze`), about its inner edge: the slot moves toward the sensor by the width it loses.
      // It may also start narrower on its presence alone (`enterNarrow`), the pill's width aside.
      const squeezeOf = (leading: boolean) => {
        if (!entering || !leading || reduced) return 1;
        const byWidth = look.enterSqueeze > 0 && sx < 1 ? sx ** look.enterSqueeze : 1;
        // Never under `narrowFloor`: the slot's width is measured through its scale (`contentWidth`),
        // and a slot drawn at no width at all would read as empty and resize the pill.
        const byPresence = look.enterNarrow > 0 ? Math.max(narrowFloor, p ** look.enterNarrow) : 1;
        return byWidth * byPresence;
      };
      // `enterSqueezeOrigin` 1 holds the outer edge instead, so the slot moves away from the sensor.
      const inward = (w: number, pres: number, squeeze: number) =>
        squeeze < 1 ? (w / 2) * k * accentScale(pres) * (1 - squeeze) * (1 - 2 * look.enterSqueezeOrigin) : 0;
      // An incoming trailing slot may start toward the sensor and slide out from under it
      // (`trailingSlide`); `toward` is +1 for a slot left of the sensor, -1 for one right of it.
      // A slot interrupted on its way in leaves from where it was drawn: its offset eases out from
      // there (`leavingSlides`).
      const kept = entering ? 0 : (leavingSlides.current.get(key)?.valueAt(t) ?? 0);
      const slide = (toward: number, pres: number) =>
        reduced
          ? 0
          : entering
            ? look.trailingSlide !== 0
              ? toward * look.trailingSlide * (1 - pres) ** look.trailingSlidePower
              : 0
            : kept !== 0
              ? toward * kept
              : 0;
      /**
       * A slot's centre `now`, moved by what puts its resting centre `restCentre` (a slot `w` by `h`)
       * on the device-pixel grid. Without a resting layout there is nothing to snap to.
       */
      const onGrid = (now: { x: number; y: number }, restCentre: { x: number; y: number }, w: number, h: number) =>
        rest ? { x: now.x + toGrid(restCentre.x - w / 2), y: now.y + toGrid(restCentre.y - h / 2) } : now;
      const restAt = (fx: number, fy: number) => ({ x: restBox.x + fx, y: restBox.y + fy });
      /**
       * A compact or split slot's centre, `fx` from the resting shape's left edge, for content at
       * presence `pres`: its fraction of the width, blended by `look.anchor` toward scaling about
       * the island's centre with the slot's own scale. A negative anchor (toward the island's end)
       * moves the leading slot only: iOS's returning circle starts near the pill's end while its
       * text stays at its place (collapse-t1, t9: "42" 15 pt in from the right end throughout).
       * `w` is the slot's own width: with it, an incoming leading slot on a negative anchor never
       * reaches past its resting inner edge (below).
       */
      const slotAt = (fx: number, fy: number, pres: number, leading: boolean, w = 0, squeeze = 1, from = look.scale) => {
        // The trailing slot may keep its distance from the pill's right end instead (`trailingRide`).
        const share = at(fx, fy);
        const rideBy = leading || reduced || !look.trailingRide ? 0 : look.trailingRide.by * (box.x + box.w - (restBox.w - fx) - share.x);
        const ride = look.trailingRide ? Math.max(-look.trailingRide.max, Math.min(look.trailingRide.max, rideBy)) : 0;
        const proportional = { x: share.x + ride, y: share.y };
        // A leaving trailing slot may take an anchor of its own (`trailingExitAnchor`); a negative
        // layer anchor moves the leading slot only.
        const anchor = leading ? look.anchor : !entering && look.trailingExitAnchor !== null ? look.trailingExitAnchor : Math.max(0, look.anchor);
        if (anchor === 0 || reduced) return { x: proportional.x + inward(w, pres, squeeze), y: proportional.y };
        const s = k * (from + (1 - from) * pres);
        const centred = box.x + box.w / 2 + (fx - restBox.w / 2) * s;
        const x = proportional.x + (centred - proportional.x) * anchor;
        // The negative anchor is fitted on pills wider than at rest. In one narrower than at rest
        // (unsplit dips to 110 pt of its 150 while A comes back) its push turns toward the centre
        // and put the returning circle under the sensor, a flat bite where iOS's stays round. iOS
        // keeps the circle's inner edge at its resting place and lets the outline clip its outer
        // side (round 35, every seen unsplit take: right edge 152.0 to 153.3 pt at every width).
        // The collapses dip under their rest width as they settle and had the same bite on a few
        // frames (collapse: past the sensor's end on 22% of the returning circle's frames, now none).
        if (!leading || !entering || anchor >= 0 || w <= 0) return { x: x + inward(w, pres, squeeze), y: proportional.y };
        const drawn = k * accentScale(pres);
        return { x: Math.min(x, restBox.x + fx + (w / 2) * (1 - drawn)) + inward(w, pres, squeeze), y: proportional.y };
      };

      switch (kind) {
        case "idle":
          break;
        case "compact": {
          const pad = m.compact.edgePadding;
          const h = m.compact.height;
          const lx = pad + size.leading / 2;
          const tx = restBox.w - pad - size.trailing / 2;
          const squeeze = squeezeOf(true);
          // A leaving accent's place may travel on a scale of its own (`exitTravel`); its text keeps `scale`.
          const leadFrom = entering ? look.scale : (look.exitTravel ?? look.scale);
          const lead = onGrid(slotAt(lx, restBox.h / 2, p, true, size.leading, squeeze, leadFrom), restAt(lx, restBox.h / 2), size.leading, h);
          // An incoming trailing slot may grow from a scale of its own (`trailingScale`).
          const trailFrom = entering && look.trailingScale !== null ? look.trailingScale : look.scale;
          const trailAt = onGrid(slotAt(tx, restBox.h / 2, pTrailing, false, 0, 1, trailFrom), restAt(tx, restBox.h / 2), size.trailing, h);
          const trail = { x: trailAt.x + slide(-1, pTrailing), y: trailAt.y };
          const glow = entering ? look.enterGlow : 0;
          // The squeeze narrows the blur with the accent; dividing by its square root splits that
          // between the two axes, so the squeezed circle is not sharper at its sides than above.
          put("leading", lead.x, lead.y, size.leading, h, p, k, leadFade, accentScale, accentBlur, squeeze, null, glow, Math.sqrt(squeeze));
          put("trailing", trail.x, trail.y, size.trailing, h, pTrailing, k, fade, (pres) => trailFrom + (1 - trailFrom) * pres, trailingBlur, 1, null, glow);
          break;
        }
        case "minimal": {
          const slotH = m.minimal.height;
          const split = size.useSplit ? size.split : null;
          const show = (element: HTMLElement | undefined, visible: boolean) => {
            if (element && !sink) element.style.visibility = visible ? "inherit" : "hidden";
          };
          show(map.attached, split === null);
          show(map.detached, split === null);
          show(map.splitAttachedLeading, split !== null);
          show(map.splitAttachedTrailing, split !== null);
          show(map.splitDetachedLeading, split !== null);
          show(map.splitDetachedTrailing, split !== null);
          // Bubble content rides the capsule (its left edge springs out of the pill) at its own size.
          // It rides the bubble's live width (`span`) also once the bubble is too small to draw or
          // gone, down to none: switching to the resting width there was a jump (canonical unsplit
          // f174: 11.3 px at 7.6% opacity; a pressed bubble taken in by an alert: 26 px at 8%).
          // Vertically it is centred in the island's current height while that is taller than the
          // bubble (coming back into a split from expanded), then cut to the row's band below:
          // the returning circle's centre tracks the collapsing shape's (split-collapse-b-t1 at
          // 138: shape 14 to 58, green 24.7 to 48.3; split-alert-t1 at 845 and 849: 36.2 and 33.0
          // against 36.5 and 33.3).
          const bubbleMid = bubble.y + bubble.height / 2;
          const boxMid = box.y + box.h / 2;
          // The island's middle is held to where the bubble still fits inside the island's height,
          // which is the bubble's own middle once the island is no taller: switching from one to the
          // other as the heights crossed was a step by the pill's lift (seed 1778: 0.63 px at 5%).
          // Once the bubble is taken in, its content keeps the resting bubble's row, as it keeps its
          // width (`span`): falling back to the island's middle there was a step (seed 1817: 0.25 px).
          const row = bubble.height > 0 ? bubble.height : (rest?.bubbleHeight ?? 0);
          const room = Math.max(0, box.h - row) / 2;
          const by = reduced ? (bubble.height > 0 ? bubbleMid : boxMid) : row > 0 ? bubbleMid + Math.max(-room, Math.min(room, boxMid - bubbleMid)) : boxMid;
          const bw = bubble.span;
          // Coming in, the bubble's content may hold its resting place and spread out about the
          // resting bubble's centre (`bubbleSpread`) instead of riding the moving bubble.
          const bubbleFrom = entering ? look.bubbleScale : look.scale;
          const spread = entering && !reduced && rest ? look.bubbleSpread : 0;
          const restBubbleX = rest ? width / 2 + rest.bubbleLeft : bubble.x;
          const restBubbleW = rest ? rest.bubbleRight - rest.bubbleLeft : bw;
          // A pressed bubble swells about its centre and its content with it, as the pill's does.
          const gb = bubble.height > 0 ? bubble.scale : 1;
          // The bubble's content is cut to the resting row's band (the compact height), whatever
          // the shape around it: returning into a split, the blurred circle shows a crisp bottom
          // edge at 50.0 to 50.7 pt inside the taller collapsing shape (split-alert-t1, 10 to 90%
          // in 0.7 pt; split-collapse-b-t1, t2, t9), where an unclipped blur fades over 13 pt.
          const bandMid = rest ? rest.top + rest.height / 2 : 0;
          const band = rest && !reduced ? { top: bandMid - (rest.height / 2) * gb, bottom: bandMid + (rest.height / 2) * gb } : null;
          for (const element of [map.detached, map.splitDetachedLeading, map.splitDetachedTrailing]) {
            if (element && !band && !sink) element.style.clipPath = "none";
          }
          // Coming in, the content may grow about a point on its row (`bubbleOrigin`) instead of
          // riding the collapsing shape's middle: its top stays near the row's top and the row cuts
          // its bottom, so the sensor bites it along its whole end.
          const origin = entering && band && look.bubbleOrigin !== null ? band.top + look.bubbleOrigin * (band.bottom - band.top) : null;
          // With an origin the content holds that larger, stretched form until presence reaches
          // `bubbleHold`, then resolves on the blur's power (`bubbleSharpen`) or its own (`bubbleResolve`):
          // iOS's patch keeps its place for 5 to 6 frames, then becomes the circle within about 6 to 10
          // (split-collapse-b-t1, t2, t9).
          const lobe = origin !== null ? clamp01(((1 - pBubble) / Math.max(1 - look.bubbleHold, 0.01)) ** (look.bubbleResolve ?? look.bubbleSharpen)) : null;
          const closing = lobe ?? (1 - pBubble) ** look.sharpen;
          const bubbleScaleAt = (pres: number) => (lobe !== null ? 1 + (bubbleFrom - 1) * lobe : bubbleFrom + (1 - bubbleFrom) * pres);
          // The accent may settle into its size from below after its presence is complete
          // (`bubbleSettle`); its place on the row and its text keep `bubbleScaleAt`.
          const settling = entering && !reduced ? bubbleSettles.current.get(key) : undefined;
          // Under `settled` (about 0.02 pt on a 22 pt circle) it is drawn at exactly scale 1, so the
          // accent drops its compositor layer as soon as it looks settled: on its own layer the
          // circle's edge rasterises up to 111 levels apart from the resting one (split-alert, round 27).
          const shortfall = settling ? look.bubbleSettle * (1 - clamp01(settling.valueAt(t))) : 0;
          const under = shortfall < settled ? 0 : shortfall;
          const accentScaleAt = (pres: number) => bubbleScaleAt(pres) * (1 - under);
          // The bubble's content may come in on its own opacity curve (`bubbleFade`): dimmer while
          // its returning form is larger than the circle. Easing it back to `fade` as the form
          // resolved left the patch too bright mid-way (split-alert blue ink 39 to 21 of 57 frames).
          const bubbleFade = entering ? (look.bubbleFade ?? fade) : fade;
          const bubbleY = origin === null ? by : origin + (bandMid - origin) * bubbleScaleAt(pBubble);
          // Coming in, the bubble's content may start stretched across the lobe (`bubbleStretch`).
          const stretch = entering && !reduced && rest ? 1 + look.bubbleStretch * closing : 1;
          // The accent's may close faster than the size does (`bubbleStretchPower`); the text keeps the size's curve.
          const accentStretch = entering && !reduced && rest ? 1 + look.bubbleStretch * closing ** look.bubbleStretchPower : 1;
          // The content may ride ahead of the bubble by its left edge's speed (`bubbleLead`): coming
          // in it leaves the sensor sooner, going out (the bubble closing in) it slides under it sooner.
          // With a ramp it grows in as the bubble's left edge comes out of the pill: the edge starts
          // its own height inside the attached pill's resting end.
          const anim = shape.current;
          const emerged = bubble.x + row - (restBox.x + restBox.w);
          const leadShare = look.bubbleLeadRamp > 0 ? clamp01(emerged / look.bubbleLeadRamp) ** look.bubbleLeadPower : 1;
          const lead = !reduced && look.bubbleLead !== 0 && anim ? look.bubbleLead * bubblePose(anim, t).left.velocity * leadShare : 0;
          // Going out, the accent may slide on toward the sensor, which sits left of the bubble (`bubbleExitSlide`).
          const exitSlide = !entering && !reduced && look.bubbleExitSlide !== 0 ? -look.bubbleExitSlide * (1 - p) ** look.bubbleExitSlidePower : 0;
          /** Centre x of a bubble slot `dx` from the bubble's left edge (`dxRest` at rest). */
          const bubbleSlot = (dx: number, dxRest: number) => {
            if (spread <= 0) return bubble.x + lead + dx * gb;
            const centre = restBubbleX + restBubbleW / 2;
            // The spread closes with the blur (`sharpen`), so the slots are in place once sharp.
            return centre + (restBubbleX + dxRest - centre) * (1 + spread * (1 - pBubble) ** look.sharpen);
          };
          // Coming in, the leading content's band may end in a cap (`bubbleCap`) right of its centre.
          // The cap comes out from under the sensor (the attached pill's resting end) and travels to
          // the row's half-height past the slot's resting centre as 1 - (1 - presence) ^ `bubbleCap`.
          // It never cuts into the content's resting size (a slot wider than the cap keeps its
          // width) and lets go once the content is in.
          const pillEnd = restBox.x + restBox.w;
          // A layer interrupted while it showed keeps the cap it had (`capHolds`): held where it
          // was, or none, until the bubble is in. Otherwise the cap travels while it comes in.
          const held = capHolds.current.get(key);
          const holding = held !== undefined && (!entering || pBubble < 0.995);
          const capTravel = holding ? held : !entering || look.bubbleCap <= 0 || pBubble >= 0.995 ? null : 1 - (1 - pBubble) ** look.bubbleCap;
          if (drawn && band) drawn.capTravel = capTravel;
          const capped = (b: typeof band, slot: { rest: number; now: number; w: number }) => {
            if (!b || capTravel === null) return b;
            const r = (b.bottom - b.top) / 2;
            const travel = capTravel;
            const end = Math.max(pillEnd + (slot.rest + r - pillEnd) * travel, slot.now + (slot.w / 2) * gb);
            return { ...b, cap: end - r };
          };
          // Coming back, the attached pill's slots may keep to the resting row (`rowAnchor`).
          const toRow = entering && band && !reduced ? look.rowAnchor : 0;
          const onRow = (slot: { x: number; y: number }) => (toRow > 0 ? { x: slot.x, y: slot.y + (bandMid - slot.y) * toRow } : slot);
          if (split) {
            const s = m.split;
            const lw = split.attached.leading;
            const lx = s.attached.outerPadding + lw / 2;
            const tx = s.attached.outerPadding + lw + (lw > 0 ? s.attached.gap : 0) + split.attached.trailing / 2;
            // The attached slots may step toward the bubble and settle back (`partStep`).
            const stepValue = entering && !reduced && look.partStep ? partSteps.current.get(key) : undefined;
            const stepNow = stepValue && look.partStep ? look.partStep.by * stepValue.valueAt(t) : 0;
            const step = Math.abs(stepNow) < 0.005 ? 0 : stepNow;
            const stepped = (slot: { x: number; y: number }) => (step === 0 ? slot : { x: slot.x + step, y: slot.y });
            const lead = onGrid(stepped(onRow(slotAt(lx, restBox.h / 2, p, true, lw))), restAt(lx, restBox.h / 2), lw, slotH);
            const trailAt = onGrid(stepped(onRow(slotAt(tx, restBox.h / 2, pTrailing, false))), restAt(tx, restBox.h / 2), split.attached.trailing, slotH);
            const trail = { x: trailAt.x + slide(1, pTrailing), y: trailAt.y };
            put("splitAttachedLeading", lead.x, lead.y, lw, slotH, p, k, leadFade, accentScale, accentBlur);
            put("splitAttachedTrailing", trail.x, trail.y, split.attached.trailing, slotH, pTrailing, k, fade, undefined, trailingBlur);
            const dl = split.detached.leading;
            const dlx = s.detached.outerPadding + dl / 2;
            const dl0 = onGrid({ x: bubbleSlot(dlx, dlx), y: bubbleY }, { x: restBubbleX + dlx, y: bandMid }, dl, slotH);
            const dlCx = dl0.x + exitSlide;
            put("splitDetachedLeading", dlCx, dl0.y, dl, slotH, pBubble, gb, bubbleFade, accentScaleAt, bubbleAccentBlur, accentStretch, capped(band, { rest: restBubbleX + dlx, now: dlCx, w: dl }));
            // The bubble's text is fully in at the pinch (split-t1), so it takes no trailing delay. It
            // rides the bubble's right edge, cut to the room the bubble leaves it (`bubbleTrailing`).
            const trailing = bubbleTrailing(split.detached, restBubbleW, m);
            const dtx = trailing.fromRight;
            // Coming in, the text may slide in from the bubble's end (`bubbleTrailingSlide`).
            const textSlide = entering && !reduced && rest && look.bubbleTrailingSlide ? look.bubbleTrailingSlide.by * (1 - pBubbleText) ** look.bubbleTrailingSlide.power : 0;
            // ...and blur on a curve of its own (`bubbleTrailingBlur`), capped where the bubble's is.
            const textBlur = look.bubbleTrailingBlur;
            const bubbleTextBlur = entering && textBlur ? (pres: number) => Math.min(look.bubbleBlurMax ?? peakBlur, textBlur.by * (1 - pres) ** textBlur.power) : bubbleBlur;
            const dt0 = onGrid({ x: bubbleSlot(bw / gb - dtx, restBubbleW - dtx) + textSlide, y: bubbleY }, { x: restBubbleX + restBubbleW - dtx, y: bandMid }, trailing.width, slotH);
            put("splitDetachedTrailing", dt0.x, dt0.y, trailing.width, slotH, pBubbleText, gb, entering && look.bubbleTrailingFade > 0 ? look.bubbleTrailingFade : bubbleFade, bubbleScaleAt, bubbleTextBlur, stretch, band);
          } else {
            const ax = m.minimal.attached.outerPadding + size.attached / 2;
            const lead = onGrid(onRow(slotAt(ax, restBox.h / 2, p, true, size.attached)), restAt(ax, restBox.h / 2), size.attached, slotH);
            put("attached", lead.x, lead.y, size.attached, slotH, p, k, fade, accentScale, accentBlur);
            const d0 = onGrid({ x: bubbleSlot(bw / gb / 2, restBubbleW / 2), y: bubbleY }, { x: restBubbleX + restBubbleW / 2, y: bandMid }, size.detached, slotH);
            const dCx = d0.x + exitSlide;
            put("detached", dCx, d0.y, size.detached, slotH, pBubble, gb, bubbleFade, accentScaleAt, bubbleAccentBlur, accentStretch, capped(band, { rest: restBubbleX + restBubbleW / 2, now: dCx, w: size.detached }));
          }
          break;
        }
        case "expanded": {
          // The expanded view's own layout (padding, grid) then lands on whole pixels too.
          const ex = settle(rest ? box.x + toGrid(restBox.x) : box.x);
          const ey = settle(rest ? box.y + toGrid(restBox.y) : box.y);
          if (map.expanded && !sink) {
            map.expanded.style.transform = `translate(${ex}px, ${ey}px)`;
            map.expanded.style.willChange = layerHint(p >= 1 && k === 1);
          }
          // iOS blurs the expanded view as one layer, after its content clip: the clip's cut softens
          // with the rest (expand-t1 140: the incoming square ramps off where the clip crosses it,
          // half height at the clip, where a clip after the blur left a hard step). Regions that
          // lag (`regions`, `centerDelay`) add their extra blur in quadrature on their own element.
          // A region with its own lower peak (`RegionLag.peak`) takes the shared blur down with it;
          // the others add the rest on their own element.
          const peakOf = (region: ExpandedRegion) => (entering ? (look.regions[region]?.peak ?? peakBlur) : peakBlur);
          const sharedPeak = regionSlots.reduce((low, [slot, region]) => (map[slot] && size.regions[region] ? Math.min(low, peakOf(region)) : low), peakBlur);
          const unused = { opacity: 1, x: 0, y: 0, sx: 1, sy: 1, lift: 0, bandTop: 0, bandBottom: 0, cap: 0, skirt: 0 };
          // Coming in, the expanded view's blur may clear early too (`enterClear`, round 40).
          const sharedBase: SlotDraw = { ...unused, blur: reduced ? 0 : remaining(p, look.enterClear) ** sharpen * sharedPeak, follow: 0 };
          // The regions' own blur is reckoned against the root's uncarried blur: each element's
          // number is then carried on its own, and what they add up to on screen stays continuous.
          const shared = sharedBase.blur;
          const rootDrawn = blend("root", sharedBase);
          if (rootDrawn) {
            map.root.style.clipPath = "none";
            writeBlur(map.root, rootDrawn.blur);
          }
          // Coming in, the clip may follow the content rather than the outline (`clipFollow`). A leaving
          // layer keeps the live clip, unless it was interrupted on its way in (`leavingClip` below).
          const follows = !reduced && rest && paths.pill ? look.clipFollow : 0;
          // In its resting shape the following clip is the live one (`followingClip`), so what is
          // carried is the follow that shows: none there, whatever the look asks.
          const resting = Math.abs(sx - 1) < 1e-9 && Math.abs(sy - 1) < 1e-9 && Math.abs(pill.radius - (rest?.radius ?? pill.radius)) < 1e-9;
          const followBase: SlotDraw = { ...unused, blur: 0, follow: resting ? 0 : follows };
          const followDrawn = map.expandedClip ? blend("expandedClip", followBase) : null;
          if (map.expandedClip && followDrawn) {
            const clipFollow = followDrawn === followBase ? follows : rest && paths.pill ? clamp01(followDrawn.follow) : 0;
            map.expandedClip.style.clipPath =
              clipFollow > 0
                ? `path("${followingClip(box, pill.radius, restBox, rest?.radius ?? pill.radius, m.contentClip.radius, clipFollow)} ${paths.bubbleClip}")`
                : clipPath;
          }
          // The regions drawing a wide part this frame (`blurSkirt`), with the copy's opacity.
          const skirted: { element: HTMLElement; opacity: number }[] = [];
          // Each region keeps its fraction of the shape and scales with it.
          for (const [slot, region] of regionSlots) {
            const element = map[slot];
            const centre = size.regions[region];
            if (!element || !centre) continue;
            // Vertically a region keeps its share of the height, or follows the bottom edge by
            // `bottomAnchor` (expand-t1 +18: iOS's title 13 to 14 pt above rest at 0.84 of the
            // height, its bar 17, the edge 16.6; a share of the height put them 7 and 13 up).
            // A region may take an anchor of its own (`regionBottomAnchor`).
            const dropY = reduced ? 0 : (look.regionBottomAnchor[region] ?? look.bottomAnchor) * (box.h - restBox.h - centre.y * (sy - 1));
            // A region may come in after the others: its opacity and its blur each lag the layer's
            // presence (`regions`); without an entry the center waits `centerDelay` for both.
            const lag = entering && !reduced ? (look.regions[region] ?? (region === "center" && look.centerDelay > 0 ? { fade: look.centerDelay, blur: look.centerDelay } : null)) : null;
            const behind = (delay: number) => (delay !== 0 ? full(clamp01(lagged(value, t, delay, rejoined) ?? 1)) : p);
            const pr = lag ? behind(lag.fade) : p;
            const pb = lag ? behind(lag.blur) : p;
            // A region may grow from a scale of its own (`RegionLag.scale`) and come in from above its place (`lift`).
            const from = lag?.scale ?? look.scale;
            const presenceScale = reduced ? 1 : from + (1 - from) * pb;
            const scale = k * presenceScale;
            const lift = reduced ? 0 : (lag?.lift ?? 0) * (1 - pb);
            // Below 0 `soften` starts the region sharper than its peak; never past no blur at all.
            const soften = Math.max(0, 1 + (lag?.soften ?? 0) * (1 - pb));
            const own = remaining(pb, look.enterClear) ** sharpen * peakOf(region) * soften;
            const blur = reduced ? 0 : Math.sqrt(Math.max(0, own * own - shared * shared)) / Math.max(scale, 0.05);
            // A leaving region may fade on its own power (`regionExitFade`).
            const lagOpacity = pr ** (entering ? (lag?.power ?? fade) : (look.regionExitFade[region] ?? fade));
            const lead = lag?.lead ?? 0;
            const base: SlotDraw = {
              ...unused,
              opacity: reduced ? reducedOpacity(pr) : lead > 0 ? Math.max(lagOpacity, Math.min(lead, p ** fade)) : lagOpacity,
              blur,
              x: settle(centre.x * (sx - 1)),
              y: settle(centre.y * (sy - 1) + dropY),
              sx: scale,
              sy: scale,
              lift,
              follow: 0,
              // The region's blur on screen (the root's and its own in quadrature) sets the weight of its wide part.
              skirt: skirt && !reduced && Skirts.canCopy(element) ? skirtWeight(skirt, own, !entering) * look.skirt : 0,
            };
            const d = blend(slot, base);
            if (!d) continue;
            const wide = d.skirt;
            const shift = `translate(${d.x}px, ${d.y}px)`;
            element.style.opacity = `${wide > 0 ? d.opacity * (1 - wide * dim) : d.opacity}`;
            writeBlur(element, d.blur);
            element.style.transform = d.lift > 0.005 ? `${shift} translate(0px, ${(-d.lift).toFixed(2)}px) scale(${d.sy})` : `${shift} scale(${d.sy})`;
            if (wide > 0) skirted.push({ element, opacity: d.opacity * wide });
          }
          // One copy of the clipped view draws every region's wide part: the copy's own clip, then
          // its blur (with the root's, `width` in all), each region at its own weight.
          const clipSlot = map.expandedClip;
          const view = map.expanded;
          const echo = skirt && clipSlot && view && skirted.length > 0 ? echoes.echo(clipSlot, map.root, true, [view, ...regionSlots.flatMap(([slot]) => map[slot] ?? [])]) : null;
          if (skirt && echo && clipSlot && view) {
            echo.node.style.filter = `blur(${Math.sqrt(Math.max(0, skirt.width ** 2 - (rootDrawn?.blur ?? 0) ** 2)).toFixed(2)}px)`;
            const copyOf = (element: HTMLElement) => echo.parts.get(element);
            const clipCopy = copyOf(clipSlot);
            if (clipCopy) clipCopy.style.clipPath = clipSlot.style.clipPath;
            const viewCopy = copyOf(view);
            if (viewCopy) viewCopy.style.transform = view.style.transform;
            for (const [slot] of regionSlots) {
              const element = map[slot];
              const copy = element ? copyOf(element) : undefined;
              if (!element || !copy) continue;
              const part = skirted.find((entry) => entry.element === element);
              copy.style.opacity = `${part ? part.opacity : 0}`;
              copy.style.filter = "none";
              copy.style.transform = element.style.transform;
            }
          }
          break;
        }
        default: {
          const exhaustive: never = kind;
          return exhaustive;
        }
      }
      // A layer going out hides at the presence it always did (its softest fade then draws at most
      // 0.001 ^ exitFade, the rest cut). One coming in hides only while it draws nothing that shows,
      // since what it hides now it shows again as it comes in.
      const hidden = presenceGone && (!entering || drawnMax <= 0.001);
      if (drawn) drawn.shown = !hidden;
      else map.root.style.visibility = hidden ? "hidden" : "visible";
    }
    if (!sink) echoes.end();
  }, []);

  /**
   * Writes one frame. Called from the clock's frame loop and right after every retarget. `still`
   * is the closing draw once everything is at rest: content near the device-pixel grid is put on it.
   * With a `sink` nothing is written: each layer's numbers go to the sink (a retarget reads what
   * shows on either side of a change this way).
   */
  const draw = useCallback((nowMs: number, still = false, sink: DrawSink | null = null) => {
    const anim = shape.current;
    if (!anim) return;
    const { metrics: m } = live.current;
    const width = islandScreenWidth(stageWidthRef.current, m);
    const t = nowMs / 1000;
    const frame = frameAt(anim, t, width, m);
    const { paths } = frame;
    const clipPath = paths.pill ? `path("${paths.clip}")` : "none";
    if (!sink) drawShape(frame, t, clipPath);
    drawLayers(frame, t, width, clipPath, still, sink);
  }, [drawShape, drawLayers]);

  const tick = useCallback(
    (nowMs: number) => {
      const started = wallNow();
      draw(nowMs);
      live.current.recorder?.record(started, wallNow() - started);
      const t = nowMs / 1000;
      const anim = shape.current;
      let rest = anim ? shapeAtRest(anim, t) : true;
      for (const [key, value] of presence.current) {
        // A slot or region that lags its layer reads the presence that far back, so an entering
        // layer is at rest only once its latest lag has settled too (reduced motion draws no lags).
        const settled = value.isAtRest(value.target === 1 && !live.current.reduced ? t - lagOf(looks.current.get(key)) : t);
        rest = rest && settled;
        // A layer leaves the page once gone and done carrying what an interruption left it (`carries`).
        const carry = carries.current.get(key);
        if (carry?.weight.isAtRest(t)) carries.current.delete(key);
        else if (carry) rest = false;
        if (settled && !carries.current.has(key) && value.target === 0 && leavingKeys.current.includes(key) && !removing.current.has(key)) {
          removing.current.add(key);
          setLeaving((list) => list.filter((layer) => layer.key !== key));
        }
      }
      // A bubble's accent may still be settling into its size after its presence is complete, and
      // a slot on a presence of its own may still be coming in or going.
      for (const values of [bubbleSettles, bubbleEnters, trailingEnters, bubbleExits, partSteps, leavingSlides]) {
        for (const value of values.current.values()) rest = value.isAtRest(t) && rest;
      }
      if (rest) {
        // The draw above read the springs a step before they snapped to their targets (`isAtRest`),
        // and a region on a lag read its presence that far back: drawn as the loop stopped, a
        // resting state kept those values. Every value is now exact, so draw once more.
        draw(nowMs, true);
        unsubscribe.current?.();
        unsubscribe.current = null;
        live.current.recorder?.breakRun();
      }
    },
    [draw],
  );

  const run = useCallback(() => {
    if (!unsubscribe.current) unsubscribe.current = live.current.clock.onFrame(tick);
  }, [tick]);

  /** Each layer's numbers at `nowMs` as they would be drawn, with or without the carries in force. */
  const sample = useCallback(
    (nowMs: number, carried: boolean) => {
      const sink: DrawSink = { carried, layers: new Map() };
      draw(nowMs, false, sink);
      return sink.layers;
    },
    [draw],
  );

  /**
   * After a change of content, every layer that showed (`before`, read at `changedAt` with its
   * carries, then `speedStep` and twice that earlier) keeps the difference between that and what
   * its new look draws at the same instant, and between how fast each moved, resolving both on its
   * presence's new spring. A layer that comes in or goes out showing no clip cap keeps none, and
   * one that showed a cap keeps it where it was (`capHolds`). Snaps and reduced motion carry nothing.
   */
  const carryOver = useCallback(
    (before: readonly [Map<string, LayerDraw>, Map<string, LayerDraw>, Map<string, LayerDraw>] | null, changedAt: number, mode: MotionMode, timing: ContentMotion, carryResponseMin: number) => {
      if (mode !== "spring") {
        carries.current.clear();
        capHolds.current.clear();
        return;
      }
      if (!before) return;
      const [shownAt, shownEarlier, shownEarliest] = before;
      const current = live.current.contentKey;
      for (const [key, was] of shownAt) {
        if (!was.shown) capHolds.current.delete(key);
        else if (key === current) capHolds.current.set(key, was.capTravel);
        else if (was.capTravel !== null) capHolds.current.set(key, was.capTravel);
        else capHolds.current.delete(key);
      }
      const after = sample(changedAt, false);
      const later = sample(changedAt + speedStep * 1000, false);
      const latest = sample(changedAt + 2 * speedStep * 1000, false);
      for (const [key, now] of after) {
        const was = shownAt.get(key);
        const response = key === current ? timing.enter.response : timing.exit.response;
        const slotCarries = new Map<SlotName, SlotCarry>();
        if (was?.shown && response > 0) {
          for (const [name, drawnNow] of now.slots) {
            const drawnBefore = was.slots.get(name);
            // A slot out of sight on both sides has nothing to show of a jump.
            if (!drawnBefore || (drawnBefore.opacity <= 0.001 && drawnNow.opacity <= 0.001)) continue;
            const delta = carryOf(drawnBefore, drawnNow);
            if (!delta) continue;
            const beforeSpeed = [shownEarlier.get(key)?.slots.get(name), shownEarliest.get(key)?.slots.get(name)];
            const afterSpeed = [later.get(key)?.slots.get(name), latest.get(key)?.slots.get(name)];
            // A layer going out that showed less than its new look draws carries its opacity as a
            // ratio. One that showed more keeps the sum: its new look may be nearly out and snap to
            // rest, and a ratio on that went with it (seed 1507: 0.044 to nothing at the snap).
            const ratio = key !== current && drawnBefore.opacity > 0.001 && drawnBefore.opacity < drawnNow.opacity ? drawnBefore.opacity / drawnNow.opacity : null;
            let speed: SlotDraw | null = null;
            if (beforeSpeed[0] && beforeSpeed[1] && afterSpeed[0] && afterSpeed[1]) {
              const came = speedOf(drawnBefore, beforeSpeed[0], beforeSpeed[1], 1);
              const goes = speedOf(drawnNow, afterSpeed[0], afterSpeed[1], -1);
              speed = { ...came };
              for (const field of slotDrawFields) speed[field] = field === "cap" && (drawnBefore.cap === 0 || drawnNow.cap === 0) ? 0 : came[field] - goes[field];
              // The multiplier's speed that keeps the drawn opacity's speed across the change.
              if (ratio !== null) speed.opacity = (came.opacity - goes.opacity * ratio) / drawnNow.opacity;
            }
            slotCarries.set(name, { delta, speed, ratio });
          }
        } else if (was && !was.shown && now.shown && response > 0) {
          // A layer hidden at its rest cut (presence 0.001, still drawing up to 0.03 under its exit
          // fade) that comes back drew nothing before the change: its slots carry their opacity up
          // from 0, and nothing else, as nothing else of them showed. Drawn at once, a split that
          // came back as it went showed its leading circle at 0.017 from the instant (seed 6314).
          for (const [name, drawnNow] of now.slots) {
            if (drawnNow.opacity <= 0.001) continue;
            const delta = carryOf({ ...drawnNow, opacity: 0 }, drawnNow);
            if (delta) slotCarries.set(name, { delta, speed: null, ratio: null });
          }
        }
        if (slotCarries.size === 0) {
          carries.current.delete(key);
          continue;
        }
        const resolve = Math.max(response, carryResponseMin);
        const weight = new AnimatedValue(1, 1e-4);
        weight.set(0, changedAt / 1000, { kind: "spring", spring: { response: resolve, dampingFraction: carryDamping } });
        carries.current.set(key, { weight, at: changedAt / 1000, omega: (2 * Math.PI) / resolve, slots: slotCarries });
      }
    },
    [sample],
  );

  /** Measures the current layer, works out where the shape is heading, and retargets the springs. */
  const retarget = useCallback(() => {
    const anim = shape.current;
    if (!anim) return;
    const p = live.current;
    const m = p.metrics;
    // A change of content reads what every layer shows first, before anything moves, so each can
    // go on from there (`carries`).
    const changedAt = p.clock.now();
    const keyChanging = last.current.key !== null && last.current.key !== p.contentKey;
    const shownBefore = keyChanging
      ? ([sample(changedAt, true), sample(changedAt - speedStep * 1000, true), sample(changedAt - 2 * speedStep * 1000, true)] as const)
      : null;
    const map = slots.current.get(p.contentKey) ?? {};
    const hasSplit = map.splitAttachedLeading !== undefined;
    // Sub-pixel widths come back with float noise through the slot's transform. A layer keeps its
    // last width unless the content really changed, or every re-render would retarget the shape.
    const before = widths.current.get(p.contentKey);
    const stable = (next: number, previous: number | undefined) =>
      previous !== undefined && Math.abs(next - previous) < 0.05 ? previous : next;
    const measure: ContentMeasure = {
      leading: stable(contentWidth(map.leading), before?.leading),
      trailing: stable(contentWidth(map.trailing), before?.trailing),
      attached: stable(contentWidth(map.attached), before?.attached),
      detached: stable(contentWidth(map.detached), before?.detached),
      split: hasSplit
        ? {
            attached: {
              leading: stable(contentWidth(map.splitAttachedLeading), before?.split?.attached.leading),
              trailing: stable(contentWidth(map.splitAttachedTrailing), before?.split?.attached.trailing),
            },
            detached: {
              leading: stable(contentWidth(map.splitDetachedLeading), before?.split?.detached.leading),
              trailing: stable(naturalWidth(map.splitDetachedTrailing), before?.split?.detached.trailing),
            },
          }
        : null,
      // The used height, fractional and untransformed: offsetHeight rounds to whole pixels, which
      // left W's two-line expanded view 0.33 pt taller than the simulator (107.51 against 107.18).
      expandedHeight: usedHeight(map.expandedInner),
    };
    const splitShape = splitLayout(measure, m);
    if (splitShape && measure.split) {
      // The bubble keeps its width; trailing content wider than its room is cut to fit.
      const room = bubbleTrailing(measure.split.detached, splitShape.bubbleRight - splitShape.bubbleLeft, m).room;
      fitSlot(map.splitDetachedTrailing, measure.split.detached.trailing, room);
    }
    widths.current.set(p.contentKey, {
      leading: measure.leading,
      trailing: measure.trailing,
      attached: measure.attached,
      detached: measure.detached,
      split: measure.split,
      useSplit: splitShape !== null,
      regions:
        p.presentation.kind === "expanded"
          ? {
              leading: regionCentre(map.expandedLeading),
              center: regionCentre(map.expandedCenter),
              trailing: regionCentre(map.expandedTrailing),
              bottom: regionCentre(map.expandedBottom),
            }
          : noRegions,
    });

    const width = islandScreenWidth(stageWidthRef.current, m);
    const target = shapeTarget(p.presentation.kind, measure, width, m);
    const prev = last.current;
    const first = prev.key === null;
    const keyChanged = prev.key !== p.contentKey;
    const change = p.change;
    const changeStamped = change !== null && change.id !== prev.changeId;
    // Snap on mount, on instant changes, and when the container resizes (desktop window, rotation).
    const instant = first || (changeStamped && change.instant) || prev.width !== width;
    const startMs = (keyChanged || changeStamped) && change !== null ? change.at : p.clock.now();
    const pressChanged = prev.pressed !== p.pressed;

    // A long-press on the bubble is decided before it joins, so its content can go first: the
    // join's `bubbleExit` with a negative delay cuts it that long ahead (split-expand-b-t1).
    const joining = p.joining ?? null;
    if (joining !== prev.joining) {
      last.current = { ...prev, joining };
      // The join's shape may start ahead of the change (`bubble.joinLead`); the change that joins
      // clears `joining` and carries the join on, so only a press let go undoes it.
      if (joining !== null || !keyChanged) {
        leadJoin(anim, {
          joinAt: joining === null ? null : joining / 1000,
          t: p.clock.now() / 1000,
          idleRight: shapeTarget("idle", emptyMeasure, width, m).right,
          restLeft: prev.target?.bubbleLeft ?? anim.bubbleLeft.target,
          motion: p.motion,
          mode: instant ? "instant" : p.reduced ? "reduced" : "spring",
        });
      }
      if (!keyChanged) {
        const join = contentMotion(p.motion, shapeTransition("minimal", "expanded", { swap: true, swelling: true, alert: false })).bubbleExit;
        if (joining !== null && join && join.delay < 0 && !p.reduced && !instant) {
          const out = new AnimatedValue(1, 0.001);
          out.set(0, joining / 1000, bubbleCut(join));
          bubbleExits.current.set(p.contentKey, out);
        } else {
          bubbleExits.current.delete(p.contentKey);
        }
      }
    }

    // A handoff may start or end without a change of shape; the next change reads it from here.
    const handingOff = p.handingOff ?? false;
    if (handingOff !== last.current.handingOff) last.current = { ...last.current, handingOff };
    // So may an alert: a press or `expand()` on an alerting island keeps the view and its content
    // and makes it the user's. Left as it was, the next change read as an alert's return and took
    // its lag and `afterAlert` timing: the split's part step drew 2.1 frames late (seed 317).
    if (p.alerting !== last.current.alerting) last.current = { ...last.current, alerting: p.alerting };

    if (!keyChanged && !instant && !pressChanged && sameTarget(prev.target, target)) return;

    const { motion, reduced } = p;
    const mode: MotionMode = instant ? "instant" : reduced ? "reduced" : "spring";
    const fromKind = prev.kind;
    const toKind = p.presentation.kind;
    const transition = shapeTransition(fromKind, toKind, {
      swap: prev.activityId !== null && p.activityId !== null && prev.activityId !== p.activityId,
      swelling: prev.pressed !== null,
      alert: prev.alerting,
    });
    // An alert's return may start a little after its hold runs out (split-alert's return); a press
    // outside starts the same motion at once (held-out split-collapse-b).
    const t0 = startMs / 1000 + (mode === "spring" && keyChanged && prev.alerting ? motion.lag[transition] : 0);

    rests.current.set(p.contentKey, target);
    // Read before the retarget, which starts the bubble's merge.
    const absorbing = absorbsBubble(anim, { transition, target, t0 });
    if (keyChanged && mode === "spring" && (transition === "collapse" || transition === "alertCollapse" || transition === "collapseSplit")) {
      keylineDip.current = t0;
    }

    // New content in the same shape (an alert's update applied in place, early when the alert
    // turns into the user's expansion) leaves the shape's motion alone: re-set to the same target on
    // the resize spring, an expansion under way bent by 0.1 pt, its shadow ramp jumped to full, and
    // the step after it read as a jump (seed 1265). A press that changes with it still folds in.
    const sameShape = transition === "resize" && mode === "spring" && !pressChanged && sameTarget(prev.target, target);
    if ((keyChanged && !sameShape) || !sameTarget(prev.target, target) || instant) {
      retargetShape(anim, {
        transition,
        target,
        idle: shapeTarget("idle", emptyMeasure, width, m),
        t0,
        motion,
        mode,
      });
    }

    if (pressChanged && !(prev.pressed !== null && keyChanged)) {
      // A swell that turned into an expansion was folded into the shape above.
      retargetPress(anim, { pressed: p.pressed, style: p.pressStyle, t: p.clock.now() / 1000, motion, metrics: m, mode, idle: toKind === "idle" });
    }

    if (keyChanged) {
      const base = contentMotion(motion, transition);
      // A change that absorbs the bubble may bring its content in on its own timing (`absorb`), and
      // so may one that leaves an alert whose hold ran out (`afterAlert`).
      // `afterAlert` keeps the bubble on the layer's presence (its own `bubbleDelay`) unless it sets
      // a `bubbleEnter` of its own.
      const { bubbleEnter: _ownBubble, ...unbubbled } = base;
      // The expansion that ends a group's handoff may too (`afterHandoff`).
      const variant: ContentMotion =
        absorbing && base.absorb
          ? { ...base, ...base.absorb }
          : prev.alerting && base.afterAlert
            ? { ...unbubbled, ...base.afterAlert }
            : prev.handingOff && base.afterHandoff
              ? { ...base, ...base.afterHandoff }
              : base;
      // Coming into a wide shape it may take a look of its own (`wide`): W's compact pill against A's.
      const { from: wideFrom = Number.MAX_VALUE, ...wideLook } = base.wide ?? {};
      const timing: ContentMotion = target.right - target.left >= wideFrom ? { ...variant, ...wideLook } : variant;
      const tween: Transition = { kind: "tween", duration: motion.reduced.duration };
      const fade = (spring: { response: number; dampingFraction: number; delay: number }): Transition =>
        mode === "instant" ? { kind: "instant" } : mode === "reduced" ? tween : { kind: "spring", spring, delay: spring.delay };
      const current = presence.current.get(p.contentKey) ?? new AnimatedValue(0, 0.001);
      presence.current.set(p.contentKey, current);
      const look: LayerLook = {
        blur: timing.blur,
        enterBlur: timing.enterBlur,
        scale: timing.scale,
        fade: timing.fade,
        exitFade: timing.exitFade,
        bubbleDelay: timing.bubbleDelay,
        trailingDelay: timing.trailingDelay,
        trailingExitPower: timing.trailingExitPower,
        anchor: timing.anchor,
        sharpen: timing.sharpen,
        leadingFade: timing.leadingFade,
        bubbleScale: timing.bubbleScale,
        bubbleSpread: timing.bubbleSpread,
        bubbleStretch: timing.bubbleStretch ?? 0,
        bubbleStretchPower: timing.bubbleStretchPower ?? 1,
        skirt: timing.skirt ?? 1,
        bubbleBlurMax: timing.bubbleBlurMax ?? null,
        bubbleLead: timing.bubbleLead ?? 0,
        bubbleLeadRamp: timing.bubbleLeadRamp ?? 0,
        bubbleLeadPower: timing.bubbleLeadPower ?? 2,
        bubbleExitSlide: timing.bubbleExitSlide ?? 0,
        bubbleExitSlidePower: timing.bubbleExitSlidePower ?? 1,
        bubbleOrigin: timing.bubbleOrigin ?? null,
        bubbleHold: timing.bubbleHold ?? 0,
        bubbleResolve: timing.bubbleResolve ?? null,
        bubbleFade: timing.bubbleFade ?? null,
        exitScale: timing.exitScale ?? null,
        exitTravel: timing.exitTravel ?? null,
        exitLeadingFade: timing.exitLeadingFade ?? 1,
        enterScale: timing.enterScale ?? null,
        enterSqueeze: timing.enterSqueeze ?? 0,
        enterSqueezeOrigin: timing.enterSqueezeOrigin ?? 0,
        enterNarrow: timing.enterNarrow ?? 0,
        trailingSlide: timing.trailingSlide ?? 0,
        trailingSlidePower: timing.trailingSlidePower ?? 1,
        enterClear: timing.enterClear ?? 0,
        trailingEnterClear: timing.trailingEnterClear ?? timing.enterClear ?? 0,
        clipFollow: timing.clipFollow ?? 0,
        exitBlur: timing.exitBlur ?? null,
        bubbleExitBlur: timing.bubbleExitBlur ?? null,
        exitSharpen: timing.exitSharpen ?? 1,
        rowAnchor: timing.rowAnchor ?? 0,
        bubbleCap: timing.bubbleCap ?? 0,
        bubbleTrailingFade: timing.bubbleTrailingFade ?? 0,
        bubbleTrailingSlide: timing.bubbleTrailingSlide ?? null,
        bubbleTrailingBlur: timing.bubbleTrailingBlur ?? null,
        bubbleSettle: timing.bubbleSettle?.depth ?? 0,
        trailingEnterBlur: timing.trailingEnterBlur ?? null,
        trailingScale: timing.trailingScale ?? null,
        enterGlow: timing.enterGlow ?? 0,
        bottomAnchor: timing.bottomAnchor ?? 0,
        trailingRide: timing.trailingRide ?? null,
        trailingExitAnchor: timing.trailingExitAnchor ?? null,
        follow: timing.follow ?? null,
        partStep: timing.partStep ?? null,
        bubbleExitAccent: timing.bubbleExitAccent ?? false,
        bubbleBlur: timing.bubbleBlur,
        bubbleSharpen: timing.bubbleSharpen,
        centerDelay: timing.centerDelay,
        regions: timing.regions ?? {},
        regionExitFade: timing.regionExitFade ?? {},
        regionBottomAnchor: timing.regionBottomAnchor ?? {},
      };
      looks.current.set(p.contentKey, look);
      // Its lagging parts read its presence up to `lagOf(look)` back: one that left a moment ago
      // comes back with that past still showing to them, even from nothing now. Counted as a
      // rejoin only when it showed now, a long press that brought the card back 0.23 s after its
      // collapse drew the lagging center at 0.34 from the first instant (seed 835).
      // Read at nine points across that span (a sampling grid, not a fitted number).
      const lagSpan = lagOf(look);
      const shownSince = Array.from({ length: 9 }, (_, k) => current.valueAt(changedAt / 1000 - (lagSpan * k) / 8)).some((value) => value > 0.001);
      if (mode === "spring" && shownSince) rejoins.current.add(p.contentKey);
      else rejoins.current.delete(p.contentKey);
      cutting.current.delete(p.contentKey);
      removing.current.delete(p.contentKey);
      bubbleExits.current.delete(p.contentKey);
      bubbleEnters.current.delete(p.contentKey);
      trailingEnters.current.delete(p.contentKey);
      bubbleSettles.current.delete(p.contentKey);
      partSteps.current.delete(p.contentKey);
      leavingSlides.current.delete(p.contentKey);
      if (timing.trailingEnter && mode === "spring") {
        const own = new AnimatedValue(clamp01(current.valueAt(t0)), 0.001);
        own.set(1, t0, fade(timing.trailingEnter));
        trailingEnters.current.set(p.contentKey, own);
      }
      if (timing.bubbleEnter && mode === "spring") {
        const own = new AnimatedValue(clamp01(current.valueAt(t0)), 0.001);
        own.set(1, t0, fade(timing.bubbleEnter));
        bubbleEnters.current.set(p.contentKey, own);
      }
      if (timing.bubbleSettle && timing.bubbleSettle.depth > 0 && mode === "spring") {
        const settle = new AnimatedValue(0, 0.001);
        settle.set(1, t0, fade(timing.bubbleSettle));
        bubbleSettles.current.set(p.contentKey, settle);
      }
      if (timing.partStep && mode === "spring") {
        // 0 until `at`, then a step to 1 that settles back to 0 on the step's spring.
        const step = new AnimatedValue(0, 0.001);
        step.set(1, t0, { kind: "tween", duration: 0, delay: timing.partStep.at });
        step.set(0, t0, { kind: "spring", spring: timing.partStep.spring, delay: timing.partStep.at });
        partSteps.current.set(p.contentKey, step);
      }
      current.set(1, t0, fade(timing.enter));
      const bubbleExit = timing.bubbleExit;
      // What this change takes out may leave on a look of its own when the compact pill it leaves is
      // wide (`exitWide`): W's dismiss and A's both go to idle, so `wide` cannot tell them apart. Only
      // a compact pill: an alert's card going to idle is wider still, and its look switched on content
      // already leaving held it at 2% until it hid (seed 508).
      const { from: exitWideFrom = Number.MAX_VALUE, ...exitWideLook } = timing.exitWide ?? {};
      const leftWide = prev.kind === "compact" && prev.target !== null && prev.target.right - prev.target.left >= exitWideFrom;
      const exitLook: LayerLook = leftWide ? { ...look, ...exitWideLook } : look;
      for (const key of leavingKeys.current) {
        const leavingPresence = presence.current.get(key);
        if (bubbleExit) {
          // From what shows now; a bubble already cut stays cut whatever comes next.
          const shown = clamp01(Math.min(leavingPresence?.valueAt(t0) ?? 1, bubbleExits.current.get(key)?.valueAt(t0) ?? 1));
          const out = new AnimatedValue(shown, 0.001);
          out.set(0, t0, mode === "spring" ? bubbleCut(bubbleExit) : fade(bubbleExit));
          bubbleExits.current.set(key, out);
        }
        // A trailing slot still sliding in keeps its drawn offset and lets it go on the exit's
        // spring, at the speed it was closing (an expansion that interrupts a collapse's return:
        // the digits came in from 12 pt out). One already leaving with a kept offset keeps easing it.
        const was = looks.current.get(key);
        if (mode !== "spring") leavingSlides.current.delete(key);
        else if (was && leavingPresence && leavingPresence.target === 1) {
          leavingSlides.current.delete(key);
          const rejoined = rejoins.current.has(key);
          const slideAt = (time: number) =>
            was.trailingSlide * (1 - enteringTrailing(leavingPresence, trailingEnters.current.get(key), was.trailingDelay, time, rejoined)) ** was.trailingSlidePower;
          const offset = was.trailingSlide !== 0 ? slideAt(t0) : 0;
          if (Math.abs(offset) > 0.005) {
            const h = speedStep;
            const slide = new AnimatedValue(offset, 0.005);
            slide.set(0, t0, { kind: "spring", spring: { response: Math.max(timing.exit.response, motion.content.carryResponseMin), dampingFraction: carryDamping } }, { value: offset, velocity: (offset - slideAt(t0 - h)) / h });
            leavingSlides.current.set(key, slide);
          }
        }
        // An expanded layer interrupted on its way in keeps its clip following the content (`clipFollow`),
        // so the clip does not jump to the outline's; one that had come in fully leaves on the live clip.
        // A layer already on its way out keeps the clip it leaves with, through any later change.
        const comingIn = was !== undefined && leavingPresence?.target === 1 && full(clamp01(leavingPresence.valueAt(t0))) < 1;
        const goingOut = was !== undefined && leavingPresence?.target === 0;
        const leavingClip = (comingIn || goingOut) && mode === "spring" ? was.clipFollow : 0;
        // A layer already on its way out keeps going; the new transition's exit takes over. A near-cut
        // exit is for the layer the transition takes out (iOS: split-collapse-b's card is gone at +1
        // on 12 of 12 takes); one already going out on another exit keeps that one, which at 75%
        // opacity took the compact content out in two frames (seed 668). One being cut finishes its
        // cut whatever exit comes next, rather than holding what is left of it for that exit (seed
        // 1060: the card held at 14% for 0.3 s).
        const nearCut = mode === "spring" && timing.exit.response < motion.content.carryResponseMin;
        const goingAlready = leavingPresence?.target === 0;
        const keepsExit = goingAlready && mode === "spring" && (nearCut || cutting.current.has(key));
        if (!keepsExit) {
          leavingPresence?.set(0, t0, fade(timing.exit));
          if (nearCut) cutting.current.add(key);
          else cutting.current.delete(key);
        }
        // A layer that keeps its exit keeps the look it leaves with, so it draws that exit as it
        // would have: the new look's fade power on the old cut took a card from 14% to 2% in half a
        // frame where the cut alone draws 3% (seed 5040).
        if (!(keepsExit && was)) looks.current.set(key, { ...exitLook, bubbleDelay: 0, trailingDelay: 0, centerDelay: 0, regions: {}, clipFollow: leavingClip });
        // Don't strand keyboard focus inside content that is going away.
        const leavingRoot = slots.current.get(key)?.root;
        if (leavingRoot && typeof document !== "undefined" && leavingRoot.contains(document.activeElement)) {
          pillHit.current?.focus({ preventScroll: true });
        }
      }
      carryOver(shownBefore, changedAt, mode, timing, motion.content.carryResponseMin);
    }

    last.current = {
      key: p.contentKey,
      kind: toKind,
      changeId: change?.id ?? null,
      width,
      target,
      pressed: p.pressed,
      joining,
      activityId: p.activityId,
      alerting: p.alerting,
      handingOff,
    };
    draw(p.clock.now());
    run();
  }, [draw, run, sample, carryOver]);

  // Runs after every commit: content may have changed size even when the presentation didn't.
  useLayoutEffect(() => {
    retarget();
  });

  // Drop slot maps and presence for layers that are gone.
  useLayoutEffect(() => {
    const keep = new Set([contentKey, ...visibleLeaving.map((layer) => layer.key)]);
    for (const key of [...presence.current.keys()]) if (!keep.has(key)) presence.current.delete(key);
    for (const key of [...bubbleExits.current.keys()]) if (!keep.has(key)) bubbleExits.current.delete(key);
    for (const key of [...bubbleEnters.current.keys()]) if (!keep.has(key)) bubbleEnters.current.delete(key);
    for (const key of [...trailingEnters.current.keys()]) if (!keep.has(key)) trailingEnters.current.delete(key);
    for (const key of [...bubbleSettles.current.keys()]) if (!keep.has(key)) bubbleSettles.current.delete(key);
    for (const key of [...partSteps.current.keys()]) if (!keep.has(key)) partSteps.current.delete(key);
    for (const key of [...leavingSlides.current.keys()]) if (!keep.has(key)) leavingSlides.current.delete(key);
    for (const key of [...carries.current.keys()]) if (!keep.has(key)) carries.current.delete(key);
    for (const key of [...rejoins.current]) if (!keep.has(key)) rejoins.current.delete(key);
    for (const key of [...cutting.current]) if (!keep.has(key)) cutting.current.delete(key);
    for (const key of [...capHolds.current.keys()]) if (!keep.has(key)) capHolds.current.delete(key);
    for (const key of [...looks.current.keys()]) if (!keep.has(key)) looks.current.delete(key);
    for (const key of [...rests.current.keys()]) if (!keep.has(key)) rests.current.delete(key);
    for (const key of [...slots.current.keys()]) if (!keep.has(key)) slots.current.delete(key);
    for (const key of [...removing.current]) if (!keep.has(key)) removing.current.delete(key);
  });

  // Track the container width (desktop vs phone) and content that resizes outside React renders.
  useLayoutEffect(() => {
    const element = root.current;
    if (!element) return;
    setContainerWidth(element.clientWidth);
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(() => setContainerWidth(element.clientWidth));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  useLayoutEffect(() => {
    if (typeof ResizeObserver === "undefined") return;
    const map = slots.current.get(contentKey);
    const observed = [
      map?.leading,
      map?.trailing,
      map?.expandedInner,
      map?.expandedLeading,
      map?.expandedCenter,
      map?.expandedTrailing,
      map?.expandedBottom,
      map?.splitAttachedLeading,
      map?.splitAttachedTrailing,
      map?.splitDetachedLeading,
      map?.splitDetachedTrailing,
    ].filter((el): el is HTMLElement => el !== undefined);
    if (observed.length === 0) return;
    const observer = new ResizeObserver(() => retarget());
    for (const element of observed) observer.observe(element);
    return () => observer.disconnect();
  }, [contentKey, retarget]);

  useLayoutEffect(
    () => () => {
      unsubscribe.current?.();
      unsubscribe.current = null;
      skirts.current.clear();
    },
    [],
  );

  // First paint (including server HTML) shows the pill where it will rest.
  const [initialPaths] = useState(
    () =>
      frameAt(
        shape.current ?? createShapeAnimation(shapeTarget("idle", emptyMeasure, metrics.screen.width, metrics), metrics),
        0,
        metrics.screen.width,
        metrics,
      ).paths,
  );

  const setRoot = useCallback(
    (element: HTMLDivElement | null) => {
      root.current = element;
      live.current.rootRef?.(element);
    },
    // Stable on purpose: a new ref callback each render would detach and reattach the root.
    [],
  );

  const keyDown = (target: PressTarget) => (event: KeyboardEvent<HTMLButtonElement>) => {
    if (event.key !== "Enter" && event.key !== "") return;
    event.preventDefault();
    interaction?.onActivate(target);
  };

  const layers: Layer[] = [...visibleLeaving, { key: contentKey, presentation }];

  const grainLevels = metrics.expanded.shadow.grain.levels;
  const grainFull = metrics.expanded.shadow.grain.full;
  return (
    <div
      ref={setRoot}
      role="region"
      aria-label={props.regionLabel}
      data-islandcn=""
      data-presentation={presentation.kind}
      className={props.className}
      style={{
        position: props.placement === "viewport" ? "fixed" : "absolute",
        top: 0,
        left: 0,
        right: 0,
        height: 0,
        zIndex: 50,
        pointerEvents: "none",
        ...props.style,
      }}
    >
      <style href="islandcn-surface" precedence="islandcn">
        {surfaceCss}
      </style>
      <div
        style={{
          position: "absolute",
          top: 0,
          left: "50%",
          width: stageWidth,
          height: stageHeight,
          marginLeft: -stageWidth / 2,
        }}
      >
        {/* The shadow in Apple's WebKit (`placeShadow`); hidden elsewhere. */}
        <div ref={shadowPill} aria-hidden="true" style={shadowBox} />
        <div ref={shadowBubble} aria-hidden="true" style={shadowBox} />
        <svg
          ref={svg}
          aria-hidden="true"
          width={stageWidth}
          height={stageHeight}
          viewBox={`0 0 ${stageWidth} ${stageHeight}`}
          shapeRendering="geometricPrecision"
          style={{ position: "absolute", inset: 0, overflow: "visible" }}
        >
          {/*
            The shadow: a key layer and a broad, faint tail, each the shape's alpha blurred,
            moved down and scaled by a per-frame slope, merged under the shape. No single CSS
            drop-shadow matched the simulator's falloff (Chrome's large blur is not quite
            Gaussian); see `metrics.expanded.shadow`.
          */}
          <defs>
            <filter
              id={filterId}
              filterUnits="userSpaceOnUse"
              x={-300}
              y={-300}
              width={stageWidth + 600}
              height={stageHeight + 600}
              colorInterpolationFilters="sRGB"
            >
              <feGaussianBlur in="SourceAlpha" stdDeviation={blurDeviation(metrics.expanded.shadow)} result="keyBlur" />
              <feOffset in="keyBlur" dx={0} dy={metrics.expanded.shadow.offsetY} result="keyMoved" />
              <feComponentTransfer in="keyMoved" result="key">
                <feFuncA ref={shadowKey} type="linear" slope={0} />
              </feComponentTransfer>
              <feGaussianBlur in="SourceAlpha" stdDeviation={blurDeviation(metrics.expanded.shadow.tail)} result="tailBlur" />
              <feOffset in="tailBlur" dx={0} dy={metrics.expanded.shadow.tail.offsetY} result="tailMoved" />
              <feComponentTransfer in="tailMoved" result="tail">
                <feFuncA ref={shadowTail} type="linear" slope={0} />
              </feComponentTransfer>
              <feMerge result="shade">
                <feMergeNode in="tail" />
                <feMergeNode in="key" />
              </feMerge>
              {grain && grainLevels > 0 ? (
                <>
                  {/*
                    The grain (`expanded.shadow.grain`): shade + g x (noise - 1/2) x levels / 255,
                    g the shade's alpha over `full`, capped at 1. Filter results are clamped to
                    0..1, so the half is taken off after the noise is added, never before.
                  */}
                  <feImage href={grain.href} x={0} y={0} width={grain.size} height={grain.size} preserveAspectRatio="none" result="grainTile" />
                  <feTile in="grainTile" result="grainNoise" />
                  <feComponentTransfer in="shade" result="grainGate">
                    <feFuncA type="linear" slope={1 / Math.max(1e-4, grainFull)} />
                  </feComponentTransfer>
                  <feComposite in="grainGate" in2="grainNoise" operator="arithmetic" k1={1} k2={0} k3={0} k4={0} result="grainScaled" />
                  <feComposite in="shade" in2="grainScaled" operator="arithmetic" k1={0} k2={1} k3={grainLevels / 255} k4={0} result="shadeRaised" />
                  <feComposite in="shadeRaised" in2="grainGate" operator="arithmetic" k1={0} k2={1} k3={-grainLevels / 510} k4={0} result="shadeGrain" />
                  <feMerge>
                    <feMergeNode in="shadeGrain" />
                    <feMergeNode in="SourceGraphic" />
                  </feMerge>
                </>
              ) : (
                <feMerge>
                  <feMergeNode in="shade" />
                  <feMergeNode in="SourceGraphic" />
                </feMerge>
              )}
            </filter>
          </defs>
          {/* Keyline strokes under the fills: only their outer half shows, outside the black edge. */}
          <g fill="none" stroke="#fff" strokeWidth={metrics.keyline.width * 2} strokeOpacity={0} strokeLinejoin="round">
            <path ref={kPill} d={initialPaths.pill} />
            <path ref={kBridge} d={initialPaths.bridge} />
            <path ref={kBubble} d={initialPaths.bubble} />
          </g>
          <path ref={svgPill} d={initialPaths.pill} fill="#000" />
          <path ref={svgBridge} d={initialPaths.bridge} fill="#000" />
          <path ref={svgBubble} d={initialPaths.bubble} fill="#000" />
        </svg>
        {interaction ? (
          <button
            ref={pillHit}
            type="button"
            data-islandcn-hit="pill"
            aria-label={interaction.pillLabel ?? undefined}
            aria-hidden={interaction.pillLabel === null || undefined}
            tabIndex={interaction.pillLabel === null ? -1 : undefined}
            aria-expanded={interaction.expanded}
            style={{ pointerEvents: "auto" }}
            onPointerDown={(event) => interaction.onPressStart("pill", event)}
            onPointerUp={(event) => interaction.onPressEnd(event)}
            onPointerCancel={() => interaction.onPressCancel()}
            onPointerLeave={() => interaction.onPressCancel()}
            onContextMenu={(event) => event.preventDefault()}
            onKeyDown={keyDown("pill")}
          />
        ) : null}
        {interaction?.bubbleLabel ? (
          <button
            ref={bubbleHit}
            type="button"
            data-islandcn-hit="bubble"
            aria-label={interaction.bubbleLabel}
            style={{ pointerEvents: "auto", display: "none" }}
            onPointerDown={(event) => interaction.onPressStart("bubble", event)}
            onPointerUp={(event) => interaction.onPressEnd(event)}
            onPointerCancel={() => interaction.onPressCancel()}
            onPointerLeave={() => interaction.onPressCancel()}
            onContextMenu={(event) => event.preventDefault()}
            onKeyDown={keyDown("bubble")}
          />
        ) : null}
        <div
          ref={content}
          style={{
            position: "absolute",
            inset: 0,
            pointerEvents: "none",
            color: "#fff",
            fontFamily: '-apple-system, BlinkMacSystemFont, "Inter", "Geist", system-ui, sans-serif',
            WebkitFontSmoothing: "antialiased",
            fontSize: 15,
            lineHeight: 1.25,
            clipPath: initialPaths.pill ? `path("${initialPaths.clip}")` : undefined,
          }}
        >
          {layers.map((layer) => (
            <IslandLayer
              key={layer.key}
              presentation={layer.presentation}
              register={(slot, element) => register(layer.key, slot, element)}
              metrics={metrics}
              expandedWidth={expandedWidth}
              leaving={layer.key !== contentKey}
            />
          ))}
        </div>
        {metrics.sensor.opacity > 0 ? (
          // The sensor housing stays put above the content, as the hardware does: content sliding
          // under it is hidden there. Same continuous capsule as the idle pill, inset by half a
          // point: flush with it, its antialiased edge would stack on the pill's and read larger.
          <svg
            aria-hidden="true"
            data-islandcn-sensor=""
            width={stageWidth}
            height={stageHeight}
            viewBox={`0 0 ${stageWidth} ${stageHeight}`}
            shapeRendering="geometricPrecision"
            style={{ position: "absolute", inset: 0, overflow: "visible", pointerEvents: "none", opacity: metrics.sensor.opacity }}
          >
            <path
              d={continuousRectPath(
                stageWidth / 2 - metrics.idle.width / 2 + sensorInset,
                metrics.top + sensorInset,
                metrics.idle.width - 2 * sensorInset,
                metrics.idle.height - 2 * sensorInset,
                metrics.idle.height / 2 - sensorInset,
                metrics.corner.smoothing,
              )}
              fill="#000"
            />
          </svg>
        ) : null}
      </div>
      <span aria-live="polite" style={srOnly}>
        {props.liveLabel}
      </span>
    </div>
  );
};
