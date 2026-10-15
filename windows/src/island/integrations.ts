// Integration events → island state. Port of the `handle…` methods in the Swift
// pollers: a genuinely new item flips the pill to finished/error, badges it when
// the pill isn't focused, plays a sound, and clears itself after 60 s.

import { onEvent, Bridge, type IntegrationUpdate } from "../core/bridge";
import { gitHubAlert, type GitHubEvent } from "../core/github";
import { availablePills } from "../core/pills";
import { Sound } from "../core/sound";
import { MUSIC_ID, State, type NowPlaying } from "../core/state";
import type { Island } from "./island";

const GITHUB = "integration_github";

const clearTimers = new Map<string, number>();

export function registerIntegrationHandlers(island: Island) {
  void onEvent<IntegrationUpdate>("integration", (update) => handle(island, update));
  void onEvent<GitHubEvent[]>("github-alerts", handleGitHubAlerts);
  void onEvent<NowPlaying | null>("now-playing", nowPlaying);
  void Bridge.musicNow().then((np) => nowPlaying(np ?? null));
  void refreshConfigured();
  State.subscribe(refreshGitHubWhenShown);
}

/** What the Windows media controls say is playing (music.rs), as it changes. */
function nowPlaying(np: NowPlaying | null) {
  if (np == null && State.nowPlaying == null) return;
  State.nowPlaying = np;
  // Melody takes the colour of the cover: pill, card, Mochi and the CSS buttons
  // (unless the user picked a colour of their own for her).
  const melody = State.tasks.find((t) => t.id === MUSIC_ID);
  if (melody && !State.settings.pillColors?.[MUSIC_ID]) melody.color = State.musicColor;
  document.documentElement.style.setProperty("--melody", melody?.color ?? State.musicColor);
  window.dispatchEvent(new Event("now-playing"));
  State.notify();
}

/**
 * AppState.handleGitHubEvents: the loudest event sets the badge — only while the
 * GitHub pill isn't the one on screen — and plays its sound. Unlike the other
 * integrations it leaves Mochi's state alone and the badge stays until the pill
 * is focused, as on macOS.
 */
export function handleGitHubAlerts(events: GitHubEvent[]) {
  if (State.paused) return;
  const alert = gitHubAlert(events);
  if (!alert) return;
  const task = State.tasks.find((t) => t.id === GITHUB);
  if (!task) return;
  if (State.focusId !== GITHUB) task.pillBadge = alert.badge;
  Sound.play(alert.sound);
  State.notify();
}

let gitHubShown = false;

/** The GitHub card just came on screen (focused, island opened): refresh it if stale. */
function refreshGitHubWhenShown() {
  const shown = State.mode === "expanded" && State.focusTask?.id === GITHUB;
  if (shown && !gitHubShown) void Bridge.githubRefresh("pulse");
  gitHubShown = shown;
}

/**
 * Whether each pill is connected, so its idle card can say so: a key in the
 * credential store for a service or a chat provider, the hooks in place for a
 * pill fed by hook events (Mac #183), nothing at all for Claude Desktop.
 */
export async function refreshConfigured() {
  const hooks = (await Bridge.agentHooksStatus()) ?? null;
  for (const def of availablePills(State.os)) {
    let configured: boolean;
    switch (def.connect.kind) {
      case "key":
        configured = (await Bridge.secretPresent(def.connect.key)) ?? false;
        break;
      case "hooks":
        // Without an answer from Rust (a plain browser), the Claude Code pill
        // falls back to what the settings say about its hooks.
        configured = hooks?.[def.id] ??
          (def.id === "integration_claude" ? State.settings.hooksInstalled : false);
        break;
      case "server":
        // A local model server counts once the chat is connected to it.
        configured = State.settings[def.connect.field] !== "";
        break;
      case "none":
        configured = true;
        break;
    }
    const info = State.integrations[def.id] ?? { data: {}, error: null, loaded: false, configured: false };
    State.integrations[def.id] = { ...info, configured };
  }
  State.notify();
}

/** Only the hook-driven pills, for when the island opens: a few small file reads. */
export async function refreshHookPills() {
  const hooks = await Bridge.agentHooksStatus();
  if (!hooks) return;
  for (const [id, present] of Object.entries(hooks)) {
    const info = State.integrations[id] ?? { data: {}, error: null, loaded: false, configured: false };
    State.integrations[id] = { ...info, configured: present };
  }
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

/** What a push needs from the island: open on the GitHub card, held open. */
export interface PushHost {
  alert(view: "overview"): void;
  hold(on: boolean): void;
}

let pushCommand: string | null = null;
let pushTimer: number | null = null;
let pushHost: PushHost | null = null;

/** The command of a Bash tool call, if it is a `git push`. */
export function gitPushCommand(tool: string, input: Record<string, unknown>): string | null {
  const command = typeof input.command === "string" ? input.command : "";
  return (tool === "Bash" || tool === "PowerShell") && /\bgit\b[^;&|]*\bpush\b/.test(command) ? command : null;
}

/** The folder a push runs in: a `cd <dir>` or `git -C <dir>` in it wins over the session's. */
export function pushRepo(command: string, cwd: string | undefined): string {
  const moved = [...command.matchAll(/(?:\bcd|\bgit\s+-C)\s+("[^"]+"|'[^']+'|[^\s;&|]+)/g)].pop()?.[1];
  const dir = (moved ?? cwd ?? "").replace(/^["']|["']$/g, "");
  return dir.split(/[\\/]/).filter(Boolean).pop() ?? "repo";
}

/**
 * Claude Code is running `git push`: GitHub can't see a push in flight, but the
 * hook can. The GitHub pill comes up with the push in progress, held open, and
 * the moment it ends the card refreshes from GitHub so the push itself shows.
 */
export function pushStarted(host: PushHost, command: string, cwd: string | undefined) {
  if (!State.settings.activeIntegrations.includes(GITHUB) || State.paused) return;
  const repo = pushRepo(command, cwd);
  pushCommand = command;
  if (pushTimer != null) window.clearTimeout(pushTimer);
  State.githubPush = { repo, state: "pushing", startedAt: Date.now() };
  const task = State.tasks.find((t) => t.id === GITHUB);
  if (task) {
    task.state = "working";
    task.steps = [`Pushing ${repo}`];
    task.stepIndex = 0;
  }
  // Pop up on the GitHub card; the pill that was in front comes back after.
  if (State.focusId !== GITHUB) {
    pushReturnFocus = State.focusId;
    State.focusId = GITHUB;
  }
  // Held open for the whole push: the usual auto-close would fold the card away
  // long before a big push ends.
  pushHost = host;
  host.alert("overview");
  host.hold(true);
  // No end ever comes if Claude Code is killed mid-push: give up after 10 min.
  pushTimer = window.setTimeout(() => pushEnded(command, false), 600_000);
  Sound.play("send");
  State.notify();
}

let pushReturnFocus: string | null = null;

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
    const back = pushReturnFocus;
    pushReturnFocus = null;
    if (State.focusId === GITHUB && back && State.tasks.some((x) => x.id === back)) State.focusId = back;
    pushHost?.hold(false);
    State.notify();
  }, 8000);
}

