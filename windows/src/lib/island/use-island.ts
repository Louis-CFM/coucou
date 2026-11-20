"use client";

import { useSyncExternalStore } from "react";

import { useIslandContext, useReducedMotion } from "./context";
import type { IslandApi } from "./types";

/**
 * Starts, updates and ends activities. The returned object is stable; reading `activities` or
 * `presentation` during render re-renders the caller when they change.
 */
export const useIsland = (): IslandApi => {
  const context = useIslandContext();
  if (!context) throw new Error("islandcn: useIsland() must be called inside <IslandProvider>.");
  const { store } = context;
  // Subscribing keeps `activities` and `presentation` fresh for callers that render them.
  useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  return store.api;
};

/**
 * The same stable API as `useIsland()`, without subscribing: the caller does not re-render when
 * the island changes. Use it in components that only start, update and end activities. Reading
 * `activities` or `presentation` still returns the current value, it just won't trigger a render.
 */
export const useIslandActions = (): IslandApi => {
  const context = useIslandContext();
  if (!context) throw new Error("islandcn: useIslandActions() must be called inside <IslandProvider>.");
  return context.store.api;
};

/** Whether the island runs reduced motion: the provider's `reducedMotion` setting resolved against the system's. */
export const useIslandReducedMotion = (): boolean => {
  const context = useIslandContext();
  return useReducedMotion(context?.reducedMotion ?? "user");
};
