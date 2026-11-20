export interface FrameStats {
  frames: number;
  /** Gaps between consecutive animating frames, in ms. */
  interval: { mean: number; p95: number; max: number };
  /** Time spent computing paths and writing styles per frame, in ms. */
  work: { mean: number; p95: number; max: number };
  /** Frames whose gap exceeded 1.5x the 60 fps budget (25 ms). */
  longFrames: number;
}

export interface FrameRecorder {
  /** Records one frame: when it started (wall ms) and how long the island's work took. */
  record(startedAt: number, work: number): void;
  /** Marks a gap (the island went to rest), so idle time isn't counted as a long frame. */
  breakRun(): void;
  stats(): FrameStats;
  clear(): void;
}

const summarize = (values: readonly number[]) => {
  if (values.length === 0) return { mean: 0, p95: 0, max: 0 };
  const sorted = [...values].sort((a, b) => a - b);
  const mean = values.reduce((sum, v) => sum + v, 0) / values.length;
  const p95 = sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))] ?? 0;
  const max = sorted[sorted.length - 1] ?? 0;
  const round = (n: number) => Math.round(n * 100) / 100;
  return { mean: round(mean), p95: round(p95), max: round(max) };
};

export const createFrameRecorder = (limit = 2000): FrameRecorder => {
  let intervals: number[] = [];
  let work: number[] = [];
  let last: number | null = null;
  return {
    record(startedAt, cost) {
      if (last !== null) intervals.push(startedAt - last);
      last = startedAt;
      work.push(cost);
      if (work.length > limit) {
        work = work.slice(-limit);
        intervals = intervals.slice(-limit);
      }
    },
    breakRun() {
      last = null;
    },
    stats() {
      return {
        frames: work.length,
        interval: summarize(intervals),
        work: summarize(work),
        longFrames: intervals.filter((gap) => gap > 25).length,
      };
    },
    clear() {
      intervals = [];
      work = [];
      last = null;
    },
  };
};
