// The editor's arithmetic, in image pixels: crop frames, the background's canvas.

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** The rectangle between two corners, whichever way it was dragged. */
export function rectFrom(ax: number, ay: number, bx: number, by: number): Rect {
  return { x: Math.min(ax, bx), y: Math.min(ay, by), w: Math.abs(bx - ax), h: Math.abs(by - ay) };
}

export function clampRect(r: Rect, w: number, h: number): Rect {
  const x = Math.max(0, Math.min(r.x, w));
  const y = Math.max(0, Math.min(r.y, h));
  return { x, y, w: Math.max(0, Math.min(r.w, w - x)), h: Math.max(0, Math.min(r.h, h - y)) };
}

/**
 * The largest frame of ratio `aspect` (w / h) centred on `r`'s centre that fits
 * the image (`w` × `h`) and is no larger than `r`. Null: keep `r` as it is.
 */
export function cropToAspect(r: Rect, aspect: number | null, w: number, h: number): Rect {
  if (!aspect) return clampRect(r, w, h);
  const cx = r.x + r.w / 2;
  const cy = r.y + r.h / 2;
  let cw = Math.min(r.w, w);
  let ch = cw / aspect;
  if (ch > Math.min(r.h, h)) {
    ch = Math.min(r.h, h);
    cw = ch * aspect;
  }
  let x = cx - cw / 2;
  let y = cy - ch / 2;
  x = Math.max(0, Math.min(x, w - cw));
  y = Math.max(0, Math.min(y, h - ch));
  return { x, y, w: cw, h: ch };
}

/** The whole image framed at `aspect`: the starting crop for a ratio. */
export function initialCrop(aspect: number | null, w: number, h: number): Rect {
  return cropToAspect({ x: 0, y: 0, w, h }, aspect, w, h);
}

/**
 * The background tool's canvas: the image with `padding` (a fraction of its
 * longer side) all round, then widened or heightened to `aspect` (null: as it
 * comes). Where the image goes inside it.
 */
export function backgroundLayout(
  imgW: number,
  imgH: number,
  padding: number,
  aspect: number | null,
): { width: number; height: number; x: number; y: number } {
  const pad = Math.round(Math.max(imgW, imgH) * padding);
  let width = imgW + pad * 2;
  let height = imgH + pad * 2;
  if (aspect) {
    if (width / height < aspect) width = Math.round(height * aspect);
    else height = Math.round(width / aspect);
  }
  return { width, height, x: Math.round((width - imgW) / 2), y: Math.round((height - imgH) / 2) };
}
