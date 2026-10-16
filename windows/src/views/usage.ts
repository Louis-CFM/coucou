// Plan usage in the island: Claude, Codex, Cursor and Kiro pills in the header
// and the card behind each. Claude/Codex match the Mac; Cursor/Kiro read their
// CLI `/usage` (no home card).
//
// The pills sit in the header's right side, before the gear, on the overview
// only. Clicking one puts its card in place of the overview's left card.

import { Bridge, type CursorPlanUsage, type KiroPlanUsage } from "../core/bridge";
import {
  PLAN_TEXT, claudeSubtitle, codexIsStale, codexResetsLabel, codexSubtitle, dominantPct,
  effectivePct, parseCodexPlan, pillLabel, planColor, resetLabel,
  type CodexPlanUsage, type PlanUsage, type PlanWindow,
} from "../core/plan";
import { State } from "../core/state";
import { clear, dot, h, svg } from "./dom";
import { ICONS } from "./icons";
import { language, t } from "../i18n/i18n";

export type PlanKind = "claude" | "codex" | "cursor" | "kiro";

/** The Claude pill is in the header: overview, turned on, relay in. */
export function claudePillVisible(): boolean {
  const s = State.settings;
  return State.view === "overview" && s.showPlanInNotch && s.planRelayInstalled;
}

/** The Codex pill is in the header: overview, turned on (nothing to install). */
export function codexPillVisible(): boolean {
  return State.view === "overview" && State.settings.showCodexPlanInNotch;
}

/** Cursor pill: overview, toggle on, and the Cursor plan turned on in Chat. */
export function cursorPillVisible(): boolean {
  return State.view === "overview"
    && State.settings.showCursorPlanInNotch
    && State.settings.planChats.includes("cursor");
}

/** Kiro pill: overview, toggle on, and the Kiro plan turned on in Chat. */
export function kiroPillVisible(): boolean {
  return State.view === "overview"
    && State.settings.showKiroPlanInNotch
    && State.settings.planChats.includes("kiro");
}

function kindVisible(kind: PlanKind): boolean {
  switch (kind) {
    case "claude": return claudePillVisible();
    case "codex": return codexPillVisible();
    case "cursor": return cursorPillVisible();
    case "kiro": return kiroPillVisible();
  }
}

/** A plan card is open and its pill is still there. */
export function planCardOpen(): boolean {
  const kind = State.planDetailKind;
  if (!State.showingPlanDetail || !kind) return false;
  return kindVisible(kind);
}

const claudeColor = (now = Date.now()) => planColor(dominantPct(State.planUsage, now));
const codexColor = (now = Date.now()) => planColor(dominantPct(State.codexPlanUsage, now));
const cursorColor = () => planColor(State.cursorPlanUsage?.percent ?? 0);
const kiroColor = () => {
  const u = State.kiroPlanUsage;
  if (!u || u.limit <= 0) return planColor(0);
  return planColor(Math.min(100, (u.used / u.limit) * 100));
};

function kindColor(kind: PlanKind, now = Date.now()): string {
  switch (kind) {
    case "claude": return claudeColor(now);
    case "codex": return codexColor(now);
    case "cursor": return cursorColor();
    case "kiro": return kiroColor();
  }
}

/** The colour of the open card's plan, which Mochi wears while it is open. */
export function openPlanColor(): string {
  return kindColor(State.planDetailKind ?? "claude");
}

/** Closes the plan card (view, mode or focus changed). */
export function closePlanCard(): void {
  State.showingPlanDetail = false;
  State.planDetailKind = null;
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

// ── Codex / Cursor / Kiro refresh ─────────────────────────────────────────────

let codexInFlight = false;
let cliInFlight = false;

/**
 * Asks Codex again when the numbers are missing or older than a minute. Only
 * from the pill (shown or clicked), never on a timer, and never while paused.
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

const CLI_STALE_MS = 60_000;

/** Cursor and Kiro `/usage` when a pill is shown and numbers are stale. */
export function refreshCliPlanUsage(): void {
  const wantsCursor = cursorPillVisible();
  const wantsKiro = kiroPillVisible();
  if (cliInFlight || State.paused || (!wantsCursor && !wantsKiro)) return;
  if (State.cliPlanFetchedAt && Date.now() - State.cliPlanFetchedAt < CLI_STALE_MS) return;
  cliInFlight = true;
  void Bridge.planUsage()
    .then((result) => {
      if (!result) return;
      State.cursorPlanUsage = result.cursor;
      State.kiroPlanUsage = result.kiro;
      State.cliPlanFetchedAt = Date.now();
      State.notify();
    })
    .finally(() => {
      cliInFlight = false;
    });
}

// ── Pill ──────────────────────────────────────────────────────────────────────

export interface PlanPill {
  el: HTMLElement;
  sync(): void;
}

const KIND_TITLE: Record<PlanKind, () => string> = {
  claude: () => t("Claude plan usage"),
  codex: () => t("Codex plan usage"),
  cursor: () => t("Cursor plan usage"),
  kiro: () => t("Kiro plan usage"),
};

/** One pill: colour dot and label, lit while hovered or while its card is open. */
export function buildPlanPill(kind: PlanKind): PlanPill {
  const label = h("span", { class: "plan-pill-label" });
  const dotEl = h("i", { class: "plan-pill-dot" });
  const isOpen = () => State.showingPlanDetail && State.planDetailKind === kind;
  const el = h("button", {
    class: "plan-pill",
    title: KIND_TITLE[kind](),
    onclick: () => {
      const open = isOpen();
      State.planDetailKind = kind;
      State.showingPlanDetail = !open;
      if (kind === "codex") refreshCodexPlanUsage();
      if (kind === "cursor" || kind === "kiro") refreshCliPlanUsage();
      State.notify();
    },
  }, dotEl, label);
  return {
    el,
    sync() {
      const color = kindColor(kind);
      el.style.setProperty("--plan", color);
      el.classList.toggle("active", isOpen());
      el.title = KIND_TITLE[kind]();
      dotEl.style.background = color;
      if (kind === "claude") label.textContent = pillLabel("Claude", State.planUsage);
      else if (kind === "codex") label.textContent = pillLabel("Codex", State.codexPlanUsage);
      else if (kind === "cursor") {
        const u = State.cursorPlanUsage;
        label.textContent = u ? `Cursor ${Math.round(u.percent)}%` : "Cursor";
      } else {
        const u = State.kiroPlanUsage;
        label.textContent = u && u.limit > 0
          ? `Kiro ${Math.round((u.used / u.limit) * 100)}%`
          : "Kiro";
      }
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

function pctRow(label: string, pct: number | null | undefined, reset: string): HTMLElement {
  const row = h("div", { class: "plan-row" }, h("span", { class: "plan-label", text: label }));
  if (pct == null || !Number.isFinite(pct)) {
    row.append(h("span", { class: "plan-none", text: PLAN_TEXT.none }));
    return row;
  }
  const fill = h("i", { class: "plan-fill" });
  fill.style.width = `${Math.min(100, pct)}%`;
  fill.style.background = planColor(pct);
  row.append(
    h("span", { class: "plan-bar" }, fill),
    h("span", { class: "plan-pct", text: `${Math.round(pct)}%` }),
    h("span", { class: "plan-reset-icon" }, svg(ICONS.arrowClockwise, 8, { stroke: 2.6 })),
    h("span", { class: "plan-reset", text: reset || PLAN_TEXT.none }),
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
    const kind = State.planDetailKind ?? "claude";
    const key = `${language()}|${kind}|${JSON.stringify({
      claude: State.planUsage,
      codex: State.codexPlanUsage,
      cursor: State.cursorPlanUsage,
      kiro: State.kiroPlanUsage,
    })}|${Math.floor(now / 30_000)}`;
    if (key === this.key) return;
    this.key = key;
    clear(this.el);
    switch (kind) {
      case "codex": this.drawCodex(State.codexPlanUsage, now); break;
      case "cursor": this.drawCursor(State.cursorPlanUsage); break;
      case "kiro": this.drawKiro(State.kiroPlanUsage); break;
      default: this.drawClaude(State.planUsage, now); break;
    }
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

  private drawCursor(u: CursorPlanUsage | null) {
    const sub = u ? `${u.plan}${u.resets ? ` · ${u.resets}` : ""}` : t("Asking Cursor…");
    const rows = h("div", { class: "plan-rows" },
      pctRow(t("Included"), u?.percent ?? null, u?.resets ?? ""),
    );
    if (u?.auto != null) rows.append(pctRow(t("Auto"), u.auto, ""));
    if (u?.api != null) rows.append(pctRow(t("API"), u.api, ""));
    this.el.append(head(cursorColor(), t("Cursor plan"), sub), rows);
  }

  private drawKiro(u: KiroPlanUsage | null) {
    const pct = u && u.limit > 0 ? (u.used / u.limit) * 100 : null;
    const sub = u ? `${u.plan}${u.resets ? ` · ${u.resets}` : ""}` : t("Asking Kiro…");
    const credits = u
      ? `${u.used.toLocaleString(undefined, { maximumFractionDigits: 2 })} / ${u.limit.toLocaleString(undefined, { maximumFractionDigits: 0 })}`
      : PLAN_TEXT.none;
    this.el.append(
      head(kiroColor(), t("Kiro plan"), sub),
      h("div", { class: "plan-rows" },
        pctRow(t("Credits"), pct, u?.resets ?? ""),
        h("div", { class: "plan-row" },
          h("span", { class: "plan-label", text: PLAN_TEXT.resets }),
          h("span", { class: "plan-credits", text: credits }),
        ),
      ),
    );
  }
}
