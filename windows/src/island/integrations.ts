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
  // The island's API dot reflects this, and it is asked separately from the
  // integration cards: a saved Anthropic key says nothing about whether Pi is
  // reachable, and Pi needs no key at all.
  State.anthropicKeyPresent = (await Bridge.secretPresent("anthropic-api-key")) ?? false;
  for (const [id, key] of Object.entries(KEY_FOR)) {
    const present = (await Bridge.secretPresent(key)) ?? false;
    const info = State.integrations[id] ?? { data: {}, error: null, loaded: false, configured: false };
    State.integrations[id] = { ...info, configured: present };
  }
  State.notify();
}

/**
 * Which agent each declared pill belongs to. These pills are wired to hooks, not
 * to an API key, so their configured state comes from whether that agent's hooks
 * are actually installed — reporting "true" unconditionally would paint a green
 * pill for an agent nothing is listening to.
 */
const AGENT_FOR_PILL: Record<string, string> = {
  integration_claude: "claudeCode",
  agent_pi: "pi",
  agent_copilot: "copilot",
  agent_antigravity: "antigravity",
  // Without this, `hooksInstalledByAgent.codex` is never written, so
  // `isAgentHooked("codex")` stays null and the island dot is stuck on amber
  // forever — which reads as "still checking" rather than "not installed".
  agent_codex: "codex",
};

/**
 * Asks Rust which agents are hooked up. Runs at boot and whenever the settings
 * window reports a change, so installing or removing hooks is reflected without
 * a restart.
 */
export async function refreshHookStatus() {
  await Promise.all(
    Object.entries(AGENT_FOR_PILL).map(async ([pillId, agent]) => {
      const status = await Bridge.hooksStatus(agent);
      if (!status) return;
      State.hooksInstalledByAgent[agent] = status.installed && status.managed;
      const info = State.integrations[pillId] ?? {
        data: {}, error: null, loaded: false, configured: false,
      };
      State.integrations[pillId] = { ...info, configured: status.installed };
    }),
  );
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
