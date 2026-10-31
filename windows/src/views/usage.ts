// Plan usage in the island: the Claude and Codex pills in the header and the
// card behind each. Same behaviour as ClaudePlanHeaderPill, ClaudePlanCardView
// and CodexPlanCardView on the Mac; the numbers and labels come from
// core/plan.ts.
//
// The pills sit in the header's right side, before the gear, on the overview
// only, Claude first. Clicking one puts its card in place of the overview's
// left card (clicking it again, or the other pill, closes or swaps it), and
// Mochi wears the plan's colour while it is open. It closes when the view, the
// mode or the focused pill changes.

import { Bridge, onEvent } from "../core/bridge";
import {
  PLAN_TEXT, claudeSubtitle, codexIsStale, codexResetsLabel, codexSubtitle, dominantPct,
  effectivePct, parseCodexPlan, pillLabel, planColor, resetLabel,
  type CodexPlanUsage, type PlanUsage, type PlanWindow,
} from "../core/plan";
import { State } from "../core/state";
import { clear, dot, h, svg } from "./dom";
import { ICONS } from "./icons";
import { language, tl } from "../i18n/i18n";

/** Numbers to show: a pill with nothing but dashes is not shown at all. */
function hasNumbers(u: PlanUsage | null | undefined): boolean {
  return !!u && (u.fiveHour != null || u.sevenDay != null);
}

/** The Claude pill is in the header: overview, turned on, and numbers came (from
 * the status line relay or the Claude desktop app). */
export function claudePillVisible(): boolean {
  return State.view === "overview" && State.settings.showPlanInNotch && hasNumbers(State.planUsage);
}

/** The compact island's Claude plan gauge: compact mode, turned on, relay in. */
export function claudeCompactPillVisible(): boolean {
  const s = State.settings;
  return State.mode === "compact" && s.showPlanInCompactIsland && s.planRelayInstalled;
}

/** The Codex pill is in the header: overview, turned on, and Codex answered with numbers. */
export function codexPillVisible(): boolean {
  return State.view === "overview" && State.settings.showCodexPlanInNotch && hasNumbers(State.codexPlanUsage);
}

/** A plan card is open and either of its pills (header or compact) is enabled. */
export function planCardOpen(): boolean {
  if (!State.showingPlanDetail) return false;
  if (State.planDetailIsCodex) return codexPillVisible();
  // The header pill's card needs numbers (no card of dashes); the compact gauge's, its relay.
  const s = State.settings;
  return claudePillVisible() || (State.view === "overview" && s.showPlanInCompactIsland && s.planRelayInstalled);
}

const claudeColor = (now = Date.now()) => planColor(dominantPct(State.planUsage, now));
const codexColor = (now = Date.now()) => planColor(dominantPct(State.codexPlanUsage, now));

/** The colour of the open card's plan, which Mochi wears while it is open. */
export function openPlanColor(): string {
  return State.planDetailIsCodex ? codexColor() : claudeColor();
}

/** Closes the plan card (view, mode or focus changed). */
export function closePlanCard(): void {
  State.showingPlanDetail = false;
}

// ── Claude numbers ────────────────────────────────────────────────────────────

const STORE_KEY = "coucou.claudePlanUsage";

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

// ── Claude numbers from the Claude desktop app ────────────────────────────────

const FIVE_HOURS = 5 * 3_600_000;
const WEEK = 7 * 86_400_000;

/**
 * The Claude desktop app's latest sample, when it is newer than what the
 * status line said. Its samples carry no reset times: a window whose sample is
 * older than the window itself is shown as reset.
 */
export async function refreshClaudeDesktopPlan(now = Date.now()): Promise<void> {
  if (State.paused) return;
  const p = await Bridge.claudeDesktopPlan();
  if (!p) return;
  if (State.planUsage && State.planUsage.updatedAt > p.at && State.planUsage.fiveHour?.resetsAt !== 0) return;
  const age = now - p.at;
  const usage: PlanUsage = { updatedAt: p.at };
  if (p.fiveHour != null) usage.fiveHour = { usedPct: age > FIVE_HOURS ? 0 : p.fiveHour, resetsAt: 0 };
  if (p.sevenDay != null) usage.sevenDay = { usedPct: age > WEEK ? 0 : p.sevenDay, resetsAt: 0 };
  if (usage.fiveHour || usage.sevenDay) setClaudePlanUsage(usage);
}

/** An RFC 3339 time as epoch ms, or 0: unknown. */
const epochOf = (at: string | null) => {
  const ms = at ? Date.parse(at) : NaN;
  return Number.isFinite(ms) ? ms : 0;
};

/**
 * The plan's use right now, from Anthropic with Claude Code's sign-in. False
 * when there is none to use (not signed in, expired, offline): the Claude
 * app's record is read instead.
 */
export async function refreshClaudeLivePlan(now = Date.now()): Promise<boolean> {
  const p = await Bridge.claudeLivePlan();
  if (!p) return false;
  const usage: PlanUsage = { updatedAt: now };
  if (p.fiveHour != null) usage.fiveHour = { usedPct: p.fiveHour, resetsAt: epochOf(p.fiveHourResetsAt) };
  if (p.sevenDay != null) usage.sevenDay = { usedPct: p.sevenDay, resetsAt: epochOf(p.sevenDayResetsAt) };
  if (!usage.fiveHour && !usage.sevenDay) return false;
  setClaudePlanUsage(usage);
  return true;
}

/** The freshest numbers there are: live when Claude Code is signed in, else the Claude app's record. */
async function refreshClaudePlan(): Promise<void> {
  if (State.paused) return;
  if (await refreshClaudeLivePlan()) return;
  await refreshClaudeDesktopPlan();
}

/** Now, and every minute: the gauge follows the plan as it is used. */
export function startClaudeDesktopPlan(): void {
  void refreshClaudePlan();
  // claude.ai just answered (claude_account.rs): shown at once, not at the next minute.
  void onEvent("claude-usage", () => void refreshClaudePlan());
  window.setInterval(() => void refreshClaudePlan(), 60_000);
}

// ── Codex numbers ─────────────────────────────────────────────────────────────

let codexInFlight = false;
/** No Codex here (or no answer): asked again ten minutes later, not on every look. */
let codexFailedAt = 0;

/**
 * Asks Codex again when the numbers are missing or older than a minute. Only
 * from the pill (shown or clicked), never on a timer, and never while paused:
 * `codex app-server` talks to Codex's own service.
 */
export function refreshCodexPlanUsage(): void {
  if (codexInFlight || State.paused || !codexIsStale(State.codexPlanUsage)) return;
  if (Date.now() - codexFailedAt < 10 * 60_000) return;
  codexInFlight = true;
  void Bridge.codexPlanUsage()
    .then((result) => {
      const usage = parseCodexPlan(result);
      if (usage) {
        State.codexPlanUsage = usage;
        State.notify();
      } else {
        codexFailedAt = Date.now();
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
      const text = codex ? pillLabel("Codex", State.codexPlanUsage) : pillLabel("Claude", State.planUsage);
      if (label.textContent !== text) label.textContent = text;
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
