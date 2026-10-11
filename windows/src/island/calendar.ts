// The calendar pill: today's agenda from the feed Rust fetched, a reminder five
// minutes before each meeting (Mochi looks up, the pill gets a badge), and a
// countdown kept right while the card is on screen. One timer for the next
// reminder, one only while the card shows: nothing runs when idle.

import {
  agenda, eventsBetween, parseIcs, reminderAt, upcomingWindow, type Agenda, type CalendarEvent, type ParsedCalendar,
} from "../core/calendar";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import type { Island } from "./island";

export const CALENDAR = "integration_calendar";

const COUNTDOWN_MS = 30_000;
const CLEAR_AFTER_START_MS = 60_000;

let parsedText: string | null = null;
let parsed: ParsedCalendar | null = null;
let windowFrom = 0;
let events: CalendarEvent[] = [];

/** Today's agenda, or null before the first feed arrives. */
export function calendarAgenda(now = Date.now()): Agenda | null {
  const text = State.integrations[CALENDAR]?.data?.ics;
  if (typeof text !== "string") return null;
  const window = upcomingWindow(now);
  if (text !== parsedText) {
    parsed = parseIcs(text);
    parsedText = text;
    windowFrom = 0;
  }
  if (window.from !== windowFrom) {
    events = eventsBetween(parsed!, window.from, window.to);
    windowFrom = window.from;
  }
  return agenda(events, now);
}

let reminderTimer: number | null = null;
let reminderKey = "";
let countdownTimer: number | null = null;

export function registerCalendar(island: Island) {
  State.subscribe(() => {
    scheduleReminder(island);
    keepCountdown();
  });
}

function scheduleReminder(island: Island) {
  const next = calendarAgenda()?.next ?? null;
  const key = next ? `${next.uid}|${next.start}` : "";
  if (key === reminderKey) return;
  reminderKey = key;
  if (reminderTimer != null) window.clearTimeout(reminderTimer);
  reminderTimer = null;

  const now = Date.now();
  const at = reminderAt(next, now);
  if (next == null || at == null) return;
  reminderTimer = window.setTimeout(() => {
    reminderTimer = null;
    remind(island, next);
  }, at - now);
}

function remind(island: Island, meeting: CalendarEvent) {
  const task = State.tasks.find((t) => t.id === CALENDAR);
  if (!task || State.paused || Date.now() >= meeting.start) return;
  task.state = "question";
  task.steps = [meeting.title];
  task.stepIndex = 0;
  if (State.focusId !== CALENDAR) task.pillBadge = "approval";
  Sound.play("question");
  island.reveal();
  State.notify();

  window.setTimeout(() => {
    const t = State.tasks.find((x) => x.id === CALENDAR);
    if (!t || t.state !== "question") return;
    t.state = "idle";
    t.steps = [];
    t.stepIndex = 0;
    t.pillBadge = null;
    State.notify();
  }, meeting.start - Date.now() + CLEAR_AFTER_START_MS);
}

/** Redraws the card every 30 s while it is on screen, so "in 4 min" stays true. */
function keepCountdown() {
  const shown = State.mode === "expanded" && State.focusTask?.id === CALENDAR;
  if (shown && countdownTimer == null) {
    countdownTimer = window.setInterval(() => State.notify(), COUNTDOWN_MS);
  } else if (!shown && countdownTimer != null) {
    window.clearInterval(countdownTimer);
    countdownTimer = null;
  }
}
