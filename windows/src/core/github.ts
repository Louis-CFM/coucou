// GitHub pulse and contribution grid — the pure half of the GitHub card.
// Port of the helpers around GitHubPulseCardView, GitHubDetailView and
// GitHubActivityDetailContent (IslandViewContent.swift), GitHubActivity.swift and
// AppState.handleGitHubEvents. No DOM here, so all of it is tested in Node.
//
// Parsing and alert detection happen in Rust (src-tauri/src/github.rs); this
// reads what Rust sends and turns it into what the card shows.

import { dayMonth, t, tn } from "../i18n/i18n";

export type CIState = "pending" | "success" | "failure" | "unknown";
export type ReviewState = "approved" | "changesRequested" | "pending" | "unknown";
export type GitHubSection = "myPRs" | "toReview" | "mainCI" | "activity";

export interface GitHubPR {
  /** "owner/repo#number" */
  id: string;
  title: string;
  url: string;
  repo: string;
  number: number;
  isDraft: boolean;
  ci: CIState;
  review: ReviewState;
  headSha: string | null;
}

export interface GitHubRepoCI {
  repo: string;
  url: string;
  branch: string;
  ci: CIState;
  headSha: string | null;
}

export interface GitHubPulse {
  login: string;
  myPRs: GitHubPR[];
  toReview: GitHubPR[];
  mainCI: GitHubRepoCI[];
  fetchedAt: number;
}

export interface ContributionDay {
  /** YYYY-MM-DD */
  date: string;
  count: number;
  /** 0…4 */
  level: number;
  /** 0 = Sunday … 6 = Saturday */
  weekday: number;
}

export interface GitHubActivity {
  total: number;
  /** Oldest week first; the last one is usually incomplete. */
  weeks: ContributionDay[][];
  fetchedAt: number;
}

export interface GitHubStats {
  totalRepos: number;
  totalStars: number;
}

export type GitHubEvent =
  | { kind: "ciFailed"; prId: string }
  | { kind: "ciPassed"; prId: string }
  | { kind: "mainFailed"; repo: string }
  | { kind: "reviewRequested"; prId: string };

/** Every word the GitHub card shows, in the current language (src/i18n). */
export const GH_STRINGS = {
  title: "GitHub",
  get overview() { return t("Overview"); },
  get totalStars() { return t("Total stars"); },
  get repositories() { return t("Repositories"); },
  get myPRs() { return t("My PRs"); },
  get toReview() { return t("To review"); },
  get mainCI() { return t("Default branch CI"); },
  get activity() { return t("Activity"); },
  get nothingHere() { return t("Nothing here"); },
  get loading() { return t("Loading…"); },
  get draft() { return t("Draft"); },
  get failing() { return t("failing"); },
  get running() { return t("running"); },
  get passing() { return t("passing"); },
  get allGreen() { return t("all green"); },
  get noRepos() { return t("no repos"); },
  get unknown() { return t("unknown"); },
  get noContributions() { return t("No contributions"); },
  get oneContribution() { return tn("{count} contribution", "{count} contributions", 1); },
  contributions: (n: number) => tn("{count} contribution", "{count} contributions", n),
  pastYear: (total: string) => t("{total} past year", { total }),
  repos: (n: number) => tn("{count} repo", "{count} repos", n),
};

export const CI_COLORS: Record<CIState, string> = {
  failure: "#F4505E",
  pending: "#F5A524",
  success: "#22C55E",
  unknown: "#6B7079",
};

/** contributionColor() — GitHub's dark-theme greens, empty days barely visible. */
export function contributionColor(level: number): string {
  switch (level) {
    case 1: return "#0E4429";
    case 2: return "#006D32";
    case 3: return "#26A641";
    case 4: return "#39D353";
    default: return "rgba(255,255,255,0.06)";
  }
}

// ── Reading what Rust sent ────────────────────────────────────────────────────

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v != null;

export function readPulse(data: Record<string, unknown>): GitHubPulse | null {
  const p = data.pulse;
  if (!isObj(p) || !Array.isArray(p.myPRs) || !Array.isArray(p.toReview) || !Array.isArray(p.mainCI)) {
    return null;
  }
  return p as unknown as GitHubPulse;
}

export function readActivity(data: Record<string, unknown>): GitHubActivity | null {
  const a = data.activity;
  if (!isObj(a) || !Array.isArray(a.weeks) || typeof a.total !== "number") return null;
  return a as unknown as GitHubActivity;
}

export function readStats(data: Record<string, unknown>): GitHubStats | null {
  if (data.totalRepos == null) return null;
  return { totalRepos: Number(data.totalRepos ?? 0), totalStars: Number(data.totalStars ?? 0) };
}

// ── Card summaries ────────────────────────────────────────────────────────────

/** ciWorstState / mainCIWorst: failure > pending > success > unknown. */
export function worstCI(states: CIState[]): CIState {
  if (states.includes("failure")) return "failure";
  if (states.includes("pending")) return "pending";
  if (states.includes("success")) return "success";
  return "unknown";
}

/** "My PRs" value: count, plus how many fail or that some are still running. */
export function myPRsValue(prs: GitHubPR[]): string {
  const n = prs.length;
  if (n === 0) return "0";
  const failing = prs.filter((p) => p.ci === "failure").length;
  if (failing > 0) return `${n} · ${failing} ${GH_STRINGS.failing}`;
  if (prs.some((p) => p.ci === "pending")) return `${n} · ${GH_STRINGS.running}`;
  return String(n);
}

/** The "Default branch CI" row: which icon, its colour and the value. */
export function mainCISummary(repos: GitHubRepoCI[]): { failing: boolean; color: string; value: string } {
  const worst = worstCI(repos.map((r) => r.ci));
  switch (worst) {
    case "failure": {
      const n = repos.filter((r) => r.ci === "failure").length;
      return { failing: true, color: CI_COLORS.failure, value: `${n} ${GH_STRINGS.failing}` };
    }
    case "pending":
      return { failing: false, color: CI_COLORS.pending, value: GH_STRINGS.running };
    case "success":
      return { failing: false, color: CI_COLORS.success, value: GH_STRINGS.allGreen };
    default:
      return {
        failing: false,
        color: CI_COLORS.unknown,
        value: repos.length === 0 ? GH_STRINGS.noRepos : GH_STRINGS.unknown,
      };
  }
}

/** The word at the end of a default-branch row; nothing when unknown. */
export function ciWord(ci: CIState): string | null {
  switch (ci) {
    case "failure": return GH_STRINGS.failing;
    case "pending": return GH_STRINGS.running;
    case "success": return GH_STRINGS.passing;
    default: return null;
  }
}

export function sectionTitle(section: GitHubSection): string {
  return GH_STRINGS[section];
}

/** "1.2k" above a thousand, like the Mac's formatCount. */
export function formatCount(n: number): string {
  return n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n);
}

/** "owner/repo" → "repo". */
export function shortRepo(repo: string): string {
  return repo.split("/").pop() || repo;
}

// ── Links ─────────────────────────────────────────────────────────────────────

/** Only http(s) links to github.com open, like safeWebURL + the host check on macOS. */
export function safeGitHubUrl(raw: string): string | null {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  if (url.hostname !== "github.com") return null;
  return url.toString();
}

/** A repository's Actions page, where a red default branch is explained. */
export function actionsUrl(repoUrl: string): string {
  return repoUrl.endsWith("/") ? `${repoUrl}actions` : `${repoUrl}/actions`;
}

export function profileUrl(login: string): string {
  return `https://github.com/${encodeURIComponent(login)}`;
}

// ── Contribution grid ─────────────────────────────────────────────────────────

/** 7 pt squares, 1.5 pt apart, in the 202 pt the card has: 23 weeks. */
export const GRID_SQUARE = 7;
export const GRID_GAP = 1.5;
export const GRID_WEEKS = Math.floor((202 + GRID_GAP) / (GRID_SQUARE + GRID_GAP));

/** The last `n` weeks, oldest first; the last may be incomplete. */
export function lastWeeks(activity: GitHubActivity, n: number): ContributionDay[][] {
  if (n <= 0) return [];
  return activity.weeks.slice(Math.max(0, activity.weeks.length - n));
}

/** The last `n` days, oldest first. */
export function lastDays(activity: GitHubActivity, n: number): ContributionDay[] {
  if (n <= 0) return [];
  const all = activity.weeks.flat();
  return all.slice(Math.max(0, all.length - n));
}

/** One column of the grid: seven slots, Sunday first, null where a day is missing. */
export function weekColumn(week: ContributionDay[]): (ContributionDay | null)[] {
  return Array.from({ length: 7 }, (_, dow) => week.find((d) => d.weekday === dow) ?? null);
}

/** "2026-01-05" → "Jan 5"; anything else is returned as is. */
export function dayLabel(date: string): string {
  const parts = date.split("-");
  if (parts.length !== 3) return date;
  const month = Number(parts[1]);
  const day = Number(parts[2]);
  if (!Number.isInteger(month) || month < 1 || month > 12 || !Number.isInteger(day)) return date;
  return dayMonth(month - 1, day);
}

export function contributionsLabel(count: number): string {
  if (count === 0) return GH_STRINGS.noContributions;
  if (count === 1) return GH_STRINGS.oneContribution;
  return GH_STRINGS.contributions(count);
}

/** 1234 → "1,234", whatever the system locale. */
export function totalLabel(n: number): string {
  return n.toLocaleString("en-US");
}

/** Right side of the Activity header: the picked day, or the year's total. */
export function activityHeader(
  activity: GitHubActivity | null,
  stats: GitHubStats | null,
  picked: ContributionDay | null,
): string {
  if (picked) return `${dayLabel(picked.date)} · ${contributionsLabel(picked.count)}`;
  if (!activity) return "";
  const total = GH_STRINGS.pastYear(totalLabel(activity.total));
  return stats ? `${total} · ${GH_STRINGS.repos(stats.totalRepos)}` : total;
}

// ── Alerts ────────────────────────────────────────────────────────────────────

export interface GitHubAlert {
  badge: "error" | "finished";
  sound: "error" | "question" | "finish";
}

/** handleGitHubEvents: the loudest event wins — red CI > review request > green CI. */
export function gitHubAlert(events: GitHubEvent[]): GitHubAlert | null {
  let level = 0;
  let alert: GitHubAlert | null = null;
  for (const e of events) {
    switch (e.kind) {
      case "ciFailed":
      case "mainFailed":
        if (level < 3) { level = 3; alert = { badge: "error", sound: "error" }; }
        break;
      case "reviewRequested":
        if (level < 2) { level = 2; alert = { badge: "finished", sound: "question" }; }
        break;
      case "ciPassed":
        if (level < 1) { level = 1; alert = { badge: "finished", sound: "finish" }; }
        break;
    }
  }
  return alert;
}
