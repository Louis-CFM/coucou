// Clearing a canvas that is drawn in CSS pixels.
//
// A canvas of 150 CSS pixels on a display scaled to 125 % has a bitmap of 188
// rows — 187.5 rounded up — so the bitmap is a fraction of a pixel taller than
// the space its drawing code thinks in. `clearRect(0, 0, width, height)` in CSS
// pixels stops short of that last row, which is then never cleared: whatever
// is drawn there with some transparency — a halo — piles up frame after frame
// into a bright line along the canvas's edge.

/** Clears the whole bitmap, whatever transform the context is drawing with. */
export function wipe(ctx: CanvasRenderingContext2D) {
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, ctx.canvas.width, ctx.canvas.height);
  ctx.restore();
}
