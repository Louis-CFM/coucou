import { readBookings, dayKey, monthDays, monthIndex, type Booking } from "../core/calendar";
import { h, clear } from "./dom";
import { language, t } from "../i18n/i18n";

/** Month → day → booking, inside the existing integration detail card. */
export function calendarDetail(data: Record<string, unknown>, close: () => void, open: () => void): HTMLElement {
  const root = h("div", { class: "int-card cal-card" });
  const bookings = readBookings(data.bookings);
  const from = new Date(Number(data.rangeStart)), until = new Date(Number(data.rangeEnd));
  if (!bookings || !Number.isFinite(from.getTime()) || !Number.isFinite(until.getTime())) {
    root.append(h("div", { class: "int-status", text: t("Unexpected API response.") }), h("button", { class: "link-btn", text: t("Back"), onclick: close }));
    return root;
  }
  const firstDay = dayKey(from), lastDay = dayKey(until);
  let month = new Date(from.getFullYear(), from.getMonth(), 1);
  let selectedDay: Date | null = null;
  let selectedBooking: Booking | null = null;
  const dateText = (date: Date) => date.toLocaleDateString(language(), { weekday: "long", day: "numeric", month: "long", year: "numeric" });
  const timeText = (date: Date) => date.toLocaleTimeString(language(), { hour: "2-digit", minute: "2-digit" });
  const onDay = (day: Date) => bookings.filter((b) => dayKey(b.start) === dayKey(day));
  function back() {
    if (selectedBooking) selectedBooking = null;
    else if (selectedDay) selectedDay = null;
    else { close(); return; }
    render();
  }
  function render() {
    clear(root);
    const backButton = h("button", { class: "link-btn cal-back", text: t("Back"), onclick: back });
    const title = selectedBooking?.title || (selectedDay ? dateText(selectedDay) : month.toLocaleDateString(language(), { month: "long", year: "numeric" }));
    root.append(h("div", { class: "int-head" }, backButton, h("b", { text: title, style: "overflow:hidden;text-overflow:ellipsis;white-space:nowrap" })));
    const body = h("div", { class: "int-detail-body", style: "max-height:220px;overflow:auto" });
    if (selectedBooking) {
      const booking = selectedBooking;
      body.append(h("div", { class: "int-status", text: dateText(booking.start) }),
        h("div", { class: "int-status", text: `${timeText(booking.start)} – ${dayKey(booking.start) === dayKey(booking.end) ? "" : `${dateText(booking.end)} `}${timeText(booking.end)}` }));
      for (const text of [booking.attendeeName, booking.attendeeEmail, booking.attendeeNotes]) {
        if (text) body.append(h("div", { class: "int-status", style: "white-space:pre-wrap;overflow-wrap:anywhere", text }));
      }
    } else if (selectedDay) {
      const dayBookings = onDay(selectedDay);
      if (!dayBookings.length) body.append(h("div", { class: "int-empty", text: t("No calls scheduled") }));
      for (const booking of dayBookings) body.append(h("button", { class: "int-row cal-booking", style: "width:100%;text-align:start",
        "data-booking": booking.id, onclick: () => { selectedBooking = booking; render(); } },
        h("span", { class: "int-time", text: timeText(booking.start) }), h("span", { class: "int-name", text: booking.title || t("Meeting") })));
    } else {
      const previous = h("button", { class: "link-btn cal-previous", text: t("Previous"), onclick: () => { month = new Date(month.getFullYear(), month.getMonth() - 1, 1); render(); } });
      const next = h("button", { class: "link-btn cal-next", text: t("Next"), onclick: () => { month = new Date(month.getFullYear(), month.getMonth() + 1, 1); render(); } });
      previous.disabled = monthIndex(month) <= monthIndex(from);
      next.disabled = monthIndex(month) >= monthIndex(until);
      body.append(h("div", { class: "int-actions", style: "justify-content:space-between" }, previous,
        h("button", { class: "link-btn", text: t("Today"), onclick: () => { month = new Date(from.getFullYear(), from.getMonth(), 1); render(); } }), next));
      const grid = h("div", { class: "cal-grid", style: "display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:3px" });
      for (let day = 0; day < 7; day++) grid.append(h("span", { style: "text-align:center;opacity:.65;font-size:10px", text: new Date(2024, 0, 1 + day).toLocaleDateString(language(), { weekday: "short" }) }));
      for (const date of monthDays(month)) {
        const key = dayKey(date), count = onDay(date).length;
        const button = h("button", { class: "link-btn cal-day", "data-day": key, "aria-label": `${dateText(date)} · ${count}`,
          style: `min-height:22px;border-radius:5px;${count ? "background:#C9956A25;color:#C9956A" : ""}`,
          text: `${date.getDate()}${count ? " •" : ""}`, onclick: () => { selectedDay = date; render(); } });
        button.disabled = date.getMonth() !== month.getMonth() || key < firstDay || key > lastDay;
        grid.append(button);
      }
      body.append(grid);
    }
    root.append(body, h("div", { class: "int-actions" }, h("button", { class: "link-btn", text: t("Open {name}", { name: "Cal.com" }), onclick: open })));
  }
  root.addEventListener("keydown", (event) => { if (event.key === "Escape") { event.stopPropagation(); back(); } });
  render();
  return root;
}
