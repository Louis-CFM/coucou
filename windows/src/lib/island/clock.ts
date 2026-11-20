export interface IslandClock {
  /** Current time in ms. */
  now(): number;
  /** Calls `onFrame` once per frame until the returned function is called. */
  onFrame(onFrame: (now: number) => void): () => void;
  /** Runs `run` once the clock reaches `at` (ms), passing the time it was due. Returns a cancel function. */
  at(at: number, run: (due: number) => void): () => void;
}

/** A clock you can pause, step and seek. Used by devtools and captures. */
export interface ControllableClock extends IslandClock {
  readonly paused: boolean;
  pause(): void;
  resume(): void;
  /** Advances paused time by `ms`, firing due timers at their exact times, then draws one frame. */
  step(ms: number): void;
  /** Jumps to `ms` without firing the timers in between. Pending timers before `ms` fire on the next frame. */
  setTime(ms: number): void;
  /** Playback speed while running. 0.25 plays at quarter speed. */
  timeScale: number;
}

interface Timer {
  id: number;
  at: number;
  run: (due: number) => void;
}

interface ClockOptions {
  /**
   * Wraps each timer callback. Devtools passes React's `flushSync` so state changes made by a
   * timer render before the next timer or frame, which keeps stepped captures exact.
   */
  wrapTimer?: (run: () => void) => void;
}

const hasWindow = () => typeof window !== "undefined" && typeof window.requestAnimationFrame === "function";

/** The real clock: wall time from `performance.now()`, frames from `requestAnimationFrame`. */
export const createFrameClock = (options: ClockOptions = {}): ControllableClock => {
  const frameListeners = new Set<(now: number) => void>();
  let timers: Timer[] = [];
  let nextTimerId = 1;
  let raf = 0;
  let paused = false;
  let frozenAt = 0;
  // Island time = (wall time - origin) * scale + base, rebased whenever the scale or pause state changes.
  let base = 0;
  let origin = 0;
  let scale = 1;
  const wrap = options.wrapTimer ?? ((run: () => void) => run());

  const wall = () => (typeof performance === "undefined" ? Date.now() : performance.now());
  const now = () => (paused ? frozenAt : (wall() - origin) * scale + base);
  const rebase = () => {
    base = now();
    origin = wall();
  };

  const runTimersUntil = (time: number, setNow: (t: number) => void) => {
    for (;;) {
      const due = timers.filter((timer) => timer.at <= time).sort((a, b) => a.at - b.at || a.id - b.id)[0];
      if (!due) return;
      timers = timers.filter((timer) => timer.id !== due.id);
      setNow(due.at);
      wrap(() => due.run(due.at));
    }
  };

  const emitFrame = (time: number) => {
    for (const listener of [...frameListeners]) listener(time);
  };

  const loop = () => {
    raf = 0;
    if (paused) return;
    const time = now();
    runTimersUntil(time, () => undefined);
    emitFrame(time);
    schedule();
  };

  const schedule = () => {
    if (raf || paused || !hasWindow()) return;
    if (frameListeners.size === 0 && timers.length === 0) return;
    raf = window.requestAnimationFrame(loop);
  };

  return {
    now,
    onFrame(onFrame) {
      frameListeners.add(onFrame);
      schedule();
      return () => {
        frameListeners.delete(onFrame);
      };
    },
    at(at, run) {
      const id = nextTimerId++;
      timers.push({ id, at, run });
      schedule();
      return () => {
        timers = timers.filter((timer) => timer.id !== id);
      };
    },
    get paused() {
      return paused;
    },
    pause() {
      if (paused) return;
      frozenAt = now();
      paused = true;
      if (raf && hasWindow()) window.cancelAnimationFrame(raf);
      raf = 0;
    },
    resume() {
      if (!paused) return;
      base = frozenAt;
      origin = wall();
      paused = false;
      schedule();
    },
    step(ms) {
      if (!paused) {
        frozenAt = now();
        paused = true;
      }
      const target = frozenAt + ms;
      runTimersUntil(target, (t) => {
        frozenAt = t;
      });
      frozenAt = target;
      emitFrame(target);
    },
    setTime(ms) {
      if (paused) {
        frozenAt = ms;
      } else {
        base = ms;
        origin = wall();
      }
      schedule();
    },
    get timeScale() {
      return scale;
    },
    set timeScale(value) {
      rebase();
      scale = value;
    },
  };
};

let sharedClock: ControllableClock | null = null;

/** The clock islands use when no provider supplies one. */
export const defaultClock = (): ControllableClock => {
  sharedClock ??= createFrameClock();
  return sharedClock;
};
