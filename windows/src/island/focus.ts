// The focus timer → the island (src/core/focus.ts holds the rules). The end of a
// phase is one timeout, so a hidden island costs nothing; the pill and the card
// tick once a second only while the island is on screen. When a phase ends,
// Mochi says so with a sound and the island comes out; on a break, the pill's
// Mochi naps.

import { FOCUS_ID, Focus, IDLE_FOCUS, formatClock, next, remainingAt, type FocusPhase } from "../core/focus";
import { pillDefinition } from "../core/pills";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import { t } from "../i18n/i18n";

export interface FocusHost {
  /** The island comes out, with its peek sound. */
  reveal(): void;
}

let host: FocusHost | null = null;
let endTimer: ReturnType<typeof setTimeout> | null = null;
let ticker: ReturnType<typeof setInterval> | null = null;

export function phaseLabel(phase: FocusPhase): string {
  return phase === "focus" ? t("Focus") : phase === "break" ? t("Break") : t("Long break");
}

export function registerFocusHandlers(island: FocusHost) {
  host = island;
  State.subscribe(() => {
    syncTask();
    syncTicker();
  });
}

/** After every change of the timer: its end is scheduled again, and shown. */
export function focusChanged() {
  if (endTimer != null) clearTimeout(endTimer);
  endTimer = null;
  const s = Focus.state;
  if (s.running && s.endsAt != null) endTimer = setTimeout(phaseEnded, Math.max(0, s.endsAt - Date.now()));
  State.notify();
}

/** The phase is over: on to the next, with a sound and the island out. */
export function phaseEnded() {
  if (endTimer != null) clearTimeout(endTimer);
  endTimer = null;
  const ended = Focus.state.phase;
  Focus.state = next(Focus.state, Date.now());
  if (State.settings.activeIntegrations.includes(FOCUS_ID) && !State.paused) {
    Sound.play(ended === "focus" ? "finish" : "greet");
    host?.reveal();
  }
  focusChanged();
}

/** The pill wears the phase and the time left; its Mochi naps on a break. */
function syncTask() {
  let task = State.tasks.find((x) => x.id === FOCUS_ID);
  const s = Focus.state;
  if (task && !State.settings.activeIntegrations.includes(FOCUS_ID)) {
    // Taken away mid-break: a napping pill counts as busy, so wake it and let it go.
    task.state = "idle";
    State.loadIntegrationTasks();
    task = State.tasks.find((x) => x.id === FOCUS_ID);
  }
  if (!task) {
    // The pill was taken away: the timer stops with it.
    if (s.started || s.round !== 1 || s.phase !== "focus") {
      Focus.state = { ...IDLE_FOCUS };
      focusChanged();
    }
    return;
  }
  const name = s.started
    ? `${phaseLabel(s.phase)} ${formatClock(remainingAt(s, Date.now()))}`
    : (pillDefinition(FOCUS_ID)?.name ?? "Focus timer");
  if (task.name !== name) task.name = name;
  const state = s.running && s.phase !== "focus" ? "sleeping" : "idle";
  if (task.state !== state) task.state = state;
}

/** A tick a second while the timer runs and the island is on screen. */
function syncTicker() {
  const run = Focus.state.running && State.mode !== "hidden" && State.tasks.some((x) => x.id === FOCUS_ID);
  if (run && ticker == null) ticker = setInterval(() => State.notify(), 1000);
  else if (!run && ticker != null) {
    clearInterval(ticker);
    ticker = null;
  }
}
