// The Coucou window's page switches. A new page rises into the
// panel from the side of the sidebar it was picked on (lower in the list:
// from below, higher: from above) while the page being left drifts the other
// way and fades. Redrawing the page on screen (a toggle, a language change)
// swaps it in place, where it was scrolled to. While the window is hidden or
// still coming up, a page is simply put in place: the window is the motion.

import { onEvent } from "../core/bridge";
import { FlowBridge } from "../core/flow";
import { clear } from "../views/dom";

const ENTER_MS = 420;
const ENTER_DELAY_MS = 60;
const LEAVE_MS = 170;
const ENTER_SHIFT = 18;
const LEAVE_SHIFT = 10;
/** Decelerates hard and settles softly: no visible end to the motion. */
const EASE_OUT = "cubic-bezier(0.16, 1, 0.3, 1)";
const EASE_IN = "cubic-bezier(0.4, 0, 1, 1)";

/** Windows' own animation of a window coming up. */
const OPEN_MS = 360;

const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");

/** In the browser (no Tauri) the window is simply on screen. */
let shown = true;
let openedAt = -Infinity;

function setShown(on: boolean) {
  if (on === shown) return;
  shown = on;
  if (on) openedAt = performance.now();
}

void onEvent<boolean>("hub-visible", setShown);
// The window is created hidden at launch: the first opening starts from there.
void FlowBridge.hubShown().then((on) => {
  if (on !== null) setShown(on);
});

function opening(): boolean {
  return !shown || performance.now() - openedAt < OPEN_MS;
}

let entering: Animation | null = null;
let leaving: HTMLElement | null = null;

/**
 * Puts `next` in the panel's scroll view. `direction` is where the new page
 * sits in the sidebar against the old one: 1 below, -1 above, 0 the same page,
 * which is redrawn in place without moving.
 */
export function swapPage(scroll: HTMLElement, next: HTMLElement, direction: number) {
  settle();
  // The window opening is the motion then: the page is simply there.
  const still = reducedMotion.matches || opening();
  if (direction === 0) {
    const top = scroll.scrollTop;
    clear(scroll);
    scroll.append(next);
    scroll.scrollTop = top;
    return;
  }
  const old = scroll.firstElementChild as HTMLElement | null;
  if (old && !still) leave(scroll, old, direction);
  clear(scroll);
  scroll.append(next);
  scroll.scrollTop = 0;
  if (still) return;
  // No fill once finished: a transform left on the page would become the
  // containing block of the fixed popups inside it.
  entering = next.animate(
    [
      { opacity: 0, transform: `translateY(${direction * ENTER_SHIFT}px)` },
      { opacity: 1, transform: "none" },
    ],
    { duration: ENTER_MS, delay: ENTER_DELAY_MS, easing: EASE_OUT, fill: "backwards" },
  );
}

/** Lays the old page over the panel, scrolled as it was, and fades it out. */
function leave(scroll: HTMLElement, old: HTMLElement, direction: number) {
  const box = scroll.getBoundingClientRect();
  const top = scroll.scrollTop;
  const layer = document.createElement("div");
  layer.className = `${scroll.className} leaving`;
  layer.setAttribute("aria-hidden", "true");
  layer.inert = true;
  Object.assign(layer.style, {
    left: `${box.left}px`,
    top: `${box.top}px`,
    width: `${box.width}px`,
    height: `${box.height}px`,
  });
  layer.append(old);
  document.body.append(layer);
  layer.scrollTop = top;
  leaving = layer;
  old
    .animate(
      [
        { opacity: 1, transform: "none" },
        { opacity: 0, transform: `translateY(${-direction * LEAVE_SHIFT}px)` },
      ],
      { duration: LEAVE_MS, easing: EASE_IN, fill: "forwards" },
    )
    .finished.then(() => layer.remove(), () => layer.remove());
}

/** Ends the switch still running, for a click that comes before it's over. */
function settle() {
  entering?.finish();
  entering = null;
  leaving?.remove();
  leaving = null;
}
