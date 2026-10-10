// Plan usage gauges — the logic of ClaudePlanGauge.swift and CodexPlanGauge.swift
// on the Mac, with no DOM so it can be tested on its own. The pills and cards
// that show it are in views/usage.ts.
//
// Claude: the numbers come from Claude Code's own status line (`rate_limits` in
// what it hands its status line command), through the relay. Pro and Max only.
// Codex: the numbers come from the Codex CLI itself (`codex app-server`,
// `account/rateLimits/read`, the source of Codex's /status), asked by the app
// when the pill shows. Nothing is read from any credentials, nothing is fetched
// by Coucou itself.

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

export interface CodexPlanUsage extends PlanUsage {
  /** Free full resets available. */
  resetCredits?: number;
  /** Soonest expiry among the available ones (epoch ms). */
  resetCreditExpiresAt?: number;
  planType?: string;
}

import { dayMonth, t, weekdayShort } from "../i18n/i18n";

const DAY_MS = 86_400_000;

/** Every user-visible string of the gauges, in the current language (src/i18n). */
export const PLAN_TEXT = {
  get claudeTitle() { return t("Claude plan"); },
  get codexTitle() { return t("Codex plan"); },
  get claudePillTitle() { return t("Claude plan usage"); },
  get codexPillTitle() { return t("Codex plan usage"); },
  get waiting() { return t("Waiting for a response from Claude Code"); },
  get askingCodex() { return t("Asking Codex…"); },
  get justNow() { return t("just now"); },
  minAgo: (n: number) => t("{n} min ago", { n }),
  hAgo: (n: number) => t("{n} h ago", { n }),
  get fiveHours() { return t("5 hours"); },
  get week() { return t("Week"); },
  get resets() { return t("Resets"); },
  get resetting() { return t("Resetting…"); },
  inHM: (h: number, m: number) => t("in {h} h {m}", { h, m }),
  inM: (m: number) => t("in {m} min", { m }),
  available: (n: number) => t("{n} available", { n }),
  until: (date: string) => t(" · until {date}", { date }),
  none: "—",
};

const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

/**
 * Claude Code's `/usage` text → the plan's numbers:
 *   Current session: 13% used · resets Oct 10, 2:39pm (Asia/Kolkata)
 *   Current week (all models): 66% used · resets Oct 15, 4:29am (Asia/Kolkata)
 * Times are local. A reset without a date is today (tomorrow once past).
 */
export function parseUsageText(text: string, now = Date.now()): PlanUsage | null {
  const when = (raw: string): number | null => {
    const s = raw.replace(/\(.*?\)/g, "").trim();
    const m = /^(?:([A-Za-z]{3,9})\s+(\d{1,2}),?\s*)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)$/i.exec(s);
    if (!m) return null;
    const [, mon, day, hh, mm, ap] = m;
    let h = Number(hh) % 12;
    if (ap.toLowerCase() === "pm") h += 12;
    const base = new Date(now);
    const d = new Date(base.getFullYear(), base.getMonth(), base.getDate(), h, Number(mm ?? 0));
    if (mon) {
      const month = new Date(`${mon} 1, 2000`).getMonth();
      if (Number.isNaN(month)) return null;
      d.setMonth(month, Number(day));
      // December's reading of a January reset.
      if (d.getTime() < now - 86_400_000) d.setFullYear(d.getFullYear() + 1);
    } else if (d.getTime() < now) {
      d.setDate(d.getDate() + 1);
    }
    return d.getTime();
  };
  const read = (label: RegExp): PlanWindow | undefined => {
    const m = new RegExp(label.source + /[^:\n]*:\s*(\d{1,3})%\s*used(?:\s*·\s*resets\s*([^\n]+))?/.source, "i").exec(text);
    if (!m) return undefined;
    const resetsAt = m[2] ? when(m[2]) : null;
    return { usedPct: Math.min(100, Number(m[1])), resetsAt: resetsAt ?? now };
  };
  const fiveHour = read(/Current session/);
  const sevenDay = read(/Current week/);
  if (!fiveHour && !sevenDay) return null;
  return { fiveHour, sevenDay, updatedAt: now };
}
const asObj = (v: unknown): Record<string, unknown> | null =>
  v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;

// ── Claude ────────────────────────────────────────────────────────────────────

function parseClaudeWindow(raw: unknown, now: number): PlanWindow | undefined {
  const w = asObj(raw);
  const pct = w?.used_percentage;
  const epoch = w?.resets_at;
  if (!isNum(pct) || !isNum(epoch)) return undefined;
  // Anything outside 0–200 is not a percentage; 100–200 is a plan over its limit, shown full.
  if (pct < 0 || pct > 200) return undefined;
  // resets_at is epoch seconds. A date more than 400 days away is milliseconds in disguise.
  if (epoch <= 0 || epoch * 1000 > now + 400 * DAY_MS) return undefined;
  return { usedPct: Math.min(100, pct), resetsAt: epoch * 1000 };
}

/** ClaudePlanGauge.parse: `rate_limits` of a status line call, or null when it holds neither window. */
export function parseClaudePlan(rateLimits: unknown, now = Date.now()): PlanUsage | null {
  const rl = asObj(rateLimits);
  const fiveHour = parseClaudeWindow(rl?.five_hour, now);
  const sevenDay = parseClaudeWindow(rl?.seven_day, now);
  if (!fiveHour && !sevenDay) return null;
  const usage: PlanUsage = { updatedAt: now };
  if (fiveHour) usage.fiveHour = fiveHour;
  if (sevenDay) usage.sevenDay = sevenDay;
  return usage;
}

// ── Codex ─────────────────────────────────────────────────────────────────────

/**
 * CodexPlanGauge.parse: the result of `account/rateLimits/read`. `primary` and
 * `secondary` are not tied to a window, so they are sorted by duration: a day or
 * less is the 5-hour window, anything else (or no duration) the week.
 */
export function parseCodexPlan(result: unknown, now = Date.now()): CodexPlanUsage | null {
  const r = asObj(result);
  const limits = asObj(r?.rateLimits);
  if (!limits) return null;
  const usage: CodexPlanUsage = { updatedAt: now };
  if (typeof limits.planType === "string" && limits.planType) usage.planType = limits.planType;
  for (const key of ["primary", "secondary"]) {
    const w = asObj(limits[key]);
    if (!w || !isNum(w.usedPercent) || !isNum(w.resetsAt)) continue;
    const window: PlanWindow = {
      usedPct: Math.min(100, Math.max(0, w.usedPercent)),
      resetsAt: w.resetsAt * 1000,
    };
    if (Number.isInteger(w.windowDurationMins) && (w.windowDurationMins as number) <= 24 * 60) {
      usage.fiveHour = window;
    } else {
      usage.sevenDay = window;
    }
  }
  const credits = asObj(r?.rateLimitResetCredits);
  if (credits) {
    if (Number.isInteger(credits.availableCount)) usage.resetCredits = credits.availableCount as number;
    const expiries = (Array.isArray(credits.credits) ? credits.credits : [])
      .map(asObj)
      .filter((c) => c?.status === "available" && isNum(c.expiresAt))
      .map((c) => (c!.expiresAt as number) * 1000);
    if (expiries.length) usage.resetCreditExpiresAt = Math.min(...expiries);
  }
  return usage.fiveHour || usage.sevenDay ? usage : null;
}

// ── Shared ────────────────────────────────────────────────────────────────────

/** What to show for a window: 0 once its reset time has passed. */
export const effectivePct = (w: PlanWindow, now = Date.now()): number => (w.resetsAt <= now ? 0 : w.usedPct);

/** The higher of the two effective percentages; null when there are no windows. */
export function dominantPct(u: PlanUsage | null | undefined, now = Date.now()): number | null {
  const pcts = [u?.fiveHour, u?.sevenDay].filter((w): w is PlanWindow => !!w).map((w) => effectivePct(w, now));
  return pcts.length ? Math.max(...pcts) : null;
}

/** Green below 50 %, orange up to 80 %, red above, grey without data. */
export function planColor(pct: number | null): string {
  if (pct == null) return "#6B7079";
  if (pct < 50) return "#22C55E";
  if (pct < 80) return "#F59E0B";
  return "#F4505E";
}

/** "Claude 73%" / "Codex 12%" on the pill; "Claude —" while there are no numbers. */
export function pillLabel(name: "Claude" | "Codex", u: PlanUsage | null | undefined, now = Date.now()): string {
  const pct = dominantPct(u, now);
  return pct == null ? `${name} ${PLAN_TEXT.none}` : `${name} ${Math.round(pct)}%`;
}

/** "just now", "12 min ago", "3 h ago". */
export function ageLabel(updatedAt: number, now = Date.now()): string {
  const secs = (now - updatedAt) / 1000;
  if (secs < 60) return PLAN_TEXT.justNow;
  const mins = Math.floor(secs / 60);
  return mins < 60 ? PLAN_TEXT.minAgo(mins) : PLAN_TEXT.hAgo(Math.floor(mins / 60));
}

/** "in 1 h 20" / "in 5 min" for the 5-hour window, "Mon 9:00" for the week. */
export function resetLabel(w: PlanWindow, weekly: boolean, now = Date.now()): string {
  const secs = (w.resetsAt - now) / 1000;
  if (secs <= 0) return PLAN_TEXT.resetting;
  if (weekly) {
    const d = new Date(w.resetsAt);
    return `${weekdayShort(d.getDay())} ${d.getHours()}:${String(d.getMinutes()).padStart(2, "0")}`;
  }
  const hours = Math.floor(secs / 3600);
  const mins = Math.floor((secs % 3600) / 60);
  return hours > 0 ? PLAN_TEXT.inHM(hours, mins) : PLAN_TEXT.inM(mins);
}

/** The Claude card's subtitle. */
export function claudeSubtitle(u: PlanUsage | null, now = Date.now()): string {
  return u ? ageLabel(u.updatedAt, now) : PLAN_TEXT.waiting;
}

/** The Codex card's subtitle: "plus · 3 min ago". */
export function codexSubtitle(u: CodexPlanUsage | null, now = Date.now()): string {
  if (!u) return PLAN_TEXT.askingCodex;
  return (u.planType ? `${u.planType} · ` : "") + ageLabel(u.updatedAt, now);
}

/** "2 available · until Oct 9", or "—" when Codex said nothing about resets. */
export function codexResetsLabel(u: CodexPlanUsage | null): string {
  if (u?.resetCredits == null) return PLAN_TEXT.none;
  let text = PLAN_TEXT.available(u.resetCredits);
  if (u.resetCredits > 0 && u.resetCreditExpiresAt != null) {
    const d = new Date(u.resetCreditExpiresAt);
    text += PLAN_TEXT.until(dayMonth(d.getMonth(), d.getDate()));
  }
  return text;
}

/** How long a Codex answer stays good before the pill asks again (as on the Mac). */
export const CODEX_STALE_MS = 60_000;

/** True when the Codex numbers are missing or older than a minute. */
export const codexIsStale = (u: CodexPlanUsage | null, now = Date.now()): boolean =>
  !u || now - u.updatedAt >= CODEX_STALE_MS;

/** A stored Claude usage, if it still looks like one (the last numbers survive a restart). */
export function restorePlanUsage(raw: string | null): PlanUsage | null {
  if (!raw) return null;
  try {
    const v = asObj(JSON.parse(raw));
    if (!v || !isNum(v.updatedAt)) return null;
    const win = (w: unknown): PlanWindow | undefined => {
      const o = asObj(w);
      return o && isNum(o.usedPct) && isNum(o.resetsAt) && o.usedPct >= 0 && o.usedPct <= 100
        ? { usedPct: o.usedPct, resetsAt: o.resetsAt }
        : undefined;
    };
    const usage: PlanUsage = { updatedAt: v.updatedAt };
    const fh = win(v.fiveHour);
    const sd = win(v.sevenDay);
    if (fh) usage.fiveHour = fh;
    if (sd) usage.sevenDay = sd;
    return fh || sd ? usage : null;
  } catch {
    return null;
  }
}
