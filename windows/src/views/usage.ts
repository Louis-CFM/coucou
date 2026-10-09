// Plan usage in the island: the Claude and Codex pills in the header and the
// card behind each. Same behaviour as ClaudePlanHeaderPill, ClaudePlanCardView
// and CodexPlanCardView on the Mac; the numbers and labels come from
// core/plan.ts.
//
// The pills sit in the header's right side, before the gear, on the overview
// only, Claude first. Clicking one puts its card in place of the overview's
// left card (clicking it again, or the other pill, closes or swaps it), and
// Nova wears the plan's colour while it is open. It closes when the view, the
// mode or the focused pill changes.

import { Bridge } from "../core/bridge";
import {
  PLAN_TEXT, claudeSubtitle, codexIsStale, codexResetsLabel, codexSubtitle, dominantPct,
  effectivePct, parseCodexPlan, pillLabel, planColor, resetLabel,
  type CodexPlanUsage, type PlanUsage, type PlanWindow,
} from "../core/plan";
import { State } from "../core/state";
import { clear, dot, h, svg } from "./dom";
import { ICONS } from "./icons";
import { language, tl } from "../i18n/i18n";

/** The Claude pill is in the header: overview, turned on, relay in. */
export function claudePillVisible(): boolean {
  const s = State.settings;
  return State.view === "overview" && s.showPlanInNotch && s.planRelayInstalled;
}

/** The Codex pill is in the header: overview, turned on (nothing to install). */
export function codexPillVisible(): boolean {
  return State.view === "overview" && State.settings.showCodexPlanInNotch;
}

/** A plan card is open and its pill is still there. */
export function planCardOpen(): boolean {
  if (!State.showingPlanDetail) return false;
  return State.planDetailIsCodex ? codexPillVisible() : claudePillVisible();
}

const claudeColor = (now = Date.now()) => planColor(dominantPct(State.planUsage, now));
const codexColor = (now = Date.now()) => planColor(dominantPct(State.codexPlanUsage, now));

/** The colour of the open card's plan, which Nova wears while it is open. */
export function openPlanColor(): string {
  return State.planDetailIsCodex ? codexColor() : claudeColor();
}

/** Closes the plan card (view, mode or focus changed). */
export function closePlanCard(): void {
  State.showingPlanDetail = false;
}

// ── Claude numbers ────────────────────────────────────────────────────────────

const STORE_KEY = "nova.claudePlanUsage";

/** New numbers from the status line; kept so they survive a restart, as on the Mac. */
export function setClaudePlanUsage(usage: PlanUsage): void {
  const prev = State.planUsage;
  const same = JSON.stringify([prev?.fiveHour, prev?.sevenDay]) === JSON.stringify([usage.fiveHour, usage.sevenDay]);
  State.planUsage = usage;
  if (!same) {
    try {
      window.localStorage?.setItem(STORE_KEY, JSON.stringify(usage));
    } catch {
      // Storage off or full: the numbers just will not outlive this run.
    }
  }
  // The relay calls in with every Claude Code update: a hidden island is only
  // woken when the numbers actually moved.
  if (!same || State.mode === "expanded") State.notify();
}

/** The last numbers seen, if any were kept. */
export function storedClaudePlanUsage(): string | null {
  try {
    return window.localStorage?.getItem(STORE_KEY) ?? null;
  } catch {
    return null;
  }
}

// ── Codex numbers ─────────────────────────────────────────────────────────────

let codexInFlight = false;

/**
 * Asks Codex again when the numbers are missing or older than a minute. Only
 * from the pill (shown or clicked), never on a timer, and never while paused:
 * `codex app-server` talks to Codex's own service.
 */
export function refreshCodexPlanUsage(): void {
  if (codexInFlight || State.paused || !codexIsStale(State.codexPlanUsage)) return;
  codexInFlight = true;
  void Bridge.codexPlanUsage()
    .then((result) => {
      const usage = parseCodexPlan(result);
      if (usage) {
        State.codexPlanUsage = usage;
        State.notify();
      }
    })
    .finally(() => {
      codexInFlight = false;
    });
}

// ── Pill ──────────────────────────────────────────────────────────────────────

export interface PlanPill {
  el: HTMLElement;
  sync(): void;
}

/** One pill: colour dot and label, lit while hovered or while its card is open. */
export function buildPlanPill(codex: boolean): PlanPill {
  const label = h("span", { class: "plan-pill-label" });
  const dotEl = h("i", { class: "plan-pill-dot" });
  const isOpen = () => State.showingPlanDetail && State.planDetailIsCodex === codex;
  const el = h("button", {
    class: "plan-pill",
    title: codex ? tl("Codex plan usage") : tl("Claude plan usage"),
    onclick: () => {
      const open = isOpen();
      State.planDetailIsCodex = codex;
      State.showingPlanDetail = !open;
      if (codex) refreshCodexPlanUsage();
      State.notify();
    },
  }, dotEl, label);
  return {
    el,
    sync() {
      const color = codex ? codexColor() : claudeColor();
      el.style.setProperty("--plan", color);
      el.classList.toggle("active", isOpen());
      dotEl.style.background = color;
      label.textContent = codex
        ? pillLabel("Codex", State.codexPlanUsage)
        : pillLabel("Claude", State.planUsage);
    },
  };
}

// ── Card ──────────────────────────────────────────────────────────────────────

function gaugeRow(label: string, w: PlanWindow | undefined, weekly: boolean, now: number): HTMLElement {
  const row = h("div", { class: "plan-row" }, h("span", { class: "plan-label", text: label }));
  if (!w) {
    row.append(h("span", { class: "plan-none", text: PLAN_TEXT.none }));
    return row;
  }
  const pct = effectivePct(w, now);
  const fill = h("i", { class: "plan-fill" });
  fill.style.width = `${pct}%`;
  fill.style.background = planColor(pct);
  row.append(
    h("span", { class: "plan-bar" }, fill),
    h("span", { class: "plan-pct", text: `${Math.round(pct)}%` }),
    h("span", { class: "plan-reset-icon" }, svg(ICONS.arrowClockwise, 8, { stroke: 2.6 })),
    h("span", { class: "plan-reset", text: resetLabel(w, weekly, now) }),
  );
  return row;
}

function head(color: string, title: string, subtitle: string): HTMLElement {
  return h("div", { class: "plan-head" },
    dot(color, 7),
    h("span", { class: "plan-title", text: title }),
    h("span", { class: "plan-sub", text: subtitle }),
  );
}

/** The card that stands in for the overview's left card while a pill is open. */
export class PlanCard {
  readonly el = h("div", { class: "plan-card" });
  private key = "";

  /** Re-renders when the numbers change, or every 30 s for the countdowns. */
  sync(now = Date.now()) {
    const codex = State.planDetailIsCodex;
    const u = codex ? State.codexPlanUsage : State.planUsage;
    const key = `${language()}|${codex}|${JSON.stringify(u)}|${Math.floor(now / 30_000)}`;
    if (key === this.key) return;
    this.key = key;
    clear(this.el);
    if (codex) this.drawCodex(State.codexPlanUsage, now);
    else this.drawClaude(State.planUsage, now);
  }

  private drawClaude(u: PlanUsage | null, now: number) {
    this.el.append(
      head(claudeColor(now), PLAN_TEXT.claudeTitle, claudeSubtitle(u, now)),
      h("div", { class: "plan-rows" },
        gaugeRow(PLAN_TEXT.fiveHours, u?.fiveHour, false, now),
        gaugeRow(PLAN_TEXT.week, u?.sevenDay, true, now),
      ),
    );
  }

  private drawCodex(u: CodexPlanUsage | null, now: number) {
    const rows = h("div", { class: "plan-rows" });
    // Codex plans without a 5-hour window show the week alone, as on the Mac.
    if (u?.fiveHour) rows.append(gaugeRow(PLAN_TEXT.fiveHours, u.fiveHour, false, now));
    rows.append(
      gaugeRow(PLAN_TEXT.week, u?.sevenDay, true, now),
      h("div", { class: "plan-row" },
        h("span", { class: "plan-label", text: PLAN_TEXT.resets }),
        h("span", { class: "plan-credits", text: codexResetsLabel(u) }),
      ),
    );
    this.el.append(head(codexColor(now), PLAN_TEXT.codexTitle, codexSubtitle(u, now)), rows);
  }
}
