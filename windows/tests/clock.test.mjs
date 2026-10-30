// The date and time in the compact bar (src/island/clock.ts): Windows'
// patterns, the locale fallback, the text, the minute timing and whether every
// language's date fits the box.

import { test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";

installFakeDom();

const { LANGUAGE_CODES, setLanguage } = await import("../src/i18n/i18n.ts");
const {
  clockText, estimateWidth, msToNextMinute, parseDatePattern, parseTimePattern, resolveFormat,
} = await import("../src/island/clock.ts");
const { CLOCK_BOX_W } = await import("../src/core/layout.ts");

/** Runs `fn` in `lang`, then puts English back for the other tests. */
function inLanguage(lang, fn) {
  setLanguage(lang);
  try {
    fn();
  } finally {
    setLanguage("en");
  }
}

/** Intl puts a narrow no break space before AM or PM; it looks like a space. */
const plain = (s) => s.replace(/[  ]/g, " ");

// Saturday 10 October 2026, 14:05 and 09:05.
const AFTERNOON = new Date(2026, 9, 10, 14, 5);
const MORNING = new Date(2026, 9, 10, 9, 5);

// ── Windows' patterns ─────────────────────────────────────────────────────────

test("a Windows short time pattern gives the hour cycle and the leading zero", () => {
  assert.deepEqual(parseTimePattern("h:mm tt"), { hour12: true, hourPad: false });
  assert.deepEqual(parseTimePattern("hh:mm tt"), { hour12: true, hourPad: true });
  assert.deepEqual(parseTimePattern("HH:mm"), { hour12: false, hourPad: true });
  assert.deepEqual(parseTimePattern("H.mm"), { hour12: false, hourPad: false });
  // The AM or PM text can come first (Korean, Chinese): still a 12 hour clock.
  assert.deepEqual(parseTimePattern("tt h:mm"), { hour12: true, hourPad: false });
  // K is a 12 hour clock counted from 0, k a 24 hour one counted from 1.
  assert.equal(parseTimePattern("K:mm tt")?.hour12, true);
  assert.equal(parseTimePattern("k:mm")?.hour12, false);
});

test("quoted text in a time pattern is skipped, and no hour means no answer", () => {
  assert.deepEqual(parseTimePattern("H 'h' mm"), { hour12: false, hourPad: false });
  assert.equal(parseTimePattern("'hours' mm"), null);
  assert.equal(parseTimePattern(""), null);
  assert.equal(parseTimePattern(null), null);
});

test("a Windows short date pattern says whether the day comes first", () => {
  assert.equal(parseDatePattern("dd-MM-yyyy")?.dayFirst, true);
  assert.equal(parseDatePattern("dd.MM.yyyy")?.dayFirst, true);
  assert.equal(parseDatePattern("d/M/yyyy")?.dayFirst, true);
  assert.equal(parseDatePattern("M/d/yyyy")?.dayFirst, false);
  assert.equal(parseDatePattern("yyyy-MM-dd")?.dayFirst, false);
  // A weekday (ddd, dddd) is not the day.
  assert.equal(parseDatePattern("ddd, MMM d")?.dayFirst, false);
  assert.equal(parseDatePattern(null), null);
  assert.equal(parseDatePattern("yyyy"), null);
});

test("the locale fills in what Windows does not say", () => {
  const us = resolveFormat(null, "en-US");
  assert.deepEqual(us, { hour12: true, hourPad: false, dayFirst: false });
  const gb = resolveFormat(null, "en-GB");
  assert.equal(gb.hour12, false);
  assert.equal(gb.dayFirst, true);
  // Windows wins where it speaks, the locale where it does not.
  assert.deepEqual(resolveFormat({ time: "HH:mm", date: null }, "en-US"), { hour12: false, hourPad: true, dayFirst: false });
  assert.deepEqual(resolveFormat({ time: null, date: "dd-MM-yyyy" }, "en-US"), { hour12: true, hourPad: false, dayFirst: true });
});

// ── The text ──────────────────────────────────────────────────────────────────

test("12 hour time and a day first date, as in India or the UK", () => {
  const fmt = { hour12: true, hourPad: false, dayFirst: true };
  const t = clockText(AFTERNOON, fmt, "en-US");
  assert.equal(plain(t.time), "2:05 PM");
  assert.equal(t.date, "Sat, 10 Oct");
});

test("a month first date, as in the US", () => {
  const fmt = { hour12: true, hourPad: false, dayFirst: false };
  assert.equal(clockText(AFTERNOON, fmt, "en-US").date, "Sat, Oct 10");
});

test("the hour is padded or not as the format says, on either clock", () => {
  const f = (hour12, hourPad) => plain(clockText(MORNING, { hour12, hourPad, dayFirst: true }, "en-US").time);
  assert.equal(f(true, false), "9:05 AM");
  assert.equal(f(true, true), "09:05 AM");
  assert.equal(f(false, true), "09:05");
  assert.equal(f(false, false), "9:05");
  assert.equal(clockText(AFTERNOON, { hour12: false, hourPad: true, dayFirst: true }, "en-US").time, "14:05");
});

test("midnight and noon read right on both clocks", () => {
  const midnight = new Date(2026, 9, 11, 0, 7);
  assert.equal(plain(clockText(midnight, { hour12: true, hourPad: false, dayFirst: true }, "en-US").time), "12:07 AM");
  assert.equal(clockText(midnight, { hour12: false, hourPad: true, dayFirst: true }, "en-US").time, "00:07");
});

test("the date follows the language picked in Coucou", () => {
  const fmt = { hour12: false, hourPad: true, dayFirst: true };
  inLanguage("fr", () => assert.match(clockText(AFTERNOON, fmt, "en-US").date, /^sam\.?, 10 oct/i));
  // Where the month is already a number with its own mark, the language's own form is used.
  inLanguage("zh-Hans", () => assert.equal(clockText(AFTERNOON, fmt, "en-US").date.endsWith("10月10日"), true));
});

test("the whole thing is spelled out for assistive tools", () => {
  const t = clockText(AFTERNOON, { hour12: true, hourPad: false, dayFirst: true }, "en-US");
  assert.equal(plain(t.label), "Saturday, October 10, 2026, 2:05 PM");
});

// ── The minute timer ──────────────────────────────────────────────────────────

test("the timer is aimed just past the next minute, whatever the second", () => {
  const minute = 60_000 * 29_000_000;
  assert.equal(msToNextMinute(minute), 60_050); // exactly on a minute: wait a whole one
  assert.equal(msToNextMinute(minute + 59_999), 51); // the last millisecond: almost there
  assert.equal(msToNextMinute(minute + 30_000), 30_050);
  for (let ms = 0; ms < 60_000; ms += 997) {
    const wait = msToNextMinute(minute + ms);
    assert.ok(wait >= 51 && wait <= 60_050, `${ms}: ${wait}`);
    // Landing on the minute and not before it.
    assert.ok((minute + ms + wait) % 60_000 >= 50, `${ms}: wakes before the minute turns`);
  }
});

// ── Every language fits ───────────────────────────────────────────────────────

test("the date without its weekday fits the clock's box in every language", () => {
  // The island shows it when the full line, weekday first, overflows the box.
  const tooWide = [];
  for (const lang of LANGUAGE_CODES) {
    inLanguage(lang, () => {
      for (const dayFirst of [true, false]) {
        const fmt = { hour12: true, hourPad: false, dayFirst };
        // Every day of 2026 covers each weekday with each month and the longest day numbers.
        for (let d = new Date(2026, 0, 1); d.getFullYear() === 2026; d.setDate(d.getDate() + 1)) {
          const { dateShort: date } = clockText(d, fmt, "en-US");
          const width = estimateWidth(date, 9);
          if (width > CLOCK_BOX_W) tooWide.push(`${lang} ${dayFirst ? "day first" : "month first"}: "${date}" ${width.toFixed(0)} px`);
        }
      }
    });
  }
  assert.deepEqual([...new Set(tooWide)].slice(0, 12), []);
});

test("the full date, weekday first, still fits in the languages with short weekday names", () => {
  const tooWide = [];
  for (const lang of LANGUAGE_CODES.filter((l) => l !== "ar" && l !== "bn")) {
    inLanguage(lang, () => {
      const fmt = { hour12: true, hourPad: false, dayFirst: true };
      for (let d = new Date(2026, 0, 1); d.getFullYear() === 2026; d.setDate(d.getDate() + 1)) {
        const { date } = clockText(d, fmt, "en-US");
        if (estimateWidth(date, 9) > CLOCK_BOX_W) tooWide.push(`${lang}: "${date}"`);
      }
    });
  }
  assert.deepEqual([...new Set(tooWide)].slice(0, 8), []);
});

test("the time fits the clock's box, in the locales Coucou's languages are used in", () => {
  const tooWide = [];
  for (const locale of ["en-US", "en-IN", "fr-FR", "es-ES", "pt-BR", "ru-RU", "id-ID", "zh-CN", "hi-IN", "ar-EG", "bn-BD"]) {
    for (const fmt of [{ hour12: true, hourPad: true }, { hour12: false, hourPad: true }]) {
      for (const at of [new Date(2026, 0, 1, 12, 59), new Date(2026, 0, 1, 23, 59), new Date(2026, 0, 1, 0, 0)]) {
        const { time } = clockText(at, { ...fmt, dayFirst: true }, locale);
        const width = estimateWidth(time, 11);
        if (width > CLOCK_BOX_W) tooWide.push(`${locale} ${fmt.hour12 ? "12h" : "24h"}: "${time}" ${width.toFixed(0)} px`);
      }
    }
  }
  assert.deepEqual([...new Set(tooWide)], []);
});
