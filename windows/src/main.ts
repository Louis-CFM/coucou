// Entry point: boot the bridge, wire the island, start the greeting.

import "./style.css";
import { Bridge, IS_TAURI, onEvent } from "./core/bridge";
import { Sound } from "./core/sound";
import { State, type Settings } from "./core/state";
import { needsCompanionOnboarding } from "./core/companion-identity";
import { Island } from "./island/island";
import { registerHookHandlers } from "./island/hooks";
import { registerPhoneLink } from "./island/phone-link";
import { registerIntegrationHandlers, refreshConfigured } from "./island/integrations";
import { registerShortcutHandlers } from "./island/shortcuts";
import { registerVoiceHandlers } from "./island/voice";
import { applySpotify, registerSpotifyHandlers } from "./island/spotify";
import { registerWhatsAppHandlers } from "./island/whatsapp";
import { SPOTIFY_ID } from "./core/spotify";
import { Recap } from "./recap/recap";
import { Updates } from "./island/update";
import { WhatsNew } from "./whats-new/controller";
import { onLanguageChange, resolveLanguage, setLanguage, systemLanguages } from "./i18n/i18n";
import { GlobalNotifications } from "./core/notifications";
import { GlobalWelcomeMessages } from "./core/welcome";
import { Diagnostics } from "./core/diagnostics";
import { nearbyTransferManager } from "./components/islandcn/transfer-adapter";
import { BatteryMonitor } from "./islandcn";
import { CompanionOrchestrator } from "./companion/orchestrator";

/** Shows the language Settings asks for ("" = the system's, when Coucou has it). */
function applyLanguage() {
  setLanguage(resolveLanguage(State.settings.language, systemLanguages()));
}

async function main() {
  const root = document.getElementById("root");
  if (!root) return;

  Diagnostics.record("boot_start");
  void Sound.preload();
  void GlobalWelcomeMessages.initIdentity();
  void CompanionOrchestrator.probeHealth("ollama", GlobalWelcomeMessages.localEndpoint);

  // Before the island exists: its canvases size their bitmaps from the pixel
  // ratio once, so the zoom correction has to land first. If zoom was adjusted,
  // wait until the ratio updates (or up to 500ms) so nothing is sized against
  // the stale value.
  const dprBefore = window.devicePixelRatio || 1;
  const zoomChanged = await Bridge.fitZoom(dprBefore);
  if (zoomChanged) {
    for (let i = 0; i < 20 && window.devicePixelRatio === dprBefore; i++) {
      await new Promise((r) => setTimeout(r, 25));
    }
  }

  const boot = await Bridge.boot();
  Diagnostics.record("boot_bridge_ready");
  if (boot) {
    State.settings = { ...State.settings, ...boot.settings };
    if (boot.battery) {
      BatteryMonitor.initialize(boot.battery);
    }
  }

  // A language change redraws the island in place: the texts given as tl(…)
  // relabel themselves (views/dom.ts) and the views redraw the rest on this
  // sync. Nothing is rebuilt, so tasks, steps and the chat stay as they are.
  onLanguageChange(() => State.notify());
  applyLanguage();
  // Rust shows the tray and its errors in the same language as the webview.
  void Bridge.setSystemLanguages(systemLanguages());

  const island = new Island(root);

  // The dev previews (dev/*.html) drive the island from the console.
  if (import.meta.env.DEV) {
    Object.assign(window, {
      __island: island,
      __state: State,
      __welcome: GlobalWelcomeMessages,
      __notifications: GlobalNotifications,
      __nearbyTransfer: nearbyTransferManager,
      __batteryMonitor: BatteryMonitor,
    });
  }

  island.applySettings();
  State.loadIntegrationTasks();
  if (boot && !boot.cursorPoll) island.followPageCursor();
  await island.desktop.init();

  await onEvent<{ x: number; y: number }>("cursor", ({ x, y }) => island.onCursor(x, y));
  await onEvent<boolean>("pointer-inside", (inside) => island.setPointerInside(inside));
  await onEvent<null>("closed-hover", () => island.wakeFromClosed());

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
      // "Update Coucou to X…", only in the menu while a new version is out.
      case "update":
        setPaused(false);
        Updates.show();
        break;
      case "pause":
        setPaused(!State.paused);
        if (State.paused) island.fsm.forceHidden();
        else island.reveal();
        break;
    }
  });

  const checkZoom = async () => {
    const dpr = window.devicePixelRatio || 1;
    await Bridge.fitZoom(dpr);
  };

  await onEvent<null>("screen-changed", async () => {
    await checkZoom();
    void Bridge.reposition();
    island.ensureRunning();
  });

  // A query only matches the ratio it was made for: once it changes, watch the
  // new one, or the next monitor's scale goes unnoticed and the zoom stays wrong.
  // One frame redraws Mochi at the new ratio, even while the loop is idle.
  const watchRatio = () => {
    window
      .matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`)
      .addEventListener?.("change", () => {
        watchRatio();
        void checkZoom();
        island.ensureRunning();
      }, { once: true });
  };
  watchRatio();

  window.addEventListener(
    "wheel",
    (e) => {
      if (e.ctrlKey) e.preventDefault();
    },
    { passive: false }
  );
  window.addEventListener("keydown", (e) => {
    if (e.ctrlKey && (e.key === "+" || e.key === "-" || e.key === "=" || e.key === "0")) {
      e.preventDefault();
    }
  });

  // Settings → Reload sounds: read the sounds folder again, and let them hear it.
  await onEvent<null>("sounds-changed", () => {
    void Sound.reload().then(() => Sound.play("pop"));
  });

  // The settings window writes preferences; apply them here without a restart.
  await onEvent<Settings>("settings-changed", (s) => {
    const previousMain = State.mainPillId;
    const previousCompanion = State.companionName;
    State.settings = { ...State.settings, ...s };
    if (State.companionName !== previousCompanion) {
      GlobalWelcomeMessages.invalidateForCompanionRename();
    }
    if (State.mode === "expanded" && State.view === "onboarding" && !needsCompanionOnboarding(State.settings)) {
      island.fsm.pinned = false;
      State.isPinned = false;
      State.view = State.defaultView();
      island.fsm.forceHidden();
    }
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
  registerVoiceHandlers();
  registerSpotifyHandlers(island);
  registerWhatsAppHandlers(island);
  // New versions: Rust offers the card, the island opens it when nothing else waits.
  await Updates.register(island);
  // Rust may have read Spotify before this page listened: ask once.
  if (State.settings.activeIntegrations.includes(SPOTIFY_ID)) {
    void Bridge.spotifyRefresh().then((s) => s && applySpotify(island, s));
  }

  // Monday recap: app start (greeting over), an agent starting work, waking up.
  const checkRecap = () => {
    if (needsCompanionOnboarding(State.settings)) return;
    void Recap.check(island);
  };
  // What's new, once after an update: when the greeting is over, or a few
  // seconds in when there is no greeting (the card waits for a quiet island).
  const whatsNew = () => {
    if (needsCompanionOnboarding(State.settings)) return;
    void WhatsNew.launch(island);
  };
  island.onGreetingDone = () => {
    checkRecap();
    whatsNew();
    GlobalWelcomeMessages.onAppLaunch();
  };
  island.onOnboardingComplete = () => {
    checkRecap();
    whatsNew();
  };
  window.setTimeout(whatsNew, 8000);
  island.onWake = checkRecap;
  await onEvent<null>("recap-check", checkRecap);

  if (IS_TAURI) {
    Diagnostics.record("intro_launch");
    island.launchIntro();
  }

  // In a plain browser there is no wake strip behind the cursor:
  if (!IS_TAURI) {
    document.documentElement.style.background = "#0c0d12";
    document.body.style.background = "#0c0d12";

    if (new URLSearchParams(window.location.search).has("onboard")) {
      island.enterOnboarding(false);
    }

    window.addEventListener("keydown", (e) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;

      if (e.key === "w" || e.key === "W") {
        island.fsm.forceHidden();
        GlobalWelcomeMessages.onUserReturned(15);
      } else if (e.key === "n" || e.key === "N") {
        island.fsm.forceHidden();
        GlobalNotifications.push({ app: "WhatsApp", title: "Alice", body: "Hello!" });
      } else if (e.key === "h" || e.key === "H") {
        if (State.mode === "hidden") {
          island.wakeFromClosed();
        } else {
          island.fsm.forceHidden();
        }
      }
    });

    // In browser mode, stay in resting closed notch by default to showcase the Balanced Dynamic Island.
    // Press H to toggle wake/closed, W for Welcome Back message, N for Notification.
  }
}

void main();
