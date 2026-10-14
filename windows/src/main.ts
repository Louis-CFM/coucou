// Entry point: boot the bridge, wire the island, start the greeting.

import "./style.css";
import { Bridge, IS_TAURI, onEvent } from "./core/bridge";
import { Sound } from "./core/sound";
import { State, type Settings } from "./core/state";
import { Island } from "./island/island";
import { registerHookHandlers } from "./island/hooks";
import { registerPhoneLink } from "./island/phone-link";
import { registerIntegrationHandlers, refreshConfigured } from "./island/integrations";
import { registerShortcutHandlers } from "./island/shortcuts";
import { applySpotify, registerSpotifyHandlers } from "./island/spotify";
import { applyAppleMusic, registerAppleMusicHandlers } from "./island/apple-music";
import { APPLE_MUSIC_ID } from "./core/apple-music";
import { SPOTIFY_ID } from "./core/spotify";
import { Recap } from "./recap/recap";
import { onLanguageChange, resolveLanguage, setLanguage, systemLanguages } from "./i18n/i18n";

/** Shows the language Settings asks for ("" = the system's, when Coucou has it). */
function applyLanguage() {
  setLanguage(resolveLanguage(State.settings.language, systemLanguages()));
}

async function main() {
  const root = document.getElementById("root");
  if (!root) return;

  void Sound.preload();

  const island = new Island(root);

  const boot = await Bridge.boot();
  if (boot) {
    State.settings = { ...State.settings, ...boot.settings };
  }
  // A language change redraws the island in place: the texts given as tl(…)
  // relabel themselves (views/dom.ts) and the views redraw the rest on this
  // sync. Nothing is rebuilt, so tasks, steps and the chat stay as they are.
  onLanguageChange(() => State.notify());
  applyLanguage();
  // Rust shows the tray and its errors in the same language as the webview.
  void Bridge.setSystemLanguages(systemLanguages());
  island.applySettings();
  if (IS_TAURI) {
    let publishing = false;
    let publishAgain = false;
    const publishPanel = async () => {
      if (publishing) { publishAgain = true; return; }
      publishing = true;
      try {
        do {
          publishAgain = false;
          const agents = State.tasks.filter(t => !t.isIntegration || t.sessionId);
          const waiting = agents.filter(t => ["approval", "question"].includes(t.state));
          const working = agents.filter(t => ["working", "thinking", "searching"].includes(t.state));
          const focus = waiting[0] ?? working[0];
          const phase = waiting.length || State.pendingApproval ? "waiting" : working.length ? "working" : "idle";
          const integrated = await Bridge.publishPanelState({working: working.length,
            waiting: Math.max(waiting.length, State.pendingApproval ? 1 : 0),
            agent: focus?.name ?? "", phase, expanded: State.mode === "expanded",
            closing: State.panelClosing, ...island.panelSurface()});
          if (integrated !== null && State.panelIntegration !== integrated) {
            State.panelIntegration = integrated;
            State.notify();
          }
        } while (publishAgain);
      } finally { publishing = false; }
    };
    State.subscribe(() => void publishPanel());
    window.setInterval(() => void publishPanel(), 1000);
    await publishPanel();
  }
  State.loadIntegrationTasks();
  if (boot && !boot.cursorPoll) island.followPageCursor();
  await island.desktop.init();

  await onEvent<{ x: number; y: number }>("cursor", ({ x, y }) => island.onCursor(x, y));
  await onEvent<boolean>("pointer-inside", (inside) => island.setPointerInside(inside));

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
      case "recap":
        setPaused(false);
        void Recap.open(island);
        break;
      case "wardrobe":
        setPaused(false);
        island.alert("wardrobe");
        break;
      case "pause":
        setPaused(!State.paused);
        if (State.paused) island.fsm.forceHidden();
        else island.reveal();
        break;
    }
  });

  await onEvent<null>("screen-changed", () => void Bridge.reposition());

  // Settings → Reload sounds: read the sounds folder again, and let them hear it.
  await onEvent<null>("sounds-changed", () => {
    void Sound.reload().then(() => Sound.play("pop"));
  });

  // The settings window writes preferences; apply them here without a restart.
  await onEvent<Settings>("settings-changed", (s) => {
    const previousMain = State.mainPillId;
    State.settings = { ...State.settings, ...s };
    applyLanguage();
    island.applySettings();
    State.loadIntegrationTasks();
    // A new main tool comes to the front, as on macOS.
    if (State.mainPillId !== previousMain) State.setFocus(State.mainPillId);
    void refreshConfigured();
  });

  registerHookHandlers(island);
  registerPhoneLink(island);
  registerIntegrationHandlers(island);
  registerShortcutHandlers(island, () => setPaused(false));
  registerSpotifyHandlers(island);
  registerAppleMusicHandlers(island);
  // Rust may have read Spotify before this page listened: ask once.
  if (State.settings.activeIntegrations.includes(APPLE_MUSIC_ID)) {
    void Bridge.ciderRefresh().then(s => s && applyAppleMusic(island, s));
  }
  if (State.settings.activeIntegrations.includes(SPOTIFY_ID)) {
    void Bridge.spotifyRefresh().then((s) => s && applySpotify(island, s));
  }

  // Monday recap: app start (greeting over), an agent starting work, waking up.
  const checkRecap = () => void Recap.check(island);
  island.onGreetingDone = checkRecap;
  island.onWake = checkRecap;
  await onEvent<null>("recap-check", checkRecap);

  island.launch();

  // In a plain browser there is no wake strip behind the cursor: make the whole
  // page wake the island so the visuals can be checked with `npm run dev`.
  if (!IS_TAURI) {
    document.addEventListener("click", () => Sound.resume(), { once: true });
  }
}

void main();
