"use client";

import { type ReactNode, useEffect, useMemo, useState } from "react";
import { flushSync } from "react-dom";

import { createFrameClock, type IslandClock } from "./clock";
import { type IslandMetricsOverrides, type IslandMotionOverrides, resolveMetrics, resolveMotion } from "./config";
import { IslandContext, type IslandContextValue } from "./context";
import { createDevtools, type DevtoolsOptions } from "./devtools";
import type { IslandMotion } from "./motion";
import { createFrameRecorder } from "./perf";
import { createIslandStore } from "./store";
import type { ReducedMotionSetting } from "./types";

export interface IslandProviderProps {
  children: ReactNode;
  /**
   * Where island time comes from. Read once, on mount. Defaults to a requestAnimationFrame clock
   * (pausable when `devtools` is on).
   */
  clock?: IslandClock;
  /**
   * Installs `window.__islandcn` (pause, step, seek, play) for frame-exact captures. Pass
   * `{ sequences }` to register named sequences. Defaults to false; leave it off in production.
   */
  devtools?: boolean | DevtoolsOptions;
  /** Geometry overrides on top of the provisional metrics table. Defaults to none. */
  metrics?: IslandMetricsOverrides;
  /** Spring and timing overrides on top of the provisional motion table. Defaults to none. */
  motion?: IslandMotionOverrides;
  /** "user" follows prefers-reduced-motion, "always" and "never" force it. Defaults to "user". */
  reducedMotion?: ReducedMotionSetting;
}

/** Owns the activity stack. Put `<Island />` and the code that calls `useIsland()` inside it. */
export const IslandProvider = ({ children, clock, devtools = false, metrics, motion, reducedMotion = "user" }: IslandProviderProps) => {
  const resolvedMetrics = useMemo(() => resolveMetrics(metrics), [metrics]);
  const resolvedMotion = useMemo(() => resolveMotion(motion), [motion]);

  // The store reads motion lazily, so motion overrides can change without rebuilding the stack.
  const [motionRef] = useState(() => ({ current: resolvedMotion }));
  motionRef.current = resolvedMotion;

  const [core] = useState(() => {
    // Devtools step frames synchronously, so timers render with flushSync.
    const ownClock = createFrameClock(devtools ? { wrapTimer: (run) => flushSync(run) } : {});
    const islandClock = clock ?? ownClock;
    const recorder = devtools ? createFrameRecorder() : null;
    const store = createIslandStore({ clock: islandClock, motion: (): IslandMotion => motionRef.current });
    return { clock: islandClock, ownClock, recorder, store };
  });

  const devtoolsOptions = typeof devtools === "object" ? devtools : devtools ? {} : null;
  const sequences = devtoolsOptions?.sequences;
  const enabled = devtoolsOptions !== null;

  useEffect(() => {
    if (!enabled || typeof window === "undefined") return;
    // Devtools need a clock they can pause; an injected clock is the caller's to drive.
    if (clock) return;
    const tools = createDevtools({
      clock: core.ownClock,
      store: core.store,
      recorder: core.recorder ?? createFrameRecorder(),
      sequences: sequences ?? {},
      flush: (run) => flushSync(run),
    });
    window.__islandcn = tools;
    return () => {
      if (window.__islandcn === tools) delete window.__islandcn;
    };
  }, [enabled, sequences, clock, core]);

  const value = useMemo<IslandContextValue>(
    () => ({
      store: core.store,
      clock: core.clock,
      metrics: resolvedMetrics,
      motion: resolvedMotion,
      reducedMotion,
      recorder: core.recorder,
    }),
    [core, resolvedMetrics, resolvedMotion, reducedMotion],
  );

  return <IslandContext value={value}>{children}</IslandContext>;
};
