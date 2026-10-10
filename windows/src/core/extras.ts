// The Windows build's own tabs: Focus (a timer in the island), To-do, and the
// Inbox of calls and messages that came while you were away. Plus the Claude
// plan alert at 80 % and 95 % of the 5-hour window. Pure logic and state; the
// cards are in views/extras.ts.

import { State } from "./state";

/** The top bar's own tabs, each a view of the island. */
export type ExtraView = "focus" | "todo" | "inbox";

function load<T>(key: string, fallback: T): T {
  try {
    const raw = window.localStorage?.getItem(key);
    return raw ? (JSON.parse(raw) as T) : fallback;
  } catch {
    return fallback;
  }
}

function store(key: string, value: unknown) {
  try {
    window.localStorage?.setItem(key, JSON.stringify(value));
  } catch {
    // Storage off: the list lives until Coucou quits.
  }
}

// ── To-do ─────────────────────────────────────────────────────────────────────

export interface Todo {
  id: number;
  text: string;
  done: boolean;
}

const TODO_KEY = "coucou.todos";
// ponytail: kept in the island's web storage (survives restarts, this PC only); a file under config_dir if it ever needs syncing.
export const Todos = {
  items: load<Todo[]>(TODO_KEY, []),
  add(text: string) {
    const t = text.trim();
    if (!t) return;
    const id = Math.max(0, ...this.items.map((x) => x.id)) + 1;
    this.items = [...this.items, { id, text: t.slice(0, 200), done: false }];
    this.save();
  },
  toggle(id: number) {
    this.items = this.items.map((x) => (x.id === id ? { ...x, done: !x.done } : x));
    this.save();
  },
  remove(id: number) {
    this.items = this.items.filter((x) => x.id !== id);
    this.save();
  },
  /** Open ones first, in the order they were added. */
  get sorted(): Todo[] {
    return [...this.items.filter((x) => !x.done), ...this.items.filter((x) => x.done)];
  },
  get open(): number {
    return this.items.filter((x) => !x.done).length;
  },
  save() {
    store(TODO_KEY, this.items);
    State.notify();
  },
};

// ── Focus ─────────────────────────────────────────────────────────────────────

export const Focus = {
  /** performance-independent: Date.now() when it ends, or null. */
  endsAt: null as number | null,
  /** Minutes chosen, for the progress. */
  minutes: 25,
  /** Left when paused, ms. */
  pausedLeft: null as number | null,
  get running(): boolean {
    return this.endsAt != null && this.pausedLeft == null;
  },
  get active(): boolean {
    return this.endsAt != null || this.pausedLeft != null;
  },
  left(now = Date.now()): number {
    if (this.pausedLeft != null) return this.pausedLeft;
    return this.endsAt == null ? 0 : Math.max(0, this.endsAt - now);
  },
};

/** 25:00, 4:05 */
export function clock(ms: number): string {
  const s = Math.ceil(ms / 1000);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

// ── Inbox ─────────────────────────────────────────────────────────────────────

export interface InboxItem {
  kind: "call" | "message";
  who: string;
  body: string;
  at: number;
}

export const Inbox = {
  items: [] as InboxItem[],
  unseen: 0,
  add(item: InboxItem) {
    this.items = [item, ...this.items].slice(0, 30);
    this.unseen += 1;
  },
  /** What came since `since` (ms), as "2 calls · 3 messages" counts. */
  since(since: number): { calls: number; messages: number } {
    const recent = this.items.filter((x) => x.at >= since);
    return { calls: recent.filter((x) => x.kind === "call").length, messages: recent.filter((x) => x.kind === "message").length };
  },
};

// ── Claude plan alert ─────────────────────────────────────────────────────────

const ALERT_KEY = "coucou.planAlert";

/**
 * The mark (80 or 95) the 5-hour window just crossed, once per window: the
 * window is told apart by its reset time.
 */
export function planAlert(usedPct: number, resetsAt: number): 80 | 95 | null {
  const mark = usedPct >= 95 ? 95 : usedPct >= 80 ? 80 : null;
  if (mark == null) return null;
  const last = load<{ resetsAt: number; mark: number } | null>(ALERT_KEY, null);
  if (last && last.resetsAt === resetsAt && last.mark >= mark) return null;
  store(ALERT_KEY, { resetsAt, mark });
  return mark;
}
