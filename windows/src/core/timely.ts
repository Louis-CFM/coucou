// Timely — what the card shows of the poller's data (integrations.rs). The
// poller asks for a day either side of UTC's today; the local day is kept here,
// where the time zone is known.

export interface TimelyEntry {
  id: number;
  day: string;
  project: string;
  client: string | null;
  color: string;
  note: string;
  /** Time already on the entry, without the run in progress. */
  loggedSeconds: number;
  /** Unix seconds, set only while the timer runs. */
  timerStartedOn: number | null;
}

export interface TimelyDay {
  entries: TimelyEntry[];
  running: TimelyEntry | null;
  capacityHours: number | null;
}

/** "2026-10-10" in the local time zone. */
export function localDay(date: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

/** The entry's time now, counting the run in progress. */
export function entrySeconds(entry: TimelyEntry, now: Date): number {
  if (entry.timerStartedOn == null) return entry.loggedSeconds;
  return entry.loggedSeconds + Math.max(0, Math.floor(now.getTime() / 1000 - entry.timerStartedOn));
}

/** 3725 → "1:02". */
export function hm(seconds: number): string {
  const minutes = Math.floor(Math.max(0, seconds) / 60);
  return `${Math.floor(minutes / 60)}:${String(minutes % 60).padStart(2, "0")}`;
}

function isEntry(v: unknown): v is TimelyEntry {
  const e = v as TimelyEntry | null;
  return e != null && typeof e.id === "number" && typeof e.day === "string" && typeof e.project === "string";
}

/** Today's entries from the card data; null until the poller has sent some. */
export function readTimelyDay(data: Record<string, unknown>, now: Date): TimelyDay | null {
  if (!Array.isArray(data.entries)) return null;
  const today = localDay(now);
  const entries = data.entries.filter(isEntry).filter((e) => e.day === today);
  const capacity = typeof data.capacityHours === "number" && data.capacityHours > 0 ? data.capacityHours : null;
  return {
    entries,
    running: entries.find((e) => e.timerStartedOn != null) ?? null,
    capacityHours: capacity,
  };
}

export function loggedSeconds(day: TimelyDay, now: Date): number {
  return day.entries.reduce((sum, e) => sum + entrySeconds(e, now), 0);
}
