// The closed island: what stays at the top of the screen once the island is
// folded all the way, where a Mac has its notch. A PC has no notch to hide
// behind, so instead of vanishing (which left nothing to find it by) the
// island keeps a small black shape there, with one thing in it: Mochi (what a
// Mac shows on a screen without a notch), the time, the date and the time, the
// Claude plan's usage, what plays, Coucoudoro focus timer, or nothing at all.
// "hidden" keeps the old behaviour: nothing shows, the top edge wakes it.
// No DOM here: the island draws what this returns.

import { dominantPct, planColor, type PlanUsage } from "./plan";
import { CoucoudoroController } from "./coucoudoro";

export type ClosedIsland = "mochi" | "time" | "datetime" | "claude" | "music" | "coucoudoro" | "empty" | "hidden";

export const CLOSED_ISLANDS: readonly ClosedIsland[] = ["mochi", "time", "datetime", "claude", "music", "coucoudoro", "empty", "hidden"];

/** A value this build doesn't know (written by a newer one) reads as the default. */
export function closedIsland(value: unknown): ClosedIsland {
  return CLOSED_ISLANDS.includes(value as ClosedIsland) ? (value as ClosedIsland) : "mochi";
}

/** The closed island's size where there is nothing but Mochi, in CSS px: the
 *  Mac's resting island on a screen without a notch (IslandScreenGeometry). */
export const CLOSED_H = 24;
export const CLOSED_MIN_W = 88;
/** Balanced Dynamic Island resting width (Mochi on left + clean clock on right). */
export const CLOSED_BALANCED_W = 150;
/** Mochi in it, as on that Mac: centred, a little smaller than the island is tall. */
export const CLOSED_BOT_D = 18;
/** Widest: a generous limit so full dates/times or song titles have ample space without running across the screen. */
export const CLOSED_MAX_W = 420;
/** Room on each side of the text, generous to clear the curved corners. */
export const CLOSED_PAD = 24;

export interface ClosedContent {
  text: string;
  /** A coloured dot before the text (the plan's gauge colour, focus phase, or app branding). */
  dot: string | null;
  /** A note before the text (what plays). */
  note: boolean;
  /** True when displaying an active notification in the small notch. */
  isNotification?: boolean;
  /** True when Mochi is displayed on the left of the closed notch (Welcome Back banner). */
  bot?: boolean;
  /** True when displaying a personal welcome companion message. */
  isWelcome?: boolean;
}

export interface ClosedInputs {
  now: Date;
  /** The interface's language, for the date and the time. */
  locale?: string;
  planUsage: PlanUsage | null;
  /** The song playing, if one plays on a declared music pill. */
  music: { title: string; artist: string } | null;
  /** Active notification (WhatsApp, social apps, system toast) to display in the small notch. */
  notification?: { text: string; dot: string } | null;
  /** Active personal welcome-back message with Mochi on the left. */
  welcome?: { text: string; bot: boolean } | null;
}

export function closedTime(now: Date, locale?: string): string {
  return now.toLocaleTimeString(locale, { hour: "2-digit", minute: "2-digit" });
}

function time(now: Date, locale?: string): string {
  return closedTime(now, locale);
}

/**
 * What the closed island shows, or null when it shows nothing (the empty
 * shape, or no island at all). The Claude usage, music and Coucoudoro fall back to
 * the time while there is nothing to show, so the island is never blank by
 * surprise.
 */
export function closedContent(style: ClosedIsland, input: ClosedInputs): ClosedContent | null {
  if (style === "hidden") return null;

  // Active welcome message with Mochi on left takes top priority when user returns
  if (input.welcome && input.welcome.text) {
    return {
      text: input.welcome.text,
      dot: null,
      note: false,
      bot: input.welcome.bot !== false,
      isWelcome: true,
    };
  }

  // Active notification takes top priority in the small notch (Dynamic Island morph)
  if (input.notification && input.notification.text) {
    return {
      text: input.notification.text,
      dot: input.notification.dot,
      note: false,
      isNotification: true,
    };
  }

  const plain = (text: string): ClosedContent => ({ text, dot: null, note: false });
  switch (style) {
    case "empty":
    case "mochi":
      return null;
    case "time":
      return plain(time(input.now, input.locale));
    case "datetime": {
      const date = input.now.toLocaleDateString(input.locale, { weekday: "short", day: "numeric", month: "short" });
      return plain(`${date}  ${time(input.now, input.locale)}`);
    }
    case "claude": {
      const pct = dominantPct(input.planUsage, input.now.getTime());
      if (pct == null) return plain(time(input.now, input.locale));
      return { text: `Claude ${Math.round(pct)}%`, dot: planColor(pct), note: false };
    }
    case "music": {
      const m = input.music;
      if (!m || !m.title) return plain(time(input.now, input.locale));
      return { text: m.artist ? `${m.title} · ${m.artist}` : m.title, dot: null, note: true };
    }
    case "coucoudoro": {
      const ctrl = CoucoudoroController.shared;
      const snap = ctrl.snapshot;
      if (snap.phase === "idle") return plain(time(input.now, input.locale));
      const dot = snap.paused ? "#F59E0B" : (snap.phase === "rest" ? "#10B981" : "#0EA5E9");
      return { text: ctrl.clock(), dot, note: false };
    }
  }
}

/** The closed island's width for a text `textWidth` px wide (0 for none), with generous clearance. */
export function closedWidth(textWidth: number, extras = 0): number {
  if (!(textWidth > 0)) return CLOSED_MIN_W;
  const w = Math.ceil(textWidth + extras + CLOSED_PAD * 2);
  return Math.max(CLOSED_MIN_W, Math.min(CLOSED_MAX_W, w));
}
