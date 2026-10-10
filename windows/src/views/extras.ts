// The cards of the Windows build's own pills (core/extras.ts): Focus, To-do
// and Inbox. Built once and synced in place, like the music card, so a field
// being typed in is never rebuilt under the cursor.

import { h, clear, dot } from "./dom";
import { Bridge, onEvent } from "../core/bridge";
import { State } from "../core/state";
import { Sound } from "../core/sound";
import { Focus, Inbox, Todos, clock, planAlert, type ExtraView } from "../core/extras";
import { Live, showLive, type LiveHost } from "../island/live";
import { t } from "../i18n/i18n";

export interface ExtraCard {
  el: HTMLElement;
  sync(): void;
}

function ago(at: number): string {
  const m = Math.round((Date.now() - at) / 60000);
  return m < 1 ? t("just now") : m < 60 ? t("{n} min ago", { n: m }) : t("{n} h ago", { n: Math.round(m / 60) });
}

// ── Focus ─────────────────────────────────────────────────────────────────────

let host: LiveHost | null = null;
let ticker: number | null = null;

function focusTick() {
  const left = Focus.left();
  if (Focus.running && left <= 0) {
    Focus.endsAt = null;
    stopTicker();
    Sound.play("finish");
    if (host) showLive(host, { kind: "focus", level: 1, muted: false, charging: false, text: t("Focus done — take a break") }, 5000);
    void Bridge.phonePush(t("Focus done"), t("{n} minutes of focus. Take a break.", { n: Focus.minutes }), false, true);
    State.notify();
    return;
  }
  // The countdown sits in the compact island; a volume change shows over it
  // for a moment, then the countdown comes back.
  // Only the compact island shows it: open, the Focus tab has the clock, and a
  // toast would sit over the top bar's tabs.
  if (host && Focus.running && State.mode !== "expanded" && (Live.current == null || Live.current.kind === "focus")) {
    const level = 1 - left / (Focus.minutes * 60_000);
    showLive(host, { kind: "focus", level, muted: false, charging: false, text: clock(left) }, 1500);
  }
  State.notify();
}

function stopTicker() {
  if (ticker != null) window.clearInterval(ticker);
  ticker = null;
}

function startFocus(minutes: number) {
  Focus.minutes = minutes;
  Focus.endsAt = Date.now() + minutes * 60_000;
  Focus.pausedLeft = null;
  Sound.play("approve");
  stopTicker();
  ticker = window.setInterval(focusTick, 1000);
  focusTick();
}

function pauseFocus() {
  if (Focus.pausedLeft != null) {
    Focus.endsAt = Date.now() + Focus.pausedLeft;
    Focus.pausedLeft = null;
    ticker = window.setInterval(focusTick, 1000);
  } else {
    Focus.pausedLeft = Focus.left();
    stopTicker();
  }
  State.notify();
}

function stopFocus() {
  Focus.endsAt = null;
  Focus.pausedLeft = null;
  stopTicker();
  State.notify();
}

function focusCard(): ExtraCard {
  const big = h("div", { class: "x-clock" });
  // Any length, typed in (1 min to 10 h), or one of the usual two.
  const minutes = h("input", { class: "x-input x-min", type: "number", min: "1", max: "600", placeholder: t("min") }) as HTMLInputElement;
  const startTyped = () => {
    const m = Math.round(Number(minutes.value));
    if (!(m >= 1 && m <= 600)) {
      minutes.focus();
      return;
    }
    minutes.value = "";
    minutes.blur();
    startFocus(m);
  };
  minutes.addEventListener("focus", () => void Bridge.focusWindow(true));
  minutes.addEventListener("blur", () => void Bridge.focusWindow(false));
  minutes.addEventListener("keydown", (e) => {
    e.stopPropagation();
    if (e.key === "Enter") startTyped();
    else if (e.key === "Escape") minutes.blur();
  });
  const startRow = h("div", { class: "int-actions x-start" },
    minutes,
    h("button", { class: "link-btn", onclick: startTyped }, t("Start")),
    h("button", { class: "link-btn", onclick: () => startFocus(25) }, t("25 min")),
    h("button", { class: "link-btn", onclick: () => startFocus(50) }, t("50 min")),
  );
  const pauseBtn = h("button", { class: "link-btn", onclick: pauseFocus });
  const runRow = h("div", { class: "int-actions" }, pauseBtn,
    h("button", { class: "link-btn", onclick: stopFocus }, t("Stop")));
  const sub = h("span");
  const el = h("div", { class: "int-card" },
    h("div", { class: "int-head" }, dot("#F97316", 7), h("b", { text: t("Focus") }), sub),
    big, startRow, runRow);
  return {
    el,
    sync() {
      const active = Focus.active;
      big.textContent = clock(active ? Focus.left() : Focus.minutes * 60_000);
      startRow.style.display = active ? "none" : "";
      runRow.style.display = active ? "" : "none";
      pauseBtn.textContent = Focus.pausedLeft != null ? t("Resume") : t("Pause");
      sub.textContent = active ? t("Notifications held, calls still ring") : t("Type minutes, or pick one");
    },
  };
}

// ── To-do ─────────────────────────────────────────────────────────────────────

function todoCard(): ExtraCard {
  const list = h("div", { class: "x-list" });
  const input = h("input", { class: "x-input", placeholder: t("Add a to-do and press Enter"), maxlength: "200" }) as HTMLInputElement;
  // The island only takes the keyboard while this field is in use.
  input.addEventListener("focus", () => void Bridge.focusWindow(true));
  input.addEventListener("blur", () => void Bridge.focusWindow(false));
  input.addEventListener("keydown", (e) => {
    e.stopPropagation();
    if (e.key === "Enter") {
      Todos.add(input.value);
      input.value = "";
      Sound.play("pop");
    } else if (e.key === "Escape") {
      input.blur();
    }
  });
  const sub = h("span");
  const el = h("div", { class: "int-card" },
    h("div", { class: "int-head" }, dot("#22D3EE", 7), h("b", { text: t("To-do") }), sub),
    list, input);
  let key = "";
  return {
    el,
    sync() {
      sub.textContent = t("{n} open", { n: Todos.open });
      const k = JSON.stringify(Todos.items);
      if (k === key) return;
      key = k;
      clear(list);
      if (Todos.items.length === 0) list.append(h("div", { class: "int-empty", text: t("Nothing to do. Nice.") }));
      for (const item of Todos.sorted) {
        const box = h("button", { class: `x-check${item.done ? " on" : ""}`, title: item.done ? t("Mark as not done") : t("Mark as done") });
        box.addEventListener("click", () => {
          Todos.toggle(item.id);
          if (!item.done) Sound.play("approve");
        });
        const del = h("button", { class: "x-del", title: t("Delete"), text: "×" });
        del.addEventListener("click", () => Todos.remove(item.id));
        list.append(h("div", { class: `x-row${item.done ? " done" : ""}` }, box, h("span", { class: "x-text", text: item.text }), del));
      }
    },
  };
}

// ── Inbox ─────────────────────────────────────────────────────────────────────

function inboxCard(): ExtraCard {
  const list = h("div", { class: "x-list" });
  const sub = h("span");
  const clearBtn = h("button", { class: "link-btn", onclick: () => { Inbox.items = []; Inbox.unseen = 0; State.notify(); } }, t("Clear"));
  const el = h("div", { class: "int-card" },
    h("div", { class: "int-head" }, dot("#60A5FA", 7), h("b", { text: t("Inbox") }), sub, h("span", { class: "grow" }), clearBtn),
    list);
  let key = "";
  return {
    el,
    sync() {
      // Looking at the card is reading it.
      Inbox.unseen = 0;
      sub.textContent = t("Calls and messages");
      const k = `${Inbox.items.length}:${Inbox.items[0]?.at ?? 0}:${Math.floor(Date.now() / 60000)}`;
      if (k === key) return;
      key = k;
      clear(list);
      if (Inbox.items.length === 0) list.append(h("div", { class: "int-empty", text: t("Nothing missed") }));
      for (const it of Inbox.items) {
        list.append(h("div", { class: "x-row" },
          h("span", { class: "x-kind", text: it.kind === "call" ? "📞" : "💬" }),
          h("span", { class: "x-text", text: it.body ? `${it.who}: ${it.body}` : it.who }),
          h("span", { class: "int-ago", text: ago(it.at) }),
        ));
      }
    },
  };
}

/** A top-bar tab's view: its card, beside Mochi, the whole width of the island. */
export function buildExtraView(view: ExtraView): { el: HTMLElement; sync(): void } {
  const c = view === "focus" ? focusCard() : view === "todo" ? todoCard() : inboxCard();
  const el = h("div", { class: "view extra-view" }, h("div", { class: "card extra-card" }, c.el));
  return { el, sync: () => c.sync() };
}

/** The 5-hour Claude window crossed 80 % or 95 %: a card, and the phone. */
export function planUsageAlert(usedPct: number, resetsAt: number) {
  const mark = planAlert(usedPct, resetsAt);
  if (mark == null) return;
  const mins = Math.max(0, Math.round((resetsAt - Date.now()) / 60000));
  const text = t("Claude plan at {p}% — resets in {m} min", { p: Math.round(usedPct), m: mins });
  if (host) showLive(host, { kind: "battery", level: usedPct / 100, muted: false, charging: false, text }, 6000);
  void Bridge.phonePush(t("Claude usage {p}%", { p: mark }), text, mark >= 95, true);
}

/** Back at the keyboard after a while: what came meanwhile (notify.rs). */
export function registerExtras(liveHost: LiveHost) {
  host = liveHost;
  void onEvent<number>("user-back", (awaySecs) => {
    const { calls, messages } = Inbox.since(Date.now() - awaySecs * 1000);
    if (calls + messages === 0) return;
    const parts = [
      calls ? t("{n} calls", { n: calls }) : "",
      messages ? t("{n} messages", { n: messages }) : "",
    ].filter((x) => x);
    showLive(liveHost, { kind: "message", level: null, muted: false, charging: false, text: t("While you were away: {0}", { 0: parts.join(" · ") }) }, 7000);
  });
}
