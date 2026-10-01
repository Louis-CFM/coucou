// The island: DOM shell, sizing animation, Mochi placement, mouse handling.
// Mirrors IslandRootView.swift + IslandWindowController.swift.

import { Tracked, Spring, clamp } from "../core/anim";
import { Bridge, IS_TAURI, onDragDrop } from "../core/bridge";
import {
  EXPANDED_CORNER, EXPANDED_W, COMPACT_W, NO_NOTCH_W, PANEL_H, PANEL_W,
  ROUNDED_CORNER, VIEW_LAYOUTS, botGlowColor, botGlowOpacity, botPosition, chatPromptHeight,
  islandSize,
  type IslandMode, type IslandViewName,
} from "../core/layout";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import { BotEngine, hexToRGB } from "../mochi/engine";
import { Greeting } from "../mochi/greeting";
import { createMiniBot, pruneMiniBots, syncMiniBotStates, tickMiniBots } from "../mochi/minibots";
import { UploadCanvas } from "../upload/canvas";
import { USC, UploadSeq } from "../upload/sequence";
import { buildHeader, buildViews, type ViewActions, type ViewHost } from "../views/views";
import { h } from "../views/dom";
import { IslandStateMachine } from "./fsm";

const BOT_OVERHANG = 40;
/** Same margin as the Rust hit test (src-tauri/src/island.rs). */
const HIT_MARGIN = 14;

/** The three views the drop sequence owns; leaving them stops the engine. */
const UPLOAD_VIEWS: ReadonlySet<IslandViewName> = new Set(["upload", "uploading", "choose"]);

/** Seconds between the drop and the moment the progress bar starts filling. */
const PRE_PROGRESS = USC.T_PROG_START - USC.T_DROP;

const modeOrder = (m: IslandMode) => (m === "hidden" ? 0 : m === "compact" ? 1 : 2);

export class Island {
  readonly fsm = new IslandStateMachine();

  private root: HTMLElement;
  private islandEl!: HTMLElement;
  private clipEl!: HTMLElement;
  private contentEl!: HTMLElement;
  private viewsEl!: HTMLElement;
  private botCanvas!: HTMLCanvasElement;
  private botGlow!: HTMLElement;
  private greetingCanvas!: HTMLCanvasElement;
  private miniGrid!: HTMLElement;
  private countdown!: HTMLElement;

  private header!: ViewHost;
  private views!: Map<IslandViewName, ViewHost>;
  private uploadCanvas!: UploadCanvas;

  private width = new Tracked(NO_NOTCH_W);
  private height = new Tracked(0);
  private radius = new Tracked(ROUNDED_CORNER);
  private botCx = new Spring(46);
  private botCy = new Spring(16);
  private botSize = new Spring(10);

  private engine = new BotEngine();
  private greeting = new Greeting();

  private running = false;
  private lastFrame = 0;
  private dirty = true;
  private canvasPx = 0;

// Rust starts the window at full size so the launch greeting has room.
  // "Wake on hover": the widening of the fully-compact bar into the retracted one.
  // A bar state only — it never opens the panel, and it never brings the island
  // back from off-screen, which is what "hover to restore" is for.
  private barHover = false;
  private collapsed = false;
  private collapseTimer: number | null = null;
  private wasInIsland = false;
  /** Last shape handed to Rust for the click-through test. */
  private pushedRect = { x: -1, y: -1, w: -1, h: -1 };
  private homeCollapseAt: number | null = null;

  // Bot hover → love (IslandWindowController.botHoverIn)
  private botHovering = false;
  private botHoverTimer: number | null = null;
  private lastLoveTime = 0;
  private botHoverStart = { x: 0, y: 0 };

  private confusedRecovery: number | null = null;
  private prevViewBeforeConfused: IslandViewName = "overview";
  private lastSyncedView: IslandViewName | null = null;

  /** Drop sequence bookkeeping: last tick played, and whether the ✓ has fired. */
  private uploadTens = 0;
  private uploadDone = false;

  constructor(root: HTMLElement) {
    this.root = root;
    this.build();
    this.wireFsm();
    this.wireInput();
    this.engine.onDizzy = () => this.handleDizzy();
    this.greeting.onComplete = () => this.fsm.greetComplete();
    State.subscribe(() => {
      this.dirty = true;
      this.ensureRunning();
    });
  }

  // ── DOM ─────────────────────────────────────────────────────────────────────

  private build() {
    const actions: ViewActions = {
      setView: (v) => this.setView(v),
      collapse: () => this.collapse(),
      setFocus: (id) => {
        State.setFocus(id);
        Sound.play("blip");
      },
      openTerminal: () => {
        const cwd = State.focusTask?.sessionCwd ?? null;
        void Bridge.openInVSCode(cwd);
      },
      // The ↗ button — same targets as openAgentTarget() on macOS.
      openTarget: () => {
        const task = State.focusTask;
        if (!task) return;
        const urls: Record<string, string> = {
          integration_resend: "https://resend.com/emails",
          integration_vercel: "https://vercel.com/dashboard",
          integration_github: "https://github.com",
          integration_stripe: "https://dashboard.stripe.com/payments",
          integration_notion: "https://notion.so",
          integration_calcom: "https://app.cal.com/bookings",
        };
        if (task.id === "integration_claude") void Bridge.openInVSCode(task.sessionCwd ?? null);
        else if (task.id === "integration_n8n") void Bridge.openN8n();
        else if (urls[task.id]) void Bridge.openUrl(urls[task.id]);
      },
      openUrl: (url) => {
        if (url) void Bridge.openUrl(url);
      },
      decide: (d) => {
        const req = State.pendingApproval;
        void Bridge.log(`decide ${d} req=${req?.requestId ?? "none"}`);
        if (!req) return;
        Sound.play(d === "deny" ? "blip" : "approve");
        void Bridge.approvalDecision(req.requestId, d);
        State.pendingApproval = null;
        State.isPinned = false;
        this.fsm.pinned = false;
        State.updateTask(req.agentId, "working");
        State.setPillBadge(req.agentId, null);
        this.setView(State.defaultView());
      },
      toggleSound: () => {
        State.settings.soundEnabled = !State.settings.soundEnabled;
        Sound.setEnabled(State.settings.soundEnabled);
        void Bridge.saveSettings(State.settings);
        State.notify();
      },
      setVolume: (v) => {
        State.settings.soundVolume = v;
        Sound.setVolume(v);
        void Bridge.saveSettings(State.settings);
        State.notify();
      },
      setAutoClose: (s) => {
        State.settings.autoCloseInterval = s;
        this.fsm.homeToPetitDelay = s;
        // Changing the timer re-arms it, so a new value takes effect at once
        // rather than after the previous (possibly long) one elapses.
        if (this.fsm.state === "home") this.fsm.mouseLeft();
        void Bridge.saveSettings(State.settings);
        State.notify();
      },
      setAbsence: (s) => {
        State.settings.absenceInterval = s;
        this.fsm.petitToHiddenDelay = s;
        if (this.fsm.state === "petit") this.fsm.mouseLeft();
        void Bridge.saveSettings(State.settings);
        State.notify();
      },
      setAutoCloseDelay: (s) => {
        State.settings.autoCloseDelay = s;
        this.fsm.hiddenToGoneDelay = s;
        void Bridge.saveSettings(State.settings);
        State.notify();
      },
      toggleHoverRestore: () => {
        State.settings.hoverRestore = !State.settings.hoverRestore;
        void Bridge.saveSettings(State.settings);
        State.notify();
      },
      togglePin: () => {
        const next = !State.settings.pinIsland;
        State.settings.pinIsland = next;
        State.isPinned = next;
        this.fsm.pinned = next;
        void Bridge.saveSettings(State.settings);
        State.notify();
      },
      toggleWakeOnHover: () => {
        State.settings.wakeOnHover = !State.settings.wakeOnHover;
        void Bridge.saveSettings(State.settings);
        State.notify();
      },
      openSettingsWindow: () => void Bridge.openSettingsWindow(),
      blip: () => Sound.play("blip"),
    };

    this.botGlow = h("div", { id: "bot-glow" });
    this.botCanvas = h("canvas", { id: "bot-canvas" });
    this.greetingCanvas = h("canvas", { id: "greeting-canvas" });
    this.miniGrid = h("div", { id: "mini-grid" });
    this.countdown = h("div", { id: "countdown" });

    this.header = buildHeader(actions);
    this.views = buildViews(actions, () => this.animateGeometry(false));
    this.viewsEl = h("div", { id: "views" });
    for (const v of this.views.values()) this.viewsEl.append(v.el);
    this.contentEl = h("div", { id: "content" }, this.header.el, this.viewsEl);

    // The drop sequence draws the card, the bar and its own Mochi. It sits under
    // the header, which stays visible on top of it exactly as on macOS.
    this.uploadCanvas = new UploadCanvas({
      ask: () => {
        State.promptContext = State.droppedFile
          ? { kind: "file", name: State.droppedFile.name, path: State.droppedFile.path }
          : null;
        this.setView("prompt");
      },
      cancel: () => this.setView(State.defaultView()),
    });

    this.clipEl = h(
      "div",
      { id: "island-clip" },
      this.greetingCanvas,
      this.uploadCanvas.el,
      this.contentEl,
    );
    this.islandEl = h(
      "div",
      { id: "island" },
      this.clipEl,
      this.botGlow,
      this.botCanvas,
      this.miniGrid,
      this.countdown,
    );

    const dpr = Math.min(2, window.devicePixelRatio || 1);
    this.greetingCanvas.width = Math.round(EXPANDED_W * dpr);
    this.greetingCanvas.height = Math.round(150 * dpr);
    this.greetingCanvas.style.width = `${EXPANDED_W}px`;
    this.greetingCanvas.style.height = "150px";

    this.root.append(this.islandEl);
    this.applyGeometry();
  }

  // ── FSM ─────────────────────────────────────────────────────────────────────

  private wireFsm() {
    this.fsm.homeToPetitDelay = State.settings.autoCloseInterval;
    this.fsm.onTransition = (from, to) => {
      switch (to) {
        case "hidden":
        case "gone":
          this.setMode("hidden");
          break;
        case "petit":
          if (from === "coucou") this.greeting.interrupt();
          else if (from === "hidden") Sound.play("peek");
          this.setMode("compact");
          if (from === "coucou") State.view = State.defaultView();
          // Always arm the fully-compact timer on arriving at the bar. Gating it
          // on `wasInIsland` meant it silently never armed whenever the cursor
          // happened to still be over the island, leaving the bar resting
          // forever.
          this.fsm.mouseLeft();
          break;
        case "home":
          this.expand(State.defaultView());
          if (!this.wasInIsland) this.fsm.mouseLeft();
          break;
        case "coucou":
          this.expand("greeting");
          this.greeting.start();
          break;
}
        void Bridge.debugLog(
          `from=${from} to=${to} mode=${State.mode} compact=${this.fsm.homeToPetitDelay} autoClose=${this.fsm.petitToHiddenDelay}`,
        );
        State.notify();
      };
    }

  launch() {
    this.fsm.launch();
  }

  // ── Mode / view ─────────────────────────────────────────────────────────────

  private setMode(mode: IslandMode) {
    const prev = State.mode;
    if (mode === prev) return;
    State.mode = mode;
    if (mode === "expanded") Sound.play("open");
    if (prev === "expanded") {
      Sound.play("close");
      State.isPinned = false;
      void Bridge.focusWindow(false);
    }
    if (mode !== "expanded") {
      this.engine.resetMorph();
      // Nothing can be seen of the sequence once the island is shut, and leaving
      // it running would keep the frame loop awake — the island must cost
      // nothing while hidden.
      UploadSeq.deactivate();
    }
    this.updateWindowCollapsed();
    this.animateGeometry(modeOrder(mode) < modeOrder(prev));
    State.notify();
  }

  /** True while the drop sequence owns the island body. */
  private get uploadActive(): boolean {
    return State.mode === "expanded" && UploadSeq.isActive && UPLOAD_VIEWS.has(State.view);
  }

  /** Navigating out of the drop flow ends the sequence, as on macOS. */
  private stopSequenceIfLeaving(view: IslandViewName) {
    if (UploadSeq.isActive && !UPLOAD_VIEWS.has(view)) UploadSeq.deactivate();
  }

  expand(view: IslandViewName) {
    this.stopSequenceIfLeaving(view);
    State.view = view;
    if (State.mode !== "expanded") this.setMode("expanded");
    else this.animateGeometry(false);
    State.lastActivity = performance.now();
    this.homeCollapseAt = null;
    State.notify();
  }

  setView(view: IslandViewName) {
    this.stopSequenceIfLeaving(view);
    if (State.mode !== "expanded") {
      this.fsm.forceHome();
      State.view = view;
      this.animateGeometry(false);
      State.notify();
      return;
    }
    const grew = VIEW_LAYOUTS[view].height >= VIEW_LAYOUTS[State.view].height;
    State.view = view;
    State.lastActivity = performance.now();
    this.animateGeometry(!grew);
    State.notify();
  }

  collapse() {
    // Explicit dismissal clears a hook alert's pin, but never the user's own:
    // `settings.pinIsland` is untouched here and keeps the island open.
    State.isPinned = false;
    this.fsm.pinned = State.settings.pinIsland;
    // Drive the state machine rather than the mode: setting the mode behind its
    // back left it thinking the island was still open, and a click on the compact
    // island then did nothing — the island could never be reopened.
    this.fsm.forcePetit();
  }

  /** Explicit outside click closes the panel, while approval cards stay actionable. */
  // ── Dragging the resting island ───────────────────────────────────────────────

private dragStartX = 0;
  private dragStartPosition = 0;
  private dragMoved = false;
/** Timestamps of recent outside clicks, for the double-click wake. */
private outsideClicks: number[] = [];

  /**
   * Grabs the resting island and follows the pointer, landing it wherever it is
   * released. The position is normalised across the target display (0 = left,
   * 1 = right) and handed straight to Rust, which owns the actual window move.
   *
   * A press that never moves more than a few pixels is left alone so an ordinary
   * click on the bar still wakes the island instead of nudging it.
   */
  private beginNotchDrag(e: MouseEvent) {
    if (e.button !== 0) return;
    const screen = State.screen;
    if (!screen || screen.width <= 0) {
      // Without screen metrics a drag can't be normalised, so fall back to the
      // plain click that opens the island.
      this.fsm.click();
      return;
    }
    // Dragging a resting bar is a deliberate act; don't also nudge the mascot.
    e.stopPropagation();

    // The bar is the island's own width in whichever resting mode we are in, so
    // the draggable span depends on it.
    const barW = islandSize(State.mode, State.view, 0, this.hidesOffscreen()).w;

    this.dragStartX = e.screenX;
    this.dragStartPosition = State.settings.notchPosition;
    this.dragMoved = false;

    const onMove = (ev: MouseEvent) => {
      const dx = ev.screenX - this.dragStartX;
      if (!this.dragMoved && Math.abs(dx) < 4) return;
      if (!this.dragMoved) {
        this.dragMoved = true;
        // Tells the server to hold this display for the drag. Without it, "display
        // under the cursor" would follow the pointer across a boundary mid-drag and
        // fight the drag.
        void Bridge.setDragging(true);
      }
      const span = Math.max(1, screen.width - barW);
      // screenX is in physical pixels; divide by the scale factor the server
      // reported so the maths matches the logical pixels Rust positions with.
      const next = this.dragStartPosition + dx / screen.scale / span;
      const clamped = Math.max(0, Math.min(1, next));
      State.settings.notchPosition = clamped;
      void Bridge.setNotchPosition(clamped);
    };

    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      if (this.dragMoved) {
        // Release the display hold before the final placement, so releasing the bar
        // over a different display moves it there rather than pinning it back.
        void Bridge.setDragging(false);
        // Persist once more so the resting place survives a restart even if the
        // last move event landed a hair short of the release point.
        void Bridge.setNotchPosition(State.settings.notchPosition);
      } else {
        // It was a click, not a drag, so open the island.
        this.fsm.click();
      }
    };

    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
    e.preventDefault();
  }

  /**
   * Whether the island must stay open: either the user pinned it, or a hook
   * alert is waiting for an answer. Hooks clear `State.isPinned` when they
   * finish, so the user's own pin has to be read from settings — otherwise an
   * alert would quietly undo it.
   */
  private get staysOpen(): boolean {
    return State.settings.pinIsland || State.isPinned;
  }

/**
   * How close to the island a click may land and still count as "near" it for
   * the double-click wake. Measured from the island's rect on both sides, so it
   * behaves the same to the left and to the right.
   */
private static readonly NEAR_RADIUS = 56;
/** Two clicks within this window count as a double-click. */
private static readonly DOUBLE_MS = 900;

/**
   * A click outside the island.
   *
   * Reduced: nothing happens on one click; a second one near the island wakes it
   * back to the bar.
   *
   * Showing: the first click closes the panel to the resting bar, and a further
   * click takes it the rest of the way to fully compact. The fully-compact timer
   * does the same thing on its own after the configured delay, so either route
   * gets there — the click just skips the wait.
   *
   * A pinned island ignores all of it.
   */
dismissOutside() {
  if (this.staysOpen) return;
  const now = performance.now();
  const near = this.isNearIsland();

  this.outsideClicks = this.outsideClicks.filter((t) => now - t < Island.DOUBLE_MS);

// Reduced, whether that is the docked bar or off-screen: only a deliberate
  // double-click near the island opens it, and all the way to the full panel.
  // `click()` takes the docked bar and the off-screen island straight to open.
  // One click on its own does nothing, otherwise every stray click on the desktop
  // would toggle the island.
  if (State.mode === "compact" || State.mode === "hidden") {
    if (near && this.outsideClicks.length > 0) {
      this.outsideClicks = [];
      // A double-click near the bar expands it to the full 240pt retracted bar, from
      // either resting width. This is a real state change rather than the visual
      // widening "wake on hover" uses, so the bar stays at 240 when the cursor leaves
      // and the Compact timer takes it down to 80 from there. It never opens the panel
      // and does not recall the island from off-screen.
      if (this.fsm.state !== "gone" || State.settings.hoverRestore) this.fsm.mouseEntered();
      return;
    }
    this.outsideClicks.push(now);
    // A second click beside the bar takes it the rest of the way down to the
    // fully-compact 80pt bar: 640 → 240 on the first click, 240 → 80 on the next.
    // Compact on Never means the 80pt bar is never reached by any route.
    if (this.fsm.state === "petit" && State.settings.absenceInterval > 0) this.fsm.forceHidden();
    return;
  }

  this.outsideClicks = [];
  // Open: the first outside click compacts to the 240pt bar, and the island stays
  // docked. Auto-close owns that step's timer; clicking again beside the bar is
  // what takes it down to the fully-compact one.
  this.collapse();
}

/** True when the cursor is within NEAR_RADIUS of the island's painted rect. */
private isNearIsland(): boolean {
  const rect = this.islandRect();
  const dx = Math.max(rect.x - State.mouse.x, 0, State.mouse.x - (rect.x + rect.w));
  const dy = Math.max(rect.y - State.mouse.y, 0, State.mouse.y - (rect.y + rect.h));
  return dx <= Island.NEAR_RADIUS && dy <= Island.NEAR_RADIUS;
}

  /** Alert from the hook server: open on this view. Pinned alerts never auto-close. */
  alert(view: IslandViewName) {
    this.fsm.pinned = this.staysOpen;
    this.fsm.forceHome();
    this.expand(view);
  }

  reveal() {
    this.fsm.reveal();
  }

  /** An alert stopped waiting for an answer: let the island auto-close again. */
  dropPin() {
    this.fsm.pinned = false;
  }

  // ── File drop ───────────────────────────────────────────────────────────────

  private onDragDrop(e: { type: string; paths?: string[] }) {
    if (e.type !== "over") void Bridge.log(`drag ${e.type} ${e.paths?.length ?? 0} file(s)`);
    if (State.paused) return;
    switch (e.type) {
      case "enter":
      case "over": {
        if (State.fileDragOver) return;
        State.fileDragOver = true;
        this.engine.animateMorph(1);
        // enterZone must run before the island expands, so the sequence is
        // already active by the time the view becomes `upload`.
        UploadSeq.enterZone(State.mouseInIsland.x, State.mouseInIsland.y);
        this.alert("upload");
        break;
      }
      case "leave": {
        if (!State.fileDragOver) return;
        State.fileDragOver = false;
        this.engine.animateMorph(0);
        // The island deliberately stays open: the drag session is still alive.
        UploadSeq.exitZone();
        State.notify();
        break;
      }
      case "drop": {
        State.fileDragOver = false;
        const path = e.paths?.[0];
        if (!path) {
          this.engine.animateMorph(0);
          this.setView(State.defaultView());
          return;
        }
        this.swallow(path);
        break;
      }
    }
  }

  /**
   * Mochi eats the file. Nothing here waits on the file system: the copy into
   * the inbox runs in the background and swaps the path in when it lands, so a
   * slow disk can never stall the animation — same as FileDropHandler on macOS.
   */
  private swallow(path: string) {
    const name = path.split(/[\\/]/).pop() || "file";
    State.droppedFile = { name, path };
    State.promptContext = { kind: "file", name, path };
    State.chatHistory = [];
    void Bridge.chatReset();

    UploadSeq.performDrop(State.uploadDuration);
    this.uploadTens = 0;
    this.uploadDone = false;

    this.engine.gulp();
    Sound.play("approve");
    this.engine.triggerEmote("happy");
    this.engine.animateMorph(0);

    State.uploadProgress = 0;
    this.setView("uploading");
    this.ensureRunning();

    void Bridge.ingestFile(path)
      .then((file) => {
        State.droppedFile = { name: file.name, path: file.path };
        State.promptContext = { kind: "file", name: file.name, path: file.path };
        State.notify();
      })
      .catch((err) => {
        UploadSeq.deactivate();
        State.noteMessage = String(err).replace(/^Error:\s*/, "");
        this.engine.animateMorph(0);
        this.setView("note");
        Sound.play("error");
        window.setTimeout(() => this.setView(State.defaultView()), 2400);
      });
  }

  /**
   * Sounds and view changes hung off the canvas timeline: a `tick` every 10 %,
   * the ✓ chime when the bar completes, then `choose` once Mochi has grown back.
   */
  private stepSequence() {
    const since = UploadSeq.sinceDrop();
    if (since == null) return;
    const dur = State.uploadDuration;
    const p = Math.max(0, Math.min(1, (since - PRE_PROGRESS) / dur));

    const tens = Math.floor(p * 10);
    if (tens > this.uploadTens && tens < 10) {
      this.uploadTens = tens;
      Sound.play("tick");
    }

    if (!this.uploadDone && since >= PRE_PROGRESS + dur) {
      this.uploadDone = true;
      Sound.play("approve");
      this.engine.triggerEmote("happy");
    }
    // The extra second is the grow-back, after which the choose card is up.
    if (since >= PRE_PROGRESS + dur + 1 && State.view === "uploading") {
      this.setView("choose");
    }
  }

  // ── Geometry ────────────────────────────────────────────────────────────────

/** Whether the island has gone off-screen, which is its own resting state.
   *
   *  Reached from the fully-compact bar by the auto-close delay. Before that step
   *  it keeps the parked bar from before the feature existed.
   */
  private hidesOffscreen(): boolean {
    return this.fsm.state === "gone";
  }


  // Wakes the fully-compact bar: it widens to the retracted width and shows the agent
  // pills, without opening the panel and without touching the off-screen state.
  // Both ways of asking for it end up here — hovering it when "wake on hover" is on,
  // and a double-click beside it — so the two behave identically.
  private setBarHover(on: boolean) {
    if (this.barHover === on) return;
    this.barHover = on;
    // Waking grows the bar, so it springs rather than curves.
    this.animateGeometry(!on);
    this.dirty = true;
  }

  private targetSize(): { w: number; h: number; r: number } {
    const { w, h } = islandSize(State.mode, State.view, State.chatHistory.length, this.hidesOffscreen());
    // The fully-compact bar is a single centred Mochi; waking widens it to the
    // retracted width, which is the one gesture both hover and a double-click do.
    const width = State.mode === "hidden" && this.barHover ? COMPACT_W : w;
    const r = State.mode === "expanded" ? EXPANDED_CORNER : ROUNDED_CORNER;
    return { w: width, h, r };
  }

  private animateGeometry(shrinking: boolean) {
    const { w, h, r } = this.targetSize();
    if (shrinking) {
      this.width.curveTowards(w);
      this.height.curveTowards(h);
      this.radius.curveTowards(r);
    } else {
      this.width.springTo(w);
      this.height.springTo(h);
      this.radius.springTo(r);
    }
    this.ensureRunning();
  }

  /**
   * Horizontal offset of the island inside the window, in logical px.
   *
   * The island must always open toward the middle of the screen: a bar resting
   * on the left edge grows rightwards, one on the right edge grows leftwards,
   * and a centred one opens symmetrically. `bias` is the resting position mapped
   * to 0..1, which makes this continuous — crossing the middle of the screen
   * slides the island rather than snapping it. At bias 0.5 it reduces exactly to
   * the old centred offset.
   */
  private islandOffsetX(w: number): number {
    // The window is always the full panel width, whatever the island draws inside
    // it. If this switched to the reduced width, the offset would jump the moment
    // the island shrank and the bar would appear to lurch to the middle before
    // settling — the window resize must not affect where the island sits.
    const winW = PANEL_W;
    const position = State.settings.notchPosition;
    const p = Number.isFinite(position) ? Math.max(0, Math.min(1, position)) : 0.5;
    return (winW - w) * p;
  }

  private applyGeometry() {
    const w = this.width.value;
    const hh = this.height.value;
    const r = this.radius.value;
    const offsetX = this.islandOffsetX(w);
    this.islandEl.style.width = `${w}px`;
    this.islandEl.style.height = `${hh}px`;
    this.islandEl.style.borderRadius = `0 0 ${r}px ${r}px`;
    // Auto-hide has to take the entire bar with it, not just the Mochi: the bot
    // already fades itself through `botPosition`'s opacity, but the bar's own
    // background outlived the zero-height animation and stayed on screen. Fading
    // the island is the only gate that covers the background, the pills and the bot
    // in one place. Left clickable, so "hover to restore" can still find it.
    this.islandEl.style.opacity = this.hidesOffscreen() ? "0" : "1";
    this.islandEl.style.transform = `translateX(${offsetX}px)`;
    // These follow the island as it resizes, so they belong here rather than in
    // the state-driven DOM sync.
    // The pill grid sits in the right end of the expanded panel and shrinks with the
    // bar, so a 24px-tall bar never crops it (PR #22 scales the grid to the resting
    // height). Left as the draft had it now that the pills only appear expanded.
    const gridScale = Math.min(1, Math.max(0, hh - 4) / 28);
    const grid = 29 * gridScale;
    this.miniGrid.style.transform = `scale(${gridScale})`;
    this.miniGrid.style.transformOrigin = "center center";
    this.miniGrid.style.left = `${w - 40 - grid / 2}px`;
    this.miniGrid.style.top = `${hh / 2 - grid / 2}px`;
    this.greetingCanvas.style.left = `${(w - EXPANDED_W) / 2}px`;
    this.uploadCanvas.el.style.left = `${(w - EXPANDED_W) / 2}px`;

    const rect = { x: offsetX, y: 0, w, h: hh };
    const p = this.pushedRect;
    if (Math.abs(p.x - rect.x) > 0.5 || Math.abs(p.w - rect.w) > 0.5 || Math.abs(p.h - rect.h) > 0.5) {
      this.pushedRect = rect;
      void Bridge.setIslandRect(rect.x, rect.y, rect.w, rect.h);
    }
  }

  /** Island rect in window coordinates (origin top-left of the 720×320 window). */
  private islandRect(): { x: number; y: number; w: number; h: number } {
    const w = this.width.value;
    const hh = this.height.value;
    return { x: this.islandOffsetX(w), y: 0, w, h: hh };
  }

  // ── Window collapse (hidden → tiny wake strip, zero polling) ────────────────

  private updateWindowCollapsed() {
    if (this.collapseTimer != null) {
      window.clearTimeout(this.collapseTimer);
      this.collapseTimer = null;
    }
    if (State.mode === "hidden") {
      // The window deliberately keeps its full size while the island shrinks.
      // Resizing it used to resize the surface underneath the shrink animation,
      // which read as a lurch toward the middle; the transparent margin is
      // click-through, so nothing is lost by leaving it in place.
      this.collapseTimer = null;
    } else if (this.collapsed) {
      // Grow the window back before the island animates open.
      this.collapsed = false;
      void Bridge.setCollapsed(false);
    }
  }

  // ── Input ───────────────────────────────────────────────────────────────────

  private wireInput() {
    // The island element is its own wake target now that the reduced state is a
    // real, visible stub. A separate wake strip used to sit centred in the window
    // and went stale the moment the island could be dragged off-centre, leaving a
    // hit area to the left of the bar that woke the island by mistake.
    this.islandEl.addEventListener("mousedown", (e) => {
      Sound.resume();
      State.lastActivity = performance.now();
      if (State.mode !== "expanded") {
        // Both resting bars drag, and the click that opens the island is decided
        // on release instead. Opening on press would flip the mode to expanded
        // mid-gesture and resize the window out from under the drag.
        this.beginNotchDrag(e);
        return;
      }
      if (this.isBotHit(e.clientX, e.clientY)) {
        this.cancelBotHover();
        this.engine.slap();
      }
    });

    window.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && State.mode === "expanded" && !this.staysOpen) this.collapse();
      State.lastActivity = performance.now();
    });

    void onDragDrop((e) => this.onDragDrop(e));

    // Outside Tauri (plain browser) drive the cursor from DOM events so the
    // island can be inspected with `npm run dev`.
    if (!IS_TAURI) {
      window.addEventListener("mousemove", (e) => this.onCursor(e.clientX, e.clientY));
      window.addEventListener("pointerdown", (e) => {
        if (!this.islandEl.contains(e.target as Node)) this.dismissOutside();
      });
    }
  }

  /** Cursor in window-logical coordinates. */
  onCursor(x: number, y: number) {
    State.mouse = { x, y };
    const rect = this.islandRect();
    State.mouseInIsland = { x: x - rect.x, y: y - rect.y };

    // Windows sends no cursor position with an OLE drag, so the drop sequence is
    // fed from the Win32 cursor poll instead — it runs throughout the drag.
    if (UploadSeq.isActive && !UploadSeq.dropped) {
      UploadSeq.updateCursor(State.mouseInIsland.x, State.mouseInIsland.y);
    }

    const inIsland =
      x >= rect.x - HIT_MARGIN && x <= rect.x + rect.w + HIT_MARGIN &&
      y >= rect.y - HIT_MARGIN && y <= rect.y + rect.h + HIT_MARGIN;

    if (inIsland && !this.wasInIsland) {
      if (this.fsm.state === "coucou") this.greeting.hover();
      // This is the poll-driven hover path and it is the one that actually wakes
      // the island on Windows, so the "wake on hover" setting has to be honoured
      // here too — gating only the DOM mouseenter left the setting inert.
      // "Wake on hover" widens the fully-compact bar into the retracted one, pills and
      // all. "Hover to restore" is the only thing that brings the island back from
      // off-screen. They are different gestures on different states and neither
      // opens the panel.
      if (this.fsm.state === "hidden") {
        if (State.settings.wakeOnHover) this.setBarHover(true);
      } else if (this.fsm.state !== "gone" || State.settings.hoverRestore) {
        this.fsm.mouseEntered();
      }
      this.homeCollapseAt = null;
    }
    if (!inIsland && this.wasInIsland) {
      // Leaving shrinks a woken bar back to the single centred Mochi.
      if (this.fsm.state === "hidden") this.setBarHover(false);
      this.fsm.mouseLeft();
      if (this.fsm.state === "home" && !this.staysOpen && State.settings.autoCloseInterval > 0) {
        this.homeCollapseAt = performance.now() + State.settings.autoCloseInterval * 1000;
      }
    }
    this.wasInIsland = inIsland;

    // Bot hover → love
    const overBot = State.mode === "expanded" && State.stateOverride == null && this.isBotHit(x, y);
    if (overBot && !this.botHovering) this.botHoverIn(x, y);
    if (!overBot && this.botHovering) this.cancelBotHover();
    this.botHovering = overBot;
    if (this.botHovering) {
      const d = Math.hypot(x - this.botHoverStart.x, y - this.botHoverStart.y);
      if (d > 40) {
        this.botHoverStart = { x, y };
        this.scheduleLove();
      }
    }

    this.ensureRunning();
  }

  private isBotHit(x: number, y: number): boolean {
    const rect = this.islandRect();
    const cx = rect.x + this.botCx.value;
    const cy = rect.y + this.botCy.value;
    const radius = this.botSize.value / 2;
    return (x - cx) ** 2 + (y - cy) ** 2 <= radius * radius;
  }

  private botHoverIn(x: number, y: number) {
    if (performance.now() / 1000 - this.lastLoveTime < 6) return;
    this.botHoverStart = { x, y };
    this.engine.blink();
    this.engine.tgEs = 1.08;
    Sound.play("hover");
    this.scheduleLove();
  }

  private scheduleLove() {
    if (this.botHoverTimer != null) window.clearTimeout(this.botHoverTimer);
    this.botHoverTimer = window.setTimeout(() => {
      this.botHoverTimer = null;
      if (!this.botHovering || State.stateOverride != null) return;
      if (performance.now() / 1000 - this.lastLoveTime < 6) return;
      this.lastLoveTime = performance.now() / 1000;
      this.engine.triggerEmote("love");
      Sound.play("love");
    }, 1900);
  }

  private cancelBotHover() {
    if (this.botHoverTimer != null) window.clearTimeout(this.botHoverTimer);
    this.botHoverTimer = null;
    this.engine.tgEs = 1;
  }

  /** Three slaps → dizzy + confused view for 3.3 s, then back. */
  private handleDizzy() {
    this.prevViewBeforeConfused = State.view;
    State.stateOverride = "dizzy";
    this.engine.setState("dizzy");
    Sound.play("dizzy");
    this.alert("confused");
    if (this.confusedRecovery != null) window.clearTimeout(this.confusedRecovery);
    this.confusedRecovery = window.setTimeout(() => {
      this.confusedRecovery = null;
      State.stateOverride = null;
      this.engine.setState(State.effectiveState);
      if (State.view === "confused") {
        const fallback = State.defaultView();
        this.setView(this.prevViewBeforeConfused === "confused" ? fallback : this.prevViewBeforeConfused);
      }
      this.engine.triggerEmote("happy");
    }, 3300);
  }

  // ── Frame loop ──────────────────────────────────────────────────────────────

  ensureRunning() {
    if (this.running) return;
    this.running = true;
    this.lastFrame = performance.now();
    requestAnimationFrame(this.frame);
  }

  private frame = (nowMs: number) => {
    const dt = Math.min(0.05, (nowMs - this.lastFrame) / 1000);
    this.lastFrame = nowMs;

    this.width.step(dt, nowMs);
    this.height.step(dt, nowMs);
    this.radius.step(dt, nowMs);
    this.applyGeometry();

    if (this.dirty) {
      this.dirty = false;
      this.syncDom();
    }

    this.updateBotTargets();
// Mochi sits at the left of the woken bar, with the pills filling the right end,
    // and dead centre in the resting 80pt bar. Both are x=40, so one value covers
    // them; the pills only appear in the wider one.
    this.botCx.step(dt);
    this.botCy.step(dt);
    this.botSize.step(dt);

    const greetingActive = State.mode === "expanded" && State.view === "greeting";
    if (greetingActive) {
      const gctx = this.greetingCanvas.getContext("2d");
      if (gctx) {
        const dpr = Math.min(2, window.devicePixelRatio || 1);
        gctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        this.greeting.draw(gctx);
      }
    } else {
      // Kept running even while the drop canvas is up, so the island's own Mochi
      // is already in the right place the moment the canvas fades out.
      this.drawBot(dt);
    }

    const uploadActive = this.uploadActive;
    if (uploadActive) this.uploadCanvas.draw(UploadSeq.frame(), nowMs / 1000);
    this.uploadCanvas.el.classList.toggle("on", uploadActive);
    this.viewsEl.classList.toggle("hidden-by-upload", uploadActive);

    tickMiniBots(dt);
    this.views.get(State.view)?.tick?.(nowMs);
    if (UploadSeq.isActive) this.stepSequence();
    this.updateCountdown(nowMs);

    // Nothing is drawn while the island is hidden, so nothing may keep the loop
    // alive either. This used to read `... || this.engine.busy || State.mode !==
    // "hidden"`, and engine.busy is permanently true for any state with a
    // looping animation — breathing, ratelimit sweat, sleeping z's, the search
    // sweep — so a hidden island went on burning frames in exactly the states it
    // spends most of its life in. Geometry still has to finish retracting.
    const settling =
      this.width.animating || this.height.animating || this.radius.animating;
    const busy = State.mode === "hidden"
      ? settling
      : settling ||
        !this.botCx.settled || !this.botCy.settled || !this.botSize.settled ||
        greetingActive || this.engine.busy || UploadSeq.isActive;

    if (busy) {
      requestAnimationFrame(this.frame);
    } else {
      this.running = false;
      Sound.idle();
    }
  };

  private updateBotTargets() {
    const p = botPosition(State.mode, State.view, this.height.value, State.uploadProgress, this.hidesOffscreen());
    this.botCx.target = p.cx;
    this.botCy.target = p.cy;
    this.botSize.target = p.diameter / 0.6;

    const greetingActive = State.mode === "expanded" && State.view === "greeting";
    // The drop canvas draws its own Mochi; two of them would overlap.
    const visible = p.opacity > 0 && !greetingActive && !this.uploadActive;
    this.botCanvas.style.opacity = visible ? "1" : "0";

    if (State.mode === "expanded" && State.view !== "uploading" && !greetingActive && !this.uploadActive) {
      const d = p.diameter;
      const color = botGlowColor(State.effectiveState);
      this.botGlow.style.display = "block";
      this.botGlow.style.width = `${d * 2.2}px`;
      this.botGlow.style.height = `${d * 2.2}px`;
      this.botGlow.style.left = `${this.botCx.value - d * 1.1}px`;
      this.botGlow.style.top = `${this.botCy.value - d * 1.1}px`;
      this.botGlow.style.background = `radial-gradient(circle, ${color} 0%, transparent 62%)`;
      this.botGlow.style.opacity = String(botGlowOpacity(State.effectiveState));
    } else {
      this.botGlow.style.display = "none";
    }
  }

  private drawBot(dt: number) {
    const size = this.botSize.value;
    const w = Math.max(1, Math.round(size));
    const hCss = w + BOT_OVERHANG;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    if (this.canvasPx !== w) {
      this.canvasPx = w;
      this.botCanvas.width = Math.round(w * dpr);
      this.botCanvas.height = Math.round(hCss * dpr);
      this.botCanvas.style.width = `${w}px`;
      this.botCanvas.style.height = `${hCss}px`;
    }
    this.botCanvas.style.left = `${this.botCx.value - w / 2}px`;
    this.botCanvas.style.top = `${this.botCy.value - BOT_OVERHANG / 2 - hCss / 2}px`;

    const ctx = this.botCanvas.getContext("2d");
    if (!ctx) return;

    const focus = State.focusTask;
    this.engine.bodyColor = focus?.isIntegration ? hexToRGB(focus.color) : null;
    this.engine.particleOverhang = BOT_OVERHANG;
    this.engine.lookX = this.lookX();
    this.engine.lookY = this.lookY();
    if (this.engine.morph > 0.3) {
      this.engine.slotHTarget = State.fileDragOver ? 0.2 : 0;
    } else {
      this.engine.slotHTarget = 0;
      if (this.engine.morph < 0.05) {
        this.engine.slotH = 0;
        this.engine.slotHVel = 0;
      }
    }
    this.engine.update(dt);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, hCss);
    this.engine.draw(ctx, w, hCss);
  }

  /** BotCanvasView.lookX / lookY — tanh of the distance to the bot. */
  private lookX(): number {
    const rect = this.islandRect();
    const botScreenX = rect.x + this.botCx.value;
    return Math.tanh((State.mouse.x - botScreenX) / 260);
  }

  private lookY(): number {
    return -Math.tanh((State.mouse.y - this.botCy.value) / 200);
  }

  private updateCountdown(nowMs: number) {
    if (State.mode !== "expanded" || this.staysOpen || this.homeCollapseAt == null) {
      this.countdown.style.width = "0px";
      return;
    }
    const autoClose = State.settings.autoCloseInterval;
    const windowS = Math.min(10, autoClose * 0.6);
    const remaining = (this.homeCollapseAt - nowMs) / 1000;
    this.countdown.style.width =
      remaining < windowS ? `${Math.max(0, clamp(remaining / windowS, 0, 1) * 160)}px` : "0px";
  }

  // ── DOM sync ────────────────────────────────────────────────────────────────

  private syncDom() {
    const expanded = State.mode === "expanded";
    const greetingActive = expanded && State.view === "greeting";

    this.contentEl.style.opacity = expanded && !greetingActive ? "1" : "0";
    this.contentEl.style.pointerEvents = expanded && !greetingActive ? "auto" : "none";
    this.greetingCanvas.style.display = greetingActive ? "block" : "none";

    this.header.sync();
    for (const [name, view] of this.views) {
      const on = name === State.view;
      view.el.classList.toggle("on", on);
      if (on) view.sync();
    }

    // The chat is the only view with a text field, so it is the only time the
    // island is allowed to take keyboard focus.
    if (this.lastSyncedView !== State.view) {
      const wasChat = this.lastSyncedView === "prompt";
      this.lastSyncedView = State.view;
      if (State.view === "prompt") {
        void Bridge.focusWindow(true);
        window.setTimeout(() => this.views.get("prompt")?.focus?.(), 120);
      } else if (wasChat) {
        void Bridge.focusWindow(false);
      }
    }

    // The agent pills belong to a woken resting bar and nowhere else — Mochi to the
    // left, pills to the right end, as the draft had it. They are deliberately not
    // shown in the expanded panel: the grid is a child of the island, so leaving
    // it visible there painted mini Mochis over the settings view and every other
    // full-screen view.
    // `State.mode` has no "petit": that FSM state is the compact mode. So the bar is
    // either the resting 80pt one or the woken 240pt one.
    // The agent pills belong to a bar wide enough to hold them — the 240pt retracted
    // bar, whether it was reached by the Compact timer or by "wake on hover"
    // widening the fully-compact one — and never to the expanded panel: the grid is
    // a child of the island, so leaving it visible there painted mini Mochis over the
    // settings view and every other full-screen view. The fully-compact bar is the
    // single centred Mochi with nothing beside it.
    const showGrid = State.mode === "compact" || (State.mode === "hidden" && this.barHover);
    this.miniGrid.style.opacity = showGrid ? "1" : "0";
    // Emptied when hidden, not just made transparent. A transparent grid still
    // occupies the island and its children still render, which is how a second
    // Mochi appeared over the first whenever the cursor came near.
    if (!showGrid) {
      if (this.miniGrid.dataset.key !== "") {
        this.miniGrid.dataset.key = "";
        this.miniGrid.replaceChildren();
        pruneMiniBots();
      }
    } else {
      const others = State.otherTasks.slice(0, 4);
      const key = others.map((t) => t.id).join("|");
      if (this.miniGrid.dataset.key !== key) {
        this.miniGrid.dataset.key = key;
        this.miniGrid.replaceChildren();
        for (const t of others) {
          this.miniGrid.append(createMiniBot(t, 13));
        }
        pruneMiniBots();
      }
    }

    syncMiniBotStates(State.tasks);
    this.engine.setState(State.effectiveState);
  }

  /** Applies settings coming from Rust at boot. */
  applySettings() {
    Sound.setEnabled(State.settings.soundEnabled);
    Sound.setVolume(State.settings.soundVolume);
    this.fsm.homeToPetitDelay = State.settings.autoCloseInterval;
    this.fsm.petitToHiddenDelay = State.settings.absenceInterval;
    this.fsm.hiddenToGoneDelay = State.settings.autoCloseDelay;
    // A pin saved last session keeps the island open across a restart.
    State.isPinned = State.settings.pinIsland;
    this.fsm.pinned = State.settings.pinIsland;
    State.notify();
  }

  get panelSize() {
    return { w: PANEL_W, h: PANEL_H };
  }

  get chatHeight() {
    return chatPromptHeight(State.chatHistory.length);
  }
}
