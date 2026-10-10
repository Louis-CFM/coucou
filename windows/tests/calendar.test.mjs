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
