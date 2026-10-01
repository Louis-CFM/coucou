// The island: DOM shell, sizing animation, Mochi placement, mouse handling.
// Mirrors IslandRootView.swift + IslandWindowController.swift.

import { Tracked, Spring, clamp } from "../core/anim";
import { Bridge, IS_TAURI, onDragDrop } from "../core/bridge";
import {
  EXPANDED_CORNER, EXPANDED_W, NOTCH_W, PANEL_H, PANEL_W,
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
  private wakeStrip!: HTMLElement;

  private header!: ViewHost;
  private views!: Map<IslandViewName, ViewHost>;
  private actions!: ViewActions;
  private lastLang: string = "en";
  private uploadCanvas!: UploadCanvas;

  private width = new Tracked(NOTCH_W);
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

  // Mochi drag-out → window attach (macOS: drag Mochi onto any window).
  // Press is recorded on mousedown; the slap is deferred until release so a
  // press that turns into a drag (> 7pt) becomes a ghost instead of a slap.
  private botPress: { x: number; y: number } | null = null;
  private draggingGhost = false;
  private ghostEl!: HTMLElement;

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
      newChat: () => {
        State.chatHistory = [];
        State.droppedFile = null;
        State.promptContext = null;
        State.stateOverride = null;
        State.noteMessage = null;
        void Bridge.chatReset();
        Sound.play("blip");
        this.setView(State.defaultView());
      },
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
          integration_spotify: "https://open.spotify.com",
          integration_whatsapp: "https://web.whatsapp.com",
          integration_gmail: "https://mail.google.com",
          integration_outlook: "https://outlook.live.com",
        };
        if (task.id === "integration_claude" || task.source === "claudeCode") {
          void Bridge.openInVSCode(task.sessionCwd ?? null);
        } else if (task.source === "geminiCli" || task.source === "antigravity" || task.source === "opencode" || task.source === "genericCli") {
          // No per-terminal jump on Windows — open the working folder like VS Code.
          void Bridge.openInVSCode(task.sessionCwd ?? null);
        } else if (task.id === "integration_n8n") void Bridge.openN8n();
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
        const focusId = State.focusId ?? "integration_claude";
        State.updateTask(focusId, "working");
        State.setPillBadge(focusId, null);
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
        void Bridge.saveSettings(State.settings);
        State.notify();
      },
      openSettingsWindow: () => void Bridge.openSettingsWindow(),
      blip: () => Sound.play("blip"),
    };

    this.wakeStrip = h("div", { id: "wake-strip" });
    this.botGlow = h("div", { id: "bot-glow" });
    this.botCanvas = h("canvas", { id: "bot-canvas" });
    this.ghostEl = this.buildGhost();
    this.greetingCanvas = h("canvas", { id: "greeting-canvas" });
    this.miniGrid = h("div", { id: "mini-grid" });
    this.countdown = h("div", { id: "countdown" });

    this.header = buildHeader(actions);
    this.views = buildViews(actions, () => this.animateGeometry(false));
    this.viewsEl = h("div", { id: "views" });
    for (const v of this.views.values()) this.viewsEl.append(v.el);
    this.contentEl = h("div", { id: "content" }, this.header.el, this.viewsEl);
    this.actions = actions;

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
      h("div", { id: "embasa-rule" }),
    );

    const dpr = Math.min(2, window.devicePixelRatio || 1);
    this.greetingCanvas.width = Math.round(EXPANDED_W * dpr);
    this.greetingCanvas.height = Math.round(150 * dpr);
    this.greetingCanvas.style.width = `${EXPANDED_W}px`;
    this.greetingCanvas.style.height = "150px";

    this.root.append(this.wakeStrip, this.islandEl, this.ghostEl);
    this.applyGeometry();
  }

  /**
   * Rebuilds header + views so a language switch re-renders every static
   * label immediately (buttons built once would otherwise stay in the old
   * language until restart). State (tasks, chat, focus) is untouched.
   */
  private rebuildChrome() {
    const old = this.contentEl;
    this.header = buildHeader(this.actions);
    this.views = buildViews(this.actions, () => this.animateGeometry(false));
    this.viewsEl = h("div", { id: "views" });
    for (const v of this.views.values()) this.viewsEl.append(v.el);
    this.contentEl = h("div", { id: "content" }, this.header.el, this.viewsEl);
    old.replaceWith(this.contentEl);
    this.lastSyncedView = null;
    this.dirty = true;
    this.ensureRunning();
  }

  /**
   * The drag ghost: a simple CSS Mochi (cream squircle + two eyes) that follows
   * the cursor while dragging the bot out. The real canvas keeps rendering
   * underneath but is hidden until the drop, so no engine coupling is needed.
   */
  private buildGhost(): HTMLElement {
    const eye = (left: string) => h("div", {
      style: `position:absolute;top:20px;left:${left};width:9px;height:11px;border-radius:50%;background:#1A1412`,
    });
    const ghost = h("div", {
      id: "bot-ghost",
      style: "position:absolute;display:none;width:54px;height:48px;border-radius:46% 46% 48% 48%/58% 58% 42% 42%;background:radial-gradient(circle at 68% 22%,#FFFAF5 0%,#EAD9CC 78%,#DDCCBF 100%);box-shadow:0 6px 22px rgba(0,0,0,.5);z-index:60;pointer-events:none",
    }, eye("15px"), eye("30px"));
    return ghost;
  }

  // ── Mochi drag-out → window attach ────────────────────────────────────────

  private startGhost(x: number, y: number) {
    this.draggingGhost = true;
    this.botPress = null;
    this.cancelBotHover();
    this.botHovering = false;
    this.engine.triggerEmote("surprised");
    Sound.play("pop");
    this.botCanvas.style.opacity = "0";
    this.moveGhost(x, y);
    this.ghostEl.style.display = "block";
    void Bridge.log("attach drag started");
  }

  private moveGhost(x: number, y: number) {
    this.ghostEl.style.left = `${x - 27}px`;
    this.ghostEl.style.top = `${y - 30}px`;
  }

  private endGhostHidden() {
    this.draggingGhost = false;
    this.ghostEl.style.display = "none";
    this.ensureRunning();
  }

  /** Release of the left button anywhere (Rust `mouse-up` or DOM fallback). */
  onMouseUp(x: number, y: number) {
    if (this.draggingGhost) {
      const rect = this.islandRect();
      const overIsland =
        x >= rect.x - HIT_MARGIN && x <= rect.x + rect.w + HIT_MARGIN &&
        y >= rect.y - HIT_MARGIN && y <= rect.y + rect.h + HIT_MARGIN;
      this.endGhostHidden();
      if (overIsland) return; // dropped back home: silent cancel
      void Bridge.log("attach capture");
      void Bridge.attachWindow()
        .then((win) => {
          const label = win.title || win.appName || win.name;
          State.droppedFile = { name: win.name, path: win.path };
          State.promptContext = { kind: "file", name: win.name, path: win.path };
          State.chatHistory = [];
          void Bridge.chatReset();
          void Bridge.log(`attach captured ${win.appName} ${label.slice(0, 40)}`);
          Sound.play("attach");
          this.engine.triggerEmote("wink");
          this.setView("prompt");
        })
        .catch((err) => {
          State.noteMessage = String(err).replace(/^Error:\s*/, "");
          this.setView("note");
          Sound.play("error");
          window.setTimeout(() => this.setView(State.defaultView()), 2400);
        });
      return;
    }
    if (this.botPress) {
      // Plain click on Mochi: the deferred slap.
      this.botPress = null;
      this.cancelBotHover();
      this.engine.slap();
    }
  }

  // ── FSM ─────────────────────────────────────────────────────────────────────

  private wireFsm() {
    this.fsm.homeToPetitDelay = State.settings.autoCloseInterval;
    this.fsm.onTransition = (from, to) => {
      switch (to) {
        case "hidden":
          this.setMode("hidden");
          break;
        case "petit":
          if (from === "coucou") this.greeting.interrupt();
          else if (from === "hidden") Sound.play("peek");
          this.setMode("compact");
          if (from === "coucou") State.view = State.defaultView();
          if (!this.wasInIsland) this.fsm.mouseLeft();
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

  /**
   * Drop views pin the island: the user opened the Drop tab and is about to
   * fetch a file from Explorer, which always takes longer than the auto-close
   * delay. Without this the island retracts to its 6px strip mid-drag and the
   * OS refuses the drop ("prohibited" cursor) — the #1 drop complaint.
   * A prompt WITH an attached file pins too, so a second drop right after the
   * first chat lands on an open island instead of a hidden strip. Approval
   * pins win over everything; leaving the flow unpins unless a decision
   * is still pending.
   */
  private pinUploadIfNeeded(view: IslandViewName) {
    if (State.pendingApproval) return; // approval owns the pin
    const pinned = UPLOAD_VIEWS.has(view) || (view === "prompt" && State.promptContext != null);
    State.isPinned = pinned;
    this.fsm.pinned = pinned;
  }

  expand(view: IslandViewName) {
    this.stopSequenceIfLeaving(view);
    this.pinUploadIfNeeded(view);
    State.view = view;
    if (State.mode !== "expanded") this.setMode("expanded");
    else this.animateGeometry(false);
    State.lastActivity = performance.now();
    this.homeCollapseAt = null;
    State.notify();
  }

  setView(view: IslandViewName) {
    this.stopSequenceIfLeaving(view);
    this.pinUploadIfNeeded(view);
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
    State.isPinned = false;
    this.fsm.pinned = false;
    // Drive the state machine rather than the mode: setting the mode behind its
    // back left it thinking the island was still open, and a click on the compact
    // island then did nothing — the island could never be reopened.
    this.fsm.forcePetit();
  }

  /** Alert from the hook server: open on this view. Pinned alerts never auto-close. */
  alert(view: IslandViewName) {
    this.fsm.pinned = State.isPinned;
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

  /** Guards the two drop transports (OS-level + DOM fallback) firing twice. */
  private lastSwallowAt = 0;

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
        this.swallowPath(path);
        break;
      }
    }
  }

  /**
   * DOM fallback for drops WebView2 swallows itself: when its inner render
   * target keeps the drop, the OS transport never fires and the cursor reads
   * "prohibited" — but the page still gets HTML5 drop events with the file
   * CONTENT (paths stay hidden). We read the bytes ourselves and hand them to
   * `ingest_bytes`, so a drop works whichever target wins.
   */
  private wireDomDrop() {
    document.addEventListener("dragover", (e) => {
      if (State.paused) return;
      if (!e.dataTransfer || !Array.from(e.dataTransfer.types).includes("Files")) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = "copy";
      if (!State.fileDragOver && State.mode === "expanded") {
        State.fileDragOver = true;
        this.engine.animateMorph(1);
        UploadSeq.enterZone(State.mouseInIsland.x, State.mouseInIsland.y);
        this.alert("upload");
      }
    });
    document.addEventListener("dragleave", (e) => {
      if (e.relatedTarget) return;
      if (!State.fileDragOver) return;
      State.fileDragOver = false;
      this.engine.animateMorph(0);
      UploadSeq.exitZone();
      State.notify();
    });
    document.addEventListener("drop", (e) => {
      if (State.paused) return;
      const files = e.dataTransfer?.files;
      if (!files || files.length === 0) return;
      e.preventDefault();
      State.fileDragOver = false;
      const file = files[0];
      void Bridge.log(`dom-drop ${file.name} ${file.size}b`);
      if (file.size > 25 * 1024 * 1024) {
        State.noteMessage = "File too large (25 MB max).";
        this.setView("note");
        Sound.play("error");
        window.setTimeout(() => this.setView(State.defaultView()), 2400);
        return;
      }
      const reader = new FileReader();
      reader.onload = () => {
        const url = String(reader.result ?? "");
        const b64 = url.includes(",") ? url.split(",")[1] : "";
        if (!b64) {
          State.noteMessage = "Could not read that file.";
          this.setView("note");
          Sound.play("error");
          window.setTimeout(() => this.setView(State.defaultView()), 2400);
          return;
        }
        this.swallowBytes(file.name, b64);
      };
      reader.onerror = () => {
        State.noteMessage = "Could not read that file.";
        this.setView("note");
        Sound.play("error");
        window.setTimeout(() => this.setView(State.defaultView()), 2400);
      };
      reader.readAsDataURL(file);
    });
  }

  /**
   * Mochi eats the file. Nothing here waits on the file system: the copy into
   * the inbox runs in the background and swaps the path in when it lands, so a
   * slow disk can never stall the animation — same as FileDropHandler on macOS.
   */
  private swallowPath(path: string) {
    const name = path.split(/[\\/]/).pop() || "file";
    if (!this.beginSwallow(name, path)) return;
    void Bridge.ingestFile(path).then(
      (file) => this.finishSwallow(file.name, file.path),
      (err) => this.failSwallow(err),
    );
  }

  /** DOM transport: bytes already read by the page (see wireDomDrop). */
  private swallowBytes(name: string, base64Data: string) {
    if (!this.beginSwallow(name, name)) return;
    void Bridge.ingestBytes(name, base64Data).then(
      (file) => this.finishSwallow(file.name, file.path),
      (err) => this.failSwallow(err),
    );
  }

  /** Shared opening choreography. False = duplicate of a swallow in flight. */
  private beginSwallow(name: string, path: string): boolean {
    const now = performance.now();
    if (now - this.lastSwallowAt < 1500) return false;
    this.lastSwallowAt = now;
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
    // Absolute fallback: whatever happens to the ingest promise or the frame
    // loop, the uploading view must never trap the user. If we are still here
    // past the choreography + margin, move on (paths swap in whenever the
    // copy actually lands).
    window.setTimeout(() => {
      if (State.view === "uploading") {
        void Bridge.log("swallow watchdog: forcing choose");
        this.setView("choose");
      }
    }, (PRE_PROGRESS + State.uploadDuration + 1 + 4) * 1000);
    return true;
  }

  private finishSwallow(name: string, path: string) {
    State.droppedFile = { name, path };
    State.promptContext = { kind: "file", name, path };
    void Bridge.log(`swallow done ${name}`);
    State.notify();
  }

  private failSwallow(err: unknown) {
    UploadSeq.deactivate();
    const message = String(err).replace(/^Error:\s*/, "");
    void Bridge.log(`swallow failed ${message.slice(0, 120)}`);
    State.noteMessage = message;
    this.engine.animateMorph(0);
    this.setView("note");
    Sound.play("error");
    window.setTimeout(() => this.setView(State.defaultView()), 2400);
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

    // The uploading card reads State.uploadProgress — nothing else ever writes
    // it, so without this the bar sits at 0% and the drop looks frozen.
    if (State.uploadProgress !== p) {
      State.uploadProgress = p;
      this.dirty = true;
    }

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

  private targetSize(): { w: number; h: number; r: number } {
    const { w, h } = islandSize(State.mode, State.view, State.chatHistory.length);
    const r = State.mode === "expanded" ? EXPANDED_CORNER : ROUNDED_CORNER;
    return { w, h, r };
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

  private applyGeometry() {
    const w = this.width.value;
    const hh = this.height.value;
    const r = this.radius.value;
    this.islandEl.style.width = `${w}px`;
    this.islandEl.style.height = `${hh}px`;
    this.islandEl.style.borderRadius = `0 0 ${r}px ${r}px`;
    this.islandEl.style.transform = `translateX(-50%)`;
    // These follow the island as it resizes, so they belong here rather than in
    // the state-driven DOM sync.
    this.miniGrid.style.left = `${w - 40 - 14.5}px`;
    this.miniGrid.style.top = `${hh / 2 - 14.5}px`;
    this.greetingCanvas.style.left = `${(w - EXPANDED_W) / 2}px`;
    this.uploadCanvas.el.style.left = `${(w - EXPANDED_W) / 2}px`;

    const rect = { x: (PANEL_W - w) / 2, y: 0, w, h: hh };
    // While a Drop view is up the whole window takes the mouse: a file drag
    // must see one stable target from approach to release. Flipping
    // click-through mid-drag is what makes Explorer cache "no drop" and show
    // the prohibited cursor on the second and later drags.
    const dropOpen = State.mode === "expanded" && UPLOAD_VIEWS.has(State.view);
    const hit = dropOpen ? { x: 0, y: 0, w: PANEL_W, h: PANEL_H } : rect;
    const p = this.pushedRect;
    if (Math.abs(p.x - hit.x) > 0.5 || Math.abs(p.w - hit.w) > 0.5 || Math.abs(p.h - hit.h) > 0.5) {
      this.pushedRect = hit;
      void Bridge.setIslandRect(hit.x, hit.y, hit.w, hit.h);
    }
  }

  /** Island rect in window coordinates (origin top-left of the 720×320 window). */
  private islandRect(): { x: number; y: number; w: number; h: number } {
    const w = this.width.value;
    const hh = this.height.value;
    return { x: (PANEL_W - w) / 2, y: 0, w, h: hh };
  }

  // ── Window collapse (hidden → tiny wake strip, zero polling) ────────────────

  private updateWindowCollapsed() {
    if (this.collapseTimer != null) {
      window.clearTimeout(this.collapseTimer);
      this.collapseTimer = null;
    }
    if (State.mode === "hidden") {
      // Let the island finish retracting, then drop the window to the wake strip:
      // from there the OS delivers no cursor events, so nothing polls at all.
      this.collapseTimer = window.setTimeout(() => {
        this.collapseTimer = null;
        if (State.mode !== "hidden") return;
        this.collapsed = true;
        void Bridge.setCollapsed(true);
      }, 420);
    } else if (this.collapsed) {
      // Grow the window back before the island animates open.
      this.collapsed = false;
      void Bridge.setCollapsed(false);
    }
  }

  // ── Input ───────────────────────────────────────────────────────────────────

  private wireInput() {
    // The wake strip is the only thing the OS can hit while the island is hidden.
    this.wakeStrip.addEventListener("mouseenter", () => {
      Sound.resume();
      if (State.mode === "hidden") this.fsm.mouseEntered();
    });

    this.islandEl.addEventListener("mousedown", (e) => {
      Sound.resume();
      State.lastActivity = performance.now();
      if (State.mode !== "expanded") {
        this.fsm.click();
        return;
      }
      if (this.isBotHit(e.clientX, e.clientY)) {
        // Press recorded; slap happens on release unless this becomes a
        // drag-out (> 7pt with the button held → ghost + window attach).
        this.botPress = { x: e.clientX, y: e.clientY };
      }
    });

    // DOM mouseup only fires over our window; releases outside arrive via the
    // Rust `mouse-up` event. Both funnel into onMouseUp (idempotent).
    window.addEventListener("mouseup", () => this.onMouseUp(State.mouse.x, State.mouse.y));

    window.addEventListener("keydown", (e) => {
      // Esc always collapses except while an approval decision is pending —
      // drop/chat pins must never trap the user (collapse() clears them).
      if (e.key === "Escape" && State.mode === "expanded" && !State.pendingApproval) this.collapse();
      State.lastActivity = performance.now();
    });

    void onDragDrop((e) => this.onDragDrop(e));
    this.wireDomDrop();

    // Outside Tauri (plain browser) drive the cursor from DOM events so the
    // island can be inspected with `npm run dev`.
    if (!IS_TAURI) {
      window.addEventListener("mousemove", (e) => this.onCursor(e.clientX, e.clientY));
    }
  }

  /** Cursor in window-logical coordinates. `down` comes from the Rust poll. */
  onCursor(x: number, y: number, down = false) {
    State.mouse = { x, y };
    const rect = this.islandRect();
    State.mouseInIsland = { x: x - rect.x, y: y - rect.y };

    // Press turned into a drag-out: show the ghost once past the 7pt threshold.
    if (this.botPress && down && IS_TAURI && !this.draggingGhost) {
      const d = Math.hypot(x - this.botPress.x, y - this.botPress.y);
      if (d > 7) this.startGhost(x, y);
    }
    if (this.draggingGhost) {
      this.moveGhost(x, y);
      this.ensureRunning();
      return; // no enter/leave, hover or auto-close bookkeeping mid-drag
    }

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
      this.fsm.mouseEntered();
      this.homeCollapseAt = null;
    }
    if (!inIsland && this.wasInIsland) {
      this.fsm.mouseLeft();
      if (this.fsm.state === "home" && !State.isPinned) {
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
    const p = botPosition(State.mode, State.view, this.height.value, State.uploadProgress);
    this.botCx.target = p.cx;
    this.botCy.target = p.cy;
    this.botSize.target = p.diameter / 0.6;

    const greetingActive = State.mode === "expanded" && State.view === "greeting";
    // The drop canvas draws its own Mochi; two of them would overlap. The drag
    // ghost replaces the bot too while a window attach is in flight.
    const visible = p.opacity > 0 && !greetingActive && !this.uploadActive && !this.draggingGhost;
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
    if (State.mode !== "expanded" || State.isPinned || this.homeCollapseAt == null) {
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

    // Compact mini grid
    const showGrid = State.mode === "compact";
    this.miniGrid.style.opacity = showGrid ? "1" : "0";
    if (showGrid) {
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

  /** Applies settings coming from Rust at boot (and on every save). */
  applySettings() {
    Sound.setEnabled(State.settings.soundEnabled);
    Sound.setVolume(State.settings.soundVolume);
    this.fsm.homeToPetitDelay = State.settings.autoCloseInterval;
    this.applyTheme();
    if (State.settings.language !== this.lastLang) {
      this.lastLang = State.settings.language;
      this.rebuildChrome();
    }
    State.notify();
  }

  /** Island theme is pure CSS: one attribute, instant, no rebuild. */
  private applyTheme() {
    const theme = State.settings.theme === "ice" || State.settings.theme === "frost"
      ? State.settings.theme
      : "onyx";
    this.root.dataset.theme = theme;
  }

  get panelSize() {
    return { w: PANEL_W, h: PANEL_H };
  }

  get chatHeight() {
    return chatPromptHeight(State.chatHistory.length);
  }
}
