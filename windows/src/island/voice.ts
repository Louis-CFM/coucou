// « OK Coucou » asks the island what only it knows (src-tauri/src/voice): the
// pills, to add, remove or pick the main one, and the user's own data for
// Claude to answer from. Port of the Mac's VoiceTools pills and service_info.

import { invoke } from "@tauri-apps/api/core";
import { Bridge, IS_TAURI, onEvent } from "../core/bridge";
import { MAX_DECLARED, availablePills, chooseMainPill, pillDefinition, sanitizeDeclared, toggleDeclared } from "../core/pills";
import { Spotify } from "../core/spotify";
import { State } from "../core/state";
import { serviceCards } from "./phone-services";

interface Ask {
  id: number;
  kind: "pills" | "info";
  input: { action?: string; names?: string[] };
}

const norm = (s: string) =>
  s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]/g, "");

/** The pill a spoken name means: exact, then the start, then anywhere in it. */
export function findPill(name: string): string | null {
  const wanted = norm(name);
  if (!wanted) return null;
  const pills = availablePills(State.os).filter((p) => p.support !== "soon");
  const hit =
    pills.find((p) => norm(p.name) === wanted || norm(p.id.replace(/^(integration|agent)_/, "")) === wanted) ??
    pills.find((p) => norm(p.name).startsWith(wanted)) ??
    pills.find((p) => norm(p.name).includes(wanted) || wanted.includes(norm(p.name)));
  return hit?.id ?? null;
}

function describe(): string {
  const d = sanitizeDeclared(State.settings, State.os);
  const name = (id: string) => pillDefinition(id)?.name ?? id;
  const all = availablePills(State.os).filter((p) => p.support !== "soon").map((p) => p.name);
  return JSON.stringify({
    main: name(d.mainPill),
    shown: d.activeIntegrations.map(name),
    maxBesidesMain: MAX_DECLARED,
    available: all,
  });
}

function pills(input: Ask["input"]): string {
  const action = input.action ?? "list";
  if (action === "list") return describe();
  const names = input.names ?? [];
  const done: string[] = [];
  const failed: string[] = [];
  for (const spoken of names) {
    const id = findPill(spoken);
    if (!id) {
      failed.push(`${spoken}: unknown pill`);
      continue;
    }
    const d = sanitizeDeclared(State.settings, State.os);
    const label = pillDefinition(id)?.name ?? id;
    if (action === "set_main") {
      const next = chooseMainPill(d, id, State.os);
      if (!next) {
        failed.push(`${label}: cannot be the main pill (only workspace tools can)`);
        continue;
      }
      State.settings.mainPill = next.mainPill;
      State.settings.activeIntegrations = next.activeIntegrations;
      done.push(label);
      continue;
    }
    const shown = id === d.mainPill || d.activeIntegrations.includes(id);
    if ((action === "add" && shown) || (action === "remove" && !shown)) {
      done.push(label);
      continue;
    }
    const next = toggleDeclared(d, id, State.os);
    if (!next) {
      failed.push(action === "add" ? `${label}: already ${MAX_DECLARED} pills, remove one first` : `${label}: the main pill cannot be removed`);
      continue;
    }
    State.settings.activeIntegrations = next;
    done.push(label);
  }
  if (done.length) {
    const previousMain = State.mainPillId;
    State.loadIntegrationTasks();
    if (State.mainPillId !== previousMain) State.setFocus(State.mainPillId);
    void Bridge.saveSettings(State.settings);
  }
  return JSON.stringify({ done, failed, now: JSON.parse(describe()) });
}

function info(): string {
  const sessions = State.tasks
    .filter((t) => !t.isIntegration || t.state !== "idle" || t.steps.length > 0)
    .map((t) => ({ pill: t.name, state: t.state, doing: t.steps[t.stepIndex] ?? t.steps[t.steps.length - 1] ?? null }));
  const plan = (p: typeof State.planUsage) =>
    p && {
      fiveHourPercent: p.fiveHour?.usedPct ?? null,
      weekPercent: p.sevenDay?.usedPct ?? null,
    };
  const s = Spotify.state;
  return JSON.stringify({
    pills: JSON.parse(describe()),
    sessions,
    claudePlan: plan(State.planUsage),
    codexPlan: plan(State.codexPlanUsage),
    spotify: s.running && s.track ? { playing: s.playing, title: s.track.title, artist: s.track.artist } : null,
    services: serviceCards().map((c) => ({ service: c.title, headline: c.headline, about: c.reason, items: c.items })),
  });
}

export function registerVoiceHandlers() {
  if (!IS_TAURI) return;
  void onEvent<Ask>("voice-ask", (ask) => {
    let text: string;
    try {
      text = ask.kind === "pills" ? pills(ask.input ?? {}) : info();
    } catch (err) {
      text = `error: ${String(err)}`;
    }
    void invoke("voice_done", { id: ask.id, text }).catch(() => {});
  });
}
