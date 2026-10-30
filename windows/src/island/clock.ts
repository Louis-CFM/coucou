// The date and time in the compact bar. Everything here is pure: the
// island draws what it returns, and tests drive it without a browser.
//
// Three things come from Windows' own short time and short date patterns (read
// by Rust, platform::regional_format): 12 or 24 hour, a leading zero on the
// hour, and whether the day comes before the month. The separator, the AM or PM
// text and the digits come from Intl, the weekday and month names from the
// language picked in Coucou (i18n.ts).

import { dayMonth, monthShort, weekdayShort } from "../i18n/i18n";

/** What Rust reports: Windows' short time and short date patterns, or null. */
export interface RegionalFormat {
  time: string | null;
  date: string | null;
}

export interface ClockFormat {
  /** 12 hour clock (with AM or PM) rather than 24 hour. */
  hour12: boolean;
  /** The hour has a leading zero ("09:05", not "9:05"). */
  hourPad: boolean;
  /** The day comes before the month ("10 Oct", not "Oct 10"). */
  dayFirst: boolean;
}

export interface ClockText {
  time: string;
  date: string;
  /**
   * The date without the weekday, for a language whose full line does not fit the
   * clock's box (Arabic and Bengali have no short weekday names): showing the
   * month whole beats cutting it off with an ellipsis.
   */
  dateShort: string;
  /** The whole thing in words, for assistive tools. */
  label: string;
}

/** Windows quotes literal text in a pattern: 'at' in "h 'at' mm". */
const withoutQuotes = (pattern: string) => pattern.replace(/'[^']*'/g, "");

/**
 * 12 or 24 hour and the leading zero, from a Windows short time pattern such as
 * "h:mm tt", "HH:mm" or "tt h:mm". Null when it holds no hour at all.
 */
export function parseTimePattern(pattern: string | null | undefined): { hour12: boolean; hourPad: boolean } | null {
  if (!pattern) return null;
  const hour = /[HhKk]+/.exec(withoutQuotes(pattern));
  if (!hour) return null;
  // H and k are 24 hour clocks, h and K are 12 hour ones.
  return { hour12: hour[0][0] === "h" || hour[0][0] === "K", hourPad: hour[0].length >= 2 };
}

/**
 * Whether the day comes before the month, from a Windows short date pattern such
 * as "dd-MM-yyyy" or "M/d/yyyy". Weekday letters (ddd, dddd) are not the day.
 */
export function parseDatePattern(pattern: string | null | undefined): { dayFirst: boolean } | null {
  if (!pattern) return null;
  const text = withoutQuotes(pattern);
  const day = /(?<!d)d{1,2}(?!d)/.exec(text);
  const month = /M+/.exec(text);
  if (!day || !month) return null;
  return { dayFirst: day.index < month.index };
}

/** What the web view's locale says, for where Windows says nothing. */
function localeFormat(locale: string): ClockFormat {
  // Nine in the morning shows whether this locale pads the hour, and which cycle.
  const nine = new Date(2024, 0, 15, 9, 5);
  const hourPart = new Intl.DateTimeFormat(locale, { hour: "numeric" }).formatToParts(nine).find((p) => p.type === "hour");
  const cycle = new Intl.DateTimeFormat(locale, { hour: "numeric" }).resolvedOptions().hourCycle;
  const parts = new Intl.DateTimeFormat(locale, { day: "numeric", month: "short" }).formatToParts(nine);
  return {
    hour12: cycle === "h11" || cycle === "h12",
    hourPad: (hourPart?.value.length ?? 1) >= 2,
    dayFirst: parts.findIndex((p) => p.type === "day") < parts.findIndex((p) => p.type === "month"),
  };
}

/** Windows' patterns first, the locale for whatever they do not say. */
export function resolveFormat(regional: RegionalFormat | null | undefined, locale: string): ClockFormat {
  const base = localeFormat(locale);
  const time = parseTimePattern(regional?.time);
  const date = parseDatePattern(regional?.date);
  return {
    hour12: time?.hour12 ?? base.hour12,
    hourPad: time?.hourPad ?? base.hourPad,
    dayFirst: date?.dayFirst ?? base.dayFirst,
  };
}

/** "2:05 PM" or "14:05", with the hour padded or not as the format says. */
function timeText(date: Date, fmt: ClockFormat, locale: string): string {
  const parts = new Intl.DateTimeFormat(locale, {
    hour: "numeric",
    minute: "2-digit",
    hourCycle: fmt.hour12 ? "h12" : "h23",
  }).formatToParts(date);
  return parts
    .map((p) => {
      // Intl pads a 24 hour clock whatever it is asked for; the format decides.
      if (p.type === "hour" && /^\d+$/.test(p.value)) return fmt.hourPad ? p.value.padStart(2, "0") : String(Number(p.value));
      return p.value;
    })
    .join("");
}

/** "10 Oct" or "Oct 10": the day and month, names in the Coucou language, order from Windows. */
function dayAndMonthText(date: Date, fmt: ClockFormat): string {
  const month = date.getMonth();
  const day = date.getDate();
  const name = monthShort(month);
  // Where the month is already a number with its own mark (10月), putting the day
  // next to it reads wrong: the language's own day and month form is used instead.
  return /\d/.test(name) ? dayMonth(month, day) : fmt.dayFirst ? `${day} ${name}` : `${name} ${day}`;
}

export function clockText(date: Date, fmt: ClockFormat, locale: string): ClockText {
  const time = timeText(date, fmt, locale);
  const dateShort = dayAndMonthText(date, fmt);
  const day = `${weekdayShort(date.getDay())}, ${dateShort}`;
  const long = new Intl.DateTimeFormat(locale, { weekday: "long", day: "numeric", month: "long", year: "numeric" }).format(date);
  return { time, date: day, dateShort, label: `${long}, ${time}` };
}

/** Milliseconds until the next minute turns, plus a little so the clock has moved on. */
export function msToNextMinute(nowMs: number): number {
  return 60_000 - (nowMs % 60_000) + 50;
}

/**
 * A rough width in pixels for a line of text at a font size, from a per character
 * table: a CJK character is a full em, a mark that sits on a letter nothing, a space
 * or a mark of punctuation about 0.3 em, anything else about 0.55 em. Enough to
 * catch a language that cannot fit the clock's box; the real app is the last word.
 */
export function estimateWidth(text: string, fontPx: number): number {
  let em = 0;
  for (const ch of text) {
    if (/\p{M}/u.test(ch)) continue; // a vowel sign or joiner sits on a letter, it adds no width
    if (/[\u1100-\u11ff\u2e80-\u9fff\uac00-\ud7af\uff00-\uffef]/.test(ch)) em += 1;
    else if (/[\s,.:;\u00b7\u060c]/.test(ch)) em += 0.3;
    else em += 0.55;
  }
  return em * fontPx;
}
