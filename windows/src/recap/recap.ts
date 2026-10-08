// Weekly recap — when the card opens, and what it shows. Port of
// AppDelegate.checkMondayRecap / openWeeklyRecap.
//
// It opens on its own once a week, on Monday from 8 am, at the first of:
//   * the launch greeting ending (the app starting that day),
//   * an agent starting work (SessionStart / UserPromptSubmit — Rust sends
//     `recap-check` when it sees one),
//   * the island waking from hidden (the user coming back to the machine).
// And any time from the tray: "Weekly recap". Nothing here runs on a timer.

import { Bridge, IS_TAURI } from "../core/bridge";
import type { IslandViewName } from "../core/layout";
import { State } from "../core/state";
import {
  DEFAULT_PREFS, dayKey, mondayOf, previousWeekStart, sampleHistory, shouldAutoShow, summarize,
  type RecapPrefs, type WeeklySummary,
} from "./summary";

/** What the recap needs from the island. */
export interface RecapHost {
  alert(view: IslandViewName): void;
}

/** Views the Monday card may replace; anything else is the user busy with something. */
const QUIET_VIEWS: ReadonlySet<IslandViewName> = new Set(["overview", "empty", "settings", "greeting"]);

/** Same 1.5 s as the Mac, so it never lands on top of the event that triggered it. */
const SHOW_DELAY_MS = 1500;

class RecapController {
  summary: WeeklySummary | null = null;
  prefs: RecapPrefs = { ...DEFAULT_PREFS };
  /** Bumped on every load, so the view knows to rebuild (and leave share mode). */
  version = 0;
  private checking = false;

  /** Reads last week from Rust. A plain browser (`npm run dev`) gets the sample week. */
  async load(now = new Date()): Promise<WeeklySummary | null> {
    const start = previousWeekStart(now);
    const history = IS_TAURI
      ? await Bridge.recapHistory(start.getTime() / 1000)
      : sampleHistory(start);
    this.prefs = { ...DEFAULT_PREFS, ...(history?.prefs ?? {}) };
    this.summary = history ? summarize(history, start) : null;
    this.version++;
    return this.summary;
  }

  /** Tray → Weekly recap. Shows the card even for an empty week. */
  async open(host: RecapHost) {
    await this.load();
    host.alert("recap");
  }

  /** Monday ≥ 8 am, not shown yet this week, something to show, nobody interrupted. */
  async check(host: RecapHost, now = new Date()) {
    // The clock first: six days out of seven this is all that runs.
    if (this.checking || !shouldAutoShow(now, "") || !this.quiet()) return;
    this.checking = true;
    try {
      const prefs = IS_TAURI ? await Bridge.recapPrefs() : null;
      if (!prefs?.enabled || !shouldAutoShow(now, prefs.lastShownWeek)) return;
      if (!(await this.load(now))) return;
      const week = dayKey(mondayOf(now));
      window.setTimeout(() => {
        if (!this.quiet()) return;
        host.alert("recap");
        void Bridge.recapMarkShown(week);
        this.prefs.lastShownWeek = week;
      }, SHOW_DELAY_MS);
    } finally {
      this.checking = false;
    }
  }

  private quiet(): boolean {
    if (State.paused || State.pendingApproval) return false;
    return State.mode !== "expanded" || QUIET_VIEWS.has(State.view);
  }

  async setHideProjects(hide: boolean) {
    this.prefs.hideProjects = hide;
    await Bridge.recapSetHideProjects(hide);
  }
}

export const Recap = new RecapController();
