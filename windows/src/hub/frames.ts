// When the Coucou window's canvases are drawn (hub/hero.ts), kept apart from
// the DOM so it can be tested. The rule is the island's: nothing on screen,
// nothing drawn, and no frame asked for.

export interface Box {
  top: number;
  left: number;
  bottom: number;
  right: number;
  width: number;
  height: number;
}

/** Whether the loop should ask for another frame: something to draw, the
 *  window shown (Rust says, see `hub-visible`) and the page visible (WebKitGTK
 *  does not always say so for a hidden window, #792). */
export function shouldAnimate(live: number, pageVisibility: string, windowShown: boolean): boolean {
  return live > 0 && windowShown && pageVisibility === "visible";
}

/** Frames a second the canvases are drawn at. They are slow drifts and walks:
 *  30 look the same as 60 while the window has the focus, and 10 are plenty
 *  behind other windows. On Linux, WebKitGTK paints and composites each
 *  changed canvas in software: at 60 the open window took about half a CPU
 *  core, at 30/10 about a third and a tenth of one (#792). */
export const FPS_FOCUSED = 30;
export const FPS_BACKGROUND = 10;

/** Milliseconds between two drawn frames. */
export function frameInterval(focused: boolean): number {
  return 1000 / (focused ? FPS_FOCUSED : FPS_BACKGROUND);
}

/** Whether the animation frame at `now` is drawn: one `interval` after the
 *  last drawn one, give or take a quarter of a 60 Hz frame, so that a 60 Hz
 *  screen draws every other frame and not one in three when they jitter. */
export function frameDue(now: number, lastDrawn: number, interval: number): boolean {
  return now - lastDrawn >= interval - 4;
}

/** Whether a canvas at `box` shows at least one pixel of a `width`×`height`
 *  viewport: one scrolled out of the page, or not laid out, is not drawn. */
export function onScreen(box: Box, width: number, height: number): boolean {
  return box.width > 0 && box.height > 0 && box.bottom > 0 && box.right > 0 && box.top < height && box.left < width;
}
