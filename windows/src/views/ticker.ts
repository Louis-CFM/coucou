// Overview task ticker — port of TickerView (V2) from IslandViewContent.swift.
//
// Three rows: completed (A), current → completed (B), incoming (C). Every row
// position is recomputed from a single clock in `tick()`, driven by the island's
// frame loop — no CSS transitions and no timers. Chaining CSS transitions with a
// reset timer let two rows land on the same line when steps arrived in bursts,
// and any step that arrived mid-animation was dropped outright. Steps are now
// queued instead, so a burst scrolls past rather than vanishing.

import { h, svg } from "./dom";
import { ICONS } from "./icons";
import { cubicBezier, clamp, lerp } from "../core/anim";
import type { AgentTask } from "../core/state";

const ROW_H = 22;
/** One step transition, milliseconds. */
const DURATION = 380;
/** Beyond this many queued steps we stop trying to show them all. */
const MAX_QUEUE = 4;
const COMPLETED_SCALE = 11.5 / 13; // 0.885 — the completed font size
const EASE = cubicBezier(0.4, 0, 0.2, 1);

/** Find items appended to a bounded rolling step list since the last render. */
export function unseenTickerSteps(previous: string[], current: string[]): string[] {
  const maxOverlap = Math.min(previous.length, current.length);
  for (let overlap = maxOverlap; overlap > 0; overlap--) {
    let matches = true;
    for (let i = 0; i < overlap; i++) {
      if (previous[previous.length - overlap + i] !== current[i]) {
        matches = false;
        break;
      }
    }
    if (matches) return current.slice(overlap);
  }
  return current;
}

interface Row {
  el: HTMLElement;
  chevron: SVGElement;
  check: SVGElement;
  shimmer: HTMLElement;
  dim: HTMLElement;
  text: string;
}

function makeRow(): Row {
  const chevron = svg(ICONS.chevronRight, 9, { stroke: 2.4 });
  const check = svg(ICONS.check, 8, { stroke: 2.2 });
  check.style.color = "#454850"; // the completed tick is dimmer than the chevron
  check.style.position = "absolute";
  chevron.style.position = "absolute";
  const shimmer = h("span", { class: "tick-text shimmer" });
  const dim = h("span", {
    class: "tick-text",
    style: "position:absolute;left:0;right:0;color:#6b7079",
  });
  const el = h(
    "div",
    { class: "ticker-row" },
    h("span", { class: "tick-icon", style: "position:relative" }, chevron, check),
    h("span", { style: "position:relative;flex:1 1 auto;min-width:0" }, shimmer, dim),
  );
  return { el, chevron, check, shimmer, dim, text: "" };
}

function setText(row: Row, text: string) {
  if (row.text === text) return;
  row.text = text;
  row.shimmer.textContent = text;
  row.dim.textContent = text;
}

/**
 * Places a row. `phase` 0 = current (shimmering, full size), 1 = completed
 * (dim, shifted up-left and scaled down) — same crossfades as the Swift view.
 */
function place(row: Row, y: number, phase: number, opacity: number) {
  const scale = 1 - phase * (1 - COMPLETED_SCALE);
  row.el.style.transform = `translate(${-phase * 10}px, ${y}px) scale(${scale})`;
  row.el.style.opacity = String(opacity);
  row.chevron.style.opacity = String(clamp(1 - phase * 2, 0, 1));
  row.check.style.opacity = String(clamp(phase * 2 - 1, 0, 1));
  row.shimmer.style.opacity = String(clamp(1 - phase * 1.6, 0, 1));
  row.dim.style.opacity = String(clamp(phase * 2 - 0.4, 0, 1));
}

export class Ticker {
  readonly el: HTMLElement;
  private a = makeRow(); // completed
  private b = makeRow(); // current
  private c = makeRow(); // incoming
  private queue: string[] = [];
  private startMs: number | null = null;
  private displayIndex = -1;
  private taskId: string | null = null;
  private sourceRevision = -1;
  private sourceSteps: string[] = [];

  constructor() {
    this.el = h("div", { class: "ticker" }, this.a.el, this.b.el, this.c.el);
    this.rest();
  }

  /** The state between transitions: completed on top, current below. */
  private rest() {
    place(this.a, 0, 1, 1);
    place(this.b, ROW_H, 0, 1);
    place(this.c, ROW_H * 2, 0, 0);
  }

  get animating(): boolean {
    return this.startMs != null || this.queue.length > 0;
  }

  sync(task: AgentTask | null) {
    const steps = task && task.steps.length > 0 ? task.steps : ["…"];
    const idx = task ? Math.min(task.stepIndex, steps.length - 1) : -1;
    const taskId = task?.id ?? null;
    const revision = task?.stepRevision ?? idx;

    // First render and task switches seed from that task's own history.
    if (this.displayIndex < 0 || taskId !== this.taskId) {
      this.taskId = taskId;
      this.displayIndex = idx;
      this.sourceRevision = revision;
      this.sourceSteps = steps.slice();
      this.queue = [];
      this.startMs = null;
      setText(this.a, idx > 0 ? steps[idx - 1] : "…");
      setText(this.b, steps[Math.max(idx, 0)]);
      this.rest();
      return;
    }

    // The session restarted (steps were cleared): re-seed rather than scroll.
    if (idx < this.displayIndex || revision < this.sourceRevision ||
        (task !== null && task.steps.length === 0 && this.sourceSteps[0] !== "…")) {
      this.queue = [];
      this.startMs = null;
      this.displayIndex = idx;
      this.sourceRevision = revision;
      this.sourceSteps = steps.slice();
      setText(this.a, idx > 0 ? steps[idx - 1] : "…");
      setText(this.b, steps[Math.max(idx, 0)]);
      this.rest();
      return;
    }

    if (idx > this.displayIndex) {
      for (let i = this.displayIndex + 1; i <= idx; i++) this.queue.push(steps[i]);
    } else if (revision > this.sourceRevision) {
      // At the 20-step cap, stepIndex remains 19 while older entries roll off.
      // Compare the snapshots to keep the newest action moving through the ticker.
      const unseen = unseenTickerSteps(this.sourceSteps, steps);
      this.queue.push(...(unseen.length ? unseen : [steps[idx]]));
    }
    this.displayIndex = idx;
    this.sourceRevision = revision;
    this.sourceSteps = steps.slice();
    if (this.queue.length > MAX_QUEUE) {
      this.queue = this.queue.slice(-MAX_QUEUE);
    }
  }

  /** Called every frame by the island while the overview is on screen. */
  tick(nowMs: number) {
    if (this.startMs == null) {
      if (this.queue.length === 0) return;
      setText(this.c, this.queue[0]);
      place(this.c, ROW_H * 2, 0, 0);
      this.startMs = nowMs;
    }

    const p = clamp((nowMs - this.startMs) / DURATION, 0, 1);
    const e = EASE(p);

    // A leaves upwards and fades a little faster than it moves, as on macOS.
    place(this.a, lerp(0, -ROW_H, e), 1, clamp(1 - p * 1.35, 0, 1));
    place(this.b, lerp(ROW_H, 0, e), e, 1);
    place(this.c, lerp(ROW_H * 2, ROW_H, e), 0, e);

    if (p < 1) return;

    // Commit: the current row becomes the completed one, the incoming row the
    // current one. Texts move, elements stay put — no reordering, no overlap.
    setText(this.a, this.b.text);
    setText(this.b, this.c.text);
    this.queue.shift();
    this.startMs = null;
    this.rest();
  }
}
