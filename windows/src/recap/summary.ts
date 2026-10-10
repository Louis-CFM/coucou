// Weekly recap — pure aggregation, port of RecapStore.weeklySummary.
// Rust (src-tauri/src/recap.rs) records the turns; this file turns them into
// one week's numbers. It lives on the JavaScript side because weeks, days and
// "Monday 8 am" are local time, and the webview knows the user's time zone.
// No DOM, no Tauri: tests/recap.test.mjs runs it as it is.

import { N_, dayMonth, t } from "../i18n/i18n";

/** One finished turn, as recap.rs stores it. Times are Unix seconds. */
export interface RecapTurn {
  agent: string;
  project: string;
  start: number;
  end: number;
  filesChanged: number;
  linesAdded: number;
  linesRemoved: number;
  commandsRun: number;
  questions: number;
}

export interface RecapDecision {
  agent: string;
  date: number;
  decision: string;
}

export interface RecapPrefs {
  enabled: boolean;
  hideProjects: boolean;
  /** Monday (YYYY-MM-DD) of the week the recap last opened on its own. */
  lastShownWeek: string;
}

export interface RecapHistory {
  turns: RecapTurn[];
  decisions: RecapDecision[];
  prefs: RecapPrefs;
}

export interface WeeklySummary {
  weekStart: Date;
  /** Last second of the week (Sunday 23:59:59). */
  weekEnd: Date;
  totalMinutes: number;
  sessionCount: number;
  filesChanged: number;
  linesAdded: number;
  linesRemoved: number;
  commandsRun: number;
  questions: number;
  permissionsAllowed: number;
  permissionsDenied: number;
  /** Display name. */
  topAgent: string | null;
  topProject: string | null;
  busiestDay: string | null;
  longestSessionMinutes: number;
}

export const DEFAULT_PREFS: RecapPrefs = { enabled: true, hideProjects: false, lastShownWeek: "" };

// ── Weeks (ISO 8601: Monday to Sunday, local time) ────────────────────────────

/** Local midnight `n` days after `d`'s date — DST-safe, unlike adding ms. */
export function addDays(d: Date, n: number): Date {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
}

/** Monday 00:00 (local) of the week holding `d`. */
export function mondayOf(d: Date): Date {
  const sinceMonday = (d.getDay() + 6) % 7;
  return addDays(d, -sinceMonday);
}

/** Monday 00:00 of the last completed week. */
export function previousWeekStart(now: Date): Date {
  return addDays(mondayOf(now), -7);
}

/** YYYY-MM-DD of a local date. */
export function dayKey(d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** The Monday recap opens on its own once per week, from 8 am on. */
export const RECAP_HOUR = 8;

export function shouldAutoShow(now: Date, lastShownWeek: string): boolean {
  return now.getDay() === 1 && now.getHours() >= RECAP_HOUR && dayKey(mondayOf(now)) !== lastShownWeek;
}

// ── Aggregation ───────────────────────────────────────────────────────────────

/** English names, kept in the summary; shown with `t()` (src/i18n). */
const DAY_NAMES = [N_("Sunday"), N_("Monday"), N_("Tuesday"), N_("Wednesday"), N_("Thursday"), N_("Friday"), N_("Saturday")];

/** Pill IDs → names, from PillCatalog.swift. Claude Code hooks come from any
 *  terminal here, so its pill reads "Claude Code" rather than "VS Code". */
const AGENT_NAMES: Record<string, string> = {
  integration_claude: "Claude Code",
  agent_cursor: "Cursor",
  agent_phpstorm: "PhpStorm",
  agent_antigravity: "Antigravity",
  agent_codex: "Codex",
  agent_gemini: "Gemini CLI",
  agent_copilot: "Copilot CLI",
  agent_muse: "Muse Code",
  agent_opencode: "OpenCode",
  agent_amp: "Amp",
  agent_hermes: "Hermes",
  "agent_claude-desktop": "Claude Desktop",
};

export function agentName(id: string): string {
  const known = AGENT_NAMES[id];
  if (known) return known;
  const raw = id.replace(/^agent_/, "");
  return raw ? raw.charAt(0).toUpperCase() + raw.slice(1) : id;
}

/** The most frequent key; ties go to whatever `order` ranks first. */
function topKey<K>(counts: Map<K, number>, order: (a: K, b: K) => number): K | null {
  let best: K | null = null;
  let bestCount = 0;
  for (const [key, n] of counts) {
    if (n > bestCount || (n === bestCount && best !== null && order(key, best) < 0)) {
      best = key;
      bestCount = n;
    }
  }
  return best;
}

/** Wall time covered by the turns, overlapping ones counted once. Seconds. */
export function mergedSeconds(turns: RecapTurn[]): number {
  const sorted = turns.filter((t) => t.end > t.start).sort((a, b) => a.start - b.start);
  let total = 0;
  let segStart = 0;
  let segEnd = -Infinity;
  for (const t of sorted) {
    if (t.start <= segEnd) {
      segEnd = Math.max(segEnd, t.end);
    } else {
      if (segEnd > segStart) total += segEnd - segStart;
      segStart = t.start;
      segEnd = t.end;
    }
  }
  if (segEnd > segStart) total += segEnd - segStart;
  return total;
}

/** The week starting at `weekStart` (a local Monday 00:00), or null when nothing ran. */
export function summarize(history: RecapHistory, weekStart: Date): WeeklySummary | null {
  const end = addDays(weekStart, 7);
  const from = weekStart.getTime() / 1000;
  const to = end.getTime() / 1000;
  const turns = history.turns.filter((t) => t.start >= from && t.start < to);
  if (turns.length === 0) return null;
  const decisions = history.decisions.filter((d) => d.date >= from && d.date < to);
  const sum = (f: (t: RecapTurn) => number) => turns.reduce((n, t) => n + f(t), 0);

  const byAgent = new Map<string, number>();
  const byProject = new Map<string, number>();
  const byDay = new Map<number, number>();
  for (const t of turns) {
    byAgent.set(t.agent, (byAgent.get(t.agent) ?? 0) + 1);
    if (t.project) byProject.set(t.project, (byProject.get(t.project) ?? 0) + 1);
    const day = new Date(t.start * 1000).getDay();
    byDay.set(day, (byDay.get(day) ?? 0) + 1);
  }
  const byName = (a: string, b: string) => a.localeCompare(b);
  // Ties go to the earlier day of the (Monday-first) week.
  const byWeekOrder = (a: number, b: number) => ((a + 6) % 7) - ((b + 6) % 7);
  const topAgent = topKey(byAgent, byName);
  const busiest = topKey(byDay, byWeekOrder);
  const longest = Math.max(0, ...turns.map((t) => t.end - t.start));

  return {
    weekStart,
    weekEnd: new Date(end.getTime() - 1000),
    totalMinutes: Math.floor(mergedSeconds(turns) / 60),
    sessionCount: turns.length,
    filesChanged: sum((t) => t.filesChanged),
    linesAdded: sum((t) => t.linesAdded),
    linesRemoved: sum((t) => t.linesRemoved),
    commandsRun: sum((t) => t.commandsRun),
    questions: sum((t) => t.questions),
    permissionsAllowed: decisions.filter((d) => d.decision === "allow" || d.decision === "always").length,
    permissionsDenied: decisions.filter((d) => d.decision === "deny").length,
    topAgent: topAgent === null ? null : agentName(topAgent),
    topProject: topKey(byProject, byName),
    busiestDay: busiest === null ? null : DAY_NAMES[busiest],
    longestSessionMinutes: Math.floor(longest / 60),
  };
}

// ── Formatting ────────────────────────────────────────────────────────────────

export function formatDuration(minutes: number): string {
  if (minutes < 60) return t("{n}m", { n: minutes });
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m === 0 ? t("{n}h", { n: h }) : t("{h}h {m}m", { h, m });
}

/** 1234 → "1,234"; 12345 → "12.3k" — keeps a stat chip narrow. */
export function formatCount(n: number): string {
  if (n >= 10_000) return `${(n / 1000).toFixed(n >= 100_000 ? 0 : 1)}k`;
  return n.toLocaleString("en-US");
}

/** "Sep 28 – Oct 4". */
export function weekRangeLabel(s: Pick<WeeklySummary, "weekStart" | "weekEnd">): string {
  const f = (d: Date) => dayMonth(d.getMonth(), d.getDate());
  return `${f(s.weekStart)} – ${f(s.weekEnd)}`;
}

// ── Sample week ───────────────────────────────────────────────────────────────

/**
 * The fake week of scripts/test-weekly-recap.swift, starting on `monday`.
 * Used by the tests and by `npm run dev` in a plain browser, where there is
 * no Rust side to read a history from.
 */
export function sampleHistory(monday: Date): RecapHistory {
  const at = (day: number, hour: number, minute = 0) =>
    Math.floor(new Date(monday.getFullYear(), monday.getMonth(), monday.getDate() + day, hour, minute).getTime() / 1000);
  const turn = (
    agent: string, project: string, start: number, end: number,
    filesChanged: number, linesAdded: number, linesRemoved: number, commandsRun: number, questions: number,
  ): RecapTurn => ({ agent, project, start, end, filesChanged, linesAdded, linesRemoved, commandsRun, questions });
  const claude = "integration_claude";
  return {
    turns: [
      turn(claude, "coucou", at(0, 9), at(0, 11, 30), 8, 312, 87, 14, 2),
      turn(claude, "coucou", at(0, 14), at(0, 15, 45), 3, 95, 20, 5, 0),
      turn("agent_gemini", "side-project", at(1, 10), at(1, 11), 2, 50, 10, 3, 1),
      turn(claude, "coucou", at(2, 9, 30), at(2, 12), 5, 180, 60, 8, 3),
      turn(claude, "coucou", at(3, 16), at(3, 17), 1, 40, 5, 2, 0),
      turn(claude, "coucou", at(4, 8), at(4, 13), 12, 540, 130, 22, 5),
    ],
    decisions: [
      { agent: claude, date: at(0, 9, 30), decision: "allow" },
      { agent: claude, date: at(0, 10), decision: "allow" },
      { agent: claude, date: at(2, 10), decision: "deny" },
      { agent: claude, date: at(4, 9), decision: "always" },
      { agent: claude, date: at(4, 10), decision: "allow" },
    ],
    prefs: { ...DEFAULT_PREFS },
  };
}
