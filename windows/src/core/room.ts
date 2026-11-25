// Mochi's room (Coucou window → Notch → Mochi's room): where Mochi stands, the
// weather at the window, the plant, the frames on the wall. Port of
// MochiRoom.swift, plus what the island sends the room (island/room.ts) and
// how the room reads it. Every object of the room comes from data Coucou
// already has; nothing here asks a service anything. No DOM, no Tauri:
// tests/room.test.mjs runs it as it is.

import { t } from "../i18n/i18n";
import type { BotStateName } from "./layout";
import { readPulse, readStats, type CIState } from "./github";
import { readBookings } from "./calendar";
import { pillDefinition } from "./pills";
import type { AgentTask, ApprovalInfo, IntegrationInfo } from "./state";
import { dayKey, mergedSeconds, type RecapHistory } from "../recap/summary";

/** The room's switches, kept by the Coucou window (same names as the Mac's). */
export const ROOM_KEYS = {
  /** Off by default: the page shows what the room is and a button to turn it on. */
  enabled: "mochiRoomEnabled",
  /** Mochi walks to the door when an agent asks something, and the card opens in the room. */
  door: "mochiRoomDoor",
  /** The window shows the CI and the deploys (sun, rain, storm). */
  weather: "mochiRoomWeather",
  /** The room gets dark at night. */
  dayNight: "mochiRoomDayNight",
  /** The tools hidden from the walls, by id ("stripe,calcom"). */
  hidden: "mochiRoomHiddenTools",
} as const;

/** Island ⇄ Coucou window events (island/room.ts, hub/pages/room.ts). */
export const ROOM_EVENTS = {
  /** Window → island: true while the room is on screen, false otherwise. */
  watch: "room-watch",
  /** Island → window: a RoomSnapshot, each time it changes while watched. */
  state: "room-state",
  /** Window → island: { requestId, decision } clicked under the room. */
  decide: "room-decide",
  /** Window → island: open the island on its card. */
  open: "room-open-island",
} as const;

// ── Where Mochi stands ───────────────────────────────────────────────────────

export type Spot = "door" | "desk" | "bed";

/** The door first (someone waits for you), then the desk, then the bed. */
export function spot(waiting: boolean, busy: boolean, useDoor = true): Spot {
  if (waiting && useDoor) return "door";
  if (waiting || busy) return "desk";
  return "bed";
}

const BUSY: BotStateName[] = ["working", "thinking", "searching"];

/** The face Mochi makes where he stands. */
export function mochiState(where: Spot, snap: RoomSnapshot): BotStateName {
  if (where === "door") return snap.approval?.question ? "question" : "approval";
  if (where === "bed") return "sleeping";
  const shown = snap.focusState;
  return BUSY.includes(shown) || shown === "approval" || shown === "question" ? shown : "working";
}

// ── The window ───────────────────────────────────────────────────────────────

export type Weather = "sun" | "cloudy" | "rain" | "storm" | "clear";

/**
 * `ci`: the CI of the main branches. `deploys`: the Vercel states, newest
 * first ("READY", "ERROR", "BUILDING"…). The worst news wins.
 */
export function weather(ci: CIState[], deploys: string[]): Weather {
  const last = deploys[0]?.toUpperCase();
  if (last === "ERROR") return "storm";
  if (ci.includes("failure")) return "rain";
  const deploying = last !== undefined && ["BUILDING", "QUEUED", "INITIALIZING"].includes(last);
  if (ci.includes("pending") || deploying) return "cloudy";
  if (ci.includes("success") || last === "READY") return "sun";
  return "clear";
}

/** Night from 20:00 to 6:59. */
export function isNight(hour: number): boolean {
  return hour >= 20 || hour < 7;
}

// ── The plant ────────────────────────────────────────────────────────────────

/**
 * Days in a row with at least one agent session, ending today or yesterday
 * (today still counts while you have not started yet). Local days.
 */
export function streak(days: Date[], today: Date): number {
  const worked = new Set(days.map(dayKey));
  let day = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  const back = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate() - 1);
  if (!worked.has(dayKey(day))) {
    day = back(day);
    if (!worked.has(dayKey(day))) return 0;
  }
  let count = 0;
  while (worked.has(dayKey(day))) {
    count += 1;
    day = back(day);
  }
  return count;
}

export type Plant = "seed" | "sprout" | "leafy" | "bloom";

/** Grows with the streak: a seed, then a sprout (1 day), leaves (3), a flower (7). */
export function plant(days: number): Plant {
  if (days < 1) return "seed";
  if (days < 3) return "sprout";
  if (days < 7) return "leafy";
  return "bloom";
}

// ── Today ────────────────────────────────────────────────────────────────────

export interface RoomToday {
  /** Minutes with an agent at work today, parallel sessions counted once. */
  minutes: number;
  allowed: number;
  denied: number;
  streak: number;
}

/** Today so far, from the weekly recap's history (RecapStore.today on the Mac). */
export function today(history: RecapHistory | null, now: Date): RoomToday {
  const key = dayKey(now);
  const isToday = (seconds: number) => dayKey(new Date(seconds * 1000)) === key;
  const turns = history?.turns ?? [];
  const decisions = (history?.decisions ?? []).filter((d) => isToday(d.date));
  return {
    minutes: Math.floor(mergedSeconds(turns.filter((x) => isToday(x.start))) / 60),
    allowed: decisions.filter((d) => d.decision === "allow" || d.decision === "always").length,
    denied: decisions.filter((d) => d.decision === "deny").length,
    streak: streak(turns.map((x) => new Date(x.start * 1000)), now),
  };
}

/** "2 h 14" or "38 min", as the Statistics page writes them. */
export function codedLabel(minutes: number): string {
  const m = Math.max(0, Math.floor(minutes));
  if (m >= 60) return t("{0} h {1}", { 0: Math.floor(m / 60), 1: String(m % 60).padStart(2, "0") });
  return t("{0} min", { 0: m });
}

// ── What the island sends ────────────────────────────────────────────────────

export interface RoomApproval {
  requestId: string;
  pillId: string;
  /** Who asks: the session's pill name. */
  asker: string;
  tool: string;
  command: string;
  /** A question (its options live in the island) rather than a permission. */
  question: boolean;
  /** Requests waiting behind this one. */
  queued: number;
}

/** What the room needs of the island's state; plain data, sent between windows. */
export interface RoomSnapshot {
  /** An agent is at work. */
  busy: boolean;
  /** The state of the pill on screen, for Mochi's face at the desk. */
  focusState: BotStateName;
  approval: RoomApproval | null;
  /** Each tool's numbers, null when its pill has nothing yet. */
  stripe: { currency: string; payments: { amount: number; createdAt: number; succeeded: boolean }[] } | null;
  github: { stars: number | null; ci: CIState[] } | null;
  /** Newest first, cancelled deploys left out. */
  vercel: { state: string; createdAt: number; project: string }[] | null;
  n8n: { workflow: string; success: boolean } | null;
  /** The starts of the upcoming bookings, in milliseconds. */
  calcom: number[] | null;
}

export const EMPTY_SNAPSHOT: RoomSnapshot = {
  busy: false, focusState: "idle", approval: null, stripe: null, github: null, vercel: null, n8n: null, calcom: null,
};

interface IslandView {
  tasks: AgentTask[];
  focusTask: AgentTask | null;
  pendingApproval: ApprovalInfo | null;
  approvalQueue: ApprovalInfo[];
  integrations: Record<string, IntegrationInfo>;
}

const arr = (v: unknown): Record<string, unknown>[] =>
  Array.isArray(v) ? v.filter((x): x is Record<string, unknown> => !!x && typeof x === "object") : [];
const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : 0);
const str = (v: unknown): string => (typeof v === "string" ? v : "");

/** The island's state, cut down to what the room shows. */
export function roomSnapshot(s: IslandView): RoomSnapshot {
  const data = (id: string) => {
    const info = s.integrations[id];
    return info?.loaded ? info.data : null;
  };
  const req = s.pendingApproval;
  const stripe = data("integration_stripe");
  const github = data("integration_github");
  const vercel = data("integration_vercel");
  const n8n = data("integration_n8n");
  const calcom = data("integration_calcom");
  const pulse = github ? readPulse(github) : null;
  const stats = github ? readStats(github) : null;
  return {
    busy: s.tasks.some((x) => BUSY.includes(x.state)),
    focusState: s.focusTask?.state ?? "idle",
    approval: req && {
      requestId: req.requestId,
      pillId: req.pillId,
      asker: s.tasks.find((x) => x.id === req.pillId)?.name ?? pillDefinition(req.pillId)?.name ?? "Claude Code",
      tool: req.tool,
      command: req.command,
      question: !!req.questions,
      queued: s.approvalQueue.length,
    },
    stripe: stripe && {
      currency: str(stripe.currency) || "usd",
      payments: arr(stripe.payments).map((p) => ({
        amount: num(p.amount), createdAt: num(p.createdAt), succeeded: str(p.status) === "succeeded",
      })),
    },
    github: github && { stars: stats ? stats.totalStars : null, ci: pulse ? pulse.mainCI.map((r) => r.ci) : [] },
    vercel: vercel && arr(vercel.deployments)
      .filter((d) => str(d.state) !== "CANCELED")
      .map((d) => ({ state: str(d.state), createdAt: num(d.createdAt), project: str(d.projectName) }))
      .sort((a, b) => b.createdAt - a.createdAt),
    n8n: n8n && str(n8n.status) ? { workflow: str(n8n.workflow), success: n8n.status === "success" } : null,
    calcom: calcom && (readBookings(calcom.bookings) ?? []).map((b) => b.start.getTime()),
  };
}

/** The weather the snapshot makes. */
export function roomWeather(snap: RoomSnapshot): Weather {
  return weather(snap.github?.ci ?? [], (snap.vercel ?? []).map((d) => d.state));
}

// ── The frames on the wall ───────────────────────────────────────────────────

export type RoomToolId = "stripe" | "github" | "vercel" | "n8n" | "calcom";

export interface RoomTool {
  id: RoomToolId;
  name: string;
  /** Connected when every one of these is in the credential store. */
  keys: string[];
  color: string;
  /** Opened by a click on its frame (n8n lives on your own server). */
  url: string;
}

export const ROOM_TOOLS: RoomTool[] = [
  { id: "stripe", name: "Stripe", keys: ["stripe-api-key"], color: "#635BFF", url: "https://dashboard.stripe.com/payments" },
  { id: "github", name: "GitHub", keys: ["github-token"], color: "#F5F6F8", url: "https://github.com" },
  { id: "vercel", name: "Vercel", keys: ["vercel-token"], color: "#F5F6F8", url: "https://vercel.com/dashboard" },
  { id: "n8n", name: "n8n", keys: ["n8n-url", "n8n-api-key"], color: "#EA4B71", url: "" },
  { id: "calcom", name: "Cal.com", keys: ["calcom-api-key"], color: "#F5F6F8", url: "https://app.cal.com/bookings/upcoming" },
];

export interface RoomFrame {
  tool: RoomTool;
  value: string;
  label: string;
  dot: "green" | "red" | null;
}

const sameDay = (ms: number, now: Date) => dayKey(new Date(ms)) === dayKey(now);

/** Amounts in the smallest unit (cents): only today's succeeded payments count. */
export function paidToday(payments: { amount: number; createdAt: number; succeeded: boolean }[], now: Date): number {
  return payments.filter((p) => p.succeeded && sameDay(p.createdAt, now)).reduce((n, p) => n + p.amount, 0);
}

/** "1.2k" for the stars on a frame. */
export function shortCount(n: number): string {
  if (n < 1000) return String(n);
  const k = n / 1000;
  const text = k < 10 ? k.toFixed(1) : k.toFixed(0);
  return `${text.endsWith(".0") ? text.slice(0, -2) : text}k`;
}

function money(cents: number, currency: string): string {
  try {
    return new Intl.NumberFormat(undefined, { style: "currency", currency: currency.toUpperCase(), maximumFractionDigits: 0 })
      .format(cents / 100);
  } catch {
    return String(Math.round(cents / 100));
  }
}

function frame(tool: RoomTool, snap: RoomSnapshot, now: Date): RoomFrame {
  switch (tool.id) {
    case "stripe": {
      const s = snap.stripe;
      return { tool, value: s ? money(paidToday(s.payments, now), s.currency) : "–", label: t("Today"), dot: null };
    }
    case "github": {
      const stars = snap.github?.stars;
      return { tool, value: stars == null ? "–" : `★ ${shortCount(stars)}`, label: t("Stars"), dot: null };
    }
    case "vercel": {
      // A cancelled deploy says nothing about production: the last one that ran.
      const last = snap.vercel?.[0];
      const ok = last?.state === "READY";
      return {
        tool, value: last ? (ok ? t("Ready") : t("Failed")) : "–", label: last?.project || "Vercel",
        dot: last ? (ok ? "green" : "red") : null,
      };
    }
    case "n8n": {
      // Windows and Linux only hear of the latest execution: its workflow, not a count.
      const last = snap.n8n;
      return { tool, value: last?.workflow || "–", label: t("Last run"), dot: last ? (last.success ? "green" : "red") : null };
    }
    case "calcom": {
      const next = (snap.calcom ?? []).filter((ms) => ms > now.getTime() && sameDay(ms, now)).sort((a, b) => a - b)[0];
      const value = next === undefined ? "–" : new Date(next).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
      return { tool, value, label: t("Next call"), dot: null };
    }
  }
}

/** One slot per tool, in order: null leaves the frame empty (not connected, or hidden). */
export function frames(snap: RoomSnapshot, connected: Set<string>, hidden: Set<string>, now: Date): (RoomFrame | null)[] {
  return ROOM_TOOLS.map((tool) => (connected.has(tool.id) && !hidden.has(tool.id) ? frame(tool, snap, now) : null));
}

/** "2 / 3": the deploys that went through today, of those that ran; "–" without any. */
export function deploysToday(snap: RoomSnapshot, now: Date): string {
  const mine = (snap.vercel ?? []).filter((d) => sameDay(d.createdAt, now));
  if (mine.length === 0) return "–";
  return `${mine.filter((d) => d.state === "READY").length} / ${mine.length}`;
}

// ── Hidden tools ─────────────────────────────────────────────────────────────

export function hiddenTools(raw: string): Set<string> {
  return new Set(raw.split(",").map((s) => s.trim()).filter(Boolean));
}

export function hiddenToolsRaw(set: Set<string>): string {
  return [...set].sort().join(",");
}
