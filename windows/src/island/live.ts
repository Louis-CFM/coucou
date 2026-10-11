// Live activities: a moment of system news in the island — the volume or the
// brightness changing, the charger plugged in, the battery running low. Windows
// only (src-tauri/src/sysevents.rs reports them).
//
// The compact island widens a little and shows it where the mini grid sits,
// then goes back to what it was; from hidden it peeks out for as long as the
// activity lasts, with no sound. Open, the island shows it as a small toast
// over its header. Everything moves with transforms and opacity, so the
// compositor does the work and nothing is laid out again per frame.

import { onEvent } from "../core/bridge";
import { State } from "../core/state";
import { ICONS } from "../views/icons";
import { h, svg, clear } from "../views/dom";
import { N_, t } from "../i18n/i18n";

/** The texts sysevents.rs sends, translated here. */
export const LIVE_TEXTS = [N_("Charging"), N_("On battery"), N_("Low battery")];

export interface LiveEvent {
  kind: "volume" | "brightness" | "battery";
  /** 0…1. */
  level: number | null;
  muted: boolean;
  charging: boolean;
  text: string;
}

/** How long each kind stays, ms. */
const DURATION: Record<LiveEvent["kind"], number> = { volume: 1500, brightness: 1500, battery: 2600 };

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

export function showLive(host: LiveHost, e: LiveEvent) {
  const ms = DURATION[e.kind] ?? 1500;
  const wasShowing = Live.current != null;
  Live.current = e;
  Live.until = performance.now() + ms;
  if (endTimer != null) window.clearTimeout(endTimer);
  endTimer = window.setTimeout(() => {
    endTimer = null;
    Live.current = null;
    host.resize();
    State.notify();
  }, ms);
  host.peek(ms + 250);
  if (!wasShowing) host.resize();
  State.notify();
}

export function registerLiveHandlers(host: LiveHost) {
  void onEvent<LiveEvent>("live", (e) => {
    showLive(host, e);
  });
}

function iconFor(e: LiveEvent): { path: string; stroke: number } {
  switch (e.kind) {
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
