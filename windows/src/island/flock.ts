// The small Mochis of the folded island, on their way to their pills and back.
//
// Folded, the island shows them stacked two by two; unfolded, each one sits in
// its pill. Those are two sets of Mochis, and one used to fade while the other
// appeared. Here a third set stands in for both while the island moves: each
// one leaves its place in the stack and lands in its pill, on a spring, the
// way the large Mochi goes from one view to another — and comes back when the
// island folds. Once they are there, the ones that live there take over.

import { Spring, lerp } from "../core/anim";
import type { AgentTask } from "../core/state";
import { createMiniBot } from "../mochi/minibots";
import { h } from "../views/dom";

/** The spring they fly on: quick, with a little give. */
const RESPONSE = 0.42;
const DAMPING = 0.78;
/**
 * The spring runs from 0, stacked, to this, in the pills. A spring is at rest
 * within a hundredth of where it goes: over this much, that is a fraction of a
 * pixel of the way, and they hand over as soon as they look arrived.
 */
const THERE = 5;

/** The stack: Mochis this wide, this far apart, two to a row (see #mini-grid). */
export const STACK_BODY = 13;
export const STACK_GAP = 3;
const STACK_COLUMNS = 2;

interface Bird {
  el: HTMLElement;
  /** Its place in the stack, counted row by row. */
  cell: number;
  /** The middle of its Mochi in the pill, from the views' left edge and the island's top. */
  x: number;
  y: number;
  /** How wide that Mochi is. */
  size: number;
}

export class Flock {
  readonly el = h("div", { id: "mini-flight" });

  private way = new Spring(0, RESPONSE, DAMPING);
  private birds: Bird[] = [];

  /** True while they are on their way: the frame loop keeps going, and the ones at both ends stay out of sight. */
  get moving(): boolean {
    return this.birds.length > 0;
  }

  /**
   * Sends them off: to their pills, or back to the stack. `pill` gives the
   * Mochi a task has in its pill, and `views` what its place is counted from.
   * A task with no pill stays where it is. False when nobody leaves.
   */
  start(tasks: AgentTask[], toPills: boolean, pill: (id: string) => HTMLElement | null, views: HTMLElement): boolean {
    if (this.birds.length === 0) {
      tasks.forEach((task, cell) => {
        const slot = pill(task.id);
        if (!slot) return;
        const size = slot.offsetWidth;
        // Counted in the layout, not on the screen: a view on its way in is
        // drawn a touch smaller, and its pills are not yet where they will be.
        let x = size / 2;
        let y = slot.offsetHeight / 2;
        // An offset is counted from inside the border of what holds it.
        for (let at: HTMLElement | null = slot; at && at !== views; at = at.offsetParent as HTMLElement | null) {
          x += at.offsetLeft + (at === slot ? 0 : at.clientLeft);
          y += at.offsetTop + (at === slot ? 0 : at.clientTop);
        }
        const el = createMiniBot(task, size);
        this.el.append(el);
        this.birds.push({ el, cell, x, y, size });
      });
      if (this.birds.length === 0) return false;
      this.way.set(toPills ? 0 : THERE);
    }
    this.way.target = toPills ? THERE : 0;
    return true;
  }

  /**
   * A frame of the way. `stackX`, `stackY`: the stack's corner in the island
   * now; `shift`: the views' left edge from the island's. True on the frame
   * they arrive: they are gone, and their canvases are to be dropped.
   */
  step(dt: number, stackX: number, stackY: number, shift: number): boolean {
    if (this.birds.length === 0) return false;
    this.way.step(dt);
    if (this.way.settled) {
      this.el.replaceChildren();
      this.birds = [];
      return true;
    }
    const p = this.way.value / THERE;
    const pitch = STACK_BODY + STACK_GAP;
    for (const bird of this.birds) {
      const fromX = stackX + STACK_BODY / 2 + (bird.cell % STACK_COLUMNS) * pitch;
      const fromY = stackY + STACK_BODY / 2 + Math.floor(bird.cell / STACK_COLUMNS) * pitch;
      const x = lerp(fromX, bird.x + shift, p) - bird.size / 2;
      const y = lerp(fromY, bird.y, p) - bird.size / 2;
      bird.el.style.transform = `translate(${x}px, ${y}px) scale(${lerp(STACK_BODY / bird.size, 1, p)})`;
    }
    return false;
  }
}
