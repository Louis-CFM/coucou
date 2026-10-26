// What's new after an update, and the blue Mochi while one waits — the rules,
// pure, so tests/whats-new.test.mjs checks them. The island side is in
// controller.ts, the card in views/whatsnew.ts.
//
// The entries come from whats-new.json, one per Windows and Linux release, in
// the 12 languages (scripts/test-whats-new.py refuses a release without its
// entry). Nothing here goes out: the numbers are the ones this computer kept.

import { isBusy, type UpdateStatus } from "../core/update";
import type { BotStateName } from "../core/layout";
import { mergedSeconds, type RecapHistory } from "../recap/summary";

/** The icons an entry may use (the same names as the Mac's). */
export const ICON_NAMES = [
  "update", "languages", "terminal", "checklist", "bell", "chat", "mic", "phone", "shield",
  "sparkles", "bolt", "puzzle", "paint", "eye", "keyboard", "heart", "clock", "download", "bug",
] as const;
export type IconName = (typeof ICON_NAMES)[number];

export interface WhatsNewItem {
  icon: string;
  title: Record<string, string>;
  detail: Record<string, string>;
}

export interface WhatsNewRelease {
  version: string;
  items: WhatsNewItem[];
}

export interface WhatsNewFile {
  releases: WhatsNewRelease[];
}

// ── Versions ──────────────────────────────────────────────────────────────────

/** -1, 0 or 1, numerically: 0.10.0 is after 0.9.3, 0.5 equals 0.5.0. */
export function compareVersions(a: string, b: string): number {
  const x = a.split(".").map((n) => Number.parseInt(n, 10) || 0);
  const y = b.split(".").map((n) => Number.parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const l = x[i] ?? 0;
    const r = y[i] ?? 0;
    if (l !== r) return l > r ? 1 : -1;
  }
  return 0;
}

/** The entry of exactly this version, or null (then there is no card). */
export function releaseFor(file: WhatsNewFile | null | undefined, version: string): WhatsNewRelease | null {
  const list = file?.releases;
  if (!Array.isArray(list) || !version) return null;
  const found = list.find((r) => r && compareVersions(r.version, version) === 0);
  if (!found || !Array.isArray(found.items) || found.items.length === 0) return null;
  return found;
}

/** The text in `lang`, else English, else nothing. */
export function localized(texts: Record<string, string> | null | undefined, lang: string): string {
  if (!texts) return "";
  const v = texts[lang];
  if (typeof v === "string" && v.trim()) return v;
  const en = texts.en;
  return typeof en === "string" ? en : "";
}

/** An unknown icon name draws the sparkles rather than nothing. */
export function iconName(name: string): IconName {
  return (ICON_NAMES as readonly string[]).includes(name) ? (name as IconName) : "sparkles";
}

// ── At launch: show it, or only remember the version ─────────────────────────

export interface LaunchFacts {
  /** The version running. */
  current: string;
  /** The last version this install saw (null: none stored yet). */
  lastSeen: string | null;
  /**
   * Signs that Coucou ran here before, for installs from before this card
   * (0.5.1 stored no version): the update question answered, agent sessions
   * or decisions in the recap, dictations, notes.
   */
  usedBefore: boolean;
  /** whats-new.json has an entry for `current`. */
  hasEntry: boolean;
}

export interface LaunchDecision {
  /** Open the card once. */
  show: boolean;
  /** Store `current` as the version seen. */
  record: boolean;
}

export function decideOnLaunch(f: LaunchFacts): LaunchDecision {
  if (!f.current) return { show: false, record: false };
  if (f.lastSeen == null) {
    // A first install says hello with the greeting, not with release notes.
    return { show: f.usedBefore && f.hasEntry, record: true };
  }
  const cmp = compareVersions(f.current, f.lastSeen);
  if (cmp === 0) return { show: false, record: false };
  // Going back to an older build: remember it, say nothing.
  return { show: cmp > 0 && f.hasEntry, record: true };
}

// ── "Your Coucou so far" ──────────────────────────────────────────────────────

export type StatKind = "agentSessions" | "agentTime" | "linesAdded" | "approvals" | "words" | "saved" | "calls";

export interface Stat {
  kind: StatKind;
  /** A count, or minutes for agentTime and saved. */
  value: number;
}

export interface StatsInput {
  history: RecapHistory | null | undefined;
  /** Flow's totals over everything kept. */
  flow: { words: number; minutesSaved: number; dictations: number } | null | undefined;
  /** Calls the Notetaker transcribed. */
  calls: number;
}

const whole = (n: unknown) => (typeof n === "number" && Number.isFinite(n) && n > 0 ? Math.floor(n) : 0);

/** Every number the island kept, in the card's order; zeros are left out. */
export function soFar(input: StatsInput): Stat[] {
  const turns = input.history?.turns ?? [];
  const decisions = input.history?.decisions ?? [];
  const answered = decisions.filter((d) => d.decision === "allow" || d.decision === "always" || d.decision === "deny");
  const all: Stat[] = [
    { kind: "agentSessions", value: turns.length },
    { kind: "agentTime", value: whole(mergedSeconds(turns) / 60) },
    { kind: "linesAdded", value: turns.reduce((n, t) => n + whole(t.linesAdded), 0) },
    { kind: "approvals", value: answered.length },
    { kind: "words", value: whole(input.flow?.words) },
    { kind: "saved", value: whole(input.flow?.minutesSaved) },
    { kind: "calls", value: whole(input.calls) },
  ];
  return all.filter((s) => s.value > 0);
}

/** Whether anything shows Coucou ran here before (see LaunchFacts.usedBefore). */
export function usedBefore(facts: {
  consent: boolean | null;
  history: RecapHistory | null | undefined;
  dictations: number;
  notes: number;
}): boolean {
  return facts.consent != null
    || (facts.history?.turns.length ?? 0) > 0
    || (facts.history?.decisions.length ?? 0) > 0
    || facts.dictations > 0
    || facts.notes > 0;
}

// ── The blue Mochi while a version waits ──────────────────────────────────────

/** "Later" keeps the version quiet for a day, the blue included (Mac: snooze). */
export const LATER_MS = 24 * 3600 * 1000;

export interface Later {
  version: string;
  /** Epoch milliseconds. */
  at: number;
}

/**
 * A newer version is out, the user let Coucou look for it, it is not being
 * installed, and "Later" was not pressed for it in the last day.
 */
export function updateWaiting(status: UpdateStatus, later: Later | null, nowMs: number): boolean {
  const latest = status.latest;
  if (status.consent !== true || !latest) return false;
  if (isBusy(status.phase) || status.phase.kind === "error") return false;
  if (later && later.version === latest.version && nowMs >= later.at && nowMs - later.at < LATER_MS) return false;
  return true;
}

/** Mochi turns blue only when he has nothing else to say. */
export function showsUpdateHint(waiting: boolean, state: BotStateName, pending: boolean): boolean {
  return waiting && !pending && (state === "idle" || state === "sleeping");
}

/** The release page of this version, for "All changes". */
export function releasePage(platform: "windows" | "linux", version: string): string {
  return `https://github.com/Louis-CFM/coucou/releases/tag/${platform}-v${encodeURIComponent(version)}`;
}

/** Buy Mochi a coffee: the same Stripe link as the Coucou page (docs/index.html). */
export const COFFEE_URL = "https://buy.stripe.com/dRm6oGbfa7Kqcqs0hxes003";

/** The blue of an update, and of the arrow badge. */
export const UPDATE_BLUE = "#3B82F6";
