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

test("weeks, a day's calls and a call's details scroll between the card's header and its Open action", () => {
  const CARD_HEIGHT = 134; // the island's overview card
  const at = (day, hour) => new Date(2026, 10, day, hour);
  const bookings = [9, 10, 11, 12, 13, 14].map((hour) => ({ id: String(hour), title: `Call ${hour}`, start: at(25, hour).toISOString(),
    end: at(25, hour + 1).toISOString(), attendeeName: "Guest", attendeeEmail: "guest@example.com", attendeeNotes: "Line 1\nLine 2\nLine 3\nLine 4" }));
  const root = calendarDetail({ rangeStart: at(2, 0).getTime(), rangeEnd: new Date(2027, 0, 1).getTime(), bookings }, () => {}, () => {});
  const check = (view) => {
    const kids = root.children, body = root.querySelector(".cal-body");
    assert.ok(body, `${view}: one scrolling area`);
    assert.ok(kids[0].classList.contains("int-head"), `${view}: Back and the title stay at the top`);
    assert.equal(kids.at(-2), body, `${view}: the scrolling area sits just above the action`);
    assert.ok(kids.at(-1).classList.contains("int-actions") && /Open Cal\.com/.test(kids.at(-1).textContent), `${view}: Open Cal.com stays at the bottom`);
    assert.equal(body.find(".int-actions").length, 0, `${view}: no action scrolls away`);
    for (const el of [root, ...root.walk()]) {
      for (const [, px] of (el.getAttribute("style") ?? "").matchAll(/height\s*:\s*(\d+(?:\.\d+)?)px/g)) {
        assert.ok(Number(px) <= CARD_HEIGHT, `${view}: no ${px}px height in a ${CARD_HEIGHT}px card`);
      }
    }
    return { kids, body };
  };
  const { kids, body } = check("month");
  assert.deepEqual(kids.slice(1, 3).map((el) => el.classList.contains("cal-nav") || el.classList.contains("cal-weekdays")), [true, true],
    "Previous/Today/Next and the weekday names stay above the weeks");
  assert.ok(root.querySelector(".cal-nav").querySelector(".cal-next"));
  assert.equal(body.find(".cal-day").length, 42, "every week is inside the scrolling area");
  body.find(".cal-day").find((el) => el.getAttribute("data-day") === "2026-11-25").fire("click");
  assert.equal(check("day").body.find(".cal-booking").length, 6, "every call of the day is inside the scrolling area");
  root.querySelector(".cal-booking").fire("click");
  assert.match(check("booking").body.textContent, /Line 4/);
});
