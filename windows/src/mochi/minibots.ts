// Mini Mochis (pills + compact grid) — port of MiniBotCanvasView.
// Each canvas owns a BotEngine; the island's frame loop ticks every live one.

import { BOT_STATES, BotEngine, hexToRGB } from "./engine";
import type { BotStateName } from "../core/layout";
import type { AgentTask } from "../core/state";

interface MiniBot {
  canvas: HTMLCanvasElement;
  engine: BotEngine;
  cssSize: number;
  taskId: string;
}

const live = new Map<HTMLCanvasElement, MiniBot>();

/**
 * Creates a mini Mochi whose **body** is `bodySize` CSS pixels across.
 *
 * The engine draws the body at 60 % of its canvas, so the canvas is
 * `bodySize / 0.6` and is centred in a `bodySize` slot, overflowing it — the
 * same thing SwiftUI does with a `.frame(width: 22/0.6)` inside a
 * `.frame(width: 22)`. Sizing the canvas itself to `bodySize` would shrink the
 * whole drawing to 60 %, which is what used to happen.
 */
export function createMiniBot(task: AgentTask, bodySize: number): HTMLElement {
  const { slot, engine } = mount(bodySize, task.id);
  engine.bodyColor = hexToRGB(task.color);
  engine.setState(task.state, true);
  if (task.emote) engine.setPermanentEmote(task.emote);
  if (task.miniEye) {
    engine.permanentEye = task.miniEye;
    engine.eyeOverride = task.miniEye;
    engine.eyeOverrideUntil = Number.POSITIVE_INFINITY;
  }
  return slot;
}

/** The slot, its canvas and its engine, ticked from now on by the island's loop. */
function mount(bodySize: number, taskId: string): { slot: HTMLElement; engine: BotEngine } {
  const slot = document.createElement("span");
  slot.className = "mini";
  slot.style.width = `${bodySize}px`;
  slot.style.height = `${bodySize}px`;

  const canvas = document.createElement("canvas");
  const engineSize = bodySize / 0.6;
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  canvas.width = Math.round(engineSize * dpr);
  canvas.height = Math.round(engineSize * dpr);
  canvas.style.width = `${engineSize}px`;
  canvas.style.height = `${engineSize}px`;
  slot.append(canvas);

  const engine = new BotEngine();
  engine.isMini = true;
  live.set(canvas, { canvas, engine, cssSize: engineSize, taskId });
  return { slot, engine };
}

/**
 * A mini Mochi that stands for something other than a task — a job of a CI
 * run. Nothing in State drives it: it comes with its engine, and whoever made
 * it changes its state.
 *
 * It appears already in `state`, without that state's entrance (the finished
 * roll, the error shake): arriving on a run that passed an hour ago is not the
 * moment it passed. `engine.setState` plays the entrance later, when the state
 * really changes, as for any other Mochi.
 *
 * `eyes` scales his eyes. A mini's are drawn large so they still read at the
 * grid's 13 px; drawn bigger than that, the same eyes fill the face and their
 * shapes — happy, flat, closed — run into each other.
 */
export function createFreeBot(
  color: string, state: BotStateName, bodySize: number, eyes = 1,
): { el: HTMLElement; engine: BotEngine } {
  const { slot, engine } = mount(bodySize, "");
  const cfg = BOT_STATES[state];
  engine.bodyColor = hexToRGB(color);
  engine.state = state;
  engine.cfg = cfg;
  engine.col = cfg.color;
  engine.colT = cfg.color;
  engine.tint = cfg.tint;
  engine.es = eyes;
  engine.tgEs = eyes;
  engine.setBadge(cfg.badge);
  return { el: slot, engine };
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

export function syncMiniBotStates(tasks: AgentTask[]) {
  for (const mb of live.values()) {
    const task = tasks.find((t) => t.id === mb.taskId);
    if (!task) continue;
    mb.engine.setState(task.state);
    mb.engine.bodyColor = hexToRGB(task.color);
  }
}

export function tickMiniBots(dt: number) {
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  for (const mb of live.values()) {
    const ctx = mb.canvas.getContext("2d");
    if (!ctx) continue;
    mb.engine.update(dt);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, mb.cssSize, mb.cssSize);
    mb.engine.draw(ctx, mb.cssSize, mb.cssSize);
  }
}

export const miniBotCount = () => live.size;
