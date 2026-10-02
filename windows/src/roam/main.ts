// Roaming Mochi: the overlay page (see src-tauri/src/roam.rs).
//
// Dragged out of the island, Mochi dangles from the cursor (carried too long or
// shaken, it gets dizzy and goes home), lands where it is dropped, then scans:
// a radar ping reveals a dot grid, viewfinder brackets hop between spots while
// its eyes follow them and a sweep line runs down, and the brackets close in on
// the whole screen. It hides for the frame the screenshot is taken in, flashes,
// leans in to peer at the user with a speech bubble, then arcs back up into the
// island, which opens the prompt with the screenshot attached. Esc, right-click
// or a drop on the island cancels at any point.
//
// The page only animates while a roam is in progress: no frame loop otherwise.

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { BotEngine } from "../mochi/engine";
import { Sound } from "../core/sound";
import { Bridge } from "../core/bridge";
import { Ease, clamp, lerp } from "../core/anim";
import { COMPACT_W, botPosition } from "../core/layout";
import type { BotStateName } from "../core/layout";
import type { RoamLook } from "../core/bridge";
import type { Settings } from "../core/state";

const BOT = 84; // Mochi's width on the overlay, CSS px
const OVERHANG = 40; // room above the body for particles
const SCAN_COLOR = "99,101,242"; // the `searching` state colour
const SCAN_RGB = [0.388, 0.396, 0.949] as const;

// Scan timeline, ms from the start of the scan.
const PING_MS = 650; // radar ring bursts out and reveals the grid
const INSPECT_FROM = 450; // brackets hop between spots, sweep line runs
const INSPECT_TO = 1950;
const HOP_MS = 500; // time on each spot
const LOCK_TO = 2400; // brackets close in on the whole screen
const SNAP_AT = 2520;

// Quick screenshot (setting): a short pause after the drop, one fast sweep.
const QUICK_DELAY_MS = 200;
const QUICK_SWEEP_MS = 280;

type Phase = "off" | "carried" | "dizzy" | "landing" | "scanning" | "snap" | "peer" | "flyback";

const canvas = document.getElementById("roam") as HTMLCanvasElement;
const ctx = canvas.getContext("2d")!;
const engine = new BotEngine();
engine.particleOverhang = OVERHANG;

let phase: Phase = "off";
let phaseAt = 0;
let lastFrame = 0;
let running = false;

const pos = { x: 0, y: 0 };
const vel = { x: 0, y: 0 };
const cursor = { x: 0, y: 0 };
let swing = 0; // dangle angle while carried
let zoom = 1; // grows while peering at the user
let alpha = 1;
let hidden = false; // true for the frames the screenshot is taken in
let flash = 0;
let scanT = -1; // ms into the scan, -1 when no scan is drawn
let dizziness = 0; // builds up while carried, faster when shaken
let endReason = "";
/** The island Mochi's state and colour, worn for the whole roam. */
let look: RoamLook = { state: "idle", bodyColor: null };
/** Settings > Quick screenshot: no cutscene, capture right after the drop. */
let quick = false;
let bubble: { text: string; at: number } | null = null;
let shot: string | null = null;
let cancelled = false;
let flyFrom = { x: 0, y: 0 };
let flyZoom = 1;
// Frame stats for the log, so a slow overlay shows up as a number.
let frames = 0;
let worstMs = 0;
let roamStartMs = 0;

function setPhase(next: Phase) {
  phase = next;
  phaseAt = performance.now();
}

function resize() {
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.round(innerWidth * dpr);
  canvas.height = Math.round(innerHeight * dpr);
}
addEventListener("resize", resize);
resize();

function start() {
  if (running) return;
  running = true;
  lastFrame = performance.now();
  requestAnimationFrame(frame);
}

// ── Sequence ─────────────────────────────────────────────────────────────────

/** Back to the island Mochi's own state and colour. */
function wearLook() {
  engine.setState(look.state as BotStateName, true);
  engine.bodyColor = look.bodyColor;
  engine.outfit = look.outfit ?? null;
}

void listen<{ x: number; y: number; look: RoamLook | null }>("roam-begin", (e) => {
  Sound.resume();
  const { x, y } = e.payload;
  look = e.payload.look ?? { state: "idle", bodyColor: null };
  Object.assign(cursor, { x, y });
  Object.assign(pos, { x, y });
  vel.x = vel.y = 0;
  swing = 0;
  zoom = 1;
  alpha = 1;
  hidden = false;
  flash = 0;
  scanT = -1;
  bubble = null;
  shot = null;
  cancelled = false;
  dizziness = 0;
  endReason = "";
  frames = 0;
  worstMs = 0;
  roamStartMs = performance.now();
  wearLook();
  engine.eyeOverride = "wide";
  engine.eyeOverrideUntil = Number.POSITIVE_INFINITY;
  engine.squash();
  Sound.play("peek");
  setPhase("carried");
  start();
});

void listen<{ x: number; y: number }>("roam-cursor", (e) => {
  Object.assign(cursor, e.payload);
});

/** Dropped back on the island: Mochi just goes home. */
function overIsland(p: { x: number; y: number }) {
  return p.y < 90 && Math.abs(p.x - innerWidth / 2) < 260;
}

void listen<{ x: number; y: number }>("roam-drop", (e) => {
  if (phase !== "carried") return; // dizzy or cancelled: already going home
  Object.assign(cursor, e.payload);
  if (overIsland(cursor)) {
    cancel();
    return;
  }
  // Land fully on screen, wherever the cursor let go.
  pos.x = clamp(cursor.x, BOT, innerWidth - BOT);
  pos.y = clamp(cursor.y + BOT * 0.35, BOT, innerHeight - BOT * 0.6);
  engine.eyeOverride = null;
  engine.eyeOverrideUntil = 0;
  engine.squash();
  engine.anim("oy", [
    [-0.45, 160, Ease.out],
    [0, 260, Ease.inOut],
  ]);
  Sound.play("pop");
  setPhase("landing");
});

async function snap() {
  setPhase("snap");
  hidden = true;
  scanT = -1;
  // Two frames so the cleared canvas is actually on screen before the capture.
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  try {
    shot = await invoke<string>("roam_capture");
  } catch (err) {
    console.error("[coucou] screenshot failed", err);
    shot = null;
  }
  hidden = false;
  if (cancelled) {
    // Esc arrived while the capture was in flight: throw the picture away.
    shot = null;
    flyBack();
    return;
  }
  if (shot && quick) {
    flash = 1;
    Sound.play("attach");
    wearLook();
    engine.emit("spark", 5);
    flyBack();
    return;
  }
  if (shot) {
    flash = 1;
    Sound.play("attach");
    wearLook();
    engine.eyeOverride = "star";
    engine.eyeOverrideUntil = performance.now() / 1000 + 0.9;
    engine.emit("spark", 7);
    bubble = { text: "Got it! What's wrong on screen?", at: performance.now() + 650 };
    setTimeout(() => engine.blink(), 700);
    setTimeout(() => Sound.play("question"), 650);
  } else {
    engine.setState("error", true);
    bubble = { text: "I couldn't see the screen", at: performance.now() + 200 };
  }
  setPhase("peer");
}

/** Esc, right-click, or a drop on the island: no screenshot, Mochi goes home. */
function cancel() {
  if (phase === "off" || phase === "flyback" || cancelled) return;
  cancelled = true;
  endReason ||= "cancelled";
  shot = null;
  scanT = -1;
  bubble = null;
  wearLook();
  engine.eyeOverride = null;
  engine.eyeOverrideUntil = 0;
  Sound.play("close");
  // Mid-capture: snap() finishes the shot, sees `cancelled` and flies back.
  if (phase !== "snap") flyBack();
}

void listen("roam-cancel", cancel);

/** Carried too long or shaken too hard: Mochi gets dizzy and wanders home. */
function goDizzy() {
  cancelled = true;
  endReason = "dizzy";
  shot = null;
  engine.eyeOverride = null;
  engine.eyeOverrideUntil = 0;
  engine.setState("dizzy", true);
  Sound.play("dizzy");
  setPhase("dizzy");
}

function startScan() {
  // A plain white Mochi takes on the `searching` purple while it scans; a
  // coloured one keeps its own colour. Either way the eyes follow the brackets.
  if (look.state === "idle" && !look.bodyColor) {
    engine.colT = SCAN_RGB;
    engine.tint = 0.72;
    engine.setBadge({ kind: "dots", color: SCAN_RGB });
  }
  foci = quick ? [] : pickFoci();
  sparks = [];
  lastHop = -1;
  lastScanDraw = 0;
  scanT = 0;
  Sound.play(quick ? "blip" : "search");
  setPhase("scanning");
}

function flyBack() {
  flyFrom = { ...pos };
  flyZoom = zoom;
  bubble = null;
  engine.tgEs = 1;
  Sound.play("send");
  setPhase("flyback");
}

/** Where Mochi sits in the compact island (centred at the top, Mochi on its left). */
function homeSpot() {
  const p = botPosition("compact", "overview", 0);
  return { x: innerWidth / 2 - COMPACT_W / 2 + p.cx, y: p.cy };
}

/** The overlay zoom at which Mochi is the compact island's size. */
function homeZoom() {
  // The island sizes its Mochi canvas as diameter / 0.6, like BOT here.
  return botPosition("compact", "overview", 0).diameter / 0.6 / BOT;
}

function finish() {
  phase = "off";
  running = false;
  engine.setState("idle", true);
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  dirty = null;
  const secs = (performance.now() - roamStartMs) / 1000;
  void Bridge.log(
    `roam: ${(frames / secs).toFixed(0)} fps avg, worst frame ${worstMs.toFixed(0)} ms` +
      (endReason ? `, ${endReason}` : shot ? ", screenshot taken" : ", no screenshot"),
  );
  void invoke("roam_end", { path: shot });
}

// ── Frame loop ───────────────────────────────────────────────────────────────

function frame(nowMs: number) {
  if (!running) return;
  const dt = Math.min(0.05, (nowMs - lastFrame) / 1000);
  worstMs = Math.max(worstMs, nowMs - lastFrame);
  frames += 1;
  lastFrame = nowMs;
  const t = nowMs - phaseAt;

  switch (phase) {
    case "carried": {
      // Held by the top: the body trails the cursor on a spring and swings.
      const tx = cursor.x;
      const ty = cursor.y + BOT * 0.35;
      vel.x += (tx - pos.x) * 260 * dt;
      vel.y += (ty - pos.y) * 260 * dt;
      vel.x *= Math.pow(0.0006, dt);
      vel.y *= Math.pow(0.0006, dt);
      pos.x += vel.x * dt;
      pos.y += vel.y * dt;
      swing = lerp(swing, clamp(-vel.x / 900, -0.55, 0.55), 1 - Math.pow(0.002, dt));
      engine.dragVel.x = vel.x;
      engine.dragVel.y = vel.y;
      engine.lookX = clamp(vel.x / 700, -1, 1);
      engine.lookY = clamp(-vel.y / 700, -1, 1);
      // ~12 s held still, a few seconds dragged around, under 2 s shaken.
      dizziness += dt * (0.08 + Math.hypot(vel.x, vel.y) / 3000);
      if (dizziness > 0.65 && engine.eyeOverride !== "spiral") {
        engine.eyeOverride = "spiral"; // a warning before it gives up
        engine.eyeOverrideUntil = Number.POSITIVE_INFINITY;
      }
      if (dizziness >= 1) goDizzy();
      break;
    }
    case "dizzy":
      engine.dragVel.x = engine.dragVel.y = 0;
      swing = Math.sin(t / 90) * 0.25 * Math.max(0, 1 - t / 1300);
      if (t > 1400) flyBack();
      break;
    case "landing":
      engine.dragVel.x = engine.dragVel.y = 0;
      swing = lerp(swing, 0, 1 - Math.pow(0.0001, dt));
      engine.lookX = engine.lookY = 0;
      if (quick ? t > QUICK_DELAY_MS : t > 550) startScan();
      break;
    case "scanning": {
      scanT = t;
      // Eyes on whatever the brackets are inspecting, then straight ahead.
      const f = currentFocus(t);
      if (f) {
        engine.lookX = Math.tanh((f.x + f.w / 2 - pos.x) / 320);
        engine.lookY = -Math.tanh((f.y + f.h / 2 - pos.y) / 260);
      } else {
        engine.lookX = 0;
        engine.lookY = 0.1;
      }
      if (t > (quick ? QUICK_SWEEP_MS : SNAP_AT)) void snap();
      break;
    }
    case "peer": {
      // Leans in towards the user, big-eyed, looking straight out of the screen.
      const p = clamp((t - 500) / 450, 0, 1);
      zoom = lerp(1, 1.35, Ease.back(p));
      engine.tgEs = lerp(1, 1.18, p);
      engine.lookX = 0;
      engine.lookY = 0.12;
      if (t > 2300) flyBack();
      break;
    }
    case "flyback": {
      // An arc up into the island, shrinking as it goes.
      const p = clamp(t / 760, 0, 1);
      const e = Ease.inOut(p);
      const end = homeSpot();
      const ctrl = { x: (flyFrom.x + end.x) / 2, y: Math.min(flyFrom.y, end.y) - 120 };
      pos.x = (1 - e) * (1 - e) * flyFrom.x + 2 * (1 - e) * e * ctrl.x + e * e * end.x;
      pos.y = (1 - e) * (1 - e) * flyFrom.y + 2 * (1 - e) * e * ctrl.y + e * e * end.y;
      zoom = lerp(flyZoom, homeZoom(), e);
      alpha = p > 0.85 ? 1 - (p - 0.85) / 0.15 : 1;
      swing = Math.sin(p * Math.PI) * 0.35;
      if (p >= 1) {
        finish();
        return;
      }
      break;
    }
  }

  engine.update(dt);
  flash = Math.max(0, flash - dt * 2.6);
  draw();
  requestAnimationFrame(frame);
}

// ── Drawing ──────────────────────────────────────────────────────────────────

type Rect = { x: number; y: number; w: number; h: number };
/** What was painted last frame. Only that is cleared, not the whole monitor. */
let dirty: Rect | null = null;

function union(a: Rect | null, b: Rect): Rect {
  if (!a) return b;
  const x = Math.min(a.x, b.x);
  const y = Math.min(a.y, b.y);
  return { x, y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y };
}

function draw() {
  const dpr = window.devicePixelRatio || 1;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  if (dirty) ctx.clearRect(dirty.x - 2, dirty.y - 2, dirty.w + 4, dirty.h + 4);
  dirty = null;
  if (hidden) return;

  const full = { x: 0, y: 0, w: innerWidth, h: innerHeight };
  if (scanT >= 0) {
    drawScan(scanT);
    dirty = full;
  }
  if (flash > 0) {
    ctx.fillStyle = `rgba(255,255,255,${flash * 0.55})`;
    ctx.fillRect(0, 0, innerWidth, innerHeight);
    dirty = full;
  }

  // Mochi, its swing, particles above it, and the bubble or hint beside it.
  const reach = BOT * zoom * 1.3 + OVERHANG;
  dirty = union(dirty, { x: pos.x - reach - 340, y: pos.y - reach - 60, w: reach * 2 + 680, h: reach * 2 + 120 });

  const W = BOT;
  const H = BOT + OVERHANG;
  ctx.save();
  ctx.globalAlpha = alpha;
  ctx.translate(pos.x, pos.y);
  // Swings around the point it is held by, just above its head.
  ctx.translate(0, -BOT * 0.35);
  ctx.rotate(swing);
  ctx.translate(0, BOT * 0.35);
  ctx.scale(zoom, zoom);
  ctx.translate(-W / 2, -H / 2 - OVERHANG / 2);
  engine.draw(ctx, W, H);
  ctx.restore();

  if (bubble && phase === "peer" && performance.now() > bubble.at) drawBubble(bubble.text);
  if (phase === "carried") drawHint();
}

function drawHint() {
  const text = "Drop to scan  ·  Esc or drop on the island to cancel";
  ctx.save();
  ctx.font = `500 12px system-ui, "Segoe UI Variable Text", "Segoe UI", sans-serif`;
  const w = ctx.measureText(text).width + 20;
  const x = pos.x - w / 2;
  const y = pos.y + BOT * 0.62;
  ctx.fillStyle = "rgba(14,15,18,0.82)";
  ctx.beginPath();
  ctx.roundRect(x, y, w, 24, 12);
  ctx.fill();
  ctx.fillStyle = "rgba(245,246,248,0.9)";
  ctx.textBaseline = "middle";
  ctx.fillText(text, x + 10, y + 12.5);
  ctx.restore();
}

// ── Scan effect ──────────────────────────────────────────────────────────────

type Focus = { x: number; y: number; w: number; h: number };
let foci: Focus[] = [];
let lastHop = -1;
let sparks: { x: number; y: number; vy: number; age: number; life: number }[] = [];
let gridTile: CanvasPattern | null = null;
let lastScanDraw = 0;

/** Three spots to inspect, one per third of the screen, in shuffled order. */
function pickFoci(): Focus[] {
  const thirds = [0, 1, 2].sort(() => Math.random() - 0.5);
  return thirds.map((third) => {
    const w = 200 + Math.random() * 220;
    const h = 100 + Math.random() * 150;
    const x = (third + 0.1 + Math.random() * 0.8) * (innerWidth / 3) - w / 2;
    const y = 80 + Math.random() * Math.max(1, innerHeight - 160 - h);
    return { x: clamp(x, 24, innerWidth - w - 24), y, w, h };
  });
}

function currentFocus(t: number): Focus | null {
  if (t < INSPECT_FROM || t >= INSPECT_TO || foci.length === 0) return null;
  const hop = Math.floor((t - INSPECT_FROM) / HOP_MS);
  if (hop !== lastHop) {
    lastHop = hop;
    Sound.play("tick");
  }
  // Glides from the previous spot to this one, then holds.
  const to = foci[hop % foci.length];
  const from = hop === 0 ? { x: pos.x, y: pos.y, w: 0, h: 0 } : foci[(hop - 1) % foci.length];
  const p = Ease.back(clamp(((t - INSPECT_FROM) % HOP_MS) / 200, 0, 1));
  return {
    x: lerp(from.x, to.x, p),
    y: lerp(from.y, to.y, p),
    w: lerp(from.w, to.w, p),
    h: lerp(from.h, to.h, p),
  };
}

function grid(): CanvasPattern | null {
  if (!gridTile) {
    const tile = document.createElement("canvas");
    tile.width = tile.height = 26;
    const g = tile.getContext("2d")!;
    g.fillStyle = `rgba(${SCAN_COLOR},1)`;
    g.beginPath();
    g.arc(13, 13, 1.2, 0, Math.PI * 2);
    g.fill();
    gridTile = ctx.createPattern(tile, "repeat");
  }
  return gridTile;
}

function drawScan(t: number) {
  if (quick) {
    drawSweep(Ease.inOut(clamp(t / QUICK_SWEEP_MS, 0, 1)) * innerHeight);
    return;
  }
  const W = innerWidth;
  const H = innerHeight;
  const dt = Math.min(0.05, Math.max(0, t - lastScanDraw) / 1000);
  lastScanDraw = t;

  // 1. Radar ping: a ring bursts out of Mochi; the dot grid shows inside it,
  //    then fades as the inspection ends.
  const maxR = Math.hypot(Math.max(pos.x, W - pos.x), Math.max(pos.y, H - pos.y));
  const ping = clamp(t / PING_MS, 0, 1);
  const r = Ease.out(ping) * maxR;
  const gridAlpha = 0.28 * clamp(t / 200, 0, 1) * (1 - clamp((t - INSPECT_TO + 300) / 400, 0, 1));
  const pattern = grid();
  if (gridAlpha > 0 && pattern) {
    ctx.save();
    ctx.beginPath();
    ctx.arc(pos.x, pos.y, Math.max(1, r), 0, Math.PI * 2);
    ctx.clip();
    ctx.globalAlpha = gridAlpha;
    ctx.fillStyle = pattern;
    ctx.fillRect(0, 0, W, H);
    ctx.restore();
  }
  if (ping < 1) {
    for (const [k, a, width] of [[1, 0.9, 3], [0.86, 0.35, 10]] as const) {
      ctx.beginPath();
      ctx.arc(pos.x, pos.y, Math.max(1, r * k), 0, Math.PI * 2);
      ctx.strokeStyle = `rgba(${SCAN_COLOR},${a * (1 - ping)})`;
      ctx.lineWidth = width;
      ctx.stroke();
    }
  }

  // 2. Sweep line with a trail, and sparks flying off it.
  if (t >= INSPECT_FROM && t < INSPECT_TO) {
    const y = Ease.inOut((t - INSPECT_FROM) / (INSPECT_TO - INSPECT_FROM)) * H;
    drawSweep(y);
    for (let i = 0; i < 3; i++) {
      sparks.push({ x: Math.random() * W, y, vy: -40 - Math.random() * 90, age: 0, life: 0.35 + Math.random() * 0.4 });
    }
  }
  sparks = sparks.filter((s) => (s.age += dt) < s.life);
  for (const s of sparks) {
    ctx.fillStyle = `rgba(200,202,255,${1 - s.age / s.life})`;
    ctx.fillRect(s.x - 1.5, s.y + s.vy * s.age - 1.5, 3, 3);
  }

  // 3. Brackets inspect a few spots, then close in on the whole screen.
  const f = currentFocus(t);
  if (f) {
    ctx.fillStyle = `rgba(${SCAN_COLOR},0.08)`;
    ctx.fillRect(f.x, f.y, f.w, f.h);
    brackets(f, 18, 1);
  } else if (t >= INSPECT_TO) {
    const p = clamp((t - INSPECT_TO) / (LOCK_TO - INSPECT_TO), 0, 1);
    const inset = lerp(-60, 24, Ease.back(p));
    brackets({ x: inset, y: inset, w: W - inset * 2, h: H - inset * 2 }, 56, p);
    if (t >= LOCK_TO && lastHop !== -2) {
      lastHop = -2;
      Sound.play("peek");
    }
  }
}

/** The sweep line at height `y`: a fading trail above a glowing line. */
function drawSweep(y: number) {
  const W = innerWidth;
  const trail = ctx.createLinearGradient(0, y - 120, 0, y);
  trail.addColorStop(0, `rgba(${SCAN_COLOR},0)`);
  trail.addColorStop(1, `rgba(${SCAN_COLOR},0.14)`);
  ctx.fillStyle = trail;
  ctx.fillRect(0, y - 120, W, 120);
  const glow = ctx.createLinearGradient(0, y - 12, 0, y + 12);
  glow.addColorStop(0, `rgba(${SCAN_COLOR},0)`);
  glow.addColorStop(0.5, `rgba(${SCAN_COLOR},0.4)`);
  glow.addColorStop(1, `rgba(${SCAN_COLOR},0)`);
  ctx.fillStyle = glow;
  ctx.fillRect(0, y - 12, W, 24);
  ctx.fillStyle = "rgba(190,192,255,0.95)";
  ctx.fillRect(0, y - 1, W, 2);
}

/** Viewfinder corners around a rect: a soft glow under a crisp white line. */
function brackets(f: Focus, len: number, alpha: number) {
  const l = Math.min(len, f.w / 2, f.h / 2);
  ctx.save();
  ctx.globalAlpha = alpha;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  for (const [width, color] of [[6, `rgba(${SCAN_COLOR},0.45)`], [2.5, "rgba(245,246,255,0.95)"]] as const) {
    ctx.lineWidth = width;
    ctx.strokeStyle = color;
    ctx.beginPath();
    for (const [cx, cy, dx, dy] of [
      [f.x, f.y, 1, 1],
      [f.x + f.w, f.y, -1, 1],
      [f.x, f.y + f.h, 1, -1],
      [f.x + f.w, f.y + f.h, -1, -1],
    ] as const) {
      ctx.moveTo(cx + dx * l, cy);
      ctx.lineTo(cx, cy);
      ctx.lineTo(cx, cy + dy * l);
    }
    ctx.stroke();
  }
  ctx.restore();
}

function drawBubble(text: string) {
  const age = clamp((performance.now() - (bubble?.at ?? 0)) / 260, 0, 1);
  const s = Ease.back(age);
  ctx.save();
  ctx.font = `600 15px system-ui, "Segoe UI Variable Text", "Segoe UI", sans-serif`;
  const padX = 14;
  const w = ctx.measureText(text).width + padX * 2;
  const h = 38;
  // Beside Mochi, on whichever side has room.
  const right = pos.x + BOT * zoom * 0.6 + w < innerWidth - 12;
  const bx = right ? pos.x + BOT * zoom * 0.62 : pos.x - BOT * zoom * 0.62 - w;
  const by = pos.y - BOT * zoom * 0.55 - h / 2;
  const ox = right ? bx : bx + w;
  ctx.translate(ox, by + h);
  ctx.scale(s, s);
  ctx.translate(-ox, -(by + h));
  ctx.globalAlpha = age;

  ctx.shadowColor = "rgba(0,0,0,0.35)";
  ctx.shadowBlur = 16;
  ctx.shadowOffsetY = 4;
  ctx.fillStyle = "rgba(14,15,18,0.94)";
  ctx.beginPath();
  ctx.roundRect(bx, by, w, h, 14);
  // Tail pointing back at Mochi.
  const tx = right ? bx + 10 : bx + w - 10;
  ctx.moveTo(tx, by + h - 6);
  ctx.lineTo(right ? tx - 12 : tx + 12, by + h + 9);
  ctx.lineTo(right ? tx + 8 : tx - 8, by + h - 2);
  ctx.fill();
  ctx.shadowColor = "transparent";
  ctx.fillStyle = "#f5f6f8";
  ctx.textBaseline = "middle";
  ctx.fillText(text, bx + padX, by + h / 2 + 1);
  ctx.restore();
}

// Same sound settings as the island.
function applySettings(s: Settings) {
  Sound.setEnabled(s.soundEnabled);
  Sound.setVolume(s.soundVolume);
  quick = s.quickScan === true;
}
void Bridge.boot().then((info) => info && applySettings(info.settings));
void listen<Settings>("settings-changed", (e) => applySettings(e.payload));
