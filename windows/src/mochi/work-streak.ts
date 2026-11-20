// How long you have been working with your agents without a break, so Mochi gets sleepy after
// a long stretch (heavy eyes, the odd yawn while he waits) and fresh again after a break.
// Port of NotchBuddy/Sources/App/WorkStreak.swift (#970 by @lovyestar).

export class WorkStreak {
  /** A pause at least this long is a break: the streak starts over (20 minutes). */
  static readonly BREAK_GAP_MS = 20 * 60 * 1000;
  /** Mochi gets sleepy after this long (2 hours). */
  static readonly SLEEPY_AFTER_MS = 2 * 3600 * 1000;
  /** ...and very sleepy after this long (3 hours). */
  static readonly VERY_SLEEPY_AFTER_MS = 3 * 3600 * 1000;

  start: number | null = null;
  last: number | null = null;

  /** An agent did something. `userIdleSeconds`: seconds since last user interaction. */
  activity(nowMs: number, userIdleSeconds = 0): void {
    if (!this.isGoing(nowMs, userIdleSeconds)) {
      this.start = nowMs;
    }
    this.last = nowMs;
  }

  /** How sleepy Mochi is, from 0 (fresh) to 1. */
  tiredness(nowMs: number, userIdleSeconds = 0): number {
    if (!this.isGoing(nowMs, userIdleSeconds) || this.start == null) {
      this.start = null;
      this.last = null;
      return 0;
    }
    const worked = nowMs - this.start;
    if (worked >= WorkStreak.VERY_SLEEPY_AFTER_MS) return 1;
    if (worked >= WorkStreak.SLEEPY_AFTER_MS) return 0.7;
    return 0;
  }

  isGoing(nowMs: number, userIdleSeconds = 0): boolean {
    if (this.start == null || this.last == null) return false;
    const idleMs = userIdleSeconds * 1000;
    return (nowMs - this.last < WorkStreak.BREAK_GAP_MS) && (idleMs < WorkStreak.BREAK_GAP_MS);
  }
}

export const GlobalWorkStreak = new WorkStreak();
