// The Kit page (src/views/kit.ts): a focus timer, a water reminder, a to-do
// list with reminders and a file shelf, all kept on this PC (kit.json,
// src-tauri/src/kit.rs). The rules live here, without the DOM, so they are
// tested on their own (tests/kit.test.mjs).

import type { AsrSchool, MethodId } from "./prayer";
import { METHODS } from "./prayer";

export type KitPage = "focus" | "water" | "todo" | "shelf" | "prayer";
export const KIT_PAGES: readonly KitPage[] = ["focus", "water", "todo", "shelf", "prayer"];

export interface FocusPrefs {
  workMin: number;
  breakMin: number;
  longMin: number;
  /** Work rounds before the long break. */
  rounds: number;
}

export interface WaterPrefs {
  goalMl: number;
  /** One tap of "Drink". */
  sipMl: number;
  remind: boolean;
  /** Reminders only between these hours (local time, 0–24). */
  fromHour: number;
  toHour: number;
  everyMin: number;
}

export interface Todo {
  id: number;
  text: string;
  /** Epoch ms, or null for no reminder. */
  due: number | null;
  done: boolean;
  /** The reminder went off (it doesn't again). */
  told: boolean;
  createdAt: number;
}

export interface PrayerPrefs {
  /** Where the times are worked out for; null until a city is chosen. */
  city: { name: string; country: string; lat: number; lng: number } | null;
  method: MethodId;
  asr: AsrSchool;
  /** A reminder this many minutes before each prayer (0: none). */
  remindMin: number;
  /** At prayer time, Spotify pauses if it plays. */
  pauseMusic: boolean;
}

export interface KitData {
  v: 1;
  focus: FocusPrefs & { log: { at: number; min: number }[] };
  water: WaterPrefs & { log: { at: number; ml: number }[] };
  todos: Todo[];
  shelf: string[];
  prayer: PrayerPrefs;
}

export function defaults(): KitData {
  return {
    v: 1,
    focus: { workMin: 25, breakMin: 5, longMin: 15, rounds: 4, log: [] },
    water: { goalMl: 2000, sipMl: 250, remind: true, fromHour: 9, toHour: 21, everyMin: 60, log: [] },
    todos: [],
    shelf: [],
    prayer: { city: null, method: "karachi", asr: "hanafi", remindMin: 10, pauseMusic: false },
  };
}

const num = (v: unknown, lo: number, hi: number, fallback: number): number =>
  typeof v === "number" && Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : fallback;

/** What kit.json held, made safe: unknown or broken fields fall back to the defaults. */
export function normalize(raw: unknown): KitData {
  const d = defaults();
  if (!raw || typeof raw !== "object") return d;
  const r = raw as Record<string, any>;
  const f = r.focus ?? {};
  const w = r.water ?? {};
  const keepDays = 60 * 86_400_000;
  const recent = (at: unknown) => typeof at === "number" && at > Date.now() - keepDays;
  return {
    v: 1,
    focus: {
      workMin: num(f.workMin, 1, 180, d.focus.workMin),
      breakMin: num(f.breakMin, 1, 60, d.focus.breakMin),
      longMin: num(f.longMin, 1, 90, d.focus.longMin),
      rounds: Math.round(num(f.rounds, 1, 12, d.focus.rounds)),
      log: Array.isArray(f.log) ? f.log.filter((e: any) => recent(e?.at) && typeof e.min === "number") : [],
    },
    water: {
      goalMl: num(w.goalMl, 250, 8000, d.water.goalMl),
      sipMl: num(w.sipMl, 50, 2000, d.water.sipMl),
      remind: typeof w.remind === "boolean" ? w.remind : d.water.remind,
      fromHour: num(w.fromHour, 0, 23, d.water.fromHour),
      toHour: num(w.toHour, 1, 24, d.water.toHour),
      everyMin: num(w.everyMin, 15, 240, d.water.everyMin),
      log: Array.isArray(w.log) ? w.log.filter((e: any) => recent(e?.at) && typeof e.ml === "number") : [],
    },
    todos: Array.isArray(r.todos)
      ? r.todos
        .filter((t: any) => t && typeof t.text === "string" && t.text.trim() && typeof t.id === "number")
        .map((t: any): Todo => ({
          id: t.id,
          text: t.text,
          due: typeof t.due === "number" ? t.due : null,
          done: t.done === true,
          told: t.told === true,
          createdAt: typeof t.createdAt === "number" ? t.createdAt : 0,
        }))
      : [],
    shelf: Array.isArray(r.shelf) ? [...new Set<string>(r.shelf.filter((p: unknown) => typeof p === "string" && p))] : [],
    prayer: normalizePrayer(r.prayer, d.prayer),
  };
}

function normalizePrayer(raw: unknown, d: PrayerPrefs): PrayerPrefs {
  if (!raw || typeof raw !== "object") return { ...d };
  const p = raw as Record<string, any>;
  const c = p.city;
  const city = c && typeof c.name === "string" && Number.isFinite(c.lat) && Number.isFinite(c.lng) &&
      Math.abs(c.lat) <= 90 && Math.abs(c.lng) <= 180
    ? { name: c.name, country: typeof c.country === "string" ? c.country : "", lat: c.lat, lng: c.lng }
    : null;
  return {
    city,
    method: typeof p.method === "string" && p.method in METHODS ? (p.method as MethodId) : d.method,
    asr: p.asr === "standard" || p.asr === "hanafi" ? p.asr : d.asr,
    remindMin: num(p.remindMin, 0, 60, d.remindMin),
    pauseMusic: p.pauseMusic === true,
  };
}

// ── Time ──────────────────────────────────────────────────────────────────────

export function startOfDay(ms: number): number {
  const d = new Date(ms);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** 1 100 000 ms → "18:20"; an hour or more → "1:02:05". */
export function clock(ms: number): string {
  const s = Math.max(0, Math.ceil(ms / 1000));
  const hh = Math.floor(s / 3600);
  const mm = Math.floor((s % 3600) / 60);
  const ss = s % 60;
  const two = (n: number) => String(n).padStart(2, "0");
  return hh > 0 ? `${hh}:${two(mm)}:${two(ss)}` : `${two(mm)}:${two(ss)}`;
}

/** "14:30" → that time today, or tomorrow when it has passed; anything else → null. */
export function dueFromTime(hhmm: string, now: number): number | null {
  const m = /^(\d{1,2}):(\d{2})$/.exec(hhmm.trim());
  if (!m) return null;
  const h = Number(m[1]);
  const min = Number(m[2]);
  if (h > 23 || min > 59) return null;
  const d = new Date(now);
  d.setHours(h, min, 0, 0);
  if (d.getTime() <= now) d.setDate(d.getDate() + 1);
  return d.getTime();
}

// ── Water ─────────────────────────────────────────────────────────────────────

export function waterToday(w: KitData["water"], now: number): number {
  const from = startOfDay(now);
  return w.log.filter((e) => e.at >= from && e.at <= now).reduce((sum, e) => sum + e.ml, 0);
}

/** The last 7 days' totals, oldest first (today last). */
export function waterWeek(w: KitData["water"], now: number): number[] {
  const today = startOfDay(now);
  const days: number[] = [];
  for (let i = 6; i >= 0; i--) {
    const from = new Date(today);
    from.setDate(from.getDate() - i);
    const to = new Date(from);
    to.setDate(to.getDate() + 1);
    days.push(w.log.filter((e) => e.at >= from.getTime() && e.at < to.getTime()).reduce((s, e) => s + e.ml, 0));
  }
  return days;
}

/**
 * Whether to remind about water now: reminders on, inside the hours, the goal
 * not reached, and neither a drink nor a reminder in the last `everyMin`.
 */
export function waterDue(w: KitData["water"], now: number, lastReminder: number): boolean {
  if (!w.remind) return false;
  const hour = new Date(now).getHours() + new Date(now).getMinutes() / 60;
  if (hour < w.fromHour || hour >= w.toHour) return false;
  if (waterToday(w, now) >= w.goalMl) return false;
  const gap = w.everyMin * 60_000;
  const lastDrink = w.log.reduce((m, e) => (e.at <= now ? Math.max(m, e.at) : m), 0);
  // The first reminder of the day counts from the start of the hours, not from midnight.
  const dayStart = startOfDay(now) + w.fromHour * 3_600_000;
  const since = Math.max(lastDrink, lastReminder, dayStart);
  return now - since >= gap;
}

// ── To-do ─────────────────────────────────────────────────────────────────────

/** Open tasks first, the soonest reminder first (none last, oldest first); done ones after. */
export function sortedTodos(todos: Todo[]): Todo[] {
  return [...todos].sort((a, b) => {
    if (a.done !== b.done) return a.done ? 1 : -1;
    if (!a.done) {
      const ad = a.due ?? Number.POSITIVE_INFINITY;
      const bd = b.due ?? Number.POSITIVE_INFINITY;
      if (ad !== bd) return ad - bd;
    }
    return a.createdAt - b.createdAt;
  });
}

/** Open tasks whose time has come and that haven't reminded yet. */
export function dueTodos(todos: Todo[], now: number): Todo[] {
  return todos.filter((t) => !t.done && !t.told && t.due != null && t.due <= now);
}

// ── Focus timer ───────────────────────────────────────────────────────────────

export type FocusPhase = "idle" | "work" | "break" | "long";

export interface FocusRun {
  phase: FocusPhase;
  /** Which work round (1-based) this is, or the one just finished during a break. */
  round: number;
  /** Epoch ms the phase ends; null while paused or idle. */
  endsAt: number | null;
  /** While paused: what was left. */
  leftMs: number;
}

export const IDLE: FocusRun = { phase: "idle", round: 0, endsAt: null, leftMs: 0 };

const phaseMs = (p: FocusPrefs, phase: FocusPhase): number =>
  (phase === "work" ? p.workMin : phase === "break" ? p.breakMin : phase === "long" ? p.longMin : 0) * 60_000;

export function startFocus(p: FocusPrefs, now: number): FocusRun {
  return { phase: "work", round: 1, endsAt: now + phaseMs(p, "work"), leftMs: phaseMs(p, "work") };
}

export function leftOf(run: FocusRun, now: number): number {
  return run.endsAt == null ? run.leftMs : Math.max(0, run.endsAt - now);
}

export function pauseFocus(run: FocusRun, now: number): FocusRun {
  return run.endsAt == null ? run : { ...run, endsAt: null, leftMs: leftOf(run, now) };
}

export function resumeFocus(run: FocusRun, now: number): FocusRun {
  return run.endsAt != null || run.phase === "idle" ? run : { ...run, endsAt: now + run.leftMs };
}

/** The phase after this one: work → break (long after the last round) → the next work round. */
export function nextPhase(run: FocusRun, p: FocusPrefs, now: number): FocusRun {
  let phase: FocusPhase;
  let round = run.round;
  if (run.phase === "work") phase = run.round >= p.rounds ? "long" : "break";
  else if (run.phase === "long") return IDLE;
  else {
    phase = "work";
    round += 1;
  }
  const ms = phaseMs(p, phase);
  return { phase, round, endsAt: now + ms, leftMs: ms };
}

/**
 * The clock moved on: when the phase is over, the next one starts by itself,
 * and `ended` says which phase just ended (to tell the user, and to log a
 * finished work round).
 */
export function tickFocus(run: FocusRun, p: FocusPrefs, now: number): { run: FocusRun; ended: FocusPhase | null } {
  if (run.endsAt == null || now < run.endsAt) return { run, ended: null };
  return { run: nextPhase(run, p, now), ended: run.phase };
}

/** Minutes of focus logged today. */
export function focusToday(f: KitData["focus"], now: number): number {
  const from = startOfDay(now);
  return f.log.filter((e) => e.at >= from && e.at <= now).reduce((s, e) => s + e.min, 0);
}

/** What the compact island shows while the timer runs: "Focus 18:42", "Break 03:10". */
export function focusLive(run: FocusRun, now: number, labels: Record<Exclude<FocusPhase, "idle">, string>): string | null {
  if (run.phase === "idle") return null;
  const left = clock(leftOf(run, now));
  return `${labels[run.phase]} ${left}${run.endsAt == null ? " ‖" : ""}`;
}

// ── Shelf ─────────────────────────────────────────────────────────────────────

/** New files go first; one already there moves to the front. At most 60. */
export function addToShelf(shelf: string[], paths: string[]): string[] {
  const fresh = paths.filter((p) => typeof p === "string" && p.trim());
  const key = (p: string) => p.toLowerCase();
  const incoming = new Set(fresh.map(key));
  return [...fresh.filter((p, i) => fresh.findIndex((q) => key(q) === key(p)) === i), ...shelf.filter((p) => !incoming.has(key(p)))].slice(0, 60);
}

/** 2 400 000 → "2.3 MB". */
export function size(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let v = bytes / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v >= 10 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}
