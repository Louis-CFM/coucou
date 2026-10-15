// Mini Mochis (pills + compact grid) — port of MiniBotCanvasView.
// Each canvas owns a BotEngine; the island's frame loop ticks every live one.

import { BotEngine, hexToRGB } from "./engine";
import type { AgentTask } from "../core/state";
import type { Outfit } from "./wardrobe";
import { dancesIn } from "../core/spotify";

interface MiniBot {
  canvas: HTMLCanvasElement;
  engine: BotEngine;
  layout: ReturnType<typeof miniLayout>;
  taskId: string;
  /** Asked every frame: whether this one dances (the music pill's, MiniBotCanvasView). */
  dancing?: () => boolean;
}

const live = new Map<HTMLCanvasElement, MiniBot>();
/** Every mini sleeps while the island's Mochis do (island.ts, after a quiet spell). */
let asleep = false;

/** Takes effect on the next syncMiniBotStates (the island redraws for it). */
export function setMiniBotsAsleep(on: boolean) {
  asleep = on;
}

/** music is playing, so every resting mini dances (island.ts, each frame). */
let music = false;
export function setMiniBotsMusic(on: boolean) {
  music = on;
}

/** extra canvas above and beside the body, in R, for the mini's own
 *  outfit (the party hat on the bean reaches 2.7 R above the body centre, the witch
 *  hat's brim and the Santa hat's tip about 1.7 R to the side). */
const OUTFIT_TOP = 1.2;
const OUTFIT_SIDE = 0.3;

/**
 * The canvas of a mini whose body is `bodySize` CSS pixels across. The engine
 * draws the body at 60 % of its square (`size`); the canvas adds `top` above
 * it and `side` on each side, and `shiftY` keeps the body where the square
 * canvas, centred on its slot, had it. `room`: canvas top to body centre, in R.
 */
export function miniLayout(bodySize: number) {
  const size = bodySize / 0.6;
  const R = size * 0.3;
  const top = Math.ceil(R * OUTFIT_TOP);
  const side = Math.ceil(R * OUTFIT_SIDE);
  return {
    size, R, top, side,
    width: size + side * 2,
    height: size + top,
    shiftY: -top / 2,
    room: (size / 2 + top + R * 0.06) / R,
  };
}

/**
 * Creates a mini Mochi whose **body** is `bodySize` CSS pixels across.
 *
 * The engine draws the body at 60 % of its canvas, so the canvas is
 * `bodySize / 0.6` and is centred in a `bodySize` slot, overflowing it — the
 * same thing SwiftUI does with a `.frame(width: 22/0.6)` inside a
 * `.frame(width: 22)`. Sizing the canvas itself to `bodySize` would shrink the
 * whole drawing to 60 %, which is what used to happen. taller and wider
 * for its outfit (miniLayout). `roomAbove`: CSS px from the slot's centre up to
 * whatever cuts it off (the compact grid's top row sits under the screen's
 * edge); a hat taller than that shrinks to fit.
 */
export function createMiniBot(task: AgentTask, bodySize: number, dancing?: () => boolean, roomAbove = Infinity): HTMLElement {
  const slot = document.createElement("span");
  slot.className = "mini";
  slot.style.width = `${bodySize}px`;
  slot.style.height = `${bodySize}px`;

  const layout = miniLayout(bodySize);
  const canvas = document.createElement("canvas");
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  canvas.width = Math.round(layout.width * dpr);
  canvas.height = Math.round(layout.height * dpr);
  canvas.style.width = `${layout.width}px`;
  canvas.style.height = `${layout.height}px`;
  canvas.style.marginTop = `${layout.shiftY}px`;
  slot.append(canvas);

  const engine = new BotEngine();
  engine.isMini = true;
  engine.particleOverhang = layout.top;
  // The body centre sits 0.06 R below the slot's; half a pixel spare for antialiasing.
  engine.outfitRoom = Math.min(layout.room, (roomAbove - 0.5) / layout.R + 0.06);
  engine.bodyColor = hexToRGB(task.color);
  engine.setState(asleep ? "sleeping" : task.state, true);
  if (task.emote) engine.setPermanentEmote(task.emote);
  if (task.miniEye) {
    engine.permanentEye = task.miniEye;
    engine.eyeOverride = task.miniEye;
    engine.eyeOverrideUntil = Number.POSITIVE_INFINITY;
  }

  live.set(canvas, { canvas, engine, layout, taskId: task.id, dancing });
  return slot;
}

export function releaseMiniBot(canvas: HTMLCanvasElement) {
  live.delete(canvas);
}

/** Drops every canvas no longer in the document (views are rebuilt wholesale). */
export function pruneMiniBots() {
  for (const [canvas] of live) {
    if (!canvas.isConnected) live.delete(canvas);
  }
}

/** Each mini's state and colour, and (extras) the look its Mochi wears. */
export function syncMiniBotStates(tasks: AgentTask[], lookOf: (task: AgentTask) => { outfit: Outfit; shape: string }) {
  for (const mb of live.values()) {
    const task = tasks.find((t) => t.id === mb.taskId);
    if (!task) continue;
    mb.engine.setState(asleep ? "sleeping" : task.state);
    mb.engine.bodyColor = hexToRGB(task.color);
    const look = lookOf(task);
    mb.engine.setOutfit(look.outfit, false);
    mb.engine.shape = look.shape;
  }
}

export function tickMiniBots(dt: number) {
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  for (const mb of live.values()) {
    const ctx = mb.canvas.getContext("2d");
    if (!ctx) continue;
    const { size, side, width, height } = mb.layout;
    mb.engine.setDancing(mb.dancing?.() ?? (music && !asleep && dancesIn(mb.engine.state)));
    mb.engine.update(dt);
    ctx.setTransform(dpr, 0, 0, dpr, side * dpr, 0);
    ctx.clearRect(-side, 0, width, height);
    ctx.save();
    mb.engine.applyDance(ctx, size, height);
    mb.engine.draw(ctx, size, height);
    ctx.restore();
  }
}

export const miniBotCount = () => live.size;

/** Runs `fn` on every live mini's engine (Settings' emote tester). */
export function forEachMiniBot(fn: (engine: BotEngine) => void) {
  for (const mb of live.values()) fn(mb.engine);
}
