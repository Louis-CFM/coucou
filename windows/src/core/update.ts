// New versions of Coucou (src-tauri/src/update.rs): what Rust reports, and the
// small rules the island applies to it. Pure, so tests/update.test.mjs checks them.

import type { IslandMode, IslandViewName } from "./layout";

export type UpdatePhase =
  | { kind: "idle" }
  | { kind: "downloading"; fraction: number }
  | { kind: "verifying" }
  | { kind: "installing" }
  | { kind: "error"; message: string };

export type UpdateCheck = "none" | "checking" | "upToDate" | "unreachable";

export interface UpdateStatus {
  /** null: not asked yet. true: Coucou may look at GitHub on its own. */
  consent: boolean | null;
  /** The version running. */
  current: string;
  /** The newest release of this platform, only while it is newer than `current`. */
  latest: { version: string; headline: string | null; pageUrl: string } | null;
  /** "Update now" installs it here (Windows, installed with setup.exe or the MSI). */
  canInstall: boolean;
  phase: UpdatePhase;
  check: UpdateCheck;
  platform: "windows" | "linux";
}

/** Rust's offers: the question, a version to announce, or the card asked for (tray, Check now). */
export type UpdateOffer = "ask" | "announce" | "show";

export const NO_UPDATE: UpdateStatus = {
  consent: null,
  current: "",
  latest: null,
  canInstall: false,
  phase: { kind: "idle" },
  check: "none",
  platform: "windows",
};

export interface IslandNow {
  paused: boolean;
  /** A permission or a question waits for an answer. */
  pending: boolean;
  mode: IslandMode;
  view: IslandViewName;
}

/**
 * Whether the island may open its update card for `offer`. Never over a
 * waiting permission or question. The question and an announcement come
 * only when nothing else is open (Mac: islandFree); the card the user asked
 * for (tray, Settings) may replace an ordinary view.
 */
export function mayOffer(offer: UpdateOffer, now: IslandNow): boolean {
  if (now.pending) return false;
  if (offer === "show") return true;
  if (now.paused) return false;
  return now.mode !== "expanded" || now.view === "update";
}

/** Download progress as a whole percentage, 0–100. */
export function percent(fraction: number): number {
  if (!Number.isFinite(fraction)) return 0;
  return Math.round(Math.max(0, Math.min(1, fraction)) * 100);
}

/** The line under "Coucou X is out": the first "What's new" bullet, then "You have Y". */
export function headerLine(headline: string | null | undefined, youHave: string): string {
  const h = headline?.trim();
  return h ? `${h}  ·  ${youHave}` : youHave;
}

/** Download, check, install: the card shows progress and offers nothing else meanwhile. */
export function isBusy(phase: UpdatePhase): boolean {
  return phase.kind === "downloading" || phase.kind === "verifying" || phase.kind === "installing";
}
