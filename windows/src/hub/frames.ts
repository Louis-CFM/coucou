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

/** Whether a canvas at `box` shows at least one pixel of a `width`×`height`
 *  viewport: one scrolled out of the page, or not laid out, is not drawn. */
export function onScreen(box: Box, width: number, height: number): boolean {
  return box.width > 0 && box.height > 0 && box.bottom > 0 && box.right > 0 && box.top < height && box.left < width;
}
