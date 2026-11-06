// What came in since you last looked, on the WhatsApp and Mail pills: a count on the pill, and a
// short wiggle when it grows. Looking is having that pill's card open in the island; the count
// goes then. What was already unread when Coucou started is not new.
//
// The numbers are the ones the cards already show (WhatsApp's unread messages, the unread mail in
// Outlook): nothing more is asked of Rust, and nothing is stored.

import { MAIL_ID } from "../core/mail";
import { State } from "../core/state";
import { WHATSAPP_ID, WhatsApp } from "../core/whatsapp";

/** The pills that count what came in. */
export const COUNTING_PILLS = [WHATSAPP_ID, MAIL_ID];

/** How long a pill wiggles once its count grew: the animation in style.css (.wiggle). */
export const WIGGLE_MS = 1_200;

interface Count {
  /** The card's count when it was last looked at (or first seen). */
  seen: number;
  /** The card's count now. */
  last: number;
  /** When it last grew, performance.now(). */
  grewAt: number;
}

const counts = new Map<string, Count>();

/** The unread count a pill's card shows, or null when it shows none (off, not set up). */
export function unreadOf(id: string): number | null {
  if (id === WHATSAPP_ID) return WhatsApp.view.on ? WhatsApp.view.unread : null;
  if (id === MAIL_ID) {
    const n = (State.integrations[MAIL_ID]?.data as { unread?: unknown } | undefined)?.unread;
    return typeof n === "number" && n >= 0 ? n : null;
  }
  return null;
}

function looking(id: string): boolean {
  return State.mode === "expanded" && State.view === "overview" && State.focusId === id;
}

/** One pill's count brought up to date. */
function track(id: string, now: number): Count | null {
  const n = unreadOf(id);
  if (n == null) {
    counts.delete(id);
    return null;
  }
  let c = counts.get(id);
  if (!c) {
    c = { seen: n, last: n, grewAt: -Infinity };
    counts.set(id, c);
  }
  if (n > c.last && !State.paused) c.grewAt = now;
  c.last = n;
  // Looked at, or read somewhere else: nothing is new any more.
  if (looking(id) || n < c.seen) c.seen = n;
  return c;
}

/** Every counting pill brought up to date: on each State change, so opening a card clears it. */
export function trackUnread(now = performance.now()) {
  for (const id of COUNTING_PILLS) track(id, now);
}

/** What came in since the pill's card was last open; the pill shows it above 0. */
export function newSince(id: string, now = performance.now()): number {
  const c = track(id, now);
  return c ? c.last - c.seen : 0;
}

/** The pill's count grew a moment ago, and nobody has looked yet. */
export function wiggling(id: string, now = performance.now()): boolean {
  const c = track(id, now);
  return c != null && c.last > c.seen && now - c.grewAt < WIGGLE_MS;
}

/** When the pill's count last grew: in the views' keys, so a new wiggle redraws the pill. */
export function grewAt(id: string): number {
  return counts.get(id)?.grewAt ?? -Infinity;
}

export function registerUnread() {
  State.subscribe(() => trackUnread());
}

/** Tests: forget every count. */
export function resetUnread() {
  counts.clear();
}
