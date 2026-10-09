// Nova on the desktop, island side: runs his life cycle (the controller in
// nova/desktop-logic.ts) against the real app, tells the desktop window what
// to show, and handles the drag out of the island. The window itself lives in
// src-tauri/src/desktop.rs and draws him in src/desktop/main.ts.

import { Bridge, emitToWindow, onEvent, type DesktopMode } from "../core/bridge";
import type { BotEmoteName } from "../core/layout";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import { desktopDances } from "../core/spotify";
import {
  DESKTOP_EVENTS, DesktopNovaController, alertActive, type DesktopSnapshot,
} from "../nova/desktop-logic";
import { SeasonCache, parseOutfit } from "../nova/wardrobe";

/** Label of the desktop Nova's window (desktop.rs LABEL). */
const WINDOW = "nova";

/** What the life cycle needs from the island. */
export interface DesktopHost {
  /** Shows the island (compact) if it is hidden. */
  reveal(): void;
  /** Right-click on the desktop Nova: the wardrobe, or back. */
  wardrobeFromDesktop(): void;
  /** Three pokes on the desktop Nova. */
  dizzyFromDesktop(): void;
}

export class DesktopLink {
  mode: DesktopMode = "off";
  readonly controller: DesktopNovaController;

  /** The pointer is dragging Nova out of the island. */
  carrying = false;

  private seasons = new SeasonCache();
  private pushed = "";
  private pendingCarry: { x: number; y: number } | null = null;
  private carryFrame = false;
  private host: DesktopHost;

  constructor(host: DesktopHost) {
    this.host = host;
    this.controller = new DesktopNovaController({
      flyOut: async (anywhere) => (await Bridge.desktopFlyOut(anywhere)) ?? false,
      flyHome: async (forget) => (await Bridge.desktopFlyHome(forget)) ?? true,
      setAway: (away) => {
        State.novaOnDesktop = away;
        State.notify();
      },
      emote: (emote: BotEmoteName, duration = 1.8) =>
        void emitToWindow(WINDOW, DESKTOP_EVENTS.emote, { emote, duration }),
      play: (sound) => Sound.play(sound),
      alertActive: () => alertActive(State),
      revealIsland: () => {
        if (State.mode === "hidden") this.host.reveal();
      },
      later: (fn, ms) => void window.setTimeout(fn, ms),
    });
  }

  /** False where windows can't be placed (GNOME on Wayland): he stays in the island. */
  get supported(): boolean {
    return this.mode !== "off";
  }

  async init() {
    const info = await Bridge.desktopInfo();
    if (!info || info.mode === "off") return;
    this.mode = info.mode;
    this.controller.enabled = info.onDesktop;

    await onEvent<{ from: "island" | "desktop"; home: boolean }>(DESKTOP_EVENTS.dropped, (e) =>
      this.onDropped(e.from, e.home),
    );
    await onEvent<null>(DESKTOP_EVENTS.home, () => void this.controller.flyHome());
    await onEvent<null>(DESKTOP_EVENTS.wardrobe, () => this.host.wardrobeFromDesktop());
    await onEvent<null>(DESKTOP_EVENTS.dizzy, () => this.host.dizzyFromDesktop());
    // The window's page (re)loaded: it knows nothing yet.
    await onEvent<null>(DESKTOP_EVENTS.ready, () => {
      this.pushed = "";
      this.push();
    });

    State.subscribe(() => this.sync());
    this.sync();
  }

  /** The launch greeting is over: back to his spot if that is where he lives. */
  launch() {
    if (this.supported) void this.controller.launchFlyIfNeeded();
  }

  /**
   * The desktop shortcut: out to his spot, or home. Not in the middle of a
   * drag out of the island — the drop decides that one.
   */
  flyOutOrHome() {
    if (!this.supported || this.carrying) return;
    void this.controller.flyOutOrHome();
  }

  // ── Drag out of the island ──────────────────────────────────────────────────

  /** Whether Nova can be picked up from the island right now. */
  canPickUp(): boolean {
    return this.supported && !State.paused && !State.novaOnDesktop && this.controller.phase === "home";
  }

  /** (x, y): the pointer, island-window coordinates. */
  pickUp(x: number, y: number) {
    this.carrying = true;
    State.novaOnDesktop = true;
    State.notify();
    void Bridge.desktopPickUp(x, y).then((ok) => {
      if (ok) return;
      this.carrying = false;
      State.novaOnDesktop = false;
      State.notify();
    });
  }

  /** The pointer moved during the drag. Windows carries him from Rust. */
  carry(x: number, y: number) {
    if (!this.carrying || this.mode === "poll") return;
    this.pendingCarry = { x, y };
    if (this.carryFrame) return;
    this.carryFrame = true;
    requestAnimationFrame(() => {
      this.carryFrame = false;
      const p = this.pendingCarry;
      this.pendingCarry = null;
      if (p && this.carrying) void Bridge.desktopCarry(p.x, p.y);
    });
  }

  /** The button went up. On Windows the cursor poll has seen it already. */
  carryEnd(x: number, y: number) {
    if (!this.carrying || this.mode === "poll") return;
    this.pendingCarry = null;
    void Bridge.desktopCarryEnd(x, y);
  }

  private onDropped(from: "island" | "desktop", home: boolean) {
    if (from === "island") {
      this.carrying = false;
      if (home) {
        // Dropped back on the island: he is simply there again.
        State.novaOnDesktop = false;
        State.notify();
      } else {
        this.controller.installed();
      }
    } else if (home) {
      void this.controller.flyHome();
    }
  }

  // ── State → desktop window ──────────────────────────────────────────────────

  private sync() {
    this.controller.updateAlert(alertActive(State));
    this.controller.updateState(State.effectiveState);
    this.push();
  }

  private push() {
    const snapshot: DesktopSnapshot = {
      state: State.effectiveState,
      outfit: State.wardrobePreview ?? this.seasons.get(parseOutfit(State.settings.novaOutfit)),
      soundEnabled: State.settings.soundEnabled,
      soundVolume: State.settings.soundVolume,
      paused: State.paused,
      dancing: desktopDances(State.spotifyPlaying, State.effectiveState),
    };
    const key = JSON.stringify(snapshot);
    if (key === this.pushed) return;
    this.pushed = key;
    void emitToWindow(WINDOW, DESKTOP_EVENTS.state, snapshot);
  }
}
