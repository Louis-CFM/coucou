import { bubblePose, pillPose, type ShapeAnimation } from "./frame";
import type { ShapeTarget } from "./geometry";
import type { IslandMetrics } from "./metrics";
import type { ContentMotion, IslandMotion, ShapeTransition, TailLegs } from "./motion";
import type { SpringConfig, Transition } from "./spring";

/**
 * How one presentation change moves the shape: which spring drives each property, which legs go
 * through the idle shape, and how the detached bubble pinches off or merges. Pure: the renderer
 * and the headless simulator (`scripts/fidelity/sim.ts`) both call it, so a fitted curve is the
 * curve the page plays.
 */

/** "spring" plays the motion, "reduced" eases with no overshoot, "instant" snaps. */
export type MotionMode = "spring" | "reduced" | "instant";

export interface ShapeChange {
  transition: ShapeTransition;
  target: ShapeTarget;
  /** The idle shape, which activity-swapping morphs pass through. */
  idle: ShapeTarget;
  /** Clock time in seconds the change starts at. */
  t0: number;
  motion: IslandMotion;
  mode: MotionMode;
}

type Start = { value: number; velocity: number };

const instant: Transition = { kind: "instant" };

/**
 * Whether a change takes a visible bubble in as its own lobe: unsplit, and a swap from the split to
 * an expanded view (a long-press on the bubble). Its shape turns late (`retargetShape`) and its
 * incoming content may have its own timing (`ContentMotion.absorb`).
 */
export const absorbsBubble = (anim: ShapeAnimation, options: { transition: ShapeTransition; target: { bubbleHeight: number }; t0: number }): boolean => {
  const { transition, target, t0 } = options;
  return anim.bubbleHeight.valueAt(t0) >= 0.5 && target.bubbleHeight === 0 && (transition === "unsplit" || transition === "swap");
};

export const retargetShape = (anim: ShapeAnimation, change: ShapeChange): void => {
  const { transition: kind, target, idle, t0, motion, mode } = change;
  if (target.height > anim.restHeight) anim.restHeight = target.height;

  // The expanded shadow eases in behind an opening shape (`shadowRamp`) and otherwise follows it.
  const opening = target.height > idle.height + 1 && anim.height.valueAt(t0) < idle.height + 0.05 * (target.height - idle.height);
  if (mode === "spring" && opening) {
    anim.shadow.set(0, t0, instant);
    anim.shadow.set(1, t0, { kind: "spring", spring: kind === "pressExpand" ? motion.shadowRampPress : motion.shadowRamp });
  } else {
    anim.shadow.set(1, t0, instant);
  }

  if (mode !== "spring") {
    const go: Transition = mode === "instant" ? instant : { kind: "tween", duration: motion.reduced.duration };
    for (const key of ["left", "right", "top", "height", "radius", "bubbleLeft", "bubbleRight", "bubbleHeight"] as const) {
      anim[key].set(target[key], t0, go);
    }
    anim.leadRadius.set(target.radius, t0, go);
    anim.lift.set(0, t0, go);
    anim.bubbleRise.set(0, t0, instant);
    anim.squish.set(0, t0, go);
    anim.bubbleSquish.set(0, t0, go);
    anim.widen.set(0, t0, go);
    return;
  }

  const go = (spring: SpringConfig, delay = 0): Transition => ({ kind: "spring", spring, delay });
  anim.neck = null;
  const edges = kind === "appear" ? appearEdges(motion, target.right - target.left) : motion.shape[kind];

  // A visible bubble that goes away. On unsplit, and on a swap from the split to an expanded view
  // (a long-press on the bubble), it slides into the pill as its own lobe (below): the two join with
  // a waist and contract toward the sensor (unsplit-t1; held-out split-expand-b). Anything else (both
  // activities ending) merges it within one tick.
  const bubbleShown = anim.bubbleHeight.valueAt(t0) >= 0.5;
  const absorbing = absorbsBubble(anim, { transition: kind, target, t0 });
  // A join that led this change (`leadJoin`) carries on into it; any other change ends it.
  if (!absorbing) anim.joinFrom = null;

  // Absorbing the bubble, the shape turns when the lobe is gone: the unsplit's turn toward compact
  // (unsplit-t1 +0.203 s), `bubble.absorbExpand` toward an expanded view (split-expand-b's takes,
  // against split-alert-t1's +0.231 out of a single pill). The body and corner wait for the turn,
  // so they move with it.
  const via = absorbing ? (kind === "swap" ? (motion.bubble.absorbExpand ?? motion.viaIdle.unsplit) : motion.viaIdle.unsplit) : motion.viaIdle[kind];
  const turnShift = via - motion.viaIdle[kind];
  const body = { ...motion.body[kind], delay: Math.max(0, motion.body[kind].delay + (motion.body[kind].delay > 0 ? turnShift : 0)) };
  const second = kind === "collapse" ? motion.retarget.collapse : kind === "alertCollapse" ? motion.retarget.alertCollapse : edges;

  // Fold a long-press swell (and an idle swell's widening) into the base values so the change
  // carries its size and speed.
  const start: { left?: Start; right?: Start; top?: Start; height?: Start; radius?: Start; leadRadius?: Start } = {};
  const squish = anim.squish.valueAt(t0);
  const moving = (value: ShapeAnimation["squish"]) => Math.abs(value.valueAt(t0)) > 1e-4 || Math.abs(value.velocityAt(t0)) > 1e-3;
  if (moving(anim.squish) || moving(anim.widen)) {
    const pose = pillPose(anim, t0);
    const g = 1 + squish * anim.squishFactor;
    start.left = pose.left;
    start.right = pose.right;
    start.top = pose.top;
    start.height = pose.height;
    start.radius = { value: anim.radius.valueAt(t0) * g, velocity: anim.radius.velocityAt(t0) * g };
    start.leadRadius = { value: anim.leadRadius.valueAt(t0) * g, velocity: anim.leadRadius.velocityAt(t0) * g };
    anim.squish.set(0, t0, instant);
    anim.widen.set(0, t0, instant);
  }

  // The same for a long-press on the bubble: its swell becomes the bubble's starting edges.
  const bubbleStart: { left?: Start; right?: Start; height?: Start } = {};
  const bubbleSquish = anim.bubbleSquish.valueAt(t0);
  if (Math.abs(bubbleSquish) > 1e-4 || Math.abs(anim.bubbleSquish.velocityAt(t0)) > 1e-3) {
    const pose = bubblePose(anim, t0);
    bubbleStart.left = pose.left;
    bubbleStart.right = pose.right;
    bubbleStart.height = pose.height;
    anim.bubbleSquish.set(0, t0, instant);
  }

  if (bubbleShown && target.bubbleHeight === 0 && !absorbing) {
    const bubbleRight = anim.bubbleRight.valueAt(t0);
    if (bubbleRight > anim.right.valueAt(t0)) start.right = { value: bubbleRight, velocity: anim.bubbleRight.velocityAt(t0) };
    anim.bubbleHeight.set(0, t0, instant);
  }

  const edge = (value: ShapeAnimation["left"], to: number, idleTo: number, from?: Start) => {
    if (via > 0) {
      value.set(idleTo, t0, go(edges), from);
      value.set(to, t0, go(second, via));
    } else {
      value.set(to, t0, go(edges), from);
    }
  };
  if (kind === "collapseSplit" && target.bubbleHeight > 0) {
    // split-alert-t1: the attached pill settles wider first, then narrows to its place.
    const spread = motion.bubble.collapseSplitSpread;
    const via = motion.bubble.collapseSplitVia;
    anim.left.set(target.left - spread.left, t0, go(edges), start.left ?? kicked(anim.left, target.left - spread.left, t0, spread.kick));
    anim.left.set(target.left, t0, go(spread, spread.at));
    // The right side shrinks as one blob with the bubble first (down to the bubble's dip), then
    // pulls back to the sensor's edge, which is what pinches the bubble off.
    anim.right.set(target.bubbleRight - via.dip, t0, go(via.down), start.right);
    if (spread.right !== 0) {
      // split-alert-t1: it holds just outside the sensor's edge first (and touches the bubble again
      // for a few frames), then pulls back. Under the bulb the body peels in ahead of the bubble's
      // right edge first (`rightPeel`), so the two share the down leg only until then.
      const peel = spread.rightPeel;
      if (peel.at < spread.rightSettle.at) anim.right.set(target.right + peel.to, t0, go(peel, peel.at));
      anim.right.set(target.right + spread.right, t0, go(spread.rightSettle, spread.rightSettle.at));
      anim.right.set(target.right, t0, go(spread.rightBack, spread.rightBack.at));
    } else {
      anim.right.set(target.right, t0, go(edges, via.at));
    }
    const tip = spread.neckTip;
    anim.neck = { gap: spread.neckGap, power: spread.neckPower, ...(tip ? { tip: { length: tip.length, reach: tip.reach, until: t0 + tip.until } } : {}) };
  } else {
    edge(anim.left, target.left, idle.left, start.left);
    edge(anim.right, target.right, idle.right, start.right);
  }

  anim.height.set(target.height, t0, go(body, body.delay), start.height);
  // Absorbing the bubble, the corner may have its own spring from the turn (`absorbExpandCorner`).
  const absorbCorner = absorbing && kind === "swap" ? motion.bubble.absorbExpandCorner : undefined;
  const corner = absorbCorner ?? motion.corner[kind];
  const cornerDelay = absorbCorner ? Math.max(0, via + absorbCorner.delay) : corner.delay > 0 ? Math.max(0, corner.delay + turnShift) : 0;
  anim.radius.set(target.radius, t0, go(corner, cornerDelay), start.radius);
  // The left corners may have their own spring (`cornerLead`, round 43); otherwise they move as one.
  const lead = absorbCorner ? undefined : motion.cornerLead?.[kind];
  const leadDelay = lead ? (lead.delay > 0 ? Math.max(0, lead.delay + turnShift) : 0) : cornerDelay;
  anim.leadRadius.set(target.radius, t0, go(lead ?? corner, leadDelay), start.leadRadius);
  if (lead?.trailing) anim.cornerTrail = { above: lead.trailing.above, below: lead.trailing.below };
  if ((kind === "collapse" || kind === "alertCollapse") && via > 0) {
    // collapse-t1: the top lifts about 1.2 pt while the shape heads for idle, then settles.
    anim.top.set(target.top - motion.collapseLift, t0, go(body), start.top);
    anim.top.set(target.top, t0, go(second, via));
  } else {
    anim.top.set(target.top, t0, go(body, body.delay), start.top);
  }

  // How the motion ends (`islandMotion.tail`): a lean past the target and a settle onto it, queued
  // after the legs above. The split's edges have their own legs, so only its height and top take one.
  const tail = motion.tail[kind];
  const ownEdges = kind === "collapseSplit" && target.bubbleHeight > 0;
  const width0 = (start.right?.value ?? anim.right.valueAt(t0)) - (start.left?.value ?? anim.left.valueAt(t0));
  const height0 = start.height?.value ?? anim.height.valueAt(t0);
  const top0 = start.top?.value ?? anim.top.valueAt(t0);
  if (!ownEdges) {
    const lean = leanOf(tail.width, target.right - target.left - width0);
    queueTail(anim.left, { to: target.left, lean: -lean / 2, legs: tail.width, t0 });
    queueTail(anim.right, { to: target.right, lean: lean / 2, legs: tail.width, t0 });
  }
  queueTail(anim.height, { to: target.height, lean: leanOf(tail.height, target.height - height0), legs: tail.height, t0 });
  queueTail(anim.top, { to: target.top, lean: leanOf(tail.top, target.top - top0), legs: tail.top, t0 });
  if (kind === "collapseSplit" && target.bubbleHeight > 0) {
    // split-alert-t1: the pill lifts as it shrinks and settles back; the bubble keeps its place.
    const lift = motion.bubble.collapseSplitLift;
    anim.lift.set(lift.by, t0, go(lift));
    anim.lift.set(0, t0, go(lift.back, lift.back.at));
  } else {
    anim.lift.set(0, t0, go(body));
  }

  if (!(kind === "collapseSplit" && target.bubbleHeight > 0 && !bubbleShown) && anim.bubbleRise.target !== 0) {
    // Only the collapse into the split lifts the bubble; anywhere else the pill is capsule height,
    // where the rise makes no difference, or the bubble is about to merge.
    anim.bubbleRise.set(0, t0, instant);
  }
  if (target.bubbleHeight > 0 && !bubbleShown) {
    // The bubble grows out of the pill's trailing end: its right edge rides the shape spring and
    // its left edge waits inside the pill, then springs out. That spring is the pinch-off.
    const bubble = kind === "collapseSplit" ? motion.bubble.collapseSplit : motion.bubble.split;
    const h = target.bubbleHeight;
    anim.bubbleHeight.set(h, t0, instant);
    anim.bubbleLeft.set(target.right - h, t0, instant);
    if (kind === "collapseSplit") {
      // Out of the expanded shape the bubble's right edge rides the shrinking blob down past its
      // place, then grows back out: one tall shape first, the bubble only as it nears capsule height.
      const via = motion.bubble.collapseSplitVia;
      anim.bubbleRight.set(start.right?.value ?? anim.right.valueAt(t0), t0, instant);
      const down = target.bubbleRight - via.dip;
      anim.bubbleRight.set(down, t0, go(via.down));
      anim.bubbleRight.set(target.bubbleRight, t0, go(via, via.at));
    } else {
      anim.bubbleRight.set(start.right?.value ?? anim.right.valueAt(t0), t0, instant);
      edge(anim.bubbleRight, target.bubbleRight, idle.right);
    }
    if (kind === "collapseSplit") {
      // It starts level with the tall pill's middle and rides up to its top (`collapseSplitRise`).
      const rise = motion.bubble.collapseSplitRise;
      anim.bubbleRise.set(0, t0, instant);
      anim.bubbleRise.set(1, t0, go(rise, rise.delay));
      // Out of the expanded shape the bubble sits inside the blob, `bubbleFrom` points short of
      // its place, and springs out as the pill pulls back to the sensor's edge: the gap opens over
      // a few frames, so the neck thins before it breaks (split-alert-t1, 847 to 854).
      const from = motion.bubble.collapseSplitSpread.bubbleFrom;
      anim.bubbleLeft.set(target.bubbleLeft - from, t0, instant);
      if (from !== 0) anim.bubbleLeft.set(target.bubbleLeft, t0, go(bubble, bubble.delay));
    } else {
      anim.bubbleLeft.set(target.bubbleLeft, t0, go(bubble, bubble.delay));
    }
  } else if (target.bubbleHeight > 0) {
    anim.bubbleLeft.set(target.bubbleLeft, t0, go(edges));
    anim.bubbleRight.set(target.bubbleRight, t0, go(edges));
    anim.bubbleHeight.set(target.bubbleHeight, t0, go(edges));
  } else if (absorbing) {
    // unsplit-t1: the gap closes within a tick (the neck), the bubble slides left under the
    // sensor as its own lobe, and it is gone at `unsplitAbsorb`, as the shape turns toward compact.
    // Into an expanded view the lobe lasts until that turn too (`viaIdle`; held-out split-expand-b:
    // the lobe at 262 to 254 until +0.22 s, when the expansion starts), and a lobe still swollen
    // from the press relaxes to capsule height on the way (40.6 to 36.8 in five frames).
    const rest = anim.bubbleHeight.valueAt(t0);
    const h = bubbleStart.height?.value ?? rest;
    if (bubbleStart.height) {
      anim.bubbleHeight.set(h, t0, instant);
      anim.bubbleHeight.set(rest, t0, go(motion.bubble.unsplit));
    }
    anim.bubbleLeft.set(idle.right - rest, t0, go(motion.bubble.unsplit), bubbleStart.left);
    anim.bubbleRight.set(idle.right, t0, go(motion.bubble.unsplitSlide), bubbleStart.right);
    const absorbAt = kind === "unsplit" || via <= 0 ? motion.bubble.unsplitAbsorb : via;
    // A step, not a short tween: a frame inside a 1 ms collapse drew the lobe as a thin bar past
    // the pill's end (round 26: split-expand-b-t10's frame 270, a 2 px line 9.7 pt long).
    anim.bubbleHeight.set(0, t0, { kind: "tween", duration: 0, delay: absorbAt });
  } else {
    anim.bubbleLeft.set(target.bubbleLeft, t0, instant);
    anim.bubbleRight.set(target.bubbleRight, t0, instant);
    anim.bubbleHeight.set(0, t0, instant);
  }
};

/**
 * A long-press on the bubble is decided before the bubble joins the pill (`joinAt`, seconds). The
 * join's shape may start ahead of it (`bubble.joinLead`): the bubble's left edge closes the gap on
 * `bubble.unsplit` and the neck draws as in the merge, so the two read as one shape that much
 * sooner, while the change itself (the turn, the content) keeps its time. A null `joinAt` (the
 * press let go before it was decided) puts the bubble back at `restLeft`.
 */
export const leadJoin = (anim: ShapeAnimation, options: { joinAt: number | null; t: number; idleRight: number; restLeft: number; motion: IslandMotion; mode: MotionMode }): void => {
  const { joinAt, t, idleRight, restLeft, motion, mode } = options;
  const lead = motion.bubble.joinLead ?? 0;
  if (mode !== "spring" || lead <= 0) return;
  // Once the shape has left the split (an alert expanded the island under the held bubble) the
  // change that took the bubble in runs the join: there is none left to lead or to undo. Decided
  // after it, the lead sent the lobe's left edge to the pill's end (the bubble's target height
  // already 0), and its text dropped 6.9 px when the narrowed lobe went (seed 6768). Cleared after
  // it by the long-press's own timer, it sent the lobe back to `restLeft`, by then the expanded
  // view's hidden bubble 95 pt right of it: the lobe flew out past the pill (seed 23: 36 px).
  if (anim.bubbleHeight.target === 0) return;
  const unsplit: Transition = { kind: "spring", spring: motion.bubble.unsplit };
  if (joinAt === null) {
    if (anim.joinFrom === null) return;
    anim.joinFrom = null;
    anim.bubbleLeft.set(restLeft, t, unsplit);
    return;
  }
  const from = Math.max(t, joinAt - lead);
  anim.joinFrom = from;
  anim.bubbleLeft.set(idleRight - anim.bubbleHeight.target, t, { ...unsplit, delay: from - t });
};

/** Points a tail leans past its target for a change of `travel` points: `by` of it, at most `max`. */
const leanOf = (legs: TailLegs, travel: number) => Math.sign(legs.lean.by) * Math.min(Math.abs(legs.lean.by * travel), legs.lean.max);

/**
 * Queues a tail's legs on one value: from `lean.at` it heads for `to + lean`, from `settle.at` it
 * settles onto `to`. Both start after the legs already planned, so they only shape the ending.
 */
const queueTail = (value: ShapeAnimation["left"], options: { to: number; lean: number; legs: TailLegs; t0: number }): void => {
  const { to, lean, legs, t0 } = options;
  if (legs.lean.by !== 0 && legs.lean.at > 0) value.set(to + lean, t0, { kind: "spring", spring: legs.lean, delay: legs.lean.at });
  if (legs.settle.at > 0) value.set(to, t0, { kind: "spring", spring: legs.settle, delay: legs.settle.at });
};

/**
 * A leg that starts already moving: `kick` times its travel per second (round 23,
 * `collapseSplitVia.kick`). Undefined without a kick, so the leg starts from where it is, at rest.
 */
const kicked = (value: { valueAt: (t: number) => number }, to: number, t0: number, kick: number | undefined): { value: number; velocity: number } | undefined => {
  if (!kick) return undefined;
  const from = value.valueAt(t0);
  return { value: from, velocity: kick * (to - from) };
};

/** The appear's edge spring for a pill `width` points wide: `appearWide` blended in past its `from`. */
const appearEdges = (motion: IslandMotion, width: number): SpringConfig => {
  const base = motion.shape.appear;
  const wide = motion.appearWide;
  if (!wide || wide.to <= wide.from) return base;
  const k = Math.min(1, Math.max(0, (width - wide.from) / (wide.to - wide.from)));
  if (k === 0) return base;
  return {
    response: base.response + (wide.spring.response - base.response) * k,
    dampingFraction: base.dampingFraction + (wide.spring.dampingFraction - base.dampingFraction) * k,
  };
};

/**
 * The press. A long-press swells the pressed part (the pill, or the detached bubble on its own)
 * about its centre; the controlled `IslandView pressed` squishes the pill gently instead.
 */
export const retargetPress = (
  anim: ShapeAnimation,
  options: { pressed: "pill" | "bubble" | null; style: "swell" | "squish"; t: number; motion: IslandMotion; metrics: IslandMetrics; mode: MotionMode; idle?: boolean },
): void => {
  const { pressed, style, t, motion, metrics, mode, idle = false } = options;
  if (pressed) anim.squishFactor = style === "swell" ? metrics.press.swell : metrics.press.squish;
  // A swelling bubble closes the gap to about 4.2 pt with no neck between them (held-out
  // split-expand-b, frame 263); the two join only when the expansion absorbs the bubble.
  if (pressed === "bubble") anim.neck = { gap: 0.01, power: 1.5 };
  const go = (spring: SpringConfig): Transition =>
    mode === "instant" ? instant : mode === "reduced" ? { kind: "tween", duration: motion.reduced.duration } : { kind: "spring", spring };
  // The stack's swell springs back with no bounce (idletap-t1); the controlled squish rebounds.
  const down = style === "swell" ? motion.press.swell : motion.press.down;
  // An idle island's swell may turn back on its own spring, keeping only part of its outward speed
  // (`idleRelease`), so it rounds over a flat top (round 30).
  const idleRelease = style === "swell" && idle ? motion.press.idleRelease : undefined;
  const up = idleRelease ? idleRelease.spring : style === "swell" ? motion.press.release : motion.press.up;
  // The bubble may swell on its own spring and to its own size, in units of the pill's factor.
  const bubbleDown = style === "swell" ? (motion.press.bubbleSwell ?? down) : down;
  const bubbleTo = style === "swell" && anim.squishFactor > 0 ? (metrics.press.bubbleSwell ?? metrics.press.swell) / anim.squishFactor : 1;
  for (const [part, value] of [["pill", anim.squish], ["bubble", anim.bubbleSquish]] as const) {
    const on = pressed === part;
    // Leave a part that is already where it should be alone, so it stays at rest.
    if (!on && value.target === 0 && value.isAtRest(t)) continue;
    const bubble = part === "bubble";
    const from = !on && idleRelease && mode === "spring" ? { value: value.valueAt(t), velocity: value.velocityAt(t) * idleRelease.carry } : undefined;
    value.set(on ? (bubble ? bubbleTo : 1) : 0, t, go(on ? (bubble ? bubbleDown : down) : up), from);
    // As an idle pill's swell turns back, its width runs on: it widens on a slow spring and lets
    // go `hold` later (`idleWiden`, round 31), while its height returns with the swell.
    const widen = motion.press.idleWiden;
    if (!on && !bubble && idleRelease && widen && mode === "spring") {
      anim.widen.set(widen.by, t, { kind: "spring", spring: widen.rise });
      anim.widen.set(0, t, { kind: "spring", spring: widen.fall, delay: widen.hold });
    }
  }
};

/** Content crossfade settings for a transition. */
export const contentMotion = (motion: IslandMotion, transition: ShapeTransition): ContentMotion => motion.contentTiming[transition];
