// Desktop Mochi — the webview half.
//
// Ownes a 120x120 transparent window containing one BotEngine, and nothing else.
// The island window keeps its own engine; this one exists so Mochi can be
// dragged out onto the desktop and left there.
//
// Every decision about where it goes and when it sleeps lives in ./desktop.ts,
// which is unit-tested (`npm run test:mochi`). This file is the part that needs
// a real desktop to test, so it stays thin.
//
// Gestures, all matching the macOS build:
//   hover ~1.9s  -> love emote + hearts (the same rule the island uses)
//   single click -> slap(); deferred in case a second click follows
//   double click -> go home (hide; the island keeps working)
//   drag         -> move, clamped in Rust, position persisted

import { Bridge, IS_TAURI, type DesktopMochiRuntime, type DesktopMochiSnapshot } from "../core/bridge";
import { Sound } from "../core/sound";
import { BotEngine, hexToRGB } from "./engine";
import type { BotStateName } from "../core/layout";
import {
  DESKTOP_PANEL_SIZE,
  isOverBody,
  shouldSleep,
} from "./desktop";

const canvas = document.getElementById("mochi") as HTMLCanvasElement | null;
const ctx = canvas?.getContext("2d");
const engine = new BotEngine();

let cssSize = DESKTOP_PANEL_SIZE;
let dpr = Math.min(2, window.devicePixelRatio || 1);

/** Rust-fed global cursor offset from Mochi's centre, in panel CSS pixels. */
const cursorOffset = { x: 0, y: 0 };

/** Last time any agent did something; the sleep timer counts from here. */
let lastActiveMs = Date.now();
let asleep = false;
let petState: BotStateName = "idle";
let focusedPillId: string | null = null;
let pillColor: string | null = null;
let permissionPending = false;
let approvalReturnTimer: number | null = null;
let approvalReturnStarted = false;

/** Last love, in seconds, so hearts are rate-limited exactly like the island's. */
let lastLoveSec = -1e9;
let hovering = false;
let hoverTimer: number | null = null;

/** Roughly the platform double-click interval. */
const DOUBLE_CLICK_MS = 320;

/** Report to the native log for debugging. */
const P = (m: string) => void Bridge.desktopMochiProbe(m);
P("mochi: boot");
P(`canvas=${!!canvas}`);

function resize() {
  if (!canvas) return;
  const rect = canvas.getBoundingClientRect();
  cssSize = Math.max(1, Math.round(rect.width || DESKTOP_PANEL_SIZE));
  dpr = Math.min(2, window.devicePixelRatio || 1);
  canvas.width = Math.round(cssSize * dpr);
  canvas.height = Math.round(cssSize * dpr);
}

// ── click-through ────────────────────────────────────────────────────────────

/**
 * Makes the invisible parts of the square window pass clicks through.
 *
 * The panel is 120x120 but the body is only a circle of radius 120 * 0.24
 * inside it. Without this the whole square swallows clicks meant for the
 * desktop underneath, which is a 120px dead zone whose cause you cannot see.
 */

// ── affection: hover-love, the same rule the island uses ─────────────────────

function startHoverLove() {
  if (hovering) return;
  hovering = true;
  engine.blink();
  if (hoverTimer != null) window.clearTimeout(hoverTimer);
  hoverTimer = window.setTimeout(() => {
    hoverTimer = null;
    if (!hovering) return;
    const nowSec = performance.now() / 1000;
    if (nowSec - lastLoveSec < 6) return;
    lastLoveSec = nowSec;
    wake();
    engine.triggerEmote("love");
    Sound.play("love");
  }, 1900);
}

function stopHoverLove() {
  hovering = false;
  if (hoverTimer != null) {
    window.clearTimeout(hoverTimer);
    hoverTimer = null;
  }
}

// ── sleep ────────────────────────────────────────────────────────────────────

function wake() {
  lastActiveMs = Date.now();
  if (asleep) {
    asleep = false;
    engine.setState(petState, true);
  }
}

function applyPetSnapshot(snapshot: DesktopMochiSnapshot, visible: boolean) {
  const nextState = snapshot.state as BotStateName;
  const focusChanged = focusedPillId !== snapshot.focused_id;
  const stateChanged = petState !== nextState;
  const colorChanged = pillColor !== snapshot.body_color;
  const musicChanged = engine.singing !== snapshot.music_playing;
  const wasPermissionPending = permissionPending;
  focusedPillId = snapshot.focused_id;
  petState = nextState;
  pillColor = snapshot.body_color;
  permissionPending = snapshot.permission_pending;
  engine.singing = snapshot.music_playing;
  engine.bodyColor = snapshot.body_color ? hexToRGB(snapshot.body_color) : null;
  if (focusChanged || stateChanged || colorChanged || musicChanged) {
    P(`pill sync id=${focusedPillId ?? "none"} state=${petState} color=${pillColor ?? "gradient"}`);
    lastActiveMs = Date.now();
    asleep = false;
    engine.setState(petState, true);
  }

  if (permissionPending && visible) {
    if (!wasPermissionPending || !lastWindowVisible || focusChanged || stateChanged || colorChanged) {
      engine.setState("approval", true);
      lastActiveMs = Date.now();
      asleep = false;
    }
    if (!approvalReturnStarted && approvalReturnTimer == null) {
      // Leave the exclamation/bounce visible briefly before Mochi flies home.
      approvalReturnTimer = window.setTimeout(() => {
        approvalReturnTimer = null;
        if (!permissionPending || !lastWindowVisible) return;
        approvalReturnStarted = true;
        engine.teleportOut(() => {
          window.setTimeout(() => void Bridge.desktopMochiSetEnabled(false), 220);
        });
      }, 900);
    }
  } else if (!permissionPending && wasPermissionPending) {
    if (approvalReturnTimer != null) window.clearTimeout(approvalReturnTimer);
    approvalReturnTimer = null;
    const returnWasStarted = approvalReturnStarted;
    approvalReturnStarted = false;
    if (!returnWasStarted) engine.setState(petState, true);
  }
}

// ── drag ─────────────────────────────────────────────────────────────────────

let dragging = false;
let nativeDragReady = false;
let dragStart = { x: 0, y: 0 };
let dragMoved = false;
let suppressNextClick = false;

function onDown(e: MouseEvent) {
  const rect = canvas?.getBoundingClientRect();
  if (!rect) return;
  // Only the body is draggable; clicking through the transparent corners must
  // reach whatever is under the panel, not start a drag of nothing.
  if (!isOverBody(e.clientX - rect.left, e.clientY - rect.top, cssSize)) return;
  stopHoverLove();
  dragging = true;
  nativeDragReady = false;
  dragMoved = false;
  suppressNextClick = false;
  document.body.classList.add("dragging");
  dragStart = { x: e.screenX, y: e.screenY };
  void Bridge.desktopMochiDragStart().then(() => { nativeDragReady = true; });
}

function onMove(e: MouseEvent) {
  cursorOffset.x = e.clientX - cssSize / 2;
  cursorOffset.y = e.clientY - cssSize / 2;

  if (dragging) {
    const dx = e.screenX - dragStart.x;
    const dy = e.screenY - dragStart.y;
    if (dx || dy) dragMoved = true;
    // Rust tracks the global cursor and moves the window itself. That continues
    // to work when click-through or the taskbar stops WebView mouse events.
    dragStart = { x: e.screenX, y: e.screenY };
    return;
  }

  const rect = canvas?.getBoundingClientRect();
  if (rect && isOverBody(e.clientX - rect.left, e.clientY - rect.top, cssSize)) startHoverLove();
  else stopHoverLove();
}

function finishDrag(notifyNative: boolean) {
  if (!dragging) return;
  const moved = dragMoved;
  dragging = false;
  nativeDragReady = false;
  dragMoved = false;
  suppressNextClick = moved;
  document.body.classList.remove("dragging");
  if (notifyNative) void Bridge.desktopMochiDragEnd();
  // A drag that ended is not a click, but the cursor is probably still over the
  // body, so hover-love should pick back up.
  if (moved) startHoverLove();
}

function onUp() {
  finishDrag(true);
}

// ── click: slap on single, go home on double ─────────────────────────────────

let pendingClick: number | null = null;

function onClick() {
  if (suppressNextClick) {
    suppressNextClick = false;
    return;
  }
  if (dragging || dragMoved) return;
  if (pendingClick != null) {
    window.clearTimeout(pendingClick);
    pendingClick = null;
    engine.teleportOut(() => {
      window.setTimeout(() => void Bridge.desktopMochiSetEnabled(false), 220);
    });
    return;
  }
  // Wait to see whether a second click arrives. Slapping is the common case,
  // and firing it immediately would slap and then go home on a real double-click.
  pendingClick = window.setTimeout(() => {
    pendingClick = null;
    wake();
    engine.slap();
  }, DOUBLE_CLICK_MS);
}

// ── loop ─────────────────────────────────────────────────────────────────────

let last = performance.now();
let frames = 0;
let lastWindowVisible: boolean | null = null;
let runtimePollInFlight = false;

function frame(now: number) {
  // BotEngine.update expects seconds; keep this in step with the island loop so
  // transient particles (music notes, teleport sparks) live for real seconds.
  const dt = Math.min(0.064, (now - last) / 1000);
  last = now;

  // Both conditions, not either: a bot that sleeps while you are working next
  // to it is worse than one that never sleeps.
  const asleepNow = !engine.singing && shouldSleep(Date.now() - lastActiveMs, Math.hypot(cursorOffset.x, cursorOffset.y));
  if (asleepNow !== asleep) {
    asleep = asleepNow;
    // A cursor-proximity wake is real activity too. Refreshing this clock keeps
    // Mochi awake for a full idle interval after it wakes instead of immediately
    // falling asleep again as soon as the cursor leaves its radius.
    if (!asleepNow) lastActiveMs = Date.now();
    engine.setState(asleepNow ? "sleeping" : petState, true);
  }

  engine.lookX = Math.tanh(cursorOffset.x / 260);
  engine.lookY = -Math.tanh(cursorOffset.y / 200);
  engine.update(dt);

  if (ctx && canvas) {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.save();
    ctx.scale(dpr, dpr);
    engine.draw(ctx, cssSize, cssSize);
    ctx.restore();
    if (frames === 0) P(`first draw ${canvas.width}x${canvas.height} css=${cssSize} state=${engine.state ?? "?"}`);
    frames++;
  }
  requestAnimationFrame(frame);
}

// ── boot ─────────────────────────────────────────────────────────────────────

resize();
window.addEventListener("resize", resize);
window.addEventListener("mousemove", onMove);
window.addEventListener("mousedown", onDown);
window.addEventListener("mouseup", onUp);
window.addEventListener("click", onClick);
window.addEventListener("blur", () => {
  // Do not cancel a drag on blur: Rust is tracking the global cursor and can
  // carry it across the taskbar until the actual mouse button is released.
  stopHoverLove();
  document.body.classList.remove("dragging");
});
// No context menu: on the desktop a stray right-click menu floating over the
// user's wallpaper is worse than nothing.
window.addEventListener("contextmenu", (e) => e.preventDefault());

if (IS_TAURI) {
  // Poll one native snapshot rather than depending on event delivery between
  // WebViews. The same reply supplies global cursor offsets, even while the
  // transparent corners are click-through.
  const pollRuntime = async () => {
    if (runtimePollInFlight) return;
    runtimePollInFlight = true;
    try {
      const runtime: DesktopMochiRuntime | null = await Bridge.desktopMochiRuntime();
      if (!runtime) return;
      if (runtime.snapshot) applyPetSnapshot(runtime.snapshot, runtime.visible);
      if (dragging && nativeDragReady && !runtime.dragging) finishDrag(false);
      if (runtime.cursor) {
        cursorOffset.x = runtime.cursor.dx;
        cursorOffset.y = runtime.cursor.dy;
      }
      if (runtime.visible && lastWindowVisible !== true) {
        P("teleport arrival");
        wake();
        engine.teleportIn();
      }
      lastWindowVisible = runtime.visible;
    } finally {
      runtimePollInFlight = false;
    }
  };
  void pollRuntime();
  window.setInterval(() => void pollRuntime(), 50);

  // Sounds live in this webview's own AudioContext, not the island's, so they
  // have to be loaded and enabled here too.
  void Sound.preload();
  void Bridge.boot().then((boot) => {
    if (boot) Sound.setEnabled(boot.settings.soundEnabled);
  });
}

requestAnimationFrame(frame);