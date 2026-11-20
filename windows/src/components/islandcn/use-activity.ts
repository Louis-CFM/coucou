"use client";

import { type DependencyList, useEffect, useMemo, useRef, useSyncExternalStore } from "react";

import { type ActivityOptions, type ActivityUpdate, useIslandActions } from "@/lib/island";

/** What `useActivity` hands back: ways to poke the activity it owns. */
export interface ActivityControls {
  readonly id: string;
  /** Expands the activity briefly, then settles back, like an alerting update. */
  alert(): void;
  /** Expands the activity and holds it until a press outside or `collapse()`. */
  expand(): void;
  collapse(): void;
}

/** Nothing to subscribe to: whether the page has hydrated never changes back. */
const subscribeNever = () => () => undefined;

/**
 * False on the server and during hydration, true in every client render after it (and from the
 * first render of a component mounted later). The server and the hydrating client therefore render
 * the same thing, so nothing that reads `useActivity`'s return can mismatch.
 */
const useHydrated = () => useSyncExternalStore(subscribeNever, () => true, () => false);

/**
 * Binds one activity to a component's lifetime: starts it on mount, updates it when `deps`
 * change, and ends it (with the dismiss motion) on unmount. Changing the id ends the old
 * activity and starts a new one.
 *
 * `build` runs only when `deps` change, so content isn't rebuilt on every island change. Keep
 * callbacks the content calls in a ref (see `useLatest`), not in `deps`. The component never
 * re-renders because the island changed (it uses `useIslandActions`). `build` runs only in the
 * browser after hydration, so it may read the clock (`until: Date.now() + ms`). Until then the
 * returned `id` is "" on the server and in the hydrating render alike, then the activity's id.
 */
export const useActivity = (build: () => ActivityOptions, deps: DependencyList): ActivityControls => {
  const island = useIslandActions();
  const latest = useRef(build);
  latest.current = build;
  // Rebuilt only when the caller's deps change (or once hydration ends). Never on the server or in
  // the hydrating render: effects don't run on the server, so the content would be thrown away, a
  // prerender (Next.js with `cacheComponents`) rejects the `Date.now()` a countdown's content
  // naturally reads, and building during hydration would give the client an `id` the server lacked.
  const hydrated = useHydrated();
  const options = useMemo(() => (hydrated ? latest.current() : undefined), [hydrated, ...deps]);
  const id = options?.id ?? "";

  useEffect(() => {
    if (options === undefined) return;
    island.start(latest.current());
    return () => island.end(id);
  }, [island, id]);

  // Also runs right after the start above; an update with the same content is cheap.
  useEffect(() => {
    if (options === undefined) return;
    const { id: _id, alert: _alert, ...content } = options;
    const update: ActivityUpdate = content;
    island.update(id, update);
  }, [island, id, options]);

  return useMemo(
    () => ({
      id,
      alert: () => island.update(id, { alert: true }),
      expand: () => island.expand(id),
      collapse: () => island.collapse(),
    }),
    [island, id],
  );
};

/** A ref that always holds the latest value, for callbacks inside island content. */
export const useLatest = <T,>(value: T) => {
  const ref = useRef(value);
  ref.current = value;
  return ref;
};
