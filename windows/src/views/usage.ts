// Claude plan usage: the 5-hour and weekly limits, as a pill in the island's header
// and a card behind it. Same behaviour as ClaudePlanGauge / ClaudePlanCardView on
// the Mac (docs/INTEGRATIONS.md, "Jauge de forfait Claude").
//
// The numbers come from Claude Code's own status line (`rate_limits` in what it
// hands its status-line command), through the relay: nothing is read from any
// credentials and nothing is fetched. They exist for Pro and Max plans only.

import { localized, uiLocale } from "../core/i18n";
import { State } from "../core/state";
import { clear, dot, h } from "./dom";
import { fa } from "./fa";

export interface PlanWindow {
  /** 0–100, clamped. */
  usedPct: number;
  /** Epoch milliseconds. */
  resetsAt: number;
}

export interface PlanUsage {
  fiveHour?: PlanWindow;
  sevenDay?: PlanWindow;
  /** When the numbers arrived (epoch ms). */
  updatedAt: number;
}

const DAY_MS = 86_400_000;

function parseWindow(raw: unknown, now: number): PlanWindow | undefined {
  const w = raw as { used_percentage?: unknown; resets_at?: unknown } | null;
  if (typeof w?.used_percentage !== "number" || typeof w.resets_at !== "number") return undefined;
  // Anything outside 0–200 is not a percentage; 100–200 is a plan over its limit, shown full.
  if (!(w.used_percentage >= 0 && w.used_percentage <= 200)) return undefined;
  // resets_at is epoch seconds. A date more than 400 days away is milliseconds in disguise.
  if (!(w.resets_at > 0) || w.resets_at * 1000 > now + 400 * DAY_MS) return undefined;
  return { usedPct: Math.min(100, w.used_percentage), resetsAt: w.resets_at * 1000 };
}

/** `rate_limits` from a status-line call, or null when it holds neither window. */
export function parsePlanUsage(rateLimits: unknown, now = Date.now()): PlanUsage | null {
  const rl = rateLimits as { five_hour?: unknown; seven_day?: unknown } | null;
  const fiveHour = parseWindow(rl?.five_hour, now);
  const sevenDay = parseWindow(rl?.seven_day, now);
  return fiveHour || sevenDay ? { fiveHour, sevenDay, updatedAt: now } : null;
}

/** What to show for a window: 0 once its reset time has passed. */
export const effectivePct = (w: PlanWindow, now = Date.now()): number => (w.resetsAt <= now ? 0 : w.usedPct);

/** The higher of the two effective percentages; null when there are no windows. */
export function dominantPct(u: PlanUsage | null, now = Date.now()): number | null {
  const pcts = [u?.fiveHour, u?.sevenDay].filter((w): w is PlanWindow => !!w).map((w) => effectivePct(w, now));
  return pcts.length ? Math.max(...pcts) : null;
}

/** Green below 50 %, orange up to 80 %, red above, grey without data. */
export function planColor(pct: number | null): string {
  if (pct == null) return "#6B7079";
  return pct < 50 ? "#22C55E" : pct < 80 ? "#F59E0B" : "#F4505E";
}

/** The colour the pill (and Mochi, while the card is open) has right now. */
export const currentPlanColor = (): string => planColor(dominantPct(State.planUsage));

/** The pill is in the header: on the overview, once turned on, once the relay is in. */
export function planPillVisible(): boolean {
  return State.view === "overview" && State.settings.showPlanInNotch && State.settings.planRelayInstalled;
}

const TEXT = {
  en: {
    plan: "Claude plan", waiting: "Waiting for a Claude Code reply", justNow: "just now",
    minAgo: (n: number) => `${n} min ago`, hAgo: (n: number) => `${n} h ago`,
    fiveHours: "5 hours", week: "Week", resetting: "Resetting…",
    inH: (h: number, m: number) => `in ${h} h ${m}`, inMin: (m: number) => `in ${m} min`,
  },
  de: {
    plan: "Claude-Abo", waiting: "Warte auf eine Antwort von Claude Code", justNow: "gerade eben",
    minAgo: (n: number) => `vor ${n} Min.`, hAgo: (n: number) => `vor ${n} Std.`,
    fiveHours: "5 Stunden", week: "Woche", resetting: "Setzt zurück…",
    inH: (h: number, m: number) => `in ${h} Std. ${m}`, inMin: (m: number) => `in ${m} Min.`,
  },
  fr: {
    plan: "Forfait Claude", waiting: "En attente d'une réponse de Claude Code", justNow: "à l'instant",
    minAgo: (n: number) => `il y a ${n} min`, hAgo: (n: number) => `il y a ${n} h`,
    fiveHours: "5 heures", week: "Semaine", resetting: "Réinitialisation…",
    inH: (h: number, m: number) => `dans ${h} h ${m}`, inMin: (m: number) => `dans ${m} min`,
  },
};

/** "Claude 73%" on the pill; "Claude —" while no numbers have come in. */
export function pillLabel(): string {
  const pct = dominantPct(State.planUsage);
  return pct == null ? "Claude —" : `Claude ${Math.round(pct)}%`;
}

/** The pill itself: colour dot and label, lit while hovered or while the card is open. */
export function buildPlanPill(): { el: HTMLElement; sync: () => void } {
  const label = h("span", { class: "plan-pill-label" });
  const dotEl = h("i", { class: "plan-pill-dot" });
  const el = h("button", {
    class: "plan-pill",
    title: "Claude plan usage",
    onclick: () => {
      State.showingPlanDetail = !State.showingPlanDetail;
      State.notify();
    },
  }, dotEl, label);
  return {
    el,
    sync() {
      const color = currentPlanColor();
      el.style.setProperty("--plan", color);
      el.classList.toggle("active", State.showingPlanDetail);
      dotEl.style.background = color;
      label.textContent = pillLabel();
    },
  };
}

function subtitle(u: PlanUsage | null, now: number): string {
  const t = localized(TEXT);
  if (!u) return t.waiting;
  const mins = Math.floor((now - u.updatedAt) / 60_000);
  return mins < 1 ? t.justNow : mins < 60 ? t.minAgo(mins) : t.hAgo(Math.floor(mins / 60));
}

/** "in 1 h 20" / "in 5 min" for the 5-hour window, "Mon 9:00" for the week. */
function resetLabel(w: PlanWindow, weekly: boolean, now: number): string {
  const t = localized(TEXT);
  const secs = (w.resetsAt - now) / 1000;
  if (secs <= 0) return t.resetting;
  if (weekly) {
    return new Date(w.resetsAt).toLocaleString(uiLocale(), { weekday: "short", hour: "numeric", minute: "2-digit", hour12: false });
  }
  const hours = Math.floor(secs / 3600);
  const mins = Math.floor((secs % 3600) / 60);
  return hours > 0 ? t.inH(hours, mins) : t.inMin(mins);
}

function gaugeRow(label: string, w: PlanWindow | undefined, weekly: boolean, now: number): HTMLElement {
  const row = h("div", { class: "plan-row" }, h("span", { class: "plan-label", text: label }));
  if (!w) {
    row.append(h("span", { class: "plan-none", text: "—" }));
    return row;
  }
  const pct = effectivePct(w, now);
  const fill = h("i", { class: "plan-fill" });
  fill.style.width = `${pct}%`;
  fill.style.background = planColor(pct);
  row.append(
    h("span", { class: "plan-bar" }, fill),
    h("span", { class: "plan-pct", text: `${Math.round(pct)}%` }),
    h("span", { class: "plan-reset-icon" }, fa("arrowRotateRight", 8)),
    h("span", { class: "plan-reset", text: resetLabel(w, weekly, now) }),
  );
  return row;
}

/** The card that replaces the left card while the pill is open. */
export class PlanCard {
  readonly el = h("div", { class: "plan-card" });
  private key = "";

  /** Re-renders when the numbers change or a minute has gone by (the countdowns). */
  sync(now = Date.now()) {
    const u = State.planUsage;
    const key = `${JSON.stringify(u)}|${State.settings.language}|${Math.floor(now / 60_000)}`;
    if (key === this.key) return;
    this.key = key;
    clear(this.el);
    const t = localized(TEXT);
    this.el.append(
      h("div", { class: "plan-head" },
        dot(currentPlanColor(), 7),
        h("span", { class: "plan-title", text: t.plan }),
        h("span", { class: "plan-sub", text: subtitle(u, now) }),
      ),
      h("div", { class: "plan-rows" },
        gaugeRow(t.fiveHours, u?.fiveHour, false, now),
        gaugeRow(t.week, u?.sevenDay, true, now),
      ),
    );
  }
}
