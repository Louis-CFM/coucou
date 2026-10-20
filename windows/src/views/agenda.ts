// The Agenda pill's card: what is left to do today, then the next days, from the Outlook and iCloud
// calendars the user set up. The grouping and the marks live in core/agenda.ts.
//
// The island's card is a strip beside Mochi, so this is one list that scrolls, not a calendar.

import { h, svg, dot } from "./dom";
import { ICONS } from "./icons";
import { State } from "../core/state";
import { Bridge } from "../core/bridge";
import { groupByDay, readAgenda, safeJoinUrl, type AgendaEvent, type DayGroup, type Row } from "../core/agenda";
import { language, t } from "../i18n/i18n";

const ACCENT = "#4F8EF7";

function time(seconds: number): string {
  return new Date(seconds * 1000).toLocaleTimeString(language(), { hour: "2-digit", minute: "2-digit" });
}

/** "Today", "Tomorrow", then the weekday and date in the shown language. */
export function dayLabel(date: Date, now: Date): string {
  const days = Math.round(
    (date.getTime() - new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()) / 86_400_000,
  );
  if (days === 0) return t("Today");
  if (days === 1) return t("Tomorrow");
  return date.toLocaleDateString(language(), { weekday: "long", day: "numeric", month: "short" });
}

function eventRow(row: Row): HTMLElement {
  const e: AgendaEvent = row.event;
  const color = e.color || ACCENT;
  const cells: Node[] = [
    dot(color, 5),
    h("span", { class: "ag-time", text: e.allDay ? t("All day") : time(e.start) }),
    h("span", { class: "ag-title", text: e.title, title: [e.title, e.calendar, e.location].filter(Boolean).join(" — ") }),
  ];
  if (e.conflict) {
    cells.push(h("span", { class: "ag-conflict", title: t("Overlaps another event"), text: t("Overlap") }));
  }
  if (row.mark === "active") cells.push(h("span", { class: "ag-badge active", text: t("Now") }));
  if (row.mark === "upcoming") cells.push(h("span", { class: "ag-badge upcoming", text: t("Next") }));
  const url = safeJoinUrl(e);
  if (url) {
    cells.push(
      h(
        "button",
        { class: "ag-join", title: url, onclick: () => void Bridge.openUrl(url) },
        svg(ICONS.arrowUpRight, 8, { stroke: 2 }),
        h("span", { text: t("Join") }),
      ),
    );
  }
  const el = h("div", { class: `ag-row ${row.mark}${e.busy ? "" : " free"}` }, ...cells);
  if (row.mark === "active") el.style.background = `${color}1f`;
  return el;
}

function dayBlock(group: DayGroup, now: Date): HTMLElement {
  return h(
    "div",
    { class: "ag-day" },
    h("div", { class: "ag-day-label", text: dayLabel(group.date, now) }),
    ...group.rows.map(eventRow),
  );
}

export function agendaCard(): HTMLElement {
  const { events, errors } = readAgenda((State.integrations["integration_agenda"]?.data ?? {}) as Record<string, unknown>);
  const now = new Date();
  const groups = groupByDay(events, now);

  const list = h("div", { class: "ag-list" });
  if (groups.length === 0) {
    list.append(h("div", { class: "int-empty", text: t("Nothing planned in the next 7 days") }));
  } else {
    // When nothing is left today, say so rather than start on tomorrow unannounced.
    if (groups[0].date.toDateString() !== now.toDateString()) {
      list.append(h("div", { class: "int-empty", text: t("Nothing left today") }));
    }
    for (const group of groups) list.append(dayBlock(group, now));
  }

  // A calendar that failed says so under the list; the other ones' events are still shown.
  const notes = errors.map((e) => h("div", { class: "ag-error", text: `${e.calendar}: ${e.message}` }));

  const head = h("div", { class: "int-head" }, dot(ACCENT, 7), h("b", { text: "Agenda" }), h("span", { text: t("Schedule") }));
  return h("div", { class: "int-card" }, head, list, ...notes);
}

