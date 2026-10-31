import test from "node:test";
import assert from "node:assert/strict";
import { readBookings, dayKey, monthDays } from "../src/core/calendar.ts";
import { calendarDetail } from "../src/views/calendar.ts";
import { installFakeDom } from "./fakedom.mjs";

installFakeDom();

test("calendar dates retain leap days and local day boundaries", () => {
  const days = monthDays(new Date(2024, 1, 1));
  assert.equal(days.length, 42);
  assert.equal(days[0].getDay(), 1);
  assert.equal(days.filter((d) => d.getMonth() === 1).length, 29);
  assert.equal(dayKey(new Date(2026, 9, 25, 0, 1)), "2026-10-25");
  assert.equal(new Set(days.map(dayKey)).size, 42);
});

test("invalid booking data is an error, distinct from a calendar without bookings", () => {
  assert.deepEqual(readBookings([]), []);
  assert.equal(readBookings({}), null);
  assert.equal(readBookings([{ id: "1", start: "invalid", end: "invalid" }]), null);
  assert.equal(readBookings([{ id: "1", start: "2026-10-28T13:00:00Z", end: "2026-10-28T12:00:00Z" }]), null);
});

test("month, day and booking navigation preserve notes as text and stay inside the fetched range", () => {
  let closed = 0, opened = 0;
  const date = new Date(2026, 9, 28, 12);
  const root = calendarDetail({ rangeStart: new Date(2026, 9, 1).getTime(), rangeEnd: new Date(2026, 10, 30).getTime(),
    bookings: [{ id: "1", title: "Planning", start: date.toISOString(), end: new Date(date.getTime() + 1800000).toISOString(),
      attendeeName: "Guest", attendeeEmail: "guest@example.com", attendeeNotes: "<b>Agenda</b>" }] }, () => closed++, () => opened++);
  assert.equal(root.querySelector(".cal-previous").disabled, true);
  root.querySelector(".cal-next").fire("click");
  assert.equal(root.querySelector(".cal-next").disabled, true);
  root.querySelector(".cal-previous").fire("click");
  root.find(".cal-day").find((el) => el.getAttribute("data-day") === dayKey(date)).fire("click");
  root.querySelector(".cal-booking").fire("click");
  assert.match(root.textContent, /guest@example.com/);
  assert.match(root.textContent, /<b>Agenda<\/b>/);
  root.querySelector(".cal-back").fire("click");
  assert.ok(root.querySelector(".cal-booking"));
  root.querySelector(".cal-back").fire("click");
  assert.ok(root.querySelector(".cal-grid"));
  root.querySelector(".cal-back").fire("click");
  assert.equal(closed, 1);
  assert.equal(opened, 0);
});
