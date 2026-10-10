// Overview task ticker — port of TickerView (V2) from IslandViewContent.swift.
//
// Three rows: completed (A), current → completed (B), incoming (C). Every row
// position is recomputed from a single clock in `tick()`, driven by the island's
// frame loop — no CSS transitions and no timers. Chaining CSS transitions with a
// reset timer let two rows land on the same line when steps arrived in bursts,
// and any step that arrived mid-animation was dropped outright. Steps are now
// queued instead, so a burst scrolls past rather than vanishing.

//
// Diff steps (see core/diff.ts) render as the file name followed by +N −M, and
// a click on one opens its diff. After Stop the card holds Claude's final
// message: no shimmer, no chevron, the ✓ on every row (TickerRowView isActive
// = false on macOS).

import { h, svg } from "./dom";
import { ICONS } from "./icons";
import { cubicBezier, clamp, lerp } from "../core/anim";
import { parseDiffStep, type DiffStep } from "../core/diff";
import type { AgentTask } from "../core/state";

const ROW_H = 22;
/** One step transition, milliseconds. */
const DURATION = 380;
/** Beyond this many queued steps we stop trying to show them all. */
const MAX_QUEUE = 4;
const COMPLETED_SCALE = 11.5 / 13; // 0.885 — the completed font size
const EASE = cubicBezier(0.4, 0, 0.2, 1);

/** The current row's text once the turn is over (TickerRowView staticColor). */
const STILL_CURRENT = "#c9cdd4";
const DIM = "#6b7079";

interface Row {
  el: HTMLElement;
  chevron: SVGElement;
  check: SVGElement;
  body: HTMLElement;
  shimmer: HTMLElement;
  dim: HTMLElement;
  /** +N −M, attached to the row only while it shows a diff. */
  counts: HTMLElement;
  plus: HTMLElement;
  minus: HTMLElement;
  text: string;
  /** Set when the row shows a file diff. */
  diff: DiffStep | null;
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
    // top:0 is where a one-line row already put it; it also keeps a text wider
    // than the row on that line instead of dropping it below the row.
    style: `position:absolute;top:0;left:0;right:0;color:${DIM}`,
  });
  const body = h("span", { style: "position:relative;flex:1 1 auto;min-width:0" }, shimmer, dim);
  const plus = h("span", { class: "plus" });
  const minus = h("span", { class: "minus" });
  const counts = h("span", { class: "tick-count" }, plus, minus);
  const el = h(
    "div",
    { class: "ticker-row" },
    h("span", { class: "tick-icon", style: "position:relative" }, chevron, check),
    body,
  );
  return { el, chevron, check, body, shimmer, dim, counts, plus, minus, text: "", diff: null };
}

function setText(row: Row, text: string) {
  if (row.text === text) return;
  row.text = text;
  const diff = parseDiffStep(text);
  row.diff = diff;
  const shown = diff ? diff.filename : text;
  row.shimmer.textContent = shown;
  row.dim.textContent = shown;
  if (diff) {
    // Filename, then the counts right after it; the name truncates first.
    row.body.style.flex = "0 1 auto";
    row.plus.textContent = diff.added > 0 ? ` +${diff.added}` : "";
    row.minus.textContent = diff.removed > 0 ? ` −${diff.removed}` : "";
    if (row.counts.parentNode !== row.el) row.el.append(row.counts);
    row.el.classList.add("diff");
  } else if (row.el.classList.contains("diff")) {
    // Back to an ordinary step: exactly the row it always was.
    row.body.style.flex = "1 1 auto";
    row.counts.remove();
    row.el.classList.remove("diff");
  }
}

/**
 * Places a row. `phase` 0 = current (shimmering, full size), 1 = completed
 * (dim, shifted up-left and scaled down) — same crossfades as the Swift view.
 * `still` is the finished look: static text, ✓ only, nothing animating.
 */
function place(row: Row, y: number, phase: number, opacity: number, still: boolean) {
  const scale = 1 - phase * (1 - COMPLETED_SCALE);
  row.el.style.transform = `translate(${-phase * 10}px, ${y}px) scale(${scale})`;
  row.el.style.opacity = String(opacity);
  if (still) {
    row.chevron.style.opacity = "0";
    row.check.style.opacity = "1";
    row.shimmer.style.opacity = "0";
    row.dim.style.opacity = "1";
    row.dim.style.color = phase < 0.5 ? STILL_CURRENT : DIM;
  } else {
    row.chevron.style.opacity = String(clamp(1 - phase * 2, 0, 1));
    row.check.style.opacity = String(clamp(phase * 2 - 1, 0, 1));
    row.shimmer.style.opacity = String(clamp(1 - phase * 1.6, 0, 1));
    row.dim.style.opacity = String(clamp(phase * 2 - 0.4, 0, 1));
    row.dim.style.color = DIM;
  }
  // An invisible shimmer must not keep the webview repainting.
  row.shimmer.style.animationPlayState = still ? "paused" : "";
}

export class Ticker {
  readonly el: HTMLElement;
  private a = makeRow(); // completed
  private b = makeRow(); // current
  private c = makeRow(); // incoming
  private queue: string[] = [];
  private startMs: number | null = null;
  private displayIndex = -1;
  /** True once Claude has finished: the final message holds still. */
  private still = false;

  /** `onDiffTap` receives the diff id of a clicked diff row. */
  constructor(onDiffTap?: (diffId: number) => void) {
    this.el = h("div", { class: "ticker" }, this.a.el, this.b.el, this.c.el);
    // The completed and the current row answer a click, as on macOS; the
    // incoming row is only ever seen mid-slide.
    for (const row of [this.a, this.b]) {
      row.el.addEventListener("click", () => {
        if (row.diff && onDiffTap) onDiffTap(row.diff.diffId);
      });
    }
    this.rest();
  }

  /** The state between transitions: completed on top, current below. */
  private rest() {
    place(this.a, 0, 1, 1, this.still);
    place(this.b, ROW_H, 0, 1, this.still);
    place(this.c, ROW_H * 2, 0, 0, this.still);
  }

  get animating(): boolean {
    return this.startMs != null || this.queue.length > 0;
  }

  sync(task: AgentTask | null) {
    const steps = task?.steps ?? [];
    // Where the newest step sits in the whole session, not in `steps`: that
    // list is capped at 20, and counting inside it made the ticker stop for
    // good at the twentieth step of a session.
    const newest = steps.length === 0 ? -1 : (task?.stepSeq ?? steps.length - 1);

    const still = !!task?.finalLine;
    if (still !== this.still) {
      this.still = still;
      // Mid-slide, the next frame places every row with the new look anyway.
      if (this.startMs == null) this.rest();
    }

    // First render, or the session restarted (steps were cleared): drop
    // straight into place rather than scroll.
    if (this.displayIndex < 0 || newest < this.displayIndex) {
      this.queue = [];
      this.startMs = null;
      this.displayIndex = newest;
      setText(this.a, steps.at(-2) ?? "…");
      setText(this.b, steps.at(-1) ?? "…");
      this.rest();
      return;
    }

    const fresh = Math.min(newest - this.displayIndex, steps.length);
    if (fresh > 0) this.queue.push(...steps.slice(-fresh));
    this.displayIndex = newest;
    if (this.queue.length > MAX_QUEUE) {
      this.queue = this.queue.slice(-MAX_QUEUE);
    }
  }

  /** Called every frame by the island while the overview is on screen. */
  tick(nowMs: number) {
    if (this.startMs == null) {
      if (this.queue.length === 0) return;
      setText(this.c, this.queue[0]);
      place(this.c, ROW_H * 2, 0, 0, this.still);
      this.startMs = nowMs;
    }

    const p = clamp((nowMs - this.startMs) / DURATION, 0, 1);
    const e = EASE(p);

    // A leaves upwards and fades a little faster than it moves, as on macOS.
    place(this.a, lerp(0, -ROW_H, e), 1, clamp(1 - p * 1.35, 0, 1), this.still);
    place(this.b, lerp(ROW_H, 0, e), e, 1, this.still);
    place(this.c, lerp(ROW_H * 2, ROW_H, e), 0, e, this.still);

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
