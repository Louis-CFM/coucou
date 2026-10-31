// The Cal.com card — DOM port of CalcomCardView, CalcomCalendarView,
// CalcomDayView and CalcomBookingDetailView (IslandViewContent.swift): half a
// month of days with a dot where calls are booked, a day's calls, then one
// call's attendee. Where it stands is kept here, so a fresh poll redrawing the
// card doesn't send the user back to the month.

import { h, svg, dot } from "./dom";
import { ICONS } from "./icons";
import { State } from "../core/state";
import { language, t } from "../i18n/i18n";

const ACCENT = "#C9956A";

export interface Booking {
  id: string;
  title: string;
  start: Date;
  attendeeName: string | null;
  attendeeEmail: string | null;
  attendeeNotes: string | null;
}

const nav = {
  month: new Date(new Date().getFullYear(), new Date().getMonth(), 1),
  /** 1: days 1–14, 2: the rest of the month (the Mac's "Q1" / "Q2"). */
  half: new Date().getDate() > 14 ? 2 : 1,
  day: null as string | null,
  booking: null as string | null,
};

let lastFocus: string | null = null;
State.subscribe(() => {
  // Another pill in front: next time the card opens on the month.
  if (State.focusId !== lastFocus) {
    lastFocus = State.focusId;
    nav.day = null;
    nav.booking = null;
  }
});

export function dayKey(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

/** The month in rows of 7 consecutive days, day 1 at the far left (no weekday alignment). */
export function monthWeeks(month: Date): (Date | null)[][] {
  const days = new Date(month.getFullYear(), month.getMonth() + 1, 0).getDate();
  const weeks: (Date | null)[][] = [];
  let row: (Date | null)[] = [];
  for (let i = 1; i <= days; i++) {
    row.push(new Date(month.getFullYear(), month.getMonth(), i));
    if (row.length === 7) {
      weeks.push(row);
      row = [];
    }
  }
  if (row.length) {
    while (row.length < 7) row.push(null);
    weeks.push(row);
  }
  return weeks;
}

export function readBookings(list: Record<string, unknown>[]): Booking[] {
  const out: Booking[] = [];
  for (const b of list) {
    const start = new Date(String(b.start));
    if (Number.isNaN(start.getTime())) continue;
    const str = (v: unknown) => (typeof v === "string" && v ? v : null);
    out.push({
      id: String(b.id ?? ""),
      title: str(b.title) ?? t("Meeting"),
      start,
      attendeeName: str(b.attendeeName),
      attendeeEmail: str(b.attendeeEmail),
      attendeeNotes: str(b.attendeeNotes),
    });
  }
  return out.sort((a, b) => a.start.getTime() - b.start.getTime());
}

function time(d: Date): string {
  return d.toLocaleTimeString(language(), { hour: "2-digit", minute: "2-digit" });
}

function backButton(onclick: () => void): HTMLElement {
  return h("button", { class: "cal-back", onclick }, svg(ICONS.chevronLeft, 9, { stroke: 2.4 }));
}

export function buildCalcomCard(bookings: Booking[]): HTMLElement {
  const el = h("div", { class: "int-card cal-card" });
  const redraw = () => el.replaceWith(buildCalcomCard(bookings));

  const booking = nav.booking ? bookings.find((b) => b.id === nav.booking) : undefined;
  if (booking) {
    const row = (icon: string, text: string, cls = "") => h("div", { class: `cal-detail ${cls}` }, h("span", { class: "cal-icon", text: icon }), h("span", { text }));
    el.append(
      h("div", { class: "cal-nav" }, backButton(() => { nav.booking = null; redraw(); }), h("span", { class: "cal-time", text: time(booking.start) })),
      h("div", { class: "cal-details" },
        h("b", { class: "cal-title", text: booking.title }),
        booking.attendeeName ? row("●", booking.attendeeName) : null,
        booking.attendeeEmail ? row("✉", booking.attendeeEmail, "small") : null,
        booking.attendeeNotes ? row("✎", booking.attendeeNotes, "small notes") : null,
      ),
    );
    return el;
  }

  if (nav.day) {
    const [y, m, d] = nav.day.split("-").map(Number);
    const date = new Date(y, m - 1, d);
    const today = bookings.filter((b) => dayKey(b.start) === nav.day);
    el.append(h("div", { class: "cal-nav" },
      backButton(() => { nav.day = null; redraw(); }),
      h("span", { class: "cal-day", text: date.toLocaleDateString(language(), { weekday: "long", day: "numeric", month: "long" }) }),
    ));
    if (today.length === 0) {
      el.append(h("div", { class: "int-empty", text: t("No calls scheduled") }));
    } else {
      el.append(h("div", { class: "cal-list" }, ...today.map((b) =>
        h("button", { class: "cal-booking", onclick: () => { nav.booking = b.id; redraw(); } },
          dot(ACCENT, 4),
          h("span", { class: "cal-time", text: time(b.start) }),
          h("span", { class: "cal-name", text: b.title }),
          svg(ICONS.chevronRight, 8, { stroke: 2 }),
        ))));
    }
    return el;
  }

  const weeks = monthWeeks(nav.month);
  const shown = nav.half === 1 ? weeks.slice(0, 2) : weeks.slice(2);
  const booked = new Set(bookings.map((b) => dayKey(b.start)));
  const todayKey = dayKey(new Date());
  const label = `${nav.month.toLocaleDateString(language(), { month: "long", year: "numeric" })} Q${nav.half}`;
  const step = (delta: 1 | -1) => {
    if (delta < 0 && nav.half === 2) nav.half = 1;
    else if (delta > 0 && nav.half === 1) nav.half = 2;
    else {
      nav.month = new Date(nav.month.getFullYear(), nav.month.getMonth() + delta, 1);
      nav.half = delta > 0 ? 1 : 2;
    }
    redraw();
  };
  el.append(
    h("div", { class: "int-head" }, dot(ACCENT, 7), h("b", { text: "Cal.com" }), h("span", { text: t("Schedule") })),
    h("div", { class: "cal-month" },
      h("button", { class: "cal-step", onclick: () => step(-1) }, svg(ICONS.chevronLeft, 8, { stroke: 2.4 })),
      h("span", { text: label }),
      h("button", { class: "cal-step", onclick: () => step(1) }, svg(ICONS.chevronRight, 8, { stroke: 2.4 })),
    ),
  );
  const grid = h("div", { class: "cal-weeks" });
  for (const week of shown) {
    const first = week.find((d) => d) ?? null;
    const row = h("div", { class: "cal-week" },
      h("span", { class: "cal-week-label", text: first ? first.toLocaleDateString(language(), { day: "2-digit", month: "2-digit" }) : "" }));
    for (const day of week) {
      if (!day) {
        row.append(h("span", { class: "cal-cell" }));
        continue;
      }
      const key = dayKey(day);
      row.append(h("button", {
        class: key === todayKey ? "cal-cell today" : "cal-cell",
        onclick: () => { nav.day = key; redraw(); },
      }, h("span", { class: "cal-num", text: String(day.getDate()) }), h("i", { class: booked.has(key) ? "cal-dot on" : "cal-dot" })));
    }
    grid.append(row);
  }
  el.append(grid);
  return el;
}
