// What's new after an update — when the card opens. Once per version, a few
// seconds after Coucou starts (after the greeting), and only when nothing
// waits in the island: a permission or a question always comes first, and
// another card the user is reading is never replaced. The rules are in
// whats-new.ts; the card is views/whatsnew.ts.
//
// The numbers of "Your Coucou so far" are read from this computer (the
// recap, Flow, the Notetaker) at that moment; nothing goes out.

import { Bridge, IS_TAURI } from "../core/bridge";
import { FlowBridge } from "../core/flow";
import type { IslandViewName } from "../core/layout";
import { State } from "../core/state";
import { Updates } from "../island/update";
import { sampleHistory, previousWeekStart, type RecapHistory } from "../recap/summary";
import FILE from "./whats-new.json";
import {
  decideOnLaunch, releaseFor, soFar, usedBefore,
  type Stat, type WhatsNewFile, type WhatsNewRelease,
} from "./whats-new";

/** What the card needs from the island. */
export interface WhatsNewHost {
  alert(view: IslandViewName): void;
  collapse(): void;
}

/** The last version this install saw. A convenience of this install, like the plan usage. */
const LAST_KEY = "coucou.whatsNew.lastVersion";

/** After the greeting, so the two never meet; then every few seconds while the island is busy. */
const FIRST_DELAY_MS = 3000;
const RETRY_MS = 5000;
const RETRIES = 24;

/** Views the card may replace: the island at rest. */
const QUIET_VIEWS: ReadonlySet<IslandViewName> = new Set(["overview", "empty"]);

function readLast(): string | null {
  try {
    return window.localStorage?.getItem(LAST_KEY) ?? null;
  } catch {
    return null;
  }
}

function writeLast(version: string) {
  try {
    window.localStorage?.setItem(LAST_KEY, version);
  } catch {
    // Storage refused: the card may come once more, never more than that per launch.
  }
}

class WhatsNewController {
  /** The release the card shows (null: no card). */
  release: WhatsNewRelease | null = null;
  stats: Stat[] = [];
  /** 1: what's new; 2: your Coucou so far. */
  step: 1 | 2 = 1;
  /** Bumped when the card opens, so the view rebuilds. */
  generation = 0;
  private host: WhatsNewHost | null = null;
  private started = false;

  /** At launch, once: show the card if Coucou was just updated. */
  async launch(host: WhatsNewHost) {
    if (this.started) return;
    this.started = true;
    this.host = host;

    // `npm run dev` in a browser: ?whats-new shows the card with the sample week.
    if (!IS_TAURI) {
      if (!location.search.includes("whats-new")) return;
      const release = (FILE as WhatsNewFile).releases[0] ?? null;
      if (!release) return;
      const history = sampleHistory(previousWeekStart(new Date()));
      this.prepare(release, soFar({ history, flow: { words: 4210, minutesSaved: 63, dictations: 88 }, calls: 3 }));
      this.openWhenQuiet(null, 0);
      return;
    }

    const current = Updates.status.current;
    const lastSeen = readLast();
    // Six launches out of seven this is all that runs.
    if (!current || lastSeen === current) return;

    const release = releaseFor(FILE as WhatsNewFile, current);
    const [history, flow, notes] = await Promise.all([
      Bridge.recapHistory(0),
      FlowBridge.stats(),
      FlowBridge.notes(),
    ]);
    const calls = notes?.notes.filter((n) => n.status === "ready").length ?? 0;
    const decision = decideOnLaunch({
      current,
      lastSeen,
      usedBefore: usedBefore({
        consent: Updates.status.consent,
        history,
        dictations: flow?.all.dictations ?? 0,
        notes: notes?.notes.length ?? 0,
      }),
      hasEntry: release != null,
    });
    if (!decision.show || !release) {
      if (decision.record) writeLast(current);
      return;
    }
    this.prepare(release, soFar({ history: history as RecapHistory | null, flow: flow?.all ?? null, calls }));
    this.openWhenQuiet(current, 0);
  }

  private prepare(release: WhatsNewRelease, stats: Stat[]) {
    this.release = release;
    this.stats = stats;
    this.step = 1;
    this.generation++;
  }

  private openWhenQuiet(version: string | null, attempt: number) {
    window.setTimeout(() => {
      if (!this.quiet()) {
        if (attempt < RETRIES) this.openWhenQuiet(version, attempt + 1);
        // Busy for two minutes: next launch, then (the version is not recorded).
        return;
      }
      if (version) writeLast(version);
      this.host?.alert("whatsNew");
    }, attempt === 0 ? FIRST_DELAY_MS : RETRY_MS);
  }

  private quiet(): boolean {
    if (State.paused || State.pendingApproval) return false;
    return State.mode !== "expanded" || QUIET_VIEWS.has(State.view);
  }

  next() {
    this.step = 2;
    State.notify();
  }

  back() {
    this.step = 1;
    State.notify();
  }

  /** "All changes": the release page of this version on GitHub. */
  openReleasePage(url: string) {
    void Bridge.openUrl(url);
  }

  openCoffee(url: string) {
    void Bridge.openUrl(url);
  }

  done() {
    this.host?.collapse();
  }
}

export const WhatsNew = new WhatsNewController();
