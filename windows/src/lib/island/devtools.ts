import type { ControllableClock } from "./clock";
import type { FrameRecorder, FrameStats } from "./perf";
import type { IslandStore } from "./store";
import type { IslandSequence, PresentationKind, SequenceIsland } from "./types";

/** `window.__islandcn`, installed only by `<IslandProvider devtools>`. */
export interface IslandDevtools {
  /** Freezes island time. */
  pause(): void;
  resume(): void;
  /** Advances paused time by `ms` and draws that frame. Returns the new time. */
  step(ms: number): number;
  /** Jumps to `ms`. With a sequence loaded, replays it from the start so the frame is exact. */
  seek(ms: number): number;
  /** Resets the island to the sequence's start at time 0 and runs it. `paused` waits for `step`. */
  play(name: string, options?: { paused?: boolean }): { duration: number };
  now(): number;
  /** Playback speed while running, 1 is real time. */
  setTimeScale(scale: number): void;
  readonly sequences: readonly string[];
  presentation(): PresentationKind;
  /** Frame timings recorded while the island animated. */
  stats(): FrameStats;
  clearStats(): void;
}

declare global {
  interface Window {
    __islandcn?: IslandDevtools;
  }
}

export interface DevtoolsOptions {
  /** Named sequences `play()` can run. Defaults to none. */
  sequences?: Readonly<Record<string, IslandSequence>>;
}

export const createDevtools = (options: {
  clock: ControllableClock;
  store: IslandStore;
  recorder: FrameRecorder;
  sequences: Readonly<Record<string, IslandSequence>>;
  /** Runs a state change and renders it synchronously (React's flushSync). */
  flush: (run: () => void) => void;
}): IslandDevtools => {
  const { clock, store, recorder, sequences, flush } = options;
  const base = store.api;
  const api: SequenceIsland = {
    start: (activity) => base.start(activity),
    update: (id, update) => base.update(id, update),
    end: (id) => base.end(id),
    expand: (id) => base.expand(id),
    collapse: () => base.collapse(),
    get activities() {
      return base.activities;
    },
    get presentation() {
      return base.presentation;
    },
    press: (target = "pill") => store.press(target),
    release: () => store.release(),
  };
  let loaded: { name: string; cancels: (() => void)[] } | null = null;

  const load = (name: string, paused: boolean) => {
    const sequence = sequences[name];
    if (!sequence) throw new Error(`islandcn: no sequence named "${name}". Known: ${Object.keys(sequences).join(",")}`);
    for (const cancel of loaded?.cancels ?? []) cancel();
    clock.pause();
    clock.setTime(0);
    flush(() => store.reset());
    flush(() => store.instantly(() => sequence.setup?.(api)));
    const cancels = sequence.events.map((event) => clock.at(event.at, () => event.run(api)));
    loaded = { name, cancels };
    recorder.clear();
    if (!paused) clock.resume();
    return sequence;
  };

  return {
    pause: () => clock.pause(),
    resume: () => clock.resume(),
    step(ms) {
      clock.step(ms);
      return clock.now();
    },
    seek(ms) {
      if (loaded) {
        load(loaded.name, true);
        clock.step(ms);
      } else {
        clock.setTime(ms);
      }
      return clock.now();
    },
    play(name, playOptions) {
      const sequence = load(name, playOptions?.paused ?? false);
      return { duration: sequence.duration };
    },
    now: () => clock.now(),
    setTimeScale(scale) {
      clock.timeScale = scale;
    },
    get sequences() {
      return Object.keys(sequences);
    },
    presentation: () => store.api.presentation,
    stats: () => recorder.stats(),
    clearStats: () => recorder.clear(),
  };
};
