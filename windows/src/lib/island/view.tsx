"use client";

import { type CSSProperties, useMemo } from "react";

import { defaultClock, type IslandClock } from "./clock";
import { type IslandMetricsOverrides, type IslandMotionOverrides, resolveMetrics, resolveMotion } from "./config";
import { type KeylineSetting, useIslandContext, useKeyline, useReducedMotion } from "./context";
import { IslandSurface } from "./surface";
import type { IslandPresentation, ReducedMotionSetting } from "./types";

export interface IslandViewProps {
  /** What to show. Changing it animates the shape and crossfades the content. */
  presentation: IslandPresentation;
  /**
   * Identity of the content. A new key crossfades; the same key updates in place (a progress
   * value ticking up, say). Defaults to `presentation.kind`.
   */
  contentKey?: string;
  /** Hold the pill down: it squishes slightly. Defaults to false. */
  pressed?: boolean;
  /** "container" (nearest positioned ancestor) or "viewport" (fixed to the window). Defaults to "container". */
  placement?: "container" | "viewport";
  /** Region name for screen readers. Defaults to "Live activity". */
  label?: string;
  /** Text announced politely when it changes. Defaults to none. */
  liveLabel?: string;
  /** Time source. Defaults to the provider's clock, or a shared requestAnimationFrame clock. */
  clock?: IslandClock;
  /** Geometry overrides. Defaults to the provider's metrics, or the provisional table. */
  metrics?: IslandMetricsOverrides;
  /** Spring overrides. Defaults to the provider's motion, or the provisional table. */
  motion?: IslandMotionOverrides;
  /** Defaults to the provider's setting, or "user". */
  reducedMotion?: ReducedMotionSetting;
  /** Class on the region element. Defaults to none. */
  className?: string;
  /** Style on the region element. Defaults to none. */
  style?: CSSProperties;
  /**
   * The thin grey band outside the edge that separates the island from a dark page. "auto" draws
   * it when `backdrop` is dark, or in dark mode when no `backdrop` is given. Defaults to "auto".
   */
  keyline?: KeylineSetting;
  /** The page colour behind the island (hex or rgb()), which sets the keyline's strength. Defaults to none. */
  backdrop?: string;
}

/**
 * One presentation, controlled, without the activity stack. For docs, playgrounds and captures.
 * It draws the same shape and motion as `<Island />` but isn't pressable.
 */
export const IslandView = ({
  presentation,
  contentKey,
  pressed = false,
  placement = "container",
  label = "Live activity",
  liveLabel = "",
  clock,
  metrics,
  motion,
  reducedMotion,
  className,
  style,
  keyline = "auto",
  backdrop,
}: IslandViewProps) => {
  const context = useIslandContext();
  const resolvedMetrics = useMemo(() => (metrics ? resolveMetrics(metrics) : (context?.metrics ?? resolveMetrics())), [metrics, context]);
  const resolvedMotion = useMemo(() => (motion ? resolveMotion(motion) : (context?.motion ?? resolveMotion())), [motion, context]);
  const reduced = useReducedMotion(reducedMotion ?? context?.reducedMotion ?? "user");
  const keylineAlpha = useKeyline(keyline, backdrop, resolvedMetrics);

  return (
    <IslandSurface
      presentation={presentation}
      contentKey={contentKey ?? presentation.kind}
      change={null}
      pressed={pressed ? "pill" : null}
      pressStyle="squish"
      activityId={null}
      alerting={false}
      placement={placement}
      regionLabel={label}
      liveLabel={liveLabel}
      clock={clock ?? context?.clock ?? defaultClock()}
      metrics={resolvedMetrics}
      motion={resolvedMotion}
      reduced={reduced}
      keyline={keylineAlpha}
      recorder={context?.recorder ?? null}
      interaction={null}
      className={className}
      style={style}
    />
  );
};
