export interface Booking {
  id: string; title: string; start: Date; end: Date;
  attendeeName: string; attendeeEmail: string; attendeeNotes: string;
}

/** Invalid data must not appear as an empty, successfully loaded calendar. */
export function readBookings(value: unknown): Booking[] | null {
  if (!Array.isArray(value)) return null;
  const out: Booking[] = [];
  for (const raw of value) {
    if (!raw || typeof raw.id !== "string" || typeof raw.start !== "string" || typeof raw.end !== "string") return null;
    const start = new Date(raw.start), end = new Date(raw.end);
    if (!Number.isFinite(start.getTime()) || !Number.isFinite(end.getTime()) || end < start) return null;
    const text = (key: string) => typeof raw[key] === "string" ? raw[key] : "";
    out.push({ id: raw.id, title: text("title"), start, end, attendeeName: text("attendeeName"),
      attendeeEmail: text("attendeeEmail"), attendeeNotes: text("attendeeNotes") });
  }
  return out.sort((a, b) => a.start.getTime() - b.start.getTime());
}

/** Local calendar dates, independent of UTC offset and daylight-saving transitions. */
export function dayKey(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}
export function monthIndex(date: Date): number { return date.getFullYear() * 12 + date.getMonth(); }
export function monthDays(month: Date): Date[] {
  const first = new Date(month.getFullYear(), month.getMonth(), 1);
  const offset = (first.getDay() + 6) % 7;
  return Array.from({ length: 42 }, (_, index) => new Date(first.getFullYear(), first.getMonth(), index + 1 - offset));
}
