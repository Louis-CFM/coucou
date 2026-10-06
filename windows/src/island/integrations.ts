// Integration events → island state. Port of the `handle…` methods in the Swift
// pollers: a genuinely new item flips the pill to finished/error, badges it when
// the pill isn't focused, plays a sound, and clears itself after 60 s.

import { onEvent, Bridge, type GithubData, type IntegrationUpdate } from "../core/bridge";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import { enterGithubPanel, sawRunEnd } from "../views/github";
import type { Island } from "./island";

/** Which Credential Manager key backs each pill. */
const KEY_FOR: Record<string, string> = {
  integration_stripe: "stripe-api-key",
  integration_github: "github-token",
  integration_vercel: "vercel-token",
  integration_n8n: "n8n-api-key",
  integration_resend: "resend-api-key",
  integration_notion: "notion-api-key",
  integration_calcom: "calcom-api-key",
};

const clearTimers = new Map<string, number>();
/** As in the Swift pollers: a pill's finished or error look clears itself after this. */
const SETTLE_MS = 60_000;
/**
 * News that speaks up stays longer: it is what tells of a build that broke,
 * and someone away from the screen for a minute must still find it there.
 * Opening it ends it sooner.
 */
const NEWS_MS = 5 * 60_000;

const GITHUB = "integration_github";

/**
 * Integrations whose news opens the island, the way a Claude Code session's
 * result does: their Mochi steps to the front and the island unfolds on the
 * finished or the error card, which says the news in words. Among four mini
 * Mochis a badge on one is easy to miss — and the folded pill has no room
 * for words: the island hides in a MacBook's notch, its middle is the notch.
 */
const SPEAKS_UP = new Set([GITHUB]);
/** The pill each of them took the front from, to hand it back. */
const borrowedFrom = new Map<string, string>();
/** States that are waiting for the user: nothing takes the front from those. */
const WAITING = new Set(["approval", "question"]);

/** Hands the front of the pill back, unless the user moved it since. */
function giveBack(id: string) {
  const previous = borrowedFrom.get(id);
  borrowedFrom.delete(id);
  if (previous && State.focusId === id) State.setFocus(previous);
}

/**
 * A pill's news is over — it got old, or it was opened, and news that was
 * opened is not news any more: the pill goes back to rest. Unless the user is
 * being taken to what it was about (`stay`), the front goes back to whoever
 * had it.
 */
function settle(id: string, stay = false) {
  const timer = clearTimers.get(id);
  if (timer != null) window.clearTimeout(timer);
  clearTimers.delete(id);
  const info = State.integrations[id];
  if (info) info.news = null;
  if (stay) borrowedFrom.delete(id);
  else giveBack(id);
  const task = State.tasks.find((t) => t.id === id);
  if (task && (task.state === "finished" || task.state === "error")) {
    task.state = "idle";
    task.steps = [];
    task.stepIndex = 0;
    task.pillBadge = null;
  }
  State.notify();
}

/** The pill whose news the user is looking at: the one at the front, else GitHub's. */
function newsId(): string | null {
  const telling = (id: string | null) => id != null && SPEAKS_UP.has(id) && State.integrations[id]?.news != null;
  return telling(State.focusId) ? State.focusId : telling(GITHUB) ? GITHUB : null;
}

/**
 * Straight to what the news is about — from its card, from the panel's line,
 * or from a click on Mochi while he has some to tell. False when there was
 * none to follow.
 */
export function followNews(island: Island): boolean {
  const id = newsId();
  const news = id ? State.integrations[id]?.news : null;
  if (!id || !news) return false;
  Sound.play("blip");
  enterGithubPanel(news.open);
  settle(id, true);
  island.setView("github");
  return true;
}

export function registerIntegrationHandlers(island: Island) {
  void onEvent<IntegrationUpdate>("integration", (update) => handle(island, update));
  void refreshConfigured();
}

/** Asks Rust which keys exist so the idle cards can say so. */
export async function refreshConfigured() {
  for (const [id, key] of Object.entries(KEY_FOR)) {
    const present = (await Bridge.secretPresent(key)) ?? false;
    const info = State.integrations[id] ?? { data: {}, error: null, loaded: false, configured: false };
    State.integrations[id] = { ...info, configured: present };
  }
  const hooks = State.settings.hooksInstalled;
  const claude = State.integrations.integration_claude ?? {
    data: {}, error: null, loaded: false, configured: false,
  };
  State.integrations.integration_claude = { ...claude, configured: hooks };
  State.notify();
}

function handle(island: Island, update: IntegrationUpdate) {
  if (State.paused) return;

  const previous = State.integrations[update.id];
  // A failed poll normally carries no data and keeps what was there. GitHub's
  // carries its last good snapshot, so the panel can go on showing it next to
  // the reason it isn't fresh.
  const hasData = Object.keys(update.data).length > 0;
  State.integrations[update.id] = {
    data: hasData ? update.data : (previous?.data ?? {}),
    error: update.error,
    loaded: hasData || (previous?.loaded ?? false),
    configured: previous?.configured ?? true,
    news: update.event ?? previous?.news ?? null,
  };

  // A run going on one of the projects: GitHub's Mochi is at work, like a
  // session's, until it ends — in news, or quietly.
  if (update.id === GITHUB && hasData) {
    const repos = (update.data as Partial<GithubData>).repos ?? [];
    const going = repos.some((r) => r.build?.state === "running");
    const task = State.tasks.find((t) => t.id === update.id);
    if (task && going && task.state === "idle") task.state = "working";
    else if (task && !going && task.state === "working") task.state = "idle";
  }

  const event = update.event;
  if (event) {
    const task = State.tasks.find((t) => t.id === update.id);
    if (task) {
      task.state = event.success ? "finished" : "error";
      task.steps = event.detail ? [event.label, event.detail] : [event.label];
      task.stepIndex = task.steps.length - 1;
      // Only while the island is away or folded: open, it is showing something
      // the user is reading, and the news has its own place there.
      const front = State.focusTask;
      let opened = false;
      if (
        SPEAKS_UP.has(update.id) && State.mode !== "expanded" && State.focusId !== update.id &&
        State.focusId && !(front && WAITING.has(front.state))
      ) {
        if (!borrowedFrom.has(update.id)) borrowedFrom.set(update.id, State.focusId);
        State.setFocus(update.id);
        opened = true;
      }
      if (State.focusId !== update.id) {
        task.pillBadge = event.success ? "finished" : "error";
      }
      // A run the panel was showing when it ended has been played there already.
      const about = event.open?.target;
      const heard = about?.kind === "run" && sawRunEnd(about.id);
      if (!heard) Sound.play(event.success ? "finish" : "error");
      // Same as the Swift pollers: show the compact island so the badge is seen,
      // but never steal the screen for a successful deploy. News that speaks up
      // unfolds the island on its card instead; it folds back on its own.
      if (opened) island.alert(event.success ? "finished" : "error");
      else island.reveal();

      const existing = clearTimers.get(update.id);
      if (existing != null) window.clearTimeout(existing);
      clearTimers.set(
        update.id,
        window.setTimeout(() => settle(update.id), SPEAKS_UP.has(update.id) ? NEWS_MS : SETTLE_MS),
      );
    }
  }

  State.notify();
}
