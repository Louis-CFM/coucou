// Calendar from an iCal feed: Google Calendar's "secret address in iCal format",
// or any other .ics link (Outlook, iCloud, Fastmail). No DOM, so it can be
// tested on its own; the card is in views/integrations.ts, the reminder in
// island/calendar.ts. On the Mac the same events come from EventKit instead
// (CalendarWatcher.swift).
//
// Only what "today and tomorrow" needs: events, all-day events, time zones
// (through Intl, which knows every IANA zone), recurrence (RRULE with
// FREQ/INTERVAL/COUNT/UNTIL/BYDAY/BYMONTHDAY/BYMONTH/WKST), EXDATE, moved or
// cancelled instances (RECURRENCE-ID).

export interface CalendarEvent {
  uid: string;
  title: string;
  /** Epoch milliseconds. */
  start: number;
  end: number;
  allDay: boolean;
  /** A Meet, Zoom or Teams link found in the event. */
  joinUrl: string | null;
}

export interface Agenda {
  /** The meeting on now, or the next one today or tomorrow. */
  next: CalendarEvent | null;
  /** The rest of today's timed events. */
  later: CalendarEvent[];
  /** Today's all-day events. */
  allDay: CalendarEvent[];
}

/** How long before a meeting the reminder fires. */
export const REMINDER_MS = 5 * 60_000;

const DAY_MS = 86_400_000;
const MAX_PERIODS = 20_000;

// ── Wall-clock dates ──────────────────────────────────────────────────────────

/** A date and time as written in the feed, before any time zone applies. */
interface Wall { y: number; mo: number; d: number; h: number; mi: number; s: number }

interface IcsTime {
  wall: Wall;
  /** An IANA zone, "UTC", or null for a floating time (the viewer's zone). */
  zone: string | null;
  date: boolean;
}

const wallMs = (w: Wall) => Date.UTC(w.y, w.mo - 1, w.d, w.h, w.mi, w.s);

function wallFrom(ms: number, time: Wall): Wall {
  const d = new Date(ms);
  return { y: d.getUTCFullYear(), mo: d.getUTCMonth() + 1, d: d.getUTCDate(), h: time.h, mi: time.mi, s: time.s };
}

const addDays = (w: Wall, n: number): Wall => wallFrom(Date.UTC(w.y, w.mo - 1, w.d + n), w);
const weekday = (w: Wall) => new Date(Date.UTC(w.y, w.mo - 1, w.d)).getUTCDay();
const daysInMonth = (y: number, mo: number) => new Date(Date.UTC(y, mo, 0)).getUTCDate();

// ── Time zones ────────────────────────────────────────────────────────────────

const formatters = new Map<string, Intl.DateTimeFormat>();
const zones = new Map<string, string | null>();

function formatter(tz: string): Intl.DateTimeFormat {
  let f = formatters.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone: tz, hourCycle: "h23",
      year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric",
    });
    formatters.set(tz, f);
  }
  return f;
}

/** A TZID Intl understands, or null. Some feeds write "/mozilla.org/.../Europe/Paris". */
function resolveZone(tzid: string): string | null {
  if (zones.has(tzid)) return zones.get(tzid)!;
  let found: string | null = null;
  for (const candidate of [tzid, tzid.match(/([A-Za-z_]+\/[A-Za-z_+-]+)$/)?.[1]]) {
    if (!candidate) continue;
    try {
      formatter(candidate);
      found = candidate;
      break;
    } catch {
      // Not a zone Intl knows: try the next spelling.
    }
  }
  zones.set(tzid, found);
  return found;
}

/** Offset of `tz` from UTC at instant `ms`, in milliseconds. */
function offsetAt(ms: number, tz: string): number {
  const parts: Record<string, number> = {};
  for (const p of formatter(tz).formatToParts(new Date(ms))) {
    if (p.type !== "literal") parts[p.type] = Number(p.value);
  }
  const asUtc = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second);
  return asUtc - Math.floor(ms / 1000) * 1000;
}

/**
 * The instant a wall-clock time in `tz` stands for. As RFC 5545 says: a time
 * repeated when clocks go back is its first occurrence, a time skipped when
 * they go forward takes the offset from before the gap.
 */
function zonedToUtc(w: Wall, tz: string): number {
  const guess = wallMs(w);
  if (tz === "UTC") return guess;
  const before = offsetAt(guess - DAY_MS, tz);
  const after = offsetAt(guess + DAY_MS, tz);
  const valid = [guess - before, guess - after].filter((utc, i) => offsetAt(utc, tz) === (i === 0 ? before : after));
  return valid.length > 0 ? Math.min(...valid) : guess - before;
}

export function localZone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
}

/** Midnight that starts the day `days` after the one containing `ms`, in `tz`. */
export function dayStart(ms: number, tz: string, days = 0): number {
  const local = new Date(ms + offsetAt(ms, tz));
  const wall = { y: local.getUTCFullYear(), mo: local.getUTCMonth() + 1, d: local.getUTCDate(), h: 0, mi: 0, s: 0 };
  return zonedToUtc(addDays(wall, days), tz);
}

// ── Lines and properties ──────────────────────────────────────────────────────

interface Prop { name: string; params: Record<string, string>; value: string }

function unfold(text: string): string[] {
  const out: string[] = [];
  for (const line of text.replace(/\r\n?/g, "\n").split("\n")) {
    if ((line.startsWith(" ") || line.startsWith("\t")) && out.length > 0) out[out.length - 1] += line.slice(1);
    else if (line !== "") out.push(line);
  }
  return out;
}

function parseProp(line: string): Prop | null {
  let quoted = false;
  let colon = -1;
  for (let i = 0; i < line.length; i++) {
    if (line[i] === '"') quoted = !quoted;
    else if (line[i] === ":" && !quoted) { colon = i; break; }
  }
  if (colon < 0) return null;
  const head = line.slice(0, colon).match(/(?:[^;"]|"[^"]*")+/g) ?? [];
  const params: Record<string, string> = {};
  for (const part of head.slice(1)) {
    const eq = part.indexOf("=");
    if (eq > 0) params[part.slice(0, eq).toUpperCase()] = part.slice(eq + 1).replace(/^"|"$/g, "");
  }
  return { name: (head[0] ?? "").toUpperCase(), params, value: line.slice(colon + 1) };
}

const unescapeText = (v: string) => v.replace(/\\([\\;,nN])/g, (_, c: string) => (c === "n" || c === "N" ? "\n" : c));

function parseTime(value: string, params: Record<string, string>): IcsTime | null {
  const m = value.trim().match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z?))?$/);
  if (!m) return null;
  const wall = { y: +m[1], mo: +m[2], d: +m[3], h: +(m[4] ?? 0), mi: +(m[5] ?? 0), s: +(m[6] ?? 0) };
  if (m[4] == null) return { wall, zone: null, date: true };
  if (m[7] === "Z") return { wall, zone: "UTC", date: false };
  return { wall, zone: params.TZID ? resolveZone(params.TZID) : null, date: false };
}

const instant = (t: IcsTime, localTz: string) => zonedToUtc(t.wall, t.zone ?? localTz);

function parseDuration(value: string): number | null {
  const m = value.match(/^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/);
  if (!m) return null;
  const ms = (((+(m[2] ?? 0) * 7 + +(m[3] ?? 0)) * 24 + +(m[4] ?? 0)) * 60 + +(m[5] ?? 0)) * 60_000 + +(m[6] ?? 0) * 1000;
  return m[1] === "-" ? -ms : ms;
}

// ── Recurrence rules ──────────────────────────────────────────────────────────

type Freq = "DAILY" | "WEEKLY" | "MONTHLY" | "YEARLY";

interface Rule {
  freq: Freq;
  interval: number;
  count: number | null;
  until: IcsTime | null;
  byday: { n: number | null; wd: number }[];
  bymonthday: number[];
  bymonth: number[];
  wkst: number;
}

const WEEKDAYS = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];

function parseRule(value: string): Rule | null {
  const parts: Record<string, string> = {};
  for (const kv of value.split(";")) {
    const eq = kv.indexOf("=");
    if (eq > 0) parts[kv.slice(0, eq).toUpperCase()] = kv.slice(eq + 1);
  }
  const freq = parts.FREQ as Freq;
  if (!["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].includes(freq)) return null;
  const list = (v: string | undefined) => (v ? v.split(",").map(Number).filter((n) => Number.isFinite(n) && n !== 0) : []);
  const byday = (parts.BYDAY ? parts.BYDAY.split(",") : [])
    .map((d) => d.match(/^([+-]?\d+)?([A-Z]{2})$/))
    .filter((m): m is RegExpMatchArray => !!m && WEEKDAYS.includes(m[2]))
    .map((m) => ({ n: m[1] ? Number(m[1]) : null, wd: WEEKDAYS.indexOf(m[2]) }));
  return {
    freq,
    interval: Math.max(1, Number(parts.INTERVAL) || 1),
    count: parts.COUNT ? Number(parts.COUNT) : null,
    until: parts.UNTIL ? parseTime(parts.UNTIL, {}) : null,
    byday,
    bymonthday: list(parts.BYMONTHDAY),
    bymonth: list(parts.BYMONTH),
    wkst: parts.WKST && WEEKDAYS.includes(parts.WKST) ? WEEKDAYS.indexOf(parts.WKST) : 1,
  };
}

/** Days of one month the rule picks, ascending. */
function monthDays(rule: Rule, y: number, mo: number, defaultDay: number): number[] {
  const dim = daysInMonth(y, mo);
  const firstWd = new Date(Date.UTC(y, mo - 1, 1)).getUTCDay();
  const wdOf = (d: number) => (firstWd + d - 1) % 7;
  let days: number[];
  if (rule.bymonthday.length > 0) {
    days = rule.bymonthday.map((n) => (n > 0 ? n : dim + n + 1)).filter((d) => d >= 1 && d <= dim);
    if (rule.byday.length > 0) days = days.filter((d) => rule.byday.some((b) => b.wd === wdOf(d)));
  } else if (rule.byday.length > 0) {
    days = [];
    for (const b of rule.byday) {
      const all: number[] = [];
      for (let d = 1; d <= dim; d++) if (wdOf(d) === b.wd) all.push(d);
      if (b.n == null) days.push(...all);
      else {
        const pick = b.n > 0 ? all[b.n - 1] : all[all.length + b.n];
        if (pick != null) days.push(pick);
      }
    }
  } else {
    days = defaultDay <= dim ? [defaultDay] : [];
  }
  return [...new Set(days)].sort((a, b) => a - b);
}

/** Every date the rule makes, period by period, ascending, from DTSTART's period. */
function* candidates(rule: Rule, start: Wall): Generator<Wall> {
  const at = (y: number, mo: number, d: number): Wall => ({ y, mo, d, h: start.h, mi: start.mi, s: start.s });
  const monthOk = (w: Wall) => rule.bymonth.length === 0 || rule.bymonth.includes(w.mo);

  for (let k = 0; k < MAX_PERIODS; k++) {
    switch (rule.freq) {
      case "DAILY": {
        const w = addDays(start, k * rule.interval);
        const dayOk = rule.byday.length === 0 || rule.byday.some((b) => b.wd === weekday(w));
        const mdOk = rule.bymonthday.length === 0 || monthDays(rule, w.y, w.mo, w.d).includes(w.d);
        if (monthOk(w) && dayOk && mdOk) yield w;
        break;
      }
      case "WEEKLY": {
        const weekStart = addDays(start, -((weekday(start) - rule.wkst + 7) % 7) + 7 * k * rule.interval);
        const offsets = rule.byday.length > 0
          ? [...new Set(rule.byday.map((b) => (b.wd - rule.wkst + 7) % 7))].sort((a, b) => a - b)
          : [(weekday(start) - rule.wkst + 7) % 7];
        for (const o of offsets) {
          const w = addDays(weekStart, o);
          if (monthOk(w)) yield w;
        }
        break;
      }
      case "MONTHLY": {
        const index = start.mo - 1 + k * rule.interval;
        const y = start.y + Math.floor(index / 12);
        const mo = (index % 12) + 1;
        if (rule.bymonth.length > 0 && !rule.bymonth.includes(mo)) break;
        for (const d of monthDays(rule, y, mo, start.d)) yield at(y, mo, d);
        break;
      }
      case "YEARLY": {
        const y = start.y + k * rule.interval;
        const months = rule.bymonth.length > 0 ? [...rule.bymonth].sort((a, b) => a - b) : [start.mo];
        for (const mo of months) {
          for (const d of monthDays(rule, y, mo, start.d)) yield at(y, mo, d);
        }
        break;
      }
    }
  }
}

// ── Events ────────────────────────────────────────────────────────────────────

interface VEvent {
  uid: string;
  title: string;
  start: IcsTime;
  end: IcsTime | null;
  duration: number | null;
  rule: Rule | null;
  exdates: { value: string; params: Record<string, string> }[];
  recurrenceId: IcsTime | null;
  cancelled: boolean;
  joinUrl: string | null;
}

export interface ParsedCalendar { events: VEvent[] }

const JOIN_LINK =
  /https:\/\/(?:meet\.google\.com\/[a-z0-9-]+|(?:[\w-]+\.)?zoom\.us\/(?:j|my|w|s)\/[^\s"<>\\]+|teams\.microsoft\.com\/l\/meetup-join\/[^\s"<>\\]+|teams\.live\.com\/meet\/[^\s"<>\\]+)/i;

/** The first Meet, Zoom or Teams link in these texts, in order. */
export function findJoinLink(...texts: (string | undefined)[]): string | null {
  for (const text of texts) {
    const m = text?.match(JOIN_LINK);
    if (m) return m[0].replace(/[).,;]+$/, "");
  }
  return null;
}

export function parseIcs(text: string): ParsedCalendar {
  const events: VEvent[] = [];
  let props: Prop[] | null = null;
  let depth = 0; // inside VEVENT, how deep in nested blocks (VALARM)

  for (const line of unfold(text)) {
    const prop = parseProp(line);
    if (!prop) continue;
    if (prop.name === "BEGIN") {
      if (props) depth++;
      else if (prop.value.toUpperCase() === "VEVENT") props = [];
      continue;
    }
    if (prop.name === "END") {
      if (props && depth > 0) depth--;
      else if (props && prop.value.toUpperCase() === "VEVENT") {
        const event = buildEvent(props);
        if (event) events.push(event);
        props = null;
      }
      continue;
    }
    if (props && depth === 0) props.push(prop);
  }
  return { events };
}

function buildEvent(props: Prop[]): VEvent | null {
  const one = (name: string) => props.find((p) => p.name === name);
  const dtstart = one("DTSTART");
  const start = dtstart ? parseTime(dtstart.value, dtstart.params) : null;
  if (!start) return null;
  const dtend = one("DTEND");
  const rrule = one("RRULE");
  const rid = one("RECURRENCE-ID");
  const text = (name: string) => {
    const p = one(name);
    return p ? unescapeText(p.value) : undefined;
  };
  return {
    uid: one("UID")?.value ?? "",
    title: text("SUMMARY")?.trim() || "",
    start,
    end: dtend ? parseTime(dtend.value, dtend.params) : null,
    duration: one("DURATION") ? parseDuration(one("DURATION")!.value) : null,
    rule: rrule ? parseRule(rrule.value) : null,
    exdates: props
      .filter((p) => p.name === "EXDATE")
      .flatMap((p) => p.value.split(",").map((value) => ({ value, params: p.params }))),
    recurrenceId: rid ? parseTime(rid.value, rid.params) : null,
    cancelled: one("STATUS")?.value.toUpperCase() === "CANCELLED",
    joinUrl: findJoinLink(text("X-GOOGLE-CONFERENCE"), text("URL"), text("LOCATION"), text("DESCRIPTION")),
  };
}

/** Length of an event: milliseconds when timed, whole days when all-day. */
function length(e: VEvent, localTz: string): { ms: number; days: number } {
  if (e.start.date) {
    const days = e.end?.date ? Math.round((wallMs(e.end.wall) - wallMs(e.start.wall)) / DAY_MS) : 1;
    return { ms: 0, days: Math.max(1, days) };
  }
  if (e.end) return { ms: Math.max(0, instant(e.end, localTz) - instant(e.start, localTz)), days: 0 };
  return { ms: Math.max(0, e.duration ?? 0), days: 0 };
}

/** The events that overlap [from, to), recurring ones expanded, by start time. */
export function eventsBetween(cal: ParsedCalendar, from: number, to: number, localTz = localZone()): CalendarEvent[] {
  const key = (uid: string, ms: number) => `${uid}|${ms}`;
  const zoneOf = (e: VEvent) => (e.start.date ? localTz : e.start.zone ?? localTz);
  const moved = new Set<string>();
  for (const e of cal.events) {
    const rid = e.recurrenceId;
    if (rid) moved.add(key(e.uid, zonedToUtc(rid.wall, rid.date ? zoneOf(e) : rid.zone ?? zoneOf(e))));
  }

  const out: CalendarEvent[] = [];
  const push = (e: VEvent, startWall: Wall, zone: string) => {
    const span = length(e, localTz);
    const start = zonedToUtc(startWall, zone);
    const end = e.start.date ? zonedToUtc(addDays(startWall, span.days), zone) : start + span.ms;
    if (start < to && (end > from || (end === start && start >= from))) {
      out.push({ uid: e.uid, title: e.title, start, end, allDay: e.start.date, joinUrl: e.joinUrl });
    }
  };

  for (const e of cal.events) {
    if (e.cancelled) continue;
    const zone = zoneOf(e);
    if (e.recurrenceId || !e.rule) {
      push(e, e.start.wall, zone);
      continue;
    }

    const first = zonedToUtc(e.start.wall, zone);
    const until = e.rule.until
      ? e.rule.until.date
        ? zonedToUtc(addDays(e.rule.until.wall, 1), zone) - 1
        : zonedToUtc(e.rule.until.wall, e.rule.until.zone ?? zone)
      : Infinity;
    const excluded = new Set(e.exdates.map((x) => {
      const t = parseTime(x.value, x.params);
      return t ? zonedToUtc(t.wall, t.date ? zone : t.zone ?? zone) : NaN;
    }));

    let n = 0;
    for (const wall of candidates(e.rule, e.start.wall)) {
      const ms = zonedToUtc(wall, zone);
      if (ms < first) continue;
      if (ms > until) break;
      n++;
      if (e.rule.count != null && n > e.rule.count) break;
      if (ms >= to) break;
      if (excluded.has(ms) || moved.has(key(e.uid, ms))) continue;
      push(e, wall, zone);
    }
  }
  return out.sort((a, b) => a.start - b.start || a.end - b.end);
}

// ── What the card shows ───────────────────────────────────────────────────────

/** Today and tomorrow, in the viewer's zone: what the card and the reminder need. */
export function upcomingWindow(now: number, localTz = localZone()): { from: number; to: number } {
  return { from: dayStart(now, localTz), to: dayStart(now, localTz, 2) };
}

export function agenda(events: CalendarEvent[], now: number, localTz = localZone()): Agenda {
  const todayEnd = dayStart(now, localTz, 1);
  const tomorrowEnd = dayStart(now, localTz, 2);
  const timed = events.filter((e) => !e.allDay && e.end > now && e.start < tomorrowEnd);
  return {
    next: timed[0] ?? null,
    later: timed.slice(1).filter((e) => e.start < todayEnd),
    allDay: events.filter((e) => e.allDay && e.start < todayEnd && e.end > now),
  };
}

/** Minutes until a meeting starts, rounded up; 0 once it has. */
export function minutesUntil(e: CalendarEvent, now: number): number {
  return Math.max(0, Math.ceil((e.start - now) / 60_000));
}

/** True when the meeting starts tomorrow or later, in the viewer's zone. */
export function isAfterToday(e: CalendarEvent, now: number, localTz = localZone()): boolean {
  return e.start >= dayStart(now, localTz, 1);
}

/** When to remind about `next`: now if inside the window, null once it has started. */
export function reminderAt(next: CalendarEvent | null, now: number): number | null {
  if (!next || next.start <= now) return null;
  return Math.max(now, next.start - REMINDER_MS);
}
