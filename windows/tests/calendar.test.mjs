// The calendar pill's iCal reading (src/core/calendar.ts): time zones, all-day
// events, recurrence, moved and cancelled instances, and what the card shows.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  agenda, eventsBetween, findJoinLink, isAfterToday, minutesUntil, parseIcs, reminderAt, REMINDER_MS,
  upcomingWindow,
} from "../src/core/calendar.ts";

const HEL = "Europe/Helsinki";
const NYC = "America/New_York";
const iso = (ms) => new Date(ms).toISOString();

function feed(...events) {
  return ["BEGIN:VCALENDAR", "VERSION:2.0", ...events.flatMap((e) => ["BEGIN:VEVENT", ...e, "END:VEVENT"]), "END:VCALENDAR"]
    .join("\r\n");
}

const between = (text, fromIso, toIso, tz = HEL) =>
  eventsBetween(parseIcs(text), Date.parse(fromIso), Date.parse(toIso), tz);

// ── Single events ─────────────────────────────────────────────────────────────

test("a TZID time is read in its own zone", () => {
  const ev = between(feed(["UID:a", "SUMMARY:Standup", "DTSTART;TZID=Europe/Helsinki:20261012T090000",
    "DTEND;TZID=Europe/Helsinki:20261012T093000"]), "2026-10-12T00:00:00Z", "2026-10-13T00:00:00Z");
  assert.equal(ev.length, 1);
  assert.equal(iso(ev[0].start), "2026-10-12T06:00:00.000Z");
  assert.equal(iso(ev[0].end), "2026-10-12T06:30:00.000Z");
  assert.equal(ev[0].title, "Standup");
  assert.equal(ev[0].allDay, false);
});

test("UTC, floating and DURATION times", () => {
  const text = feed(
    ["UID:z", "SUMMARY:UTC", "DTSTART:20261012T120000Z", "DURATION:PT1H30M"],
    ["UID:f", "SUMMARY:Floating", "DTSTART:20261012T120000", "DTEND:20261012T130000"],
  );
  const ev = between(text, "2026-10-12T00:00:00Z", "2026-10-13T00:00:00Z", NYC);
  const utc = ev.find((e) => e.uid === "z");
  const floating = ev.find((e) => e.uid === "f");
  assert.equal(iso(utc.start), "2026-10-12T12:00:00.000Z");
  assert.equal(iso(utc.end), "2026-10-12T13:30:00.000Z");
  // A floating time is the viewer's: noon in New York (EDT).
  assert.equal(iso(floating.start), "2026-10-12T16:00:00.000Z");
});

test("a mozilla-style TZID still finds its zone", () => {
  const ev = between(feed(["UID:m", "SUMMARY:x", "DTSTART;TZID=/mozilla.org/20070129_1/Europe/Helsinki:20261012T090000"]),
    "2026-10-12T00:00:00Z", "2026-10-13T00:00:00Z", NYC);
  assert.equal(iso(ev[0].start), "2026-10-12T06:00:00.000Z");
});

test("an all-day event covers the viewer's whole day, end exclusive", () => {
  const text = feed(["UID:d", "SUMMARY:Holiday", "DTSTART;VALUE=DATE:20261012", "DTEND;VALUE=DATE:20261014"]);
  const ev = between(text, "2026-10-11T00:00:00Z", "2026-10-16T00:00:00Z");
  assert.equal(ev.length, 1);
  assert.equal(ev[0].allDay, true);
  assert.equal(iso(ev[0].start), "2026-10-11T21:00:00.000Z"); // midnight in Helsinki (EEST)
  assert.equal(iso(ev[0].end), "2026-10-13T21:00:00.000Z");
  // Without DTEND it lasts one day.
  const one = between(feed(["UID:e", "SUMMARY:x", "DTSTART;VALUE=DATE:20261012"]), "2026-10-11T00:00:00Z", "2026-10-16T00:00:00Z");
  assert.equal(iso(one[0].end), "2026-10-12T21:00:00.000Z");
});

test("folded lines, escaped text, alarms and cancelled events", () => {
  const text = [
    "BEGIN:VCALENDAR",
    "BEGIN:VEVENT", "UID:fold", "SUMMARY:Planning\\, review\\; and", " more", "DTSTART:20261012T100000Z",
    "BEGIN:VALARM", "ACTION:DISPLAY", "SUMMARY:alarm text", "END:VALARM", "END:VEVENT",
    "BEGIN:VEVENT", "UID:gone", "SUMMARY:Cancelled", "STATUS:CANCELLED", "DTSTART:20261012T110000Z", "END:VEVENT",
    "END:VCALENDAR",
  ].join("\n");
  const ev = between(text, "2026-10-12T00:00:00Z", "2026-10-13T00:00:00Z");
  assert.deepEqual(ev.map((e) => e.title), ["Planning, review; andmore"]);
});

// ── Recurrence ────────────────────────────────────────────────────────────────

test("weekly on two days keeps its wall-clock time across a DST change", () => {
  const text = feed(["UID:w", "SUMMARY:Sync", "DTSTART;TZID=America/New_York:20261026T100000",
    "DTEND;TZID=America/New_York:20261026T103000", "RRULE:FREQ=WEEKLY;BYDAY=MO,WE"]);
  const ev = between(text, "2026-10-26T00:00:00Z", "2026-11-05T00:00:00Z", NYC);
  assert.deepEqual(ev.map((e) => iso(e.start)), [
    "2026-10-26T14:00:00.000Z", // EDT
    "2026-10-28T14:00:00.000Z",
    "2026-11-02T15:00:00.000Z", // EST after 1 November
    "2026-11-04T15:00:00.000Z",
  ]);
});

test("COUNT and UNTIL end a series; INTERVAL skips", () => {
  const counted = between(feed(["UID:c", "SUMMARY:x", "DTSTART:20261010T080000Z", "RRULE:FREQ=DAILY;COUNT=3"]),
    "2026-10-01T00:00:00Z", "2026-10-31T00:00:00Z");
  assert.deepEqual(counted.map((e) => iso(e.start).slice(0, 10)), ["2026-10-10", "2026-10-11", "2026-10-12"]);

  const until = between(feed(["UID:u", "SUMMARY:x", "DTSTART;VALUE=DATE:20261010", "RRULE:FREQ=DAILY;UNTIL=20261012"]),
    "2026-10-01T00:00:00Z", "2026-10-31T00:00:00Z", "UTC");
  assert.equal(until.length, 3);

  const everyOther = between(feed(["UID:i", "SUMMARY:x", "DTSTART:20261001T080000Z", "RRULE:FREQ=DAILY;INTERVAL=2"]),
    "2026-10-01T00:00:00Z", "2026-10-07T00:00:00Z");
  assert.deepEqual(everyOther.map((e) => iso(e.start).slice(8, 10)), ["01", "03", "05"]);
});

test("a series started years ago still lands on today", () => {
  const ev = between(feed(["UID:old", "SUMMARY:Weekly 1:1", "DTSTART;TZID=Europe/Helsinki:20190107T140000",
    "RRULE:FREQ=WEEKLY"]), "2026-10-12T00:00:00Z", "2026-10-13T00:00:00Z");
  assert.equal(ev.length, 1);
  assert.equal(iso(ev[0].start), "2026-10-12T11:00:00.000Z");
});

test("monthly by last weekday and by month day, yearly by month", () => {
  const lastFriday = between(feed(["UID:lf", "SUMMARY:x", "DTSTART:20260925T090000Z", "RRULE:FREQ=MONTHLY;BYDAY=-1FR"]),
    "2026-10-01T00:00:00Z", "2026-11-01T00:00:00Z", "UTC");
  assert.deepEqual(lastFriday.map((e) => iso(e.start).slice(0, 10)), ["2026-10-30"]);

  const secondTuesday = between(feed(["UID:st", "SUMMARY:x", "DTSTART:20260908T090000Z", "RRULE:FREQ=MONTHLY;BYDAY=2TU"]),
    "2026-10-01T00:00:00Z", "2026-11-01T00:00:00Z", "UTC");
  assert.deepEqual(secondTuesday.map((e) => iso(e.start).slice(0, 10)), ["2026-10-13"]);

  // The 31st only exists in some months.
  const thirtyFirst = between(feed(["UID:31", "SUMMARY:x", "DTSTART:20260831T090000Z", "RRULE:FREQ=MONTHLY"]),
    "2026-09-01T00:00:00Z", "2026-11-01T00:00:00Z", "UTC");
  assert.deepEqual(thirtyFirst.map((e) => iso(e.start).slice(0, 10)), ["2026-10-31"]);

  const birthday = between(feed(["UID:b", "SUMMARY:x", "DTSTART;VALUE=DATE:20101012", "RRULE:FREQ=YEARLY"]),
    "2026-10-01T00:00:00Z", "2026-11-01T00:00:00Z", "UTC");
  assert.deepEqual(birthday.map((e) => iso(e.start).slice(0, 10)), ["2026-10-12"]);
});

test("EXDATE removes an instance, RECURRENCE-ID moves or cancels one", () => {
  const text = feed(
    ["UID:s", "SUMMARY:Daily", "DTSTART;TZID=Europe/Helsinki:20261012T090000", "RRULE:FREQ=DAILY;COUNT=5",
      "EXDATE;TZID=Europe/Helsinki:20261013T090000"],
    ["UID:s", "SUMMARY:Daily (moved)", "RECURRENCE-ID;TZID=Europe/Helsinki:20261014T090000",
      "DTSTART;TZID=Europe/Helsinki:20261014T150000"],
    ["UID:s", "SUMMARY:Daily", "RECURRENCE-ID;TZID=Europe/Helsinki:20261015T090000", "STATUS:CANCELLED",
      "DTSTART;TZID=Europe/Helsinki:20261015T090000"],
  );
  const ev = between(text, "2026-10-12T00:00:00Z", "2026-10-20T00:00:00Z");
  assert.deepEqual(ev.map((e) => [iso(e.start), e.title]), [
    ["2026-10-12T06:00:00.000Z", "Daily"],
    ["2026-10-14T12:00:00.000Z", "Daily (moved)"],
    ["2026-10-16T06:00:00.000Z", "Daily"],
  ]);
});

test("a time skipped when clocks go forward moves forward", () => {
  // Helsinki jumps from 03:00 to 04:00 on 29 March 2026.
  const ev = between(feed(["UID:gap", "SUMMARY:x", "DTSTART;TZID=Europe/Helsinki:20260329T033000"]),
    "2026-03-28T00:00:00Z", "2026-03-30T00:00:00Z");
  assert.equal(iso(ev[0].start), "2026-03-29T01:30:00.000Z"); // 04:30 EEST
});

// ── Far from DTSTART ──────────────────────────────────────────────────────────

// A series that started long ago is not walked from its first day: the window is
// reached arithmetically. The expected rows are what the walk from DTSTART gave.
const FAR_CASES = [
  ["daily from 1900", "2026-10-12T12:00:00Z", HEL, feed(["UID:a", "SUMMARY:a", "DTSTART;TZID=Europe/Paris:19000101T090000", "DTEND;TZID=Europe/Paris:19000101T093000", "RRULE:FREQ=DAILY"])],
  ["weekly BYDAY interval 2 from 2015", "2026-10-12T12:00:00Z", HEL, feed(["UID:b", "SUMMARY:b", "DTSTART;TZID=Europe/Helsinki:20150105T100000", "DTEND;TZID=Europe/Helsinki:20150105T110000", "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TU,FR"])],
  ["weekly BYDAY interval 2 other phase", "2026-10-19T12:00:00Z", HEL, feed(["UID:b2", "SUMMARY:b", "DTSTART;TZID=Europe/Helsinki:20150105T100000", "DTEND;TZID=Europe/Helsinki:20150105T110000", "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TU,FR;WKST=SU"])],
  ["monthly 2nd Monday from 2010", "2026-10-12T05:00:00Z", HEL, feed(["UID:c", "SUMMARY:c", "DTSTART;TZID=America/New_York:20100111T080000", "DTEND;TZID=America/New_York:20100111T090000", "RRULE:FREQ=MONTHLY;BYDAY=2MO"])],
  ["monthly last day interval 5", "2026-07-31T05:00:00Z", HEL, feed(["UID:c2", "SUMMARY:c", "DTSTART:19990131T080000Z", "DURATION:PT1H", "RRULE:FREQ=MONTHLY;INTERVAL=5;BYMONTHDAY=-1"])],
  ["yearly BYMONTH BYMONTHDAY from 1990", "2026-10-12T05:00:00Z", HEL, feed(["UID:d", "SUMMARY:d", "DTSTART;VALUE=DATE:19901012", "RRULE:FREQ=YEARLY;BYMONTH=10;BYMONTHDAY=12,13"])],
  ["yearly interval 4 Feb 29", "2028-02-29T05:00:00Z", HEL, feed(["UID:d2", "SUMMARY:d", "DTSTART;TZID=Europe/Helsinki:19960229T120000", "DTEND;TZID=Europe/Helsinki:19960229T130000", "RRULE:FREQ=YEARLY;INTERVAL=4"])],
  ["daily COUNT ends today", "2026-10-12T12:00:00Z", HEL, feed(["UID:e", "SUMMARY:e", "DTSTART;TZID=Europe/Helsinki:20150101T090000", "DTEND;TZID=Europe/Helsinki:20150101T091500", "RRULE:FREQ=DAILY;COUNT=4303"])],
  ["daily COUNT reaches past window", "2026-10-12T12:00:00Z", HEL, feed(["UID:e2", "SUMMARY:e", "DTSTART;TZID=Europe/Helsinki:20150101T090000", "DTEND;TZID=Europe/Helsinki:20150101T091500", "RRULE:FREQ=DAILY;COUNT=5000"])],
  ["daily UNTIL today", "2026-10-12T12:00:00Z", HEL, feed(["UID:f", "SUMMARY:f", "DTSTART;TZID=Europe/Helsinki:20000101T090000", "DTEND;TZID=Europe/Helsinki:20000101T091500", "RRULE:FREQ=DAILY;UNTIL=20261012T235959Z"])],
  ["daily UNTIL long gone", "2026-10-12T12:00:00Z", HEL, feed(["UID:f2", "SUMMARY:f", "DTSTART;TZID=Europe/Helsinki:20000101T090000", "DTEND;TZID=Europe/Helsinki:20000101T091500", "RRULE:FREQ=DAILY;UNTIL=20100101"])],
  ["daily interval 3 from 1950", "2026-10-12T12:00:00Z", HEL, feed(["UID:g", "SUMMARY:g", "DTSTART;TZID=Europe/Helsinki:19500101T070000", "DTEND;TZID=Europe/Helsinki:19500101T080000", "RRULE:FREQ=DAILY;INTERVAL=3"])],
  ["DST end in Helsinki, repeated hour", "2026-10-25T12:00:00Z", HEL, feed(["UID:h", "SUMMARY:h", "DTSTART;TZID=Europe/Helsinki:19800101T033000", "DTEND;TZID=Europe/Helsinki:19800101T040000", "RRULE:FREQ=DAILY"])],
  ["DST start in New York, skipped hour", "2027-03-14T12:00:00Z", "America/New_York", feed(["UID:h2", "SUMMARY:h", "DTSTART;TZID=America/New_York:19900101T023000", "DTEND;TZID=America/New_York:19900101T030000", "RRULE:FREQ=DAILY"])],
  ["EXDATE and moved instance", "2026-10-12T12:00:00Z", HEL, feed(
    ["UID:i", "SUMMARY:i", "DTSTART;TZID=Europe/Helsinki:20000103T090000", "DTEND;TZID=Europe/Helsinki:20000103T100000", "RRULE:FREQ=DAILY", "EXDATE;TZID=Europe/Helsinki:20261012T090000"],
    ["UID:i", "SUMMARY:i moved", "RECURRENCE-ID;TZID=Europe/Helsinki:20261013T090000", "DTSTART;TZID=Europe/Helsinki:20261013T150000", "DTEND;TZID=Europe/Helsinki:20261013T160000"])],
  ["weekly started in the window", "2026-10-12T12:00:00Z", HEL, feed(["UID:j", "SUMMARY:j", "DTSTART;TZID=Europe/Helsinki:20261013T090000", "DTEND;TZID=Europe/Helsinki:20261013T100000", "RRULE:FREQ=WEEKLY"])],
  ["multi-day all-day yearly", "2026-12-25T12:00:00Z", HEL, feed(["UID:k", "SUMMARY:k", "DTSTART;VALUE=DATE:19801224", "DTEND;VALUE=DATE:19801227", "RRULE:FREQ=YEARLY"])],
];

const FAR_EXPECTED = {
  "daily from 1900": [
    "a|2026-10-12T07:00:00.000Z|2026-10-12T07:30:00.000Z",
    "a|2026-10-13T07:00:00.000Z|2026-10-13T07:30:00.000Z"
  ],
  "weekly BYDAY interval 2 from 2015": [
    "b|2026-10-12T07:00:00.000Z|2026-10-12T08:00:00.000Z",
    "b|2026-10-13T07:00:00.000Z|2026-10-13T08:00:00.000Z"
  ],
  "weekly BYDAY interval 2 other phase": [],
  "monthly 2nd Monday from 2010": [
    "c|2026-10-12T12:00:00.000Z|2026-10-12T13:00:00.000Z"
  ],
  "monthly last day interval 5": [
    "c|2026-07-31T08:00:00.000Z|2026-07-31T09:00:00.000Z"
  ],
  "yearly BYMONTH BYMONTHDAY from 1990": [
    "d|2026-10-11T21:00:00.000Z|2026-10-12T21:00:00.000Z",
    "d|2026-10-12T21:00:00.000Z|2026-10-13T21:00:00.000Z"
  ],
  "yearly interval 4 Feb 29": [
    "d|2028-02-29T10:00:00.000Z|2028-02-29T11:00:00.000Z"
  ],
  "daily COUNT ends today": [
    "e|2026-10-12T06:00:00.000Z|2026-10-12T06:15:00.000Z"
  ],
  "daily COUNT reaches past window": [
    "e|2026-10-12T06:00:00.000Z|2026-10-12T06:15:00.000Z",
    "e|2026-10-13T06:00:00.000Z|2026-10-13T06:15:00.000Z"
  ],
  "daily UNTIL today": [
    "f|2026-10-12T06:00:00.000Z|2026-10-12T06:15:00.000Z"
  ],
  "daily UNTIL long gone": [],
  "daily interval 3 from 1950": [
    "g|2026-10-13T04:00:00.000Z|2026-10-13T05:00:00.000Z"
  ],
  "DST end in Helsinki, repeated hour": [
    "h|2026-10-25T00:30:00.000Z|2026-10-25T01:00:00.000Z",
    "h|2026-10-26T01:30:00.000Z|2026-10-26T02:00:00.000Z"
  ],
  "DST start in New York, skipped hour": [
    "h|2027-03-14T07:30:00.000Z|2027-03-14T08:00:00.000Z",
    "h|2027-03-15T06:30:00.000Z|2027-03-15T07:00:00.000Z"
  ],
  "EXDATE and moved instance": [
    "i moved|2026-10-13T12:00:00.000Z|2026-10-13T13:00:00.000Z"
  ],
  "weekly started in the window": [
    "j|2026-10-13T06:00:00.000Z|2026-10-13T07:00:00.000Z"
  ],
  "multi-day all-day yearly": [
    "k|2026-12-23T22:00:00.000Z|2026-12-26T22:00:00.000Z"
  ]
};

for (const [name, now, tz, text] of FAR_CASES) {
  test(`far from DTSTART: ${name}`, () => {
    const w = upcomingWindow(Date.parse(now), tz);
    const ev = eventsBetween(parseIcs(text), w.from, w.to, tz);
    assert.deepEqual(ev.map((e) => `${e.title}|${iso(e.start)}|${iso(e.end)}`), FAR_EXPECTED[name]);
  });
}

const timed = (fn) => {
  const t0 = performance.now();
  const value = fn();
  return { value, ms: performance.now() - t0 };
};

test("a rule built to expand forever stays fast", () => {
  const w = upcomingWindow(Date.parse("2026-10-12T12:00:00Z"), HEL);
  const rules = [
    "FREQ=DAILY",
    "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR,SA,SU",
    "FREQ=YEARLY;BYMONTH=1,2,3,4,5,6,7,8,9,10,11,12;BYDAY=MO,TU,WE,TH,FR,SA,SU",
    "FREQ=YEARLY;BYMONTH=1,2,3,4,5,6,7,8,9,10,11,12;BYDAY=MO,TU,WE,TH,FR,SA,SU;COUNT=100000000",
  ];
  for (const rule of rules) {
    const text = feed(["UID:x", "SUMMARY:x", "DTSTART;TZID=Europe/Paris:01000101T090000", "DTEND;TZID=Europe/Paris:01000101T093000",
      `RRULE:${rule}`]);
    const { value, ms } = timed(() => eventsBetween(parseIcs(text), w.from, w.to, HEL));
    assert.ok(ms < 100, `${rule}: ${ms.toFixed(0)} ms`);
    if (!rule.includes("COUNT")) assert.equal(value.length, 2, rule);
  }
});

test("a feed full of such rules stays fast", () => {
  const w = upcomingWindow(Date.parse("2026-10-12T12:00:00Z"), HEL);
  const many = Array.from({ length: 50 }, (_, i) => ["UID:x" + i, "SUMMARY:x", "DTSTART;TZID=Europe/Paris:01000101T090000",
    "RRULE:FREQ=YEARLY;BYMONTH=1,2,3,4,5,6,7,8,9,10,11,12;BYDAY=MO,TU,WE,TH,FR,SA,SU;COUNT=100000000"]);
  const { ms } = timed(() => eventsBetween(parseIcs(feed(...many)), w.from, w.to, HEL));
  assert.ok(ms < 500, `${ms.toFixed(0)} ms`);
});

// ── Join links ────────────────────────────────────────────────────────────────

test("a Meet, Zoom or Teams link is found where calendars put it", () => {
  assert.equal(findJoinLink("Room 4", "Join: https://meet.google.com/abc-defg-hij."), "https://meet.google.com/abc-defg-hij");
  assert.equal(findJoinLink("https://acme.zoom.us/j/123456789?pwd=xyz)"), "https://acme.zoom.us/j/123456789?pwd=xyz");
  assert.equal(
    findJoinLink("<https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d>"),
    "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d",
  );
  assert.equal(findJoinLink("https://example.com/agenda", undefined), null);

  const ev = between(feed(["UID:j", "SUMMARY:x", "DTSTART:20261012T100000Z",
    "DESCRIPTION:Notes\\nhttps://us02web.zoom.us/j/111", "X-GOOGLE-CONFERENCE:https://meet.google.com/aaa-bbbb-ccc"]),
    "2026-10-12T00:00:00Z", "2026-10-13T00:00:00Z");
  assert.equal(ev[0].joinUrl, "https://meet.google.com/aaa-bbbb-ccc");
});

test("a link made of punctuation does not stall, and an endless link is ignored", () => {
  const dots = "https://zoom.us/j/" + ".".repeat(40_000) + "x";
  const { value, ms } = timed(() => findJoinLink(dots));
  assert.ok(ms < 50, `${ms.toFixed(0)} ms`);
  assert.equal(value, null);
  const trailing = timed(() => findJoinLink("https://zoom.us/j/123" + ").,;".repeat(10_000)));
  assert.ok(trailing.ms < 50, `${trailing.ms.toFixed(0)} ms`);
  assert.equal(trailing.value, "https://zoom.us/j/123");
  assert.equal(findJoinLink("https://acme.zoom.us/j/" + "1".repeat(3000), "https://meet.google.com/abc-defg-hij"),
    "https://meet.google.com/abc-defg-hij");
});

// ── The card and the reminder ─────────────────────────────────────────────────

const at = (h, m = 0) => Date.UTC(2026, 9, 12, h - 3, m); // Helsinki wall time on 12 October (UTC+3)
const event = (uid, startH, endH, allDay = false) => ({
  uid, title: uid, start: allDay ? Date.UTC(2026, 9, 11, 21) : at(startH), end: allDay ? Date.UTC(2026, 9, 12, 21) : at(endH),
  allDay, joinUrl: null,
});

test("the next meeting is the one on now, then the rest of today", () => {
  const events = [event("holiday", 0, 0, true), event("past", 8, 9), event("now", 10, 11), event("later", 14, 15),
    event("tomorrow", 33, 34)];
  const a = agenda(events, at(10, 15), HEL);
  assert.equal(a.next.uid, "now");
  assert.deepEqual(a.later.map((e) => e.uid), ["later"]);
  assert.deepEqual(a.allDay.map((e) => e.uid), ["holiday"]);
  assert.equal(minutesUntil(a.next, at(10, 15)), 0);
});

test("with nothing left today the next meeting is tomorrow's", () => {
  const events = [event("past", 8, 9), event("tomorrow", 33, 34), event("day after", 57, 58)];
  const a = agenda(events, at(20), HEL);
  assert.equal(a.next.uid, "tomorrow");
  assert.equal(isAfterToday(a.next, at(20), HEL), true);
  assert.deepEqual(a.later, []);
  assert.equal(agenda([event("day after", 57, 58)], at(20), HEL).next, null);
});

test("the reminder fires five minutes before, at once inside them, never after the start", () => {
  const meeting = event("m", 14, 15);
  assert.equal(reminderAt(meeting, at(9)), meeting.start - REMINDER_MS);
  assert.equal(reminderAt(meeting, at(13, 58)), at(13, 58));
  assert.equal(reminderAt(meeting, at(14)), null);
  assert.equal(reminderAt(null, at(9)), null);
  assert.equal(minutesUntil(meeting, at(13, 1)), 59);
});

test("the window is today and tomorrow in the viewer's zone", () => {
  const w = upcomingWindow(at(10), HEL);
  assert.equal(iso(w.from), "2026-10-11T21:00:00.000Z");
  assert.equal(iso(w.to), "2026-10-13T21:00:00.000Z");
});
