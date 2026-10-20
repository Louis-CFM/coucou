// The Agenda pill's data: what Rust sends (src-tauri/src/agenda/) turned into what the card shows.
// No DOM here, so the day grouping and the "now / soon" marks are tested on their own.

export interface AgendaEvent {
  id: string;
  title: string;
  /** Unix seconds. An all-day event's are its first and last days' midnights in UTC, only for ordering. */
  start: number;
  end: number;
  allDay: boolean;
  /** `YYYY-MM-DD`, set for an all-day event; `endDay` is the day after its last. */
  startDay: string | null;
  endDay: string | null;
  location: string | null;
  joinUrl: string | null;
  /** The id of the calendar it comes from. */
  source: string;
  /** That calendar's name, as the user gave it. */
  calendar: string;
  /** That calendar's dot (`#RRGGBB`). */
  color: string;
  /** False for an event the calendar marks as free. */
  busy: boolean;
  /** Another busy event of the day overlaps this one. */
  conflict: boolean;
}

export interface AgendaData {
  events: AgendaEvent[];
  /** Why a calendar gave nothing; one failing never hides the others' events. */
  errors: { id: string; calendar: string; message: string }[];
}

/** A calendar the user added. Its link is a secret, in the credential store under `linkKey(id)`. */
export interface AgendaCalendar {
  /** Lower case letters and digits; names the calendar's entry in the credential store. */
  id: string;
  name: string;
  color: string;
  /** Off keeps the calendar and its link but reads nothing from it. */
  enabled: boolean;
}

/** Calendars the user may add (src-tauri/src/agenda/mod.rs holds the same cap). */
export const MAX_CALENDARS = 10;

/** The dots, handed out in this order to the calendars as they are added. */
export const CALENDAR_COLORS = [
  "#7B83EB", "#34C759", "#F5A524", "#F4505E", "#4F8EF7", "#C084FC", "#2DD4BF", "#F29B38",
];

/** The credential-store entry of a calendar's link. */
export function linkKey(id: string): string {
  return `agenda-link-${id}`;
}

/** The first colour no calendar wears; once all are used, they come round again. */
export function nextColor(calendars: AgendaCalendar[]): string {
  const used = new Set(calendars.map((c) => c.color));
  return CALENDAR_COLORS.find((c) => !used.has(c)) ?? CALENDAR_COLORS[calendars.length % CALENDAR_COLORS.length];
}

/** A fresh id: eight lower case letters and digits, none of `taken`. */
export function newCalendarId(taken: string[], random: () => number = Math.random): string {
  const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
  for (;;) {
    let id = "";
    for (let i = 0; i < 8; i++) id += alphabet[Math.floor(random() * alphabet.length)];
    if (!taken.includes(id)) return id;
  }
}

/** What may be pasted as a calendar's link: https, or webcal (which is https by another name). */
export function isCalendarLink(link: string): boolean {
  const l = link.trim().toLowerCase();
  return (l.startsWith("https://") && l.length > "https://".length) ||
    (l.startsWith("webcal://") && l.length > "webcal://".length);
}

/** How close a coming event must be to be marked, in milliseconds. */
export const SOON_MS = 60 * 60 * 1000;

export function readAgenda(data: Record<string, unknown>): AgendaData {
  const events = Array.isArray(data.events) ? (data.events as AgendaEvent[]) : [];
  const errors = Array.isArray(data.errors) ? (data.errors as AgendaData["errors"]) : [];
  return { events, errors };
}

/** What an event is, for the card: running, the next one within the hour, or just later. */
export type Mark = "active" | "upcoming" | "later";

export interface Row {
  event: AgendaEvent;
  mark: Mark;
}

export interface DayGroup {
  /** `YYYY-MM-DD`, in the local zone. */
  key: string;
  /** Local midnight of that day. */
  date: Date;
  rows: Row[];
}

function dayKey(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function parseDay(key: string): Date {
  const [y, m, d] = key.split("-").map(Number);
  return new Date(y, m - 1, d);
}

/**
 * The events grouped by local day, from today for `days` days: all-day ones first within a day (and
 * on each day a long one covers), then the timed ones in order. What already ended today is left out
 * — the list says what is still to do. Days with nothing are left out too.
 */
export function groupByDay(events: AgendaEvent[], now: Date, days = 7): DayGroup[] {
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const last = new Date(today.getFullYear(), today.getMonth(), today.getDate() + days - 1);
  const nowMs = now.getTime();
  const groups = new Map<string, DayGroup>();
  const put = (when: Date, event: AgendaEvent) => {
    // The day, whatever the time of the event: its local midnight.
    const day = new Date(when.getFullYear(), when.getMonth(), when.getDate());
    if (day < today || day > last) return;
    const key = dayKey(day);
    const group = groups.get(key) ?? { key, date: day, rows: [] };
    group.rows.push({ event, mark: "later" });
    groups.set(key, group);
  };

  for (const event of events) {
    if (event.allDay) {
      if (!event.startDay || !event.endDay) continue;
      const end = parseDay(event.endDay);
      for (let d = parseDay(event.startDay); d < end; d = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1)) {
        put(d, event);
      }
    } else {
      if (event.end * 1000 <= nowMs && event.end > event.start) continue;
      if (event.end === event.start && event.start * 1000 < nowMs) continue;
      put(new Date(event.start * 1000), event);
    }
  }

  const out = [...groups.values()].sort((a, b) => a.date.getTime() - b.date.getTime());
  for (const group of out) {
    group.rows.sort((a, b) => {
      if (a.event.allDay !== b.event.allDay) return a.event.allDay ? -1 : 1;
      return a.event.start - b.event.start || a.event.end - b.event.end || a.event.title.localeCompare(b.event.title);
    });
  }

  // Marks: what is running; and the first timed event to come, when it is within the hour.
  let soonGiven = false;
  for (const group of out) {
    for (const row of group.rows) {
      const e = row.event;
      if (e.allDay) continue;
      if (e.start * 1000 <= nowMs && nowMs < e.end * 1000) row.mark = "active";
      else if (!soonGiven && e.start * 1000 > nowMs && e.start * 1000 - nowMs <= SOON_MS) {
        row.mark = "upcoming";
        soonGiven = true;
      }
    }
  }
  return out;
}

/** `https` links only: the card hands this to the browser. */
export function safeJoinUrl(event: AgendaEvent): string | null {
  return event.joinUrl && event.joinUrl.startsWith("https://") ? event.joinUrl : null;
}
