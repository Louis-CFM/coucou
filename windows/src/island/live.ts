// Live activities: a moment of system news in the island — the volume or the
// brightness changing, the charger plugged in, the battery running low. Windows
// only (src-tauri/src/sysevents.rs reports them).
//
// The compact island widens a little and shows it where the mini grid sits,
// then goes back to what it was; from hidden it peeks out for as long as the
// activity lasts, with no sound. Open, the island shows it as a small toast
// over its header. Everything moves with transforms and opacity, so the
// compositor does the work and nothing is laid out again per frame.

import { Bridge, onEvent } from "../core/bridge";
import { State } from "../core/state";
import { Sound } from "../core/sound";
import { ICONS } from "../views/icons";
import { h, svg, clear } from "../views/dom";
import { N_, t } from "../i18n/i18n";

/** The texts sysevents.rs sends, translated here. */
export const LIVE_TEXTS = [N_("Charging"), N_("On battery"), N_("Low battery")];

export interface LiveEvent {
  kind: "volume" | "brightness" | "battery" | "phone" | "call" | "message" | "app";
  /** 0…1. */
  level: number | null;
  muted: boolean;
  charging: boolean;
  text: string;
}

/** How long each kind stays, ms. */
const DURATION: Record<LiveEvent["kind"], number> = { volume: 1500, brightness: 1500, battery: 2600, phone: 5000, call: 12000, message: 5000, app: 4500 };

/** The compact island's width while a live activity shows. */
export const LIVE_W = 336;

export const Live = {
  current: null as LiveEvent | null,
  /** performance.now() when it ends. */
  until: 0,
};

export interface LiveHost {
  /** Hidden → compact for `ms`, without the peek sound. */
  peek(ms: number): void;
  /** The island's width target changed. */
  resize(): void;
}

let endTimer: number | null = null;
/** A ringing call rings until its card goes. */
let ringTimer: number | null = null;

function stopRing() {
  if (ringTimer != null) window.clearInterval(ringTimer);
  ringTimer = null;
}

export function showLive(host: LiveHost, e: LiveEvent, duration?: number) {
  const ms = duration ?? DURATION[e.kind] ?? 1500;
  const wasShowing = Live.current != null;
  Live.current = e;
  Live.until = performance.now() + ms;
  if (endTimer != null) window.clearTimeout(endTimer);
  endTimer = window.setTimeout(() => {
    endTimer = null;
    stopRing();
    Live.current = null;
    host.resize();
    State.notify();
  }, ms);
  host.peek(ms + 250);
  if (!wasShowing) host.resize();
  State.notify();
}

/** The call whose card is up, so it goes when the call ends. */
let ringing: number | null = null;
/** A call's card stays while it rings, at most this long. */
const CALL_MAX_MS = 90_000;

export function endLive(host: LiveHost) {
  if (endTimer != null) window.clearTimeout(endTimer);
  endTimer = null;
  stopRing();
  Live.current = null;
  ringing = null;
  host.resize();
  State.notify();
}

export interface ToastEvent {
  id: number;
  kind: "call" | "message" | "app";
  who: string;
  app: string;
  title: string;
  body: string;
}

export function registerLiveHandlers(host: LiveHost) {
  void onEvent<LiveEvent>("live", (e) => showLive(host, e));
  // Another app's notification (notify.rs): who, and the first line.
  void onEvent<ToastEvent>("toast", (n) => {
    const who = n.who || n.title || n.app;
    if (n.kind === "call") {
      // Stays while it rings: Phone Link takes the toast away when it ends.
      ringing = n.id;
      stopRing();
      Sound.play("approval");
      ringTimer = window.setInterval(() => Sound.play("approval"), 2200);
      showLive(host, { kind: "call", level: null, muted: false, charging: false, text: t("{0} is calling", { 0: who }) }, CALL_MAX_MS);
      return;
    }
    // A message never covers a ringing call.
    if (ringing != null) return;
    const text = [who, n.body].filter((x) => x).join(" · ");
    Sound.play("pop");
    showLive(host, { kind: n.kind, level: null, muted: false, charging: false, text });
  });
  void onEvent<number>("toast-gone", (id) => {
    if (id === ringing) endLive(host);
  });
}

function iconFor(e: LiveEvent): { path: string; stroke: number } {
  switch (e.kind) {
    case "phone":
    case "call":
      return { path: ICONS.phone, stroke: 2 };
    case "message":
    case "app":
      return { path: ICONS.bubble, stroke: 0 };
    case "brightness":
      return { path: ICONS.sun, stroke: 2 };
    case "battery":
      return e.charging ? { path: ICONS.bolt, stroke: 0 } : { path: ICONS.battery, stroke: 2 };
    default: {
      const v = e.muted ? 0 : (e.level ?? 0);
      const path = v <= 0 ? ICONS.volume0 : v < 0.34 ? ICONS.volume1 : v < 0.67 ? ICONS.volume2 : ICONS.volume3;
      return { path, stroke: 2.2 };
    }
  }
}

function colorFor(e: LiveEvent): string {
  if (e.kind === "battery") {
    if (e.charging) return "#34D399";
    return (e.level ?? 1) <= 0.2 ? "#F4505E" : "#F5F6F8";
  }
  if (e.kind === "brightness") return "#FACC15";
  if (e.kind === "phone") return "#60A5FA";
  if (e.kind === "call") return "#34D399";
  if (e.kind === "message") return "#60A5FA";
  if (e.kind === "app") return "#C5C8CD";
  return e.muted ? "#6B7079" : "#F5F6F8";
}

/** The element the island places; `sync()` repaints it from Live.current. */
export function buildLive(): { el: HTMLElement; sync(expanded: boolean): void } {
  const icon = h("span", { class: "live-icon" });
  const fill = h("i", { class: "live-fill" });
  const bar = h("div", { class: "live-bar" }, fill);
  const label = h("span", { class: "live-label" });
  const el = h("div", { id: "live" }, icon, bar, label);
  let shownIcon = "";

  return {
    el,
    sync(expanded) {
      const e = Live.current;
      el.classList.toggle("on", e != null);
      el.classList.toggle("expanded", expanded);
      if (!e) return;
      const { path, stroke } = iconFor(e);
      const color = colorFor(e);
      const key = `${path}|${color}`;
      if (key !== shownIcon) {
        shownIcon = key;
        clear(icon);
        icon.append(svg(path, 15, stroke ? { stroke } : {}));
        icon.style.color = color;
      }
      const isText = e.kind === "phone" || e.kind === "call" || e.kind === "message" || e.kind === "app";
      el.classList.toggle("phone", isText);
      if (isText && e.kind !== "phone") {
        label.textContent = e.text;
        // A call opens Phone Link, where it is answered or declined.
        el.title = e.kind === "call" ? t("Click to answer or decline in Phone Link") : e.text;
        el.onclick = e.kind === "call" ? () => void Bridge.openPhoneLink() : null;
        return;
      }
      if (e.kind === "phone") {
        // The iPhone's link or text, already on the clipboard; a link opens on click.
        const url = /^https?:\/\/\S+$/i.test(e.text) ? e.text : null;
        label.textContent = url ? url.replace(/^https?:\/\/(www\.)?/i, "") : e.text.replace(/\s+/g, " ");
        el.title = url ? t("From iPhone — click to open") : t("From iPhone — copied");
        el.onclick = url ? () => void Bridge.openUrl(url) : null;
        return;
      }
      el.onclick = null;
      const level = e.muted ? 0 : Math.max(0, Math.min(1, e.level ?? 0));
      // scaleX, not width: the compositor animates it without a layout.
      fill.style.transform = `scaleX(${level})`;
      fill.style.background = e.kind === "battery" ? color : e.kind === "brightness" ? "#FACC15" : "#F5F6F8";
      const pct = `${Math.round(level * 100)}`;
      label.textContent = e.text ? `${t(e.text)} · ${pct}%` : e.muted ? t("Muted") : pct;
      el.classList.toggle("has-text", !!e.text || e.muted);
    },
  };
}
