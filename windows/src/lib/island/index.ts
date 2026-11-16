export { IslandProvider, type IslandProviderProps } from "./provider";
export { Island, type IslandProps } from "./island-root";
export { IslandView, type IslandViewProps } from "./view";
export { useIsland, useIslandActions, useIslandReducedMotion } from "./use-island";
export { IslandNumber, IslandProgress, numberMotion, type IslandNumberProps, type IslandProgressProps } from "./primitives";
export { colourLuma, keylineAlphaFor, type KeylineSetting } from "./context";

export type {
  Activity,
  ActivityContent,
  ActivityHandle,
  ActivityOptions,
  ActivityUpdate,
  CompactContent,
  ExpandedContent,
  ExpandReason,
  IslandApi,
  IslandPresentation,
  IslandSequence,
  PresentationKind,
  ReducedMotionSetting,
  SequenceIsland,
} from "./types";

export { createFrameClock, defaultClock, type ControllableClock, type IslandClock } from "./clock";
export { AnimatedValue, solveSpring, type SpringConfig, type Transition } from "./spring";
export { islandMetrics, type IslandMetrics } from "./metrics";
export { islandMotion, shapeTransitions, type IslandMotion, type ShapeTransition } from "./motion";
export { resolveMetrics, resolveMotion, type IslandMetricsOverrides, type IslandMotionOverrides } from "./config";
export { bridgePath, capsulePath, continuousRectPath, roundedRectPath, type CornerShape } from "./path";
export type { IslandDevtools, DevtoolsOptions } from "./devtools";
export type { FrameStats } from "./perf";
