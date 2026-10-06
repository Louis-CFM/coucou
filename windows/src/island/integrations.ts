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
  // Connected once Google has handed back a refresh token.
  integration_gcal: "gcal-refresh-token",
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
    // Google is connected and disconnected from the settings window, which the
    // key check at boot doesn't see: the poller's own answer says which it is
    // (events, or an error such as an expired sign-in, versus the `{}` that
    // disconnecting sends).
    configured:
      update.id === "integration_gcal"
        ? update.error != null || Array.isArray(update.data.events)
        : (previous?.configured ?? true),
  };

  const event = update.event;
  if (event) {
    const task = State.tasks.find((t) => t.id === update.id);
    if (task) {
      // Something waiting on you (a review asked of you, a meeting about to
      // start) reads as a question with the amber badge, not as done or broken.
      const attention = event.attention === true;
      task.state = attention ? "question" : event.success ? "finished" : "error";
      task.steps = event.detail ? [event.label, event.detail] : [event.label];
      task.stepIndex = task.steps.length - 1;
      if (State.focusId !== update.id) {
        task.pillBadge = attention ? "approval" : event.success ? "finished" : "error";
      }

      if (event.item && update.id === "integration_gcal") {
        // A reminder is a message, not a badge: open a card that says what,
        // when and where, with Join / Open. Unless you are in the middle of
        // something — the chat, an approval, a file drop — then it waits as
        // the amber badge on the Calendar pill.
        Sound.play("approval");
        const busy: string[] = ["prompt", "approval", "question", "upload", "uploading", "choose", "mail"];
        if (State.mode === "expanded" && busy.includes(State.view)) {
          island.reveal();
        } else {
          State.reminder = event.item;
          State.setFocus(update.id);
          if (State.mode === "expanded") island.setView("reminder");
          else island.alert("reminder");
        }
      } else {
        Sound.play(attention ? "question" : event.success ? "finish" : "error");
        // Same as the Swift pollers: show the compact island so the badge is seen,
        // but never steal the screen for a successful deploy.
        island.reveal();
      }

      const existing = clearTimers.get(update.id);
      if (existing != null) window.clearTimeout(existing);
      clearTimers.set(
        update.id,
        window.setTimeout(() => {
          clearTimers.delete(update.id);
          const t = State.tasks.find((x) => x.id === update.id);
          if (!t || (t.state !== "finished" && t.state !== "error" && t.state !== "question")) return;
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
