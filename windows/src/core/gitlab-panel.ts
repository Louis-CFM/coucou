// The GitLab panel — the pure half: the shapes Rust sends, the four sections, the
// "+N" of what is new since a section was last opened, the colour of what waits,
// and the words for what can go wrong. No DOM here, so all of it is tested in
// Node; src/gitlab-panel/main.ts draws it.
//
// What the data means (which thread "waits for me", which merge requests are in
// which list) is decided in src-tauri/src/gitlab_dash.rs.

import { N_, t } from "../i18n/i18n";
import type { CIState } from "./github";

// ── What Rust sends ───────────────────────────────────────────────────────────

export interface Approvals {
  given: number;
  /** 0 when the project asks for none. */
  required: number;
}

export interface DashMr {
  /** "group/project!12" */
  id: string;
  project: string;
  projectId: number;
  iid: number;
  title: string;
  url: string;
  isDraft: boolean;
  ci: CIState;
  /** Unix milliseconds, 0 when unknown. */
  updatedAt: number;
  approvals: Approvals | null;
  unresolved: number | null;
}

export interface ThreadNote {
  id: number;
  author: string;
  username: string;
  body: string;
  createdAt: number;
  isMe: boolean;
}

export interface CodePosition {
  file: string;
  line: number;
  side: "new" | "old";
  sha: string;
}

export interface PendingThread {
  id: string;
  /** Changes with the thread's last message. */
  key: string;
  project: string;
  projectId: number;
  mrIid: number;
  mrRef: string;
  mrTitle: string;
  mrUrl: string;
  resolvable: boolean;
  notes: ThreadNote[];
  position: CodePosition | null;
  lastAt: number;
}

export interface Dashboard {
  me: string;
  baseUrl: string;
  /** Whether the token has the `api` scope; null when GitLab did not say. */
  canWrite: boolean | null;
  toReview: DashMr[];
  mine: DashMr[];
  approved: DashMr[];
  comments: PendingThread[];
  fetchedAt: number;
}

export interface SnippetLine {
  number: number;
  text: string;
  target: boolean;
}

export interface Sent {
  ok: boolean;
  error: "empty" | "no_token" | "forbidden" | "not_found" | "network" | "error" | null;
}

// ── Sections ──────────────────────────────────────────────────────────────────

export type SectionId = "comments" | "toReview" | "mine" | "approved";

/** What asks for an action first, then what to follow. */
export const SECTION_ORDER: readonly SectionId[] = ["comments", "toReview", "mine", "approved"];

/** The sections that take the colour of "something waits for you". */
const ATTENTION: readonly SectionId[] = ["comments", "toReview"];

export const SECTION_TITLES: Record<SectionId, string> = {
  comments: N_("Comments waiting"),
  toReview: N_("To review"),
  mine: N_("My MRs"),
  approved: N_("Approved"),
};

export function sectionTitle(id: SectionId): string {
  return t(SECTION_TITLES[id]);
}

/** What identifies an item in a section: a thread by its last message, a merge request by its reference. */
export function itemIds(dash: Dashboard, section: SectionId): string[] {
  switch (section) {
    case "comments": return dash.comments.map((c) => c.key);
    case "toReview": return dash.toReview.map((m) => m.id);
    case "mine": return dash.mine.map((m) => m.id);
    case "approved": return dash.approved.map((m) => m.id);
  }
}

export function count(dash: Dashboard, section: SectionId): number {
  return itemIds(dash, section).length;
}

/** Something in the section waits for an action of yours. */
export function waiting(dash: Dashboard, section: SectionId): boolean {
  return ATTENTION.includes(section) && count(dash, section) > 0;
}

// ── What has been seen ────────────────────────────────────────────────────────

export interface PanelState {
  /** False until the first data arrives: it is taken as already seen. */
  initialized: boolean;
  /** The items present when each section was last looked at. */
  seen: Record<SectionId, string[]>;
  open: Record<SectionId, boolean>;
}

export function emptyState(): PanelState {
  return {
    initialized: false,
    seen: { comments: [], toReview: [], mine: [], approved: [] },
    open: { comments: false, toReview: false, mine: false, approved: false },
  };
}

function withSeen(state: PanelState, section: SectionId, ids: string[]): PanelState {
  return { ...state, seen: { ...state.seen, [section]: ids } };
}

/**
 * New data arrived. The very first data is taken as seen, so the badges start at
 * nothing; after that, a section the user has open is being looked at, so what
 * arrives in it is seen at once.
 */
export function receive(state: PanelState, dash: Dashboard): PanelState {
  let next = state;
  for (const section of SECTION_ORDER) {
    if (!state.initialized || state.open[section]) next = withSeen(next, section, itemIds(dash, section));
  }
  return state.initialized ? next : { ...next, initialized: true };
}

/** Opening a section marks what it holds as seen; closing it keeps that. */
export function toggle(state: PanelState, dash: Dashboard | null, section: SectionId): PanelState {
  const open = !state.open[section];
  const next: PanelState = { ...state, open: { ...state.open, [section]: open } };
  return open && dash ? withSeen(next, section, itemIds(dash, section)) : next;
}

/** The "+N": items present now that were not when the section was last looked at. */
export function newCount(state: PanelState, dash: Dashboard, section: SectionId): number {
  if (!state.initialized) return 0;
  const seen = new Set(state.seen[section]);
  return itemIds(dash, section).filter((id) => !seen.has(id)).length;
}

const STORAGE_KEY = "gitlab-panel-state";

interface Storage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

/** What was kept from last time; a fresh state when nothing usable is there. */
export function loadState(storage: Storage | undefined): PanelState {
  try {
    const raw = storage?.getItem(STORAGE_KEY);
    if (!raw) return emptyState();
    const parsed = JSON.parse(raw) as Partial<PanelState>;
    const base = emptyState();
    const list = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);
    for (const s of SECTION_ORDER) {
      base.seen[s] = list(parsed.seen?.[s]);
      base.open[s] = parsed.open?.[s] === true;
    }
    base.initialized = parsed.initialized === true;
    return base;
  } catch {
    return emptyState();
  }
}

export function saveState(storage: Storage | undefined, state: PanelState) {
  try {
    storage?.setItem(STORAGE_KEY, JSON.stringify(state));
  } catch {
    // Storage can be missing or full: the panel just forgets next time.
  }
}

// ── Words and numbers ─────────────────────────────────────────────────────────

/** "just now", "5m", "3h", "2d" — the same words as the other cards. */
export function ageLabel(ms: number, now = Date.now()): string {
  if (!ms) return "";
  const diff = (now - ms) / 1000;
  if (!Number.isFinite(diff)) return "";
  if (diff < 60) return t("just now");
  if (diff < 3600) return t("{n}m", { n: Math.floor(diff / 60) });
  if (diff < 86400) return t("{n}h", { n: Math.floor(diff / 3600) });
  return t("{n}d", { n: Math.floor(diff / 86400) });
}

/** "1/2" when the project asks for approvals, "✓ 1" when some came without being asked. */
export function approvalsLabel(a: Approvals | null): string | null {
  if (!a) return null;
  if (a.required > 0) return `${a.given}/${a.required}`;
  return a.given > 0 ? `✓ ${a.given}` : null;
}

/** "mr!12" → short project name: the last path segment. */
export function shortProject(project: string): string {
  return project.split("/").pop() || project;
}

/** The last message of a thread, on one line, for the collapsed row. */
export function preview(thread: PendingThread, max = 90): string {
  const last = thread.notes[thread.notes.length - 1];
  if (!last) return "";
  const flat = last.body.replace(/\s+/g, " ").trim();
  return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
}

/** Why a reply or a resolve did not go through, in the user's words. */
export function sendError(error: Sent["error"]): string {
  switch (error) {
    case "forbidden": return t("This token is read-only: add the api scope to reply");
    case "network": return t("Could not reach GitLab. Your text is kept.");
    case "not_found": return t("This thread no longer exists.");
    case "no_token": return t("No GitLab token.");
    case "empty": return "";
    default: return t("GitLab refused it. Your text is kept.");
  }
}

/** Only http(s) links to the instance the data came from open. */
export function safeInstanceUrl(raw: string, baseUrl: string): string | null {
  let url: URL;
  let base: URL;
  try {
    url = new URL(raw);
    base = new URL(baseUrl);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  return url.host === base.host ? url.toString() : null;
}

/** A link to one message of a thread, so GitLab scrolls to it. */
export function noteUrl(thread: PendingThread): string {
  const last = thread.notes[thread.notes.length - 1];
  return last ? `${thread.mrUrl}#note_${last.id}` : thread.mrUrl;
}

// ── Avatars ───────────────────────────────────────────────────────────────────

/** "Jane Doe" → "JD", "bob" → "B": what a little round avatar carries. */
export function initials(name: string): string {
  const words = name.trim().split(/[\s._-]+/).filter(Boolean);
  if (words.length === 0) return "?";
  const first = Array.from(words[0])[0] ?? "?";
  const second = words.length > 1 ? (Array.from(words[words.length - 1])[0] ?? "") : "";
  return (first + second).toUpperCase();
}

/** A colour for a person, the same every time: a hue from 0 to 359. */
export function avatarHue(username: string): number {
  let hash = 0;
  for (const ch of username) hash = (hash * 31 + (ch.codePointAt(0) ?? 0)) >>> 0;
  return hash % 360;
}
