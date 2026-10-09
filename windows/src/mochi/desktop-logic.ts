// Mochi on the desktop — the pure logic, port of
// NotchBuddy/Sources/App/DesktopMochiLogic.swift and of the life cycle in
// DesktopMochiController (DesktopMochi.swift). No DOM, no Tauri: the island
// wires it up in src/island/desktop.ts, the desktop window draws him in
// src/desktop/main.ts, and Rust owns the window (src-tauri/src/desktop.rs).
//
// Coordinates are y-down everywhere on a PC, so the Mac's DesktopSpace flip is
// not needed: a point on the desktop is used as the OS reports it.

import type { BotEmoteName, BotStateName } from "../core/layout";
import type { Outfit } from "./wardrobe";

/** What the island tells the desktop window, whenever it changes. */
export interface DesktopSnapshot {
  state: BotStateName;
  /** He is always the main Mochi, so always dressed (try-ons included). */
  outfit: Outfit;
  soundEnabled: boolean;
  soundVolume: number;
  /** Tray → Pause: he dozes off and stays asleep. */
  paused: boolean;
  /** Music plays: he dances (the compact island's rules, core/spotify.ts). */
  dancing: boolean;
}

/** Events between the two windows. Rust adds `desktop-mochi-dropped`. */
export const DESKTOP_EVENTS = {
  /** island → desktop window */
  state: "desktop-mochi-state",
  emote: "desktop-mochi-emote",
  /** desktop window → island */
  ready: "desktop-mochi-ready",
  home: "desktop-mochi-home",
  wardrobe: "desktop-mochi-wardrobe",
  dizzy: "desktop-mochi-dizzy",
  /** Rust → island: a drag ended, `{ from: "island" | "desktop", home }`. */
  dropped: "desktop-mochi-dropped",
  /** Rust → desktop window */
  cursor: "desktop-cursor",
  visible: "desktop-visible",
  flight: "desktop-flight",
} as const;

// ── Constants (DesktopMochiLogic) ────────────────────────────────────────────

/** Side of the desktop window, logical pixels. */
export const PANEL_SIZE = 120;
/** Seconds without agent activity before he may fall asleep. */
export const SLEEP_TIMEOUT = 120;
/** He only dozes off once the pointer is at least this far from him. */
export const SLEEP_MOUSE_DISTANCE = 150;
/** Clickable body radius, as a fraction of the window side. */
export const BODY_RADIUS_FRACTION = 0.24;

/** Surprised, then off to the island (DesktopMochi.swift: 0.45 s). */
export const RETRACT_DELAY_MS = 450;
/** Pause in the island after the alert is answered, before flying back (0.6 s). */
export const RETURN_DELAY_MS = 600;
/** Single click → poke, unless it turns out to be a double click. */
export const DOUBLE_CLICK_MS = 300;
/** A press that moves farther than this is a drag, not a click. */
export const DRAG_THRESHOLD = 3;

// ── Pure helpers ─────────────────────────────────────────────────────────────

export interface Point {
  x: number;
  y: number;
}

/**
 * Whether Mochi should be asleep: no agent activity for longer than
 * SLEEP_TIMEOUT (strictly), and the pointer not close to him.
 */
export function shouldSleep(sinceAgentActive: number, mouseDistanceToCenter: number): boolean {
  return sinceAgentActive > SLEEP_TIMEOUT && mouseDistanceToCenter >= SLEEP_MOUSE_DISTANCE;
}

/** Hit test of the round body inside the square window (window-local). */
export function isOverBody(local: Point, panelSize = PANEL_SIZE): boolean {
  const c = panelSize / 2;
  const r = panelSize * BODY_RADIUS_FRACTION;
  const dx = local.x - c;
  const dy = local.y - c;
  return dx * dx + dy * dy <= r * r;
}

/** Eye-tracking origin: the window centre, in the same space as the cursor. */
export function lookOrigin(panelMinX: number, panelMinY: number, panelSize = PANEL_SIZE): Point {
  return { x: panelMinX + panelSize / 2, y: panelMinY + panelSize / 2 };
}

/** BotCanvasView.lookX / lookY: x right +, y up +. */
export function gaze(bot: Point, mouse: Point): { lookX: number; lookY: number } {
  return {
    lookX: Math.tanh((mouse.x - bot.x) / 260),
    lookY: -Math.tanh((mouse.y - bot.y) / 200),
  };
}

/** An alert went up during a flight: once landed, he turns right back. */
export function shouldRetractOnLanding(alertActive: boolean): boolean {
  return alertActive;
}

/** Agent work keeps him awake; idle and sleeping don't. */
export function agentActive(state: BotStateName): boolean {
  return state !== "idle" && state !== "sleeping";
}

/**
 * What sends him back to the island (the Mac's pendingApproval /
 * pendingQuestion): the island's card waiting for an answer — a permission
 * from any agent, or a question Claude Code asked (#216, the same card with
 * `questions`), folded or not — or an agent asking a question by notification.
 */
export function alertActive(s: {
  pendingApproval: { questions?: unknown } | null;
  tasks: ReadonlyArray<{ state: BotStateName }>;
}): boolean {
  if (s.pendingApproval != null) return true;
  return s.tasks.some((t) => t.state === "question");
}

/**
 * Linux has no global cursor (Wayland), so his window only hears the pointer
 * while it is over his body. That counts as "near" for this long afterwards.
 */
export const POINTER_MEMORY_MS = 4000;

/**
 * Distance from the pointer to his centre, for shouldSleep. With a cursor
 * poll (Windows) it is measured; without one, the pointer is near while it was
 * over him a moment ago, and far otherwise.
 */
export function pointerDistance(
  cursorPoll: boolean,
  cursor: Point | null,
  sincePointerMs: number,
  panelSize = PANEL_SIZE,
): number {
  if (cursorPoll) {
    return cursor ? Math.hypot(cursor.x - panelSize / 2, cursor.y - panelSize / 2) : Infinity;
  }
  return sincePointerMs < POINTER_MEMORY_MS ? 0 : Infinity;
}

/**
 * Layer-shell drag: the surface is stretched over the display, so the pointer
 * reads in display coordinates — once the compositor has applied it. Until
 * then the pointer is still relative to the small surface at `origin`.
 */
export function layerDragTopLeft(origin: Point, client: Point, grab: Point, overlayApplied: boolean): Point {
  const base = overlayApplied ? { x: 0, y: 0 } : origin;
  return { x: base.x + client.x - grab.x, y: base.y + client.y - grab.y };
}

/** X11 drag: screen coordinates are global there; the window moves in physical pixels. */
export function windowDragTopLeft(origin: Point, screen: Point, screenAtPress: Point, dpr: number): Point {
  return {
    x: origin.x + (screen.x - screenAtPress.x) * dpr,
    y: origin.y + (screen.y - screenAtPress.y) * dpr,
  };
}

// ── Life cycle (DesktopMochiController) ──────────────────────────────────────

export type DesktopPhase =
  /** No window on screen. */
  | "home"
  /** Window flying from the island to his spot. */
  | "flyingOut"
  /** On the desktop: the normal state. */
  | "onDesktop"
  /** An alert just went up: surprised, about to fly to the island. */
  | "retracting"
  /** The alert was answered while he was flying to the island. */
  | "alertResolvedDuringRetract"
  /** In the island, showing the alert; back out once it is answered. */
  | "atNotchForAlert";

/**
 * Mochi is between the island and the desktop: carried out of the island, flying (including the trip
 * home asked for by a double-click, where the phase turns "home" before the flight), or about to leave
 * for an alert. The island must not move: his flights aim at where it was when they started (desktop.rs).
 */
export function mochiMoving(carrying: boolean, onDesktop: boolean, phase: DesktopPhase): boolean {
  return carrying || (onDesktop && phase !== "onDesktop");
}

/** Everything the life cycle does to the world, injected so it can be tested. */
export interface DesktopPorts {
  /**
   * Shows the window at the island and flies it to his spot. False: no spot.
   * `anywhere`: a spot on a display that is gone gives way to the first-visit
   * corner instead of keeping him home (the user asked him out).
   */
  flyOut(anywhere: boolean): Promise<boolean>;
  /** Flies the window to the island and hides it. `forget`: he lives there again. */
  flyHome(forget: boolean): Promise<boolean>;
  /** The island's own Mochi hides while he is out. */
  setAway(away: boolean): void;
  /** An emote on the desktop Mochi. */
  emote(emote: BotEmoteName, duration?: number): void;
  play(sound: string): void;
  alertActive(): boolean;
  /** The island must be on screen for him to show the alert there. */
  revealIsland(): void;
  later(fn: () => void, ms: number): void;
}

export class DesktopMochiController {
  phase: DesktopPhase = "home";
  /** He lives on the desktop (the `onDesktop` preference). */
  enabled = false;

  private lastState: BotStateName | null = null;
  private port: DesktopPorts;

  constructor(port: DesktopPorts) {
    this.port = port;
  }

  /** Launch, and back from an alert: fly out to his spot if he lives there. */
  async launchFlyIfNeeded(anywhere = false): Promise<void> {
    if (!this.enabled || this.phase !== "home") return;
    // An alert is up: wait in the island, the alert's end flies him out.
    if (this.port.alertActive()) {
      this.phase = "atNotchForAlert";
      return;
    }
    this.phase = "flyingOut";
    this.port.setAway(true);
    const ok = await this.port.flyOut(anywhere);
    if (this.phase !== "flyingOut") return;
    if (!ok) {
      // His spot is on a display that is gone: he stays home.
      this.phase = "home";
      this.enabled = false;
      this.port.setAway(false);
      return;
    }
    this.landed();
  }

  /** Dropped on the desktop after a drag out of the island (Rust placed him). */
  installed() {
    if (this.phase !== "home") return;
    this.enabled = true;
    this.port.setAway(true);
    this.port.emote("happy", 0.6);
    this.port.play("pop");
    this.landed();
  }

  /** Double click, or dropped on the island: home for good. */
  async flyHome(): Promise<void> {
    // Also in the instant between an alert and his flight to the island: the
    // user's "home" wins, and the pending retract finds nothing left to do.
    const out = ["onDesktop", "retracting", "alertResolvedDuringRetract"];
    if (!out.includes(this.phase)) return;
    this.phase = "home";
    this.enabled = false;
    await this.port.flyHome(true);
    this.port.play("peek");
    this.port.setAway(false);
  }

  /**
   * The desktop shortcut (DesktopMochiController.flyOutOrHome, ⌃⌥D on the
   * Mac): out to his spot from the island, home from the desktop. In flight,
   * or away for an alert, nothing.
   */
  async flyOutOrHome(): Promise<void> {
    if (this.phase === "home") {
      this.enabled = true;
      await this.launchFlyIfNeeded(true);
    } else if (this.phase === "onDesktop") {
      await this.flyHome();
    }
  }

  /** Call whenever the alert condition may have changed; only edges count. */
  private alertWas = false;
  updateAlert(active: boolean) {
    if (active === this.alertWas) return;
    this.alertWas = active;
    if (active) {
      if (this.phase === "onDesktop") this.beginRetract();
      return;
    }
    if (this.phase === "atNotchForAlert") {
      this.phase = "home";
      this.port.later(() => void this.launchFlyIfNeeded(), RETURN_DELAY_MS);
    } else if (this.phase === "retracting") {
      this.phase = "alertResolvedDuringRetract";
    }
  }

  /** Call with the effective state; a task finishing gets a happy jump. */
  updateState(state: BotStateName) {
    const prev = this.lastState;
    this.lastState = state;
    if (prev == null || prev === state) return;
    if (state === "finished" && this.phase === "onDesktop") this.port.emote("happy", 1.2);
  }

  private landed() {
    this.phase = "onDesktop";
    // An alert may have gone up during the flight, when nothing reacts to it.
    this.alertWas = this.port.alertActive();
    if (shouldRetractOnLanding(this.alertWas)) this.beginRetract();
  }

  private beginRetract() {
    this.port.emote("surprised");
    this.phase = "retracting";
    this.port.later(() => {
      if (this.phase === "retracting") {
        void this.retractForAlert();
      } else if (this.phase === "alertResolvedDuringRetract") {
        // Answered before he even took off: he never left his spot.
        this.phase = "onDesktop";
      }
    }, RETRACT_DELAY_MS);
  }

  private async retractForAlert() {
    await this.port.flyHome(false);
    this.port.setAway(false);
    if (this.phase === "alertResolvedDuringRetract") {
      this.phase = "home";
      await this.launchFlyIfNeeded();
    } else if (this.phase === "retracting") {
      this.phase = "atNotchForAlert";
      this.port.revealIsland();
    }
  }
}
