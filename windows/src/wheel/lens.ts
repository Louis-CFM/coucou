// The wheel's liquid glass, as on macOS: the screen behind it stays nearly
// sharp, and each piece of glass (a wedge, the hub, the disc's rim, the ring
// pill) bends it near its edges like a lens, the colours parting a little
// there. Done once per opening (and per ring) on a canvas under the wedges.

import type { Ring } from "./geometry";

export interface Pieces {
  ring: Ring;
  /** How many wedges. */
  n: number;
  /** The hub's radius, and the disc's (the rim around the wedges). */
  hub: number;
  disc: number;
  /** The ring pill: a rounded rectangle. */
  bar: { x: number; y: number; w: number; h: number; r: number };
}

/** Inside a piece of glass: how far from its edge, the outward normal there,
 *  and how wide its bevel is (where it bends the light). */
export interface Edge {
  d: number;
  nx: number;
  ny: number;
  bevel: number;
}

const BEVEL = { wedge: 15, hub: 12, disc: 9, bar: 11 };

/** The piece of glass under (x, y) and its nearest edge, or null outside. */
export function edgeAt(p: Pieces, x: number, y: number): Edge | null {
  const { ring } = p;
  const dx = x - ring.cx;
  const dy = y - ring.cy;
  const r = Math.hypot(dx, dy);
  if (r <= p.disc) {
    // Radial (outward) and tangential (clockwise) unit vectors.
    const ux = r > 0 ? dx / r : 0;
    const uy = r > 0 ? dy / r : -1;
    if (r <= p.hub) return { d: p.hub - r, nx: ux, ny: uy, bevel: BEVEL.hub };
    if (p.n > 0 && r >= ring.inner && r <= ring.outer) {
      const span = (2 * Math.PI) / p.n;
      // 0 at the top, clockwise, as geometry.ts.
      const a = (Math.atan2(dy, dx) + Math.PI / 2 + 2 * Math.PI) % (2 * Math.PI);
      const i = Math.min(p.n - 1, Math.floor(a / span));
      // Away from each dividing line, less half the (even) gap.
      const fromStart = r * Math.sin(a - i * span) - ring.gap / 2;
      const fromEnd = r * Math.sin((i + 1) * span - a) - ring.gap / 2;
      if (fromStart >= 0 && fromEnd >= 0) {
        const tx = -uy;
        const ty = ux;
        const sides: Edge[] = [
          { d: ring.outer - r, nx: ux, ny: uy, bevel: BEVEL.wedge },
          { d: r - ring.inner, nx: -ux, ny: -uy, bevel: BEVEL.wedge },
          { d: fromStart, nx: -tx, ny: -ty, bevel: BEVEL.wedge },
          { d: fromEnd, nx: tx, ny: ty, bevel: BEVEL.wedge },
        ];
        return sides.reduce((m, s) => (s.d < m.d ? s : m));
      }
    }
    return { d: p.disc - r, nx: ux, ny: uy, bevel: BEVEL.disc };
  }
  const b = p.bar;
  const d = roundRect(b, x, y);
  if (d > 0) return null;
  const e = 0.5;
  const gx = roundRect(b, x + e, y) - roundRect(b, x - e, y);
  const gy = roundRect(b, x, y + e) - roundRect(b, x, y - e);
  const g = Math.hypot(gx, gy) || 1;
  return { d: -d, nx: gx / g, ny: gy / g, bevel: BEVEL.bar };
}

/** Signed distance to a rounded rectangle: negative inside. */
function roundRect(b: Pieces["bar"], x: number, y: number): number {
  const qx = Math.abs(x - (b.x + b.w / 2)) - (b.w / 2 - b.r);
  const qy = Math.abs(y - (b.y + b.h / 2)) - (b.h / 2 - b.r);
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - b.r;
}

/** How far the glass shifts what is behind it, d in from an edge: most at the
 *  edge, nothing past the bevel (a lens's rounded rim). */
export function bend(e: Edge, most: number): number {
  if (e.d >= e.bevel) return 0;
  const t = 1 - e.d / e.bevel;
  return most * t * t;
}

/** The glass drawn from `src` (the screen behind, at `scale` pixels per unit)
 *  into a new image the same size: bent at the edges, the colours parting
 *  there, a little brighter and livelier, clear outside the pieces. */
export function refract(src: ImageData, p: Pieces, scale: number): ImageData {
  const { width: w, height: h, data } = src;
  const out = new ImageData(w, h);
  const o = out.data;
  const most = 16 * scale;
  const sample = (x: number, y: number, c: number): number => {
    // Bilinear, clamped to the picture.
    const fx = Math.min(w - 1, Math.max(0, x));
    const fy = Math.min(h - 1, Math.max(0, y));
    const x0 = Math.floor(fx);
    const y0 = Math.floor(fy);
    const x1 = Math.min(w - 1, x0 + 1);
    const y1 = Math.min(h - 1, y0 + 1);
    const ax = fx - x0;
    const ay = fy - y0;
    const at = (xx: number, yy: number) => data[(yy * w + xx) * 4 + c];
    return (at(x0, y0) * (1 - ax) + at(x1, y0) * ax) * (1 - ay) + (at(x0, y1) * (1 - ax) + at(x1, y1) * ax) * ay;
  };
  for (let py = 0; py < h; py++) {
    for (let px = 0; px < w; px++) {
      const e = edgeAt(p, (px + 0.5) / scale, (py + 0.5) / scale);
      if (!e) continue;
      const k = (py * w + px) * 4;
      // Outward: near its edge the glass shows what is just beyond it.
      const s = bend(e, most);
      let r = sample(px + e.nx * s * 1.12, py + e.ny * s * 1.12, 0);
      let g = sample(px + e.nx * s, py + e.ny * s, 1);
      let b = sample(px + e.nx * s * 0.88, py + e.ny * s * 0.88, 2);
      // Livelier (saturation) and a touch brighter, as Apple's glass.
      const l = 0.299 * r + 0.587 * g + 0.114 * b;
      r = l + (r - l) * 1.25 + 6;
      g = l + (g - l) * 1.25 + 6;
      b = l + (b - l) * 1.25 + 6;
      o[k] = r;
      o[k + 1] = g;
      o[k + 2] = b;
      // Smooth edges: the last pixel fades.
      o[k + 3] = Math.round(255 * Math.min(1, e.d * scale + 0.5));
    }
  }
  return out;
}
