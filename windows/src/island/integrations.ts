// Integration events → island state. Port of the `handle…` methods in the Swift
// pollers: a genuinely new item flips the pill to finished/error, badges it when
// the pill isn't focused, plays a sound, and clears itself after 60 s.

import { onEvent, Bridge, type IntegrationUpdate } from "../core/bridge";
import { Sound } from "../core/sound";
import { State } from "../core/state";
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
  State.integrations[update.id] = {
    data: update.error ? (previous?.data ?? {}) : update.data,
    error: update.error,
    loaded: update.error ? (previous?.loaded ?? false) : true,
    configured: previous?.configured ?? true,
  };

  const event = update.event;
  if (event) {
    const task = State.tasks.find((t) => t.id === update.id);
    if (task) {
      task.state = event.success ? "finished" : "error";
      task.steps = event.detail ? [event.label, event.detail] : [event.label];
      task.stepIndex = task.steps.length - 1;
      if (State.focusId !== update.id) {
        task.pillBadge = event.success ? "finished" : "error";
      }
      Sound.play(event.success ? "finish" : "error");
      // Same as the Swift pollers: show the compact island so the badge is seen,
      // but never steal the screen for a successful deploy.
      island.reveal();

      const existing = clearTimers.get(update.id);
      if (existing != null) window.clearTimeout(existing);
      clearTimers.set(
        update.id,
        window.setTimeout(() => {
          clearTimers.delete(update.id);
          const t = State.tasks.find((x) => x.id === update.id);
          if (!t || (t.state !== "finished" && t.state !== "error")) return;
          t.state = "idle";
          t.steps = [];
          t.stepIndex = 0;
          t.pillBadge = null;
          State.notify();
        }, 60_000),
      );
    }
  }

  State.notify();
}

// ── Live pushes ───────────────────────────────────────────────────────────────

const GITHUB = "integration_github";
let pushCommand: string | null = null;
let pushTimer: number | null = null;
let pushIsland: Island | null = null;

/** The command of a Bash tool call, if it is a `git push`. */
export function gitPushCommand(tool: string, input: Record<string, unknown>): string | null {
  const command = typeof input.command === "string" ? input.command : "";
  return tool === "Bash" && /\bgit\b[^;&|]*\bpush\b/.test(command) ? command : null;
}

/**
 * Claude Code is running `git push`: GitHub can't see a push in flight, but the
 * hook can. The GitHub pill pops up with the push in progress, and the moment
 * it ends the card refreshes from GitHub so the push itself shows.
 */
export function pushStarted(island: Island, command: string, cwd: string | undefined) {
  if (!State.settings.activeIntegrations.includes(GITHUB)) return;
  // The folder pushed from: a `cd <dir>` or `git -C <dir>` in the command wins
  // over Claude Code's working folder.
  const moved = [...command.matchAll(/(?:\bcd|\bgit\s+-C)\s+("[^"]+"|'[^']+'|[^\s;&|]+)/g)].pop()?.[1];
  const dir = (moved ?? cwd ?? "").replace(/^["']|["']$/g, "");
  const repo = dir.split(/[\\/]/).filter(Boolean).pop() ?? "repo";
  pushCommand = command;
  if (pushTimer != null) window.clearTimeout(pushTimer);
  State.githubPush = { repo, state: "pushing", startedAt: Date.now() };
  const task = State.tasks.find((t) => t.id === GITHUB);
  if (task) {
    task.state = "working";
    task.steps = [`Pushing ${repo}`];
    task.stepIndex = 0;
  }
  // Pop up: show the GitHub card with the push, and give the view back after.
  if (State.focusId !== GITHUB) {
    State.returnFocusId = State.focusId;
    State.focusId = GITHUB;
  }
  // Held open for the whole push: the usual auto-close (3 s for some) would
  // fold the card away long before a big push ends.
  pushIsland = island;
  island.alert("overview");
  island.hold(true);
  // No end ever comes if Claude Code is killed mid-push: give up after 10 min.
  pushTimer = window.setTimeout(() => pushEnded(command, false), 600_000);
  Sound.play("send");
  State.notify();
}

/** The push's tool call ended (ok or failed). */
export function pushEnded(command: string, ok: boolean) {
  if (!State.githubPush || command !== pushCommand) return;
  pushCommand = null;
  if (pushTimer != null) window.clearTimeout(pushTimer);
  State.githubPush = { ...State.githubPush, state: ok ? "done" : "failed" };
  const task = State.tasks.find((t) => t.id === GITHUB);
  if (task) {
    task.state = ok ? "finished" : "error";
    task.steps = [`${ok ? "Pushed" : "Push failed"}: ${State.githubPush.repo}`];
    task.stepIndex = 0;
  }
  Sound.play(ok ? "finish" : "error");
  void Bridge.refreshIntegration(GITHUB);
  State.notify();
  pushTimer = window.setTimeout(() => {
    pushTimer = null;
    State.githubPush = null;
    const t = State.tasks.find((x) => x.id === GITHUB);
    if (t && (t.state === "finished" || t.state === "error")) t.state = "idle";
    if (State.focusId === GITHUB) State.restoreFocus();
    pushIsland?.hold(false);
    State.notify();
  }, 8000);
}
