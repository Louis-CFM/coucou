// Overview task ticker — port of TickerView (V2) from IslandViewContent.swift.
//
// Three rows: completed (A, kept hidden — one visible line only), current →
// completed (B), incoming (C). Every row
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
  /** The task's step count last time it was seen; -1 before the first. */
  private shown = -1;

  constructor() {
    this.el = h("div", { class: "ticker" }, this.a.el, this.b.el, this.c.el);
    this.rest();
  }

  /** The state between transitions: only the current step, centred. A completed
   *  line stacked above it read as two overlapping commands (they often share a
   *  long `cd "/c/Users/…` prefix and truncate identically), so it is not shown. */
  private rest() {
    place(this.a, -ROW_H / 2, 1, 0);
    place(this.b, ROW_H / 2, 0, 1);
    place(this.c, ROW_H * 1.5, 0, 0);
  }

  get animating(): boolean {
    return this.startMs != null || this.queue.length > 0;
  }

  sync(task: AgentTask | null) {
    const steps = task?.steps ?? [];
    // Counted, not indexed: the list keeps its last 20 steps, so once full its
    // length and index stay put while new steps keep coming, and the ticker
    // used to freeze on the 20th step of a session.
    const total = task?.stepCount ?? steps.length;

    // First render, or the session restarted (steps were cleared): drop
    // straight into place, no animation.
    if (this.shown < 0 || total < this.shown) {
      this.queue = [];
      this.startMs = null;
      this.shown = total;
      const idx = steps.length - 1;
      setText(this.a, idx > 0 ? steps[idx - 1] : "…");
      setText(this.b, idx >= 0 ? steps[idx] : "…");
      this.rest();
      return;
    }

    for (const step of steps.slice(Math.max(0, steps.length - (total - this.shown)))) {
      // A repeat of the step already on screen (or already queued) would scroll
      // an identical line into place: nothing to show.
      const last = this.queue.length > 0 ? this.queue[this.queue.length - 1] : this.b.text;
      if (step !== last) this.queue.push(step);
    }
    this.shown = total;
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

    // The current step turns into a tick and slides up out of view, fading out
    // before it gets there; the next step slides up into its place.
    place(this.b, lerp(ROW_H / 2, -ROW_H / 2, e), e, clamp(1 - p * 1.6, 0, 1));
    place(this.c, lerp(ROW_H * 1.5, ROW_H / 2, e), 0, e);

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
