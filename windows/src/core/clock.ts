// The island's clock text (Settings → General): what it shows next to the
// time, and a 12- or 24-hour clock. The closed island's time follows the same
// hours. No DOM here.

/** "auto" follows the interface's language. */
export type ClockHours = "auto" | "24" | "12";
export type ClockDate = "date" | "weekday" | "none";

const HOURS: readonly ClockHours[] = ["auto", "24", "12"];
const DATES: readonly ClockDate[] = ["date", "weekday", "none"];

/** A value this build doesn't know (written by a newer one) reads as the default. */
export function clockHours(value: unknown): ClockHours {
  return HOURS.includes(value as ClockHours) ? (value as ClockHours) : "auto";
}

export function clockDate(value: unknown): ClockDate {
  return DATES.includes(value as ClockDate) ? (value as ClockDate) : "date";
}

export function timeText(now: Date, hours: ClockHours, locale?: string): string {
  switch (hours) {
    case "24":
      return now.toLocaleTimeString(locale, { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
    case "12":
      return now.toLocaleTimeString(locale, { hour: "numeric", minute: "2-digit", hourCycle: "h12" });
    case "auto":
      return now.toLocaleTimeString(locale, { hour: "2-digit", minute: "2-digit" });
  }
}

export function clockText(now: Date, date: ClockDate, hours: ClockHours, locale?: string): string {
  const time = timeText(now, hours, locale);
  switch (date) {
    case "none":
      return time;
    case "weekday":
      return `${now.toLocaleDateString(locale, { weekday: "short" })}  ${time}`;
    case "date":
      return `${now.toLocaleDateString(locale, { weekday: "short", day: "numeric", month: "short" })}  ${time}`;
  }
}
