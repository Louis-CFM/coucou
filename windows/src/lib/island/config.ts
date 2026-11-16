import { islandMetrics, type IslandMetrics } from "./metrics";
import { type BlurSkirt, type BubbleSettle, type ContentMotion, type CornerLead, type ExpandedRegion, islandMotion, type IslandMotion, type NeckTip, type RegionLag, type ShapeTail, type ShapeTransition, shapeTransitions, type TailLegs } from "./motion";

/** Every key optional, at every depth. Used for metrics and motion overrides. */
export type DeepPartial<T> = { [K in keyof T]?: T[K] extends number ? number : DeepPartial<T[K]> };

export type IslandMetricsOverrides = DeepPartial<IslandMetrics>;
export type IslandMotionOverrides = DeepPartial<IslandMotion>;

const expandedRegions = ["leading", "center", "trailing", "bottom"] as const satisfies readonly ExpandedRegion[];

type RegionLags = Partial<Record<ExpandedRegion, RegionLag>>;

/** The base for a partial `blurSkirt` override when the motion has none: no weight, so no copy. */
const noSkirt: BlurSkirt = { width: 13.3, gain: 0, max: 0, floor: 0 };

/** A `bubbleSettle` set on neither side: no settle (depth 0). */
/** No nub after the neck's first break: the base for a partial `neckTip` override when the motion has none. */
const noNeckTip: NeckTip = { length: 0, reach: 1, until: 0 };

/** A collapseSplitSpread override without its `neckTip`, which is merged on its own (a partial nub fills from the base). */
const withoutNeckTip = <T extends { neckTip?: unknown }>(over: T | undefined): Omit<T, "neckTip"> | undefined => {
  if (!over) return undefined;
  const { neckTip: _tip, ...rest } = over;
  return rest;
};

const noSettle: BubbleSettle = { depth: 0, response: 0.3, dampingFraction: 1, delay: 0 };

/** `bubbleSettle`, `over` on `base` field by field; absent on both sides it stays absent. */
const settleOf = (base: BubbleSettle | undefined, over: DeepPartial<BubbleSettle> | undefined): BubbleSettle | undefined =>
  base || over ? { ...(base ?? noSettle), ...over } : undefined;

/**
 * Per-region lags, `over` on `base`. A region on neither side stays absent (the center then waits
 * `centerDelay`); a field set on neither side is the center's `centerDelay`, or 0 elsewhere.
 */
const regionLags = (base: RegionLags | undefined, over: DeepPartial<RegionLags> | undefined, centerDelay: number): RegionLags | undefined => {
  if (!base && !over) return undefined;
  const out: RegionLags = {};
  for (const region of expandedRegions) {
    const b = base?.[region];
    const o = over?.[region];
    if (!b && !o) continue;
    const fallback = region === "center" ? centerDelay : 0;
    const soften = o?.soften ?? b?.soften;
    const lead = o?.lead ?? b?.lead;
    const peak = o?.peak ?? b?.peak;
    const scale = o?.scale ?? b?.scale;
    const lift = o?.lift ?? b?.lift;
    const power = o?.power ?? b?.power;
    out[region] = {
      fade: o?.fade ?? b?.fade ?? fallback,
      blur: o?.blur ?? b?.blur ?? fallback,
      ...(soften !== undefined ? { soften } : {}),
      ...(lead !== undefined ? { lead } : {}),
      ...(peak !== undefined ? { peak } : {}),
      ...(scale !== undefined ? { scale } : {}),
      ...(lift !== undefined ? { lift } : {}),
      ...(power !== undefined ? { power } : {}),
    };
  }
  return out;
};

/** Overlays `overrides` on the metrics table, one group at a time. */
export const resolveMetrics = (o?: IslandMetricsOverrides): IslandMetrics => {
  if (!o) return islandMetrics;
  const m = islandMetrics;
  return {
    screen: { ...m.screen, ...o.screen },
    top: o.top ?? m.top,
    idle: { ...m.idle, ...o.idle },
    corner: { ...m.corner, ...o.corner },
    compact: { ...m.compact, ...o.compact, innerPadding: { ...m.compact.innerPadding, ...o.compact?.innerPadding } },
    minimal: {
      ...m.minimal,
      ...o.minimal,
      attached: { ...m.minimal.attached, ...o.minimal?.attached },
      detached: { ...m.minimal.detached, ...o.minimal?.detached },
    },
    split: {
      ...m.split,
      ...o.split,
      attached: { ...m.split.attached, ...o.split?.attached },
      detached: { ...m.split.detached, ...o.split?.detached },
    },
    expanded: {
      ...m.expanded,
      ...o.expanded,
      padding: { ...m.expanded.padding, ...o.expanded?.padding },
      shadow: {
        ...m.expanded.shadow,
        ...o.expanded?.shadow,
        tail: { ...m.expanded.shadow.tail, ...o.expanded?.shadow?.tail },
        pull: { ...m.expanded.shadow.pull, ...o.expanded?.shadow?.pull },
        grain: { ...m.expanded.shadow.grain, ...o.expanded?.shadow?.grain },
      },
    },
    contentClip: { ...m.contentClip, ...o.contentClip },
    press: { ...m.press, ...o.press },
    bridge: { ...m.bridge, ...o.bridge },
    content: { ...m.content, ...o.content },
    sensor: { ...m.sensor, ...o.sensor },
    keyline: { ...m.keyline, ...o.keyline },
  };
};

/** Builds a per-transition record from the default entry and its override. */
const perTransition = <T,>(build: (transition: ShapeTransition) => T): Record<ShapeTransition, T> => {
  const out: Partial<Record<ShapeTransition, T>> = {};
  for (const transition of shapeTransitions) out[transition] = build(transition);
  const complete = (record: Partial<Record<ShapeTransition, T>>): record is Record<ShapeTransition, T> =>
    shapeTransitions.every((transition) => record[transition] !== undefined);
  if (!complete(out)) throw new Error("islandcn: motion table is missing a transition");
  return out;
};

const tailLegs = (base: TailLegs, over?: DeepPartial<TailLegs>): TailLegs => ({
  lean: { ...base.lean, ...over?.lean },
  settle: { ...base.settle, ...over?.settle },
});

const shapeTail = (base: ShapeTail, over?: DeepPartial<ShapeTail>): ShapeTail => ({
  width: tailLegs(base.width, over?.width),
  height: tailLegs(base.height, over?.height),
  top: tailLegs(base.top, over?.top),
});

/**
 * `cornerLead`, `over` on `base` per transition. A transition on neither side keeps no entry (its left
 * corners follow `corner`); a partial entry fills from the base's, or from that transition's `corner`.
 */
const cornerLeadOf = (m: IslandMotion, o: IslandMotionOverrides): Partial<Record<ShapeTransition, CornerLead>> => {
  const out: Partial<Record<ShapeTransition, CornerLead>> = {};
  for (const k of shapeTransitions) {
    const base = m.cornerLead?.[k];
    const over = o.cornerLead?.[k];
    if (!base && !over) continue;
    const { trailing: baseTrail, ...baseSpring } = base ?? { ...m.corner[k] };
    const trailing = baseTrail || over?.trailing ? { ...(baseTrail ?? noTrail), ...over?.trailing } : undefined;
    const { trailing: _trail, ...overSpring } = over ?? {};
    out[k] = { ...baseSpring, ...overSpring, ...(trailing ? { trailing } : {}) };
  }
  return out;
};

/** A `cornerLead.trailing` set on neither side: the right corners never share the leading radius. */
const noTrail = { above: Number.MAX_VALUE, below: Number.MAX_VALUE } as const;

/** Overlays `overrides` on the motion table, one spring at a time. */
export const resolveMotion = (o?: IslandMotionOverrides): IslandMotion => {
  if (!o) return islandMotion;
  const m = islandMotion;
  return {
    shape: perTransition((k) => ({ ...m.shape[k], ...o.shape?.[k] })),
    ...(m.appearWide || o.appearWide
      ? {
          appearWide: {
            from: o.appearWide?.from ?? m.appearWide?.from ?? 0,
            to: o.appearWide?.to ?? m.appearWide?.to ?? 0,
            spring: { ...(m.appearWide?.spring ?? m.shape.appear), ...o.appearWide?.spring },
          },
        }
      : {}),
    body: perTransition((k) => ({ ...m.body[k], ...o.body?.[k] })),
    corner: perTransition((k) => ({ ...m.corner[k], ...o.corner?.[k] })),
    ...(m.cornerLead || o.cornerLead ? { cornerLead: cornerLeadOf(m, o) } : {}),
    viaIdle: perTransition((k) => o.viaIdle?.[k] ?? m.viaIdle[k]),
    collapseLift: o.collapseLift ?? m.collapseLift,
    retarget: {
      collapse: { ...m.retarget.collapse, ...o.retarget?.collapse },
      alertCollapse: { ...m.retarget.alertCollapse, ...o.retarget?.alertCollapse },
    },
    tail: perTransition((k) => shapeTail(m.tail[k], o.tail?.[k])),
    bubble: {
      split: { ...m.bubble.split, ...o.bubble?.split },
      collapseSplit: { ...m.bubble.collapseSplit, ...o.bubble?.collapseSplit },
      unsplit: { ...m.bubble.unsplit, ...o.bubble?.unsplit },
      unsplitSlide: { ...m.bubble.unsplitSlide, ...o.bubble?.unsplitSlide },
      unsplitAbsorb: o.bubble?.unsplitAbsorb ?? m.bubble.unsplitAbsorb,
      absorbExpand: o.bubble?.absorbExpand ?? m.bubble.absorbExpand,
      joinLead: o.bubble?.joinLead ?? m.bubble.joinLead,
      ...(o.bubble?.absorbExpandCorner !== undefined || m.bubble.absorbExpandCorner !== undefined
        ? { absorbExpandCorner: { ...(m.bubble.absorbExpandCorner ?? { ...m.corner.swap, delay: m.corner.swap.delay - m.viaIdle.swap }), ...o.bubble?.absorbExpandCorner } }
        : {}),
      collapseSplitVia: {
        ...m.bubble.collapseSplitVia,
        ...o.bubble?.collapseSplitVia,
        down: { ...m.bubble.collapseSplitVia.down, ...o.bubble?.collapseSplitVia?.down },
      },
      collapseSplitRise: { ...m.bubble.collapseSplitRise, ...o.bubble?.collapseSplitRise },
      collapseSplitLift: {
        ...m.bubble.collapseSplitLift,
        ...o.bubble?.collapseSplitLift,
        back: { ...m.bubble.collapseSplitLift.back, ...o.bubble?.collapseSplitLift?.back },
      },
      collapseSplitSpread: {
        ...m.bubble.collapseSplitSpread,
        ...withoutNeckTip(o.bubble?.collapseSplitSpread),
        rightPeel: { ...m.bubble.collapseSplitSpread.rightPeel, ...o.bubble?.collapseSplitSpread?.rightPeel },
        rightSettle: { ...m.bubble.collapseSplitSpread.rightSettle, ...o.bubble?.collapseSplitSpread?.rightSettle },
        rightBack: { ...m.bubble.collapseSplitSpread.rightBack, ...o.bubble?.collapseSplitSpread?.rightBack },
        // A partial override fills the rest from the base, or from no nub (length 0) when the base has none.
        ...(o.bubble?.collapseSplitSpread?.neckTip !== undefined || m.bubble.collapseSplitSpread.neckTip !== undefined
          ? { neckTip: { ...(m.bubble.collapseSplitSpread.neckTip ?? noNeckTip), ...o.bubble?.collapseSplitSpread?.neckTip } }
          : {}),
      },
    },
    lag: perTransition((k) => o.lag?.[k] ?? m.lag[k]),
    content: {
      enter: { ...m.content.enter, ...o.content?.enter },
      exit: { ...m.content.exit, ...o.content?.exit },
      carryResponseMin: o.content?.carryResponseMin ?? m.content.carryResponseMin,
    },
    contentTiming: perTransition((k) => {
      const base: ContentMotion = m.contentTiming[k];
      const over = o.contentTiming?.[k];
      const exit = { ...base.exit, ...over?.exit };
      // No `bubbleExit` on either side keeps it absent, so the bubble follows `exit` as before.
      const bubbleExit = base.bubbleExit || over?.bubbleExit ? { ...(base.bubbleExit ?? exit), ...over?.bubbleExit } : undefined;
      const enter = { ...base.enter, ...over?.enter };
      // The same for `bubbleEnter`: absent on both sides, the bubble rides `enter`; and `trailingEnter`.
      const bubbleEnter = base.bubbleEnter || over?.bubbleEnter ? { ...(base.bubbleEnter ?? enter), ...over?.bubbleEnter } : undefined;
      const trailingEnter = base.trailingEnter || over?.trailingEnter ? { ...(base.trailingEnter ?? enter), ...over?.trailingEnter } : undefined;
      const centerDelay = over?.centerDelay ?? base.centerDelay;
      const regions = regionLags(base.regions, over?.regions, centerDelay);
      // The same for `absorb`: absent on both sides, the absorbing change uses `enter`, `centerDelay` and `regions`.
      const absorbCenter = over?.absorb?.centerDelay ?? base.absorb?.centerDelay ?? centerDelay;
      const absorbRegions = regionLags(base.absorb?.regions ?? regions, over?.absorb?.regions, absorbCenter);
      const absorb =
        base.absorb || over?.absorb
          ? {
              enter: { ...(base.absorb?.enter ?? enter), ...over?.absorb?.enter },
              centerDelay: absorbCenter,
              ...(absorbRegions ? { regions: absorbRegions } : {}),
              ...(over?.absorb?.enterBlur !== undefined || base.absorb?.enterBlur !== undefined ? { enterBlur: over?.absorb?.enterBlur ?? base.absorb?.enterBlur } : {}),
              ...(over?.absorb?.exitFade !== undefined || base.absorb?.exitFade !== undefined ? { exitFade: over?.absorb?.exitFade ?? base.absorb?.exitFade } : {}),
              ...(over?.absorb?.exitSharpen !== undefined || base.absorb?.exitSharpen !== undefined ? { exitSharpen: over?.absorb?.exitSharpen ?? base.absorb?.exitSharpen } : {}),
              ...(over?.absorb?.clipFollow !== undefined || base.absorb?.clipFollow !== undefined ? { clipFollow: over?.absorb?.clipFollow ?? base.absorb?.clipFollow } : {}),
              ...(over?.absorb?.regionBottomAnchor || base.absorb?.regionBottomAnchor ? { regionBottomAnchor: { ...base.absorb?.regionBottomAnchor, ...over?.absorb?.regionBottomAnchor } } : {}),
            }
          : undefined;
      // `afterHandoff` the same: absent on both sides, a handoff's expansion uses `enter`, `fade` and `regions`.
      const handoffBase = base.afterHandoff;
      const handoffOver = over?.afterHandoff;
      const handoffRegions = regionLags(handoffBase?.regions ?? regions, handoffOver?.regions, centerDelay);
      const afterHandoff =
        handoffBase || handoffOver
          ? {
              enter: { ...(handoffBase?.enter ?? enter), ...handoffOver?.enter },
              fade: handoffOver?.fade ?? handoffBase?.fade ?? over?.fade ?? base.fade,
              ...(handoffRegions ? { regions: handoffRegions } : {}),
            }
          : undefined;
      // `wide` the same: only the fields set on either side; `trailingEnter` over this transition's.
      const wideBase = base.wide;
      const wideOver = over?.wide;
      const wideNumber = (key: "scale" | "enterBlur" | "sharpen" | "trailingEnterBlur" | "trailingScale" | "trailingEnterClear" | "enterGlow" | "leadingFade") => {
        const v = wideOver?.[key] ?? wideBase?.[key];
        return v === undefined ? {} : { [key]: v };
      };
      const wide =
        wideBase || wideOver
          ? {
              from: wideOver?.from ?? wideBase?.from ?? Number.MAX_VALUE,
              ...wideNumber("scale"),
              ...wideNumber("enterBlur"),
              ...wideNumber("sharpen"),
              ...wideNumber("trailingEnterBlur"),
              ...wideNumber("trailingScale"),
              ...wideNumber("trailingEnterClear"),
              ...wideNumber("enterGlow"),
              ...wideNumber("leadingFade"),
              ...(wideBase?.trailingEnter || wideOver?.trailingEnter ? { trailingEnter: { ...(wideBase?.trailingEnter ?? trailingEnter ?? enter), ...wideOver?.trailingEnter } } : {}),
            }
          : undefined;
      // `exitWide` the same: only the fields set on either side.
      const exitWideBase = base.exitWide;
      const exitWideOver = over?.exitWide;
      const exitWideNumber = (key: "scale" | "blur" | "exitScale" | "exitTravel" | "exitLeadingFade" | "exitBlur" | "exitSharpen" | "exitFade" | "anchor" | "trailingExitPower") => {
        const v = exitWideOver?.[key] ?? exitWideBase?.[key];
        return v === undefined ? {} : { [key]: v };
      };
      const exitWide =
        exitWideBase || exitWideOver
          ? {
              from: exitWideOver?.from ?? exitWideBase?.from ?? Number.MAX_VALUE,
              ...exitWideNumber("scale"),
              ...exitWideNumber("blur"),
              ...exitWideNumber("exitScale"),
              ...exitWideNumber("exitTravel"),
              ...exitWideNumber("exitLeadingFade"),
              ...exitWideNumber("exitBlur"),
              ...exitWideNumber("exitSharpen"),
              ...exitWideNumber("exitFade"),
              ...exitWideNumber("anchor"),
              ...exitWideNumber("trailingExitPower"),
            }
          : undefined;
      // `afterAlert` the same: only the fields set on either side, `enter` over this transition's.
      const alertBase = base.afterAlert;
      const alertOver = over?.afterAlert;
      const alertSettle = settleOf(alertBase?.bubbleSettle, alertOver?.bubbleSettle);
      const bubbleSettle = settleOf(base.bubbleSettle, over?.bubbleSettle);
      const afterAlert =
        alertBase || alertOver
          ? {
              ...(alertBase?.enter || alertOver?.enter ? { enter: { ...(alertBase?.enter ?? enter), ...alertOver?.enter } } : {}),
              ...(alertBase?.bubbleEnter || alertOver?.bubbleEnter
                ? { bubbleEnter: { ...(alertBase?.bubbleEnter ?? alertBase?.enter ?? enter), ...alertOver?.bubbleEnter } }
                : {}),
              ...(alertOver?.bubbleDelay !== undefined || alertBase?.bubbleDelay !== undefined ? { bubbleDelay: alertOver?.bubbleDelay ?? alertBase?.bubbleDelay } : {}),
              ...(alertOver?.bubbleFade !== undefined || alertBase?.bubbleFade !== undefined ? { bubbleFade: alertOver?.bubbleFade ?? alertBase?.bubbleFade } : {}),
              ...(alertOver?.bubbleResolve !== undefined || alertBase?.bubbleResolve !== undefined ? { bubbleResolve: alertOver?.bubbleResolve ?? alertBase?.bubbleResolve } : {}),
              ...(alertOver?.bubbleBlur !== undefined || alertBase?.bubbleBlur !== undefined ? { bubbleBlur: alertOver?.bubbleBlur ?? alertBase?.bubbleBlur } : {}),
              ...(alertOver?.bubbleSharpen !== undefined || alertBase?.bubbleSharpen !== undefined ? { bubbleSharpen: alertOver?.bubbleSharpen ?? alertBase?.bubbleSharpen } : {}),
              ...(alertOver?.bubbleTrailingFade !== undefined || alertBase?.bubbleTrailingFade !== undefined
                ? { bubbleTrailingFade: alertOver?.bubbleTrailingFade ?? alertBase?.bubbleTrailingFade }
                : {}),
              ...(alertOver?.bubbleTrailingSlide !== undefined || alertBase?.bubbleTrailingSlide !== undefined
                ? { bubbleTrailingSlide: { by: alertOver?.bubbleTrailingSlide?.by ?? alertBase?.bubbleTrailingSlide?.by ?? 0, power: alertOver?.bubbleTrailingSlide?.power ?? alertBase?.bubbleTrailingSlide?.power ?? 1 } }
                : {}),
              ...(alertOver?.bubbleScale !== undefined || alertBase?.bubbleScale !== undefined ? { bubbleScale: alertOver?.bubbleScale ?? alertBase?.bubbleScale } : {}),
              ...(alertOver?.bubbleSpread !== undefined || alertBase?.bubbleSpread !== undefined ? { bubbleSpread: alertOver?.bubbleSpread ?? alertBase?.bubbleSpread } : {}),
              ...(alertOver?.bubbleHold !== undefined || alertBase?.bubbleHold !== undefined ? { bubbleHold: alertOver?.bubbleHold ?? alertBase?.bubbleHold } : {}),
              ...(alertSettle ? { bubbleSettle: alertSettle } : {}),
            }
          : undefined;
      return {
        enter,
        exit,
        ...(bubbleExit ? { bubbleExit } : {}),
        ...(bubbleEnter ? { bubbleEnter } : {}),
        ...(trailingEnter ? { trailingEnter } : {}),
        ...(wide ? { wide } : {}),
        ...(exitWide ? { exitWide } : {}),
        ...(over?.trailingEnterBlur !== undefined || base.trailingEnterBlur !== undefined ? { trailingEnterBlur: over?.trailingEnterBlur ?? base.trailingEnterBlur } : {}),
        ...(over?.trailingScale !== undefined || base.trailingScale !== undefined ? { trailingScale: over?.trailingScale ?? base.trailingScale } : {}),
        ...(over?.enterGlow !== undefined || base.enterGlow !== undefined ? { enterGlow: over?.enterGlow ?? base.enterGlow } : {}),
        ...(over?.bottomAnchor !== undefined || base.bottomAnchor !== undefined ? { bottomAnchor: over?.bottomAnchor ?? base.bottomAnchor } : {}),
        ...(over?.trailingRide !== undefined || base.trailingRide !== undefined ? { trailingRide: { by: over?.trailingRide?.by ?? base.trailingRide?.by ?? 0, max: over?.trailingRide?.max ?? base.trailingRide?.max ?? Infinity } } : {}),
        ...(over?.trailingExitAnchor !== undefined || base.trailingExitAnchor !== undefined ? { trailingExitAnchor: over?.trailingExitAnchor ?? base.trailingExitAnchor } : {}),
        ...(over?.follow !== undefined || base.follow !== undefined ? { follow: over?.follow ?? base.follow } : {}),
        ...(over?.bubbleExitAccent !== undefined || base.bubbleExitAccent !== undefined ? { bubbleExitAccent: over?.bubbleExitAccent ?? base.bubbleExitAccent } : {}),
        ...(over?.partStep !== undefined || base.partStep !== undefined ? { partStep: { at: over?.partStep?.at ?? base.partStep?.at ?? 0, by: over?.partStep?.by ?? base.partStep?.by ?? 0, spring: { ...(base.partStep?.spring ?? { response: 0.3, dampingFraction: 1 }), ...over?.partStep?.spring } } } : {}),
        ...(absorb ? { absorb } : {}),
        ...(afterHandoff ? { afterHandoff } : {}),
        ...(afterAlert ? { afterAlert } : {}),
        blur: over?.blur ?? base.blur,
        enterBlur: over?.enterBlur ?? base.enterBlur,
        scale: over?.scale ?? base.scale,
        fade: over?.fade ?? base.fade,
        exitFade: over?.exitFade ?? base.exitFade,
        bubbleDelay: over?.bubbleDelay ?? base.bubbleDelay,
        trailingDelay: over?.trailingDelay ?? base.trailingDelay,
        trailingExitPower: over?.trailingExitPower ?? base.trailingExitPower,
        anchor: over?.anchor ?? base.anchor,
        sharpen: over?.sharpen ?? base.sharpen,
        leadingFade: over?.leadingFade ?? base.leadingFade,
        skirt: over?.skirt ?? base.skirt ?? 1,
        bubbleScale: over?.bubbleScale ?? base.bubbleScale,
        bubbleSpread: over?.bubbleSpread ?? base.bubbleSpread,
        bubbleStretch: over?.bubbleStretch ?? base.bubbleStretch ?? 0,
        bubbleStretchPower: over?.bubbleStretchPower ?? base.bubbleStretchPower ?? 1,
        bubbleBlur: over?.bubbleBlur ?? base.bubbleBlur,
        bubbleSharpen: over?.bubbleSharpen ?? base.bubbleSharpen,
        ...(over?.bubbleBlurMax !== undefined || base.bubbleBlurMax !== undefined ? { bubbleBlurMax: over?.bubbleBlurMax ?? base.bubbleBlurMax } : {}),
        ...(over?.bubbleLead !== undefined || base.bubbleLead !== undefined ? { bubbleLead: over?.bubbleLead ?? base.bubbleLead } : {}),
        ...(over?.bubbleLeadRamp !== undefined || base.bubbleLeadRamp !== undefined ? { bubbleLeadRamp: over?.bubbleLeadRamp ?? base.bubbleLeadRamp } : {}),
        ...(over?.bubbleLeadPower !== undefined || base.bubbleLeadPower !== undefined ? { bubbleLeadPower: over?.bubbleLeadPower ?? base.bubbleLeadPower } : {}),
        ...(over?.bubbleExitSlide !== undefined || base.bubbleExitSlide !== undefined ? { bubbleExitSlide: over?.bubbleExitSlide ?? base.bubbleExitSlide } : {}),
        ...(over?.bubbleExitSlidePower !== undefined || base.bubbleExitSlidePower !== undefined ? { bubbleExitSlidePower: over?.bubbleExitSlidePower ?? base.bubbleExitSlidePower } : {}),
        ...(over?.bubbleOrigin !== undefined || base.bubbleOrigin !== undefined ? { bubbleOrigin: over?.bubbleOrigin ?? base.bubbleOrigin } : {}),
        ...(over?.bubbleHold !== undefined || base.bubbleHold !== undefined ? { bubbleHold: over?.bubbleHold ?? base.bubbleHold } : {}),
        ...(over?.bubbleResolve !== undefined || base.bubbleResolve !== undefined ? { bubbleResolve: over?.bubbleResolve ?? base.bubbleResolve } : {}),
        ...(over?.bubbleFade !== undefined || base.bubbleFade !== undefined ? { bubbleFade: over?.bubbleFade ?? base.bubbleFade } : {}),
        ...(over?.exitScale !== undefined || base.exitScale !== undefined ? { exitScale: over?.exitScale ?? base.exitScale } : {}),
        ...(over?.exitTravel !== undefined || base.exitTravel !== undefined ? { exitTravel: over?.exitTravel ?? base.exitTravel } : {}),
        ...(over?.exitLeadingFade !== undefined || base.exitLeadingFade !== undefined ? { exitLeadingFade: over?.exitLeadingFade ?? base.exitLeadingFade } : {}),
        ...(over?.enterScale !== undefined || base.enterScale !== undefined ? { enterScale: over?.enterScale ?? base.enterScale } : {}),
        ...(over?.enterSqueeze !== undefined || base.enterSqueeze !== undefined ? { enterSqueeze: over?.enterSqueeze ?? base.enterSqueeze } : {}),
        ...(over?.enterSqueezeOrigin !== undefined || base.enterSqueezeOrigin !== undefined ? { enterSqueezeOrigin: over?.enterSqueezeOrigin ?? base.enterSqueezeOrigin } : {}),
        ...(over?.enterNarrow !== undefined || base.enterNarrow !== undefined ? { enterNarrow: over?.enterNarrow ?? base.enterNarrow } : {}),
        ...(over?.trailingSlide !== undefined || base.trailingSlide !== undefined ? { trailingSlide: over?.trailingSlide ?? base.trailingSlide } : {}),
        ...(over?.trailingSlidePower !== undefined || base.trailingSlidePower !== undefined ? { trailingSlidePower: over?.trailingSlidePower ?? base.trailingSlidePower } : {}),
        ...(over?.enterClear !== undefined || base.enterClear !== undefined ? { enterClear: over?.enterClear ?? base.enterClear } : {}),
        ...(over?.trailingEnterClear !== undefined || base.trailingEnterClear !== undefined ? { trailingEnterClear: over?.trailingEnterClear ?? base.trailingEnterClear } : {}),
        ...(over?.clipFollow !== undefined || base.clipFollow !== undefined ? { clipFollow: over?.clipFollow ?? base.clipFollow } : {}),
        ...(over?.exitBlur !== undefined || base.exitBlur !== undefined ? { exitBlur: over?.exitBlur ?? base.exitBlur } : {}),
        ...(over?.bubbleExitBlur !== undefined || base.bubbleExitBlur !== undefined ? { bubbleExitBlur: over?.bubbleExitBlur ?? base.bubbleExitBlur } : {}),
        ...(over?.exitSharpen !== undefined || base.exitSharpen !== undefined ? { exitSharpen: over?.exitSharpen ?? base.exitSharpen } : {}),
        ...(over?.rowAnchor !== undefined || base.rowAnchor !== undefined ? { rowAnchor: over?.rowAnchor ?? base.rowAnchor } : {}),
        ...(over?.bubbleCap !== undefined || base.bubbleCap !== undefined ? { bubbleCap: over?.bubbleCap ?? base.bubbleCap } : {}),
        ...(over?.bubbleTrailingFade !== undefined || base.bubbleTrailingFade !== undefined ? { bubbleTrailingFade: over?.bubbleTrailingFade ?? base.bubbleTrailingFade } : {}),
        ...(over?.bubbleTrailingSlide !== undefined || base.bubbleTrailingSlide !== undefined
          ? { bubbleTrailingSlide: { by: over?.bubbleTrailingSlide?.by ?? base.bubbleTrailingSlide?.by ?? 0, power: over?.bubbleTrailingSlide?.power ?? base.bubbleTrailingSlide?.power ?? 1 } }
          : {}),
        ...(over?.bubbleTrailingBlur !== undefined || base.bubbleTrailingBlur !== undefined
          ? { bubbleTrailingBlur: { by: over?.bubbleTrailingBlur?.by ?? base.bubbleTrailingBlur?.by ?? 0, power: over?.bubbleTrailingBlur?.power ?? base.bubbleTrailingBlur?.power ?? 1 } }
          : {}),
        ...(bubbleSettle ? { bubbleSettle } : {}),
        centerDelay,
        ...(regions ? { regions } : {}),
        ...(base.regionExitFade || over?.regionExitFade ? { regionExitFade: { ...base.regionExitFade, ...over?.regionExitFade } } : {}),
        ...(base.regionBottomAnchor || over?.regionBottomAnchor ? { regionBottomAnchor: { ...base.regionBottomAnchor, ...over?.regionBottomAnchor } } : {}),
      };
    }),
    press: {
      down: { ...m.press.down, ...o.press?.down },
      up: { ...m.press.up, ...o.press?.up },
      swell: { ...m.press.swell, ...o.press?.swell },
      swellTime: o.press?.swellTime ?? m.press.swellTime,
      decide: o.press?.decide ?? m.press.decide,
      release: { ...m.press.release, ...o.press?.release },
      // Built field by field, so an optional field left out here is dropped by any override: a
      // page with motion overrides lost the idle swell's flat top (round 31).
      ...(o.press?.idleRelease !== undefined || m.press.idleRelease !== undefined
        ? { idleRelease: { carry: o.press?.idleRelease?.carry ?? m.press.idleRelease?.carry ?? 0, spring: { ...(m.press.idleRelease?.spring ?? m.press.release), ...o.press?.idleRelease?.spring } } }
        : {}),
      ...(o.press?.idleWiden !== undefined || m.press.idleWiden !== undefined
        ? {
            idleWiden: {
              by: o.press?.idleWiden?.by ?? m.press.idleWiden?.by ?? 0,
              hold: o.press?.idleWiden?.hold ?? m.press.idleWiden?.hold ?? 0,
              rise: { ...(m.press.idleWiden?.rise ?? m.press.release), ...o.press?.idleWiden?.rise },
              fall: { ...(m.press.idleWiden?.fall ?? m.press.release), ...o.press?.idleWiden?.fall },
            },
          }
        : {}),
      tapReturn: o.press?.tapReturn ?? m.press.tapReturn,
      ...(o.press?.releaseReturn !== undefined || m.press.releaseReturn !== undefined ? { releaseReturn: o.press?.releaseReturn ?? m.press.releaseReturn } : {}),
      ...(o.press?.idleTapReturn !== undefined || m.press.idleTapReturn !== undefined ? { idleTapReturn: o.press?.idleTapReturn ?? m.press.idleTapReturn } : {}),
      holdReturn: o.press?.holdReturn ?? m.press.holdReturn,
      ...(o.press?.bubbleSwell !== undefined || m.press.bubbleSwell !== undefined ? { bubbleSwell: { ...(m.press.bubbleSwell ?? m.press.swell), ...o.press?.bubbleSwell } } : {}),
    },
    longPress: o.longPress ?? m.longPress,
    // An override of `longPress` alone moves the bubble's too.
    longPressBubble: o.longPressBubble ?? (o.longPress !== undefined ? o.longPress : m.longPressBubble),
    alertContentDelay: o.alertContentDelay ?? m.alertContentDelay,
    group: { ...m.group, ...o.group },
    keyline: { ...m.keyline, ...o.keyline },
    shadowRamp: { ...m.shadowRamp, ...o.shadowRamp },
    shadowRampPress: { ...m.shadowRampPress, ...o.shadowRampPress },
    alertHold: o.alertHold ?? m.alertHold,
    // An override of `alertHold` alone moves the idle island's hold too.
    alertHoldIdle: o.alertHoldIdle ?? (o.alertHold !== undefined ? o.alertHold : (m.alertHoldIdle ?? m.alertHold)),
    ...(m.blurSkirt || o.blurSkirt ? { blurSkirt: { ...noSkirt, ...m.blurSkirt, ...o.blurSkirt } } : {}),
    reduced: { ...m.reduced, ...o.reduced },
  };
};
