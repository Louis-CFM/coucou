// The focus timer: a pomodoro in the island — 25 minutes of focus, a 5-minute
// break (15 after every fourth round). Pure rules here; the clock, sounds and
// the island in src/island/focus.ts, the card in src/views/focus.ts.
// Nothing leaves the computer and nothing is stored: a restart starts afresh.

export const FOCUS_ID = "integration_focus";
export const FOCUS_COLOR = "#FB7185";

export type FocusPhase = "focus" | "break" | "longBreak";

/** Seconds. */
export const DURATIONS: Readonly<Record<FocusPhase, number>> = { focus: 25 * 60, break: 5 * 60, longBreak: 15 * 60 };
/** A long break after this many focus rounds. */
export const ROUNDS = 4;

export interface FocusState {
  phase: FocusPhase;
  running: boolean;
  /** Unix ms the phase ends at, while running. */
  endsAt: number | null;
  /** Seconds left, while paused. */
  remaining: number;
  /** The focus round, 1…ROUNDS. */
  round: number;
  /** The phase has been started (it may be paused since). */
  started: boolean;
}

export const IDLE_FOCUS: FocusState = {
  phase: "focus", running: false, endsAt: null, remaining: DURATIONS.focus, round: 1, started: false,
};

/** The page's copy of the timer. */
export const Focus = { state: { ...IDLE_FOCUS } as FocusState };

/** Seconds left at `now`. */
export function remainingAt(s: FocusState, now: number): number {
  if (s.running && s.endsAt != null) return Math.max(0, (s.endsAt - now) / 1000);
  return s.remaining;
}

/** How far into the phase, 0…1. */
export function progressAt(s: FocusState, now: number): number {
  const total = DURATIONS[s.phase];
  return total > 0 ? Math.min(1, Math.max(0, 1 - remainingAt(s, now) / total)) : 0;
}

export function start(s: FocusState, now: number): FocusState {
  if (s.running) return s;
  return { ...s, running: true, endsAt: now + s.remaining * 1000, started: true };
}

export function pause(s: FocusState, now: number): FocusState {
  if (!s.running) return s;
  return { ...s, running: false, endsAt: null, remaining: remainingAt(s, now) };
}

export function reset(): FocusState {
  return { ...IDLE_FOCUS };
}

/**
 * The phase after this one. A break starts by itself — the point is to stop —
 * but the next focus waits for a click, so time away from the desk isn't
 * counted as focus.
 */
export function next(s: FocusState, now: number): FocusState {
  if (s.phase === "focus") {
    const phase: FocusPhase = s.round >= ROUNDS ? "longBreak" : "break";
    return {
      phase, running: true, endsAt: now + DURATIONS[phase] * 1000, remaining: DURATIONS[phase], round: s.round, started: true,
    };
  }
  const round = s.phase === "longBreak" ? 1 : s.round + 1;
  return { phase: "focus", running: false, endsAt: null, remaining: DURATIONS.focus, round, started: false };
}

/** m:ss (the timer never passes an hour). */
export function formatClock(seconds: number): string {
  const s = Math.max(0, Math.ceil(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}
