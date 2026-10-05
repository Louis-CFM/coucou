// Devin poller events → island state. The Windows/Linux port of the macOS
// DevinMonitor's apply path: one pill aggregates every cloud session, each
// transition becomes a ticker step, waiting-for-you gets the question sound
// and a badge, and the pill opens the session the poller chose (by id, never
// a guessed URL).

import { onEvent } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, type AgentTask } from "../core/state";

const ID = "agent_devin";
const FALLBACK_URL = "https://app.devin.ai/sessions";

interface DevinTick {
  kind: "started" | "working" | "waiting" | "finished" | "failed" | "rate" | "suspended" | "pr";
  step: string;
}

interface DevinUpdate {
  state: AgentTask["state"];
  name: string;
  url: string | null;
  tracked: number;
  active: number;
  user: string | null;
  error: string | null;
  events: DevinTick[];
}

export function registerDevinHandlers() {
  void onEvent<DevinUpdate>("devin", apply);
}

function apply(update: DevinUpdate) {
  // Paused means paused: no pill updates either.
  if (State.paused) return;

  State.integrations[ID] = {
    data: { activeCount: update.active, url: update.url ?? FALLBACK_URL, user: update.user },
    error: update.error,
    loaded: !update.error,
    configured: true,
  };

  const declared = State.settings.activeIntegrations.includes(ID);
  if (update.tracked === 0) {
    // Nothing to show: a declared pill resets to idle (the Active pills
    // contract), an undeclared one disappears — same as Stop for hook agents.
    const t = State.tasks.find((x) => x.id === ID);
    if (declared && t) {
      t.state = "idle";
      t.steps = [];
      t.stepIndex = 0;
      t.name = "Devin";
      t.pillBadge = null;
    } else if (t) {
      State.removeTask(ID);
    }
    State.notify();
    return;
  }

  State.upsertExternalAgent(ID, "Devin", "#3969CA");
  const t = State.tasks.find((x) => x.id === ID);
  if (!t) return;
  t.state = update.state;
  t.name = update.name || "Devin";

  const focused = State.focusId === ID;
  for (const event of update.events) {
    State.appendStep(ID, event.step);
    switch (event.kind) {
      case "started":
        Sound.play("work");
        break;
      case "waiting":
        Sound.play("question");
        if (!focused) State.setPillBadge(ID, "finished");
        break;
      case "finished":
        Sound.play("finish");
        if (!focused) State.setPillBadge(ID, "finished");
        break;
      case "failed":
        Sound.play("error");
        if (!focused) State.setPillBadge(ID, "error");
        break;
      default:
        break;
    }
  }
  State.notify();
}
