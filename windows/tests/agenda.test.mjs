// The Agenda pill's data (src/core/agenda.ts): the day grouping and the marks.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  CALENDAR_COLORS, MAX_CALENDARS, groupByDay, isCalendarLink, linkKey, newCalendarId, nextColor, readAgenda,
  safeJoinUrl, SOON_MS,
} from "../src/core/agenda.ts";

/** A local date and time, as Unix seconds. */
const at = (y, mo, d, h = 0, mi = 0) => Math.floor(new Date(y, mo - 1, d, h, mi).getTime() / 1000);
/** Monday 2026-01-05, 10:00 local. */
const NOW = new Date(2026, 0, 5, 10, 0);

function event(title, start, end, extra = {}) {
  return {
    id: title, title, start, end, allDay: false, startDay: null, endDay: null, location: null,
    joinUrl: null, source: "work1234", calendar: "Work", color: "#7B83EB", busy: true, conflict: false, ...extra,
  };
}

function allDay(title, startDay, endDay) {
  return event(title, 0, 0, { allDay: true, startDay, endDay });
}

test("events are grouped by local day, in order, all-day ones first", () => {
  const groups = groupByDay(
    [
      event("lunch", at(2026, 1, 5, 12), at(2026, 1, 5, 13)),
      event("tomorrow", at(2026, 1, 6, 9), at(2026, 1, 6, 10)),
      allDay("holiday", "2026-01-05", "2026-01-06"),
      event("standup", at(2026, 1, 5, 11), at(2026, 1, 5, 11, 15)),
    ],
    NOW,
  );
  assert.deepEqual(groups.map((g) => g.key), ["2026-01-05", "2026-01-06"]);
  assert.deepEqual(groups[0].rows.map((r) => r.event.title), ["holiday", "standup", "lunch"]);
});

test("what already ended today is left out, what is running is kept", () => {
  const groups = groupByDay(
    [
      event("done", at(2026, 1, 5, 8), at(2026, 1, 5, 9)),
      event("running", at(2026, 1, 5, 9, 30), at(2026, 1, 5, 10, 30)),
    ],
    NOW,
  );
  assert.deepEqual(groups[0].rows.map((r) => r.event.title), ["running"]);
});

test("a running event is marked active and the first one within the hour upcoming", () => {
  const [today] = groupByDay(
    [
      event("running", at(2026, 1, 5, 9, 30), at(2026, 1, 5, 10, 30)),
      event("next", at(2026, 1, 5, 10, 40), at(2026, 1, 5, 11)),
      event("after", at(2026, 1, 5, 10, 50), at(2026, 1, 5, 11, 30)),
      event("later", at(2026, 1, 5, 15), at(2026, 1, 5, 16)),
    ],
    NOW,
  );
  const marks = Object.fromEntries(today.rows.map((r) => [r.event.title, r.mark]));
  assert.deepEqual(marks, { running: "active", next: "upcoming", after: "later", later: "later" });
});

test("nothing is upcoming when the next event is more than an hour away", () => {
  const [today] = groupByDay([event("far", NOW.getTime() / 1000 + SOON_MS / 1000 + 60, NOW.getTime() / 1000 + 7200)], NOW);
  assert.equal(today.rows[0].mark, "later");
});

test("a multi-day all-day event shows on each day it covers, inside the window", () => {
  const groups = groupByDay([allDay("trip", "2026-01-04", "2026-01-08")], NOW);
  // The 4th is before today; the 5th, 6th and 7th remain.
  assert.deepEqual(groups.map((g) => g.key), ["2026-01-05", "2026-01-06", "2026-01-07"]);
});

test("only seven days are shown", () => {
  const groups = groupByDay(
    [
      event("day 7", at(2026, 1, 11, 9), at(2026, 1, 11, 10)),
      event("day 8", at(2026, 1, 12, 9), at(2026, 1, 12, 10)),
    ],
    NOW,
  );
  assert.deepEqual(groups.map((g) => g.key), ["2026-01-11"]);
});

test("a day with nothing is left out, and an empty list gives no groups", () => {
  assert.deepEqual(groupByDay([], NOW), []);
  const groups = groupByDay([event("later", at(2026, 1, 8, 9), at(2026, 1, 8, 10))], NOW);
  assert.deepEqual(groups.map((g) => g.key), ["2026-01-08"]);
});

test("only an https link is handed to the browser", () => {
  assert.equal(safeJoinUrl(event("a", 0, 0, { joinUrl: "https://teams.microsoft.com/l/meetup-join/x" })), "https://teams.microsoft.com/l/meetup-join/x");
  assert.equal(safeJoinUrl(event("a", 0, 0, { joinUrl: "http://teams.microsoft.com/x" })), null);
  assert.equal(safeJoinUrl(event("a", 0, 0, { joinUrl: "javascript:alert(1)" })), null);
  assert.equal(safeJoinUrl(event("a", 0, 0)), null);
});

test("what Rust sends is read, and anything else is an empty agenda", () => {
  assert.deepEqual(readAgenda({}), { events: [], errors: [] });
  assert.deepEqual(readAgenda({ events: "no", errors: 3 }), { events: [], errors: [] });
  const failure = { id: "perso123", calendar: "Perso", message: "refused" };
  const read = readAgenda({ events: [event("a", 1, 2)], errors: [failure] });
  assert.equal(read.events.length, 1);
  assert.deepEqual(read.errors, [failure]);
});

test("a calendar's link is kept under its own credential-store entry", () => {
  assert.equal(linkKey("a1b2c3d4"), "agenda-link-a1b2c3d4");
});

test("each new calendar gets the first colour nobody wears, and they come round when all are used", () => {
  const wearing = (...colors) => colors.map((color, i) => ({ id: `id${i}xxxxx`, name: "n", color, enabled: true }));
  assert.equal(nextColor([]), CALENDAR_COLORS[0]);
  assert.equal(nextColor(wearing(CALENDAR_COLORS[0])), CALENDAR_COLORS[1]);
  assert.equal(nextColor(wearing(CALENDAR_COLORS[1])), CALENDAR_COLORS[0], "a freed colour is handed out again");
  const all = wearing(...CALENDAR_COLORS);
  assert.equal(nextColor(all), CALENDAR_COLORS[all.length % CALENDAR_COLORS.length]);
  assert.ok(CALENDAR_COLORS.length < MAX_CALENDARS, "more calendars than colours is expected");
  assert.equal(new Set(CALENDAR_COLORS).size, CALENDAR_COLORS.length);
});

test("a new id is eight lower case letters and digits, and never one already taken", () => {
  assert.match(newCalendarId([]), /^[a-z0-9]{8}$/);
  // A generator that would answer the taken id first, then another.
  const draws = [0, 0, 0, 0, 0, 0, 0, 0, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5];
  let i = 0;
  const id = newCalendarId(["aaaaaaaa"], () => draws[i++]);
  assert.notEqual(id, "aaaaaaaa");
  assert.match(id, /^[a-z0-9]{8}$/);
});

test("only an https or webcal link can be added", () => {
  assert.ok(isCalendarLink("https://outlook.office365.com/owa/calendar/x/reachcalendar.ics"));
  assert.ok(isCalendarLink("  webcal://p01-caldav.icloud.com/published/2/abc  "));
  assert.ok(isCalendarLink("HTTPS://example.com/a.ics"));
  assert.ok(!isCalendarLink("http://example.com/a.ics"), "no http: the link is a secret");
  assert.ok(!isCalendarLink("https://"));
  assert.ok(!isCalendarLink("webcal://"));
  assert.ok(!isCalendarLink("javascript:alert(1)"));
  assert.ok(!isCalendarLink("file:///etc/passwd"));
  assert.ok(!isCalendarLink(""));
});
