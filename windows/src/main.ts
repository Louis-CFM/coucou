// Entry point: boot the bridge, wire the island, start the greeting.

import "./style.css";
import { Bridge, IS_TAURI, onEvent, type MediaState } from "./core/bridge";
import { Sound } from "./core/sound";
import { State, type Settings } from "./core/state";
import { Island } from "./island/island";
import { registerHookHandlers } from "./island/hooks";
import { registerIntegrationHandlers, refreshConfigured, refreshHookStatus } from "./island/integrations";

async function main() {
  const root = document.getElementById("root");
  if (!root) return;

  void Sound.preload();

  const island = new Island(root);

  const boot = await Bridge.boot();
  if (boot) {
    State.settings = { ...State.settings, ...boot.settings };
  }
  island.applySettings();
  State.loadIntegrationTasks();
  const syncDesktopMochi = () => {
    const focused = State.focusTask;
    void Bridge.desktopMochiSync(
      State.effectiveState,
      focused?.color ?? null,
      focused?.id ?? null,
      focused?.id === "integration_music" && State.integrations.integration_music?.data.playing === true,
      State.pendingApproval !== null,
    );
  };
  State.subscribe(syncDesktopMochi);
  syncDesktopMochi();
  void refreshHookStatus();
  if (boot && !boot.cursorPoll) island.followPageCursor();

  await onEvent<{ x: number; y: number }>("cursor", ({ x, y }) => island.onCursor(x, y));

  /** Pause has to reach Rust too, or the pollers keep calling out. */
  const setPaused = (on: boolean) => {
    if (State.paused === on) return;
    State.paused = on;
    void Bridge.setPaused(on);
  };

  await onEvent<string>("tray", (what) => {
    switch (what) {
      case "settings":
        setPaused(false);
        island.alert("settings");
        break;
      case "open":
        setPaused(false);
        island.alert(State.defaultView());
        break;
      case "pause":
        setPaused(!State.paused);
        if (State.paused) island.fsm.forceHidden();
        else island.reveal();
        break;
    }
  });

  await onEvent<null>("screen-changed", () => void Bridge.reposition());

  // Music: Windows pushes this whenever the media session changes, so the card
  // never polls. The payload is `null` when nothing is playing, which is a
  // normal state and clears the card rather than showing an error.
  await onEvent<MediaState | null>("media-changed", (state) => {
    const previous = State.integrations.integration_music;
    State.integrations.integration_music = {
      data: (state ?? {}) as Record<string, unknown>,
      error: null,
      loaded: true,
      configured: previous?.configured ?? true,
    };
    const task = State.tasks.find((t) => t.id === "integration_music");
    if (task && state?.title) task.steps = [state.title];
    else if (task && !state?.title) task.steps = [];
    State.notify();
  });

  // The settings window writes preferences; apply them here without a restart.
  await onEvent<Settings>("settings-changed", (s) => {
    const shouldPlayMochiReturn = State.settings.desktopMochi && !s.desktopMochi;
    State.settings = { ...State.settings, ...s };
    // Apply the returned setting and let the island render its Mochi canvas again
    // before starting the entrance tween. Otherwise the first frames can be
    // consumed while the island canvas is still hidden for desktop mode.
    island.applySettings();
    State.loadIntegrationTasks();
    if (shouldPlayMochiReturn) {
      requestAnimationFrame(() => island.playMochiTeleportIn());
    }
    void refreshHookStatus();
    void refreshConfigured();
  });

  registerHookHandlers(island);
  registerIntegrationHandlers(island);

  island.launch();

  // In a plain browser there is no wake strip behind the cursor: make the whole
  // page wake the island so the visuals can be checked with `npm run dev`.
  if (!IS_TAURI) {
    document.addEventListener("click", () => Sound.resume(), { once: true });
  }
}

void main();
