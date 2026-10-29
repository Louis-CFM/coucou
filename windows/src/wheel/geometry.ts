// The wheel's shapes: n wedges in a ring around a hub, starting at the top and
// going clockwise, with a small gap between them. All in the SVG's own units.

export interface Ring {
  cx: number;
  cy: number;
  /** The wedges' inner and outer radius. */
  inner: number;
  outer: number;
  /** The gap between two wedges, in degrees. */
  gap: number;
}

const rad = (deg: number) => ((deg - 90) * Math.PI) / 180;

function point(r: Ring, radius: number, deg: number): [number, number] {
  return [r.cx + radius * Math.cos(rad(deg)), r.cy + radius * Math.sin(rad(deg))];
}

/** Wedge i of n as an SVG path (a ring sector). */
export function wedgePath(ring: Ring, i: number, n: number): string {
  const span = 360 / n;
  const a0 = i * span + ring.gap / 2;
  const a1 = (i + 1) * span - ring.gap / 2;
  const large = a1 - a0 > 180 ? 1 : 0;
  const [ox0, oy0] = point(ring, ring.outer, a0);
  const [ox1, oy1] = point(ring, ring.outer, a1);
  const [ix1, iy1] = point(ring, ring.inner, a1);
  const [ix0, iy0] = point(ring, ring.inner, a0);
  const f = (v: number) => v.toFixed(2);
  return [
    `M${f(ox0)} ${f(oy0)}`,
    `A${ring.outer} ${ring.outer} 0 ${large} 1 ${f(ox1)} ${f(oy1)}`,
    `L${f(ix1)} ${f(iy1)}`,
    `A${ring.inner} ${ring.inner} 0 ${large} 0 ${f(ix0)} ${f(iy0)}`,
    "Z",
  ].join(" ");
}

/** Where wedge i's label goes: the middle of the wedge. */
export function labelPoint(ring: Ring, i: number, n: number): [number, number] {
  const mid = (i + 0.5) * (360 / n);
  return point(ring, (ring.inner + ring.outer) / 2, mid);
}

/** The wedge under (x, y), or -1 on the hub or outside the ring. */
export function wedgeAt(ring: Ring, n: number, x: number, y: number): number {
  if (n <= 0) return -1;
  const dx = x - ring.cx;
  const dy = y - ring.cy;
  const d = Math.hypot(dx, dy);
  if (d < ring.inner || d > ring.outer) return -1;
  // 0° at the top, clockwise.
  const deg = ((Math.atan2(dy, dx) * 180) / Math.PI + 90 + 360) % 360;
  return Math.min(n - 1, Math.floor(deg / (360 / n)));
}

/** "2.2 MB", "640 KB", in the language's number format. */
export function fileSize(bytes: number, lang: string): string {
  const units = ["byte", "kilobyte", "megabyte", "gigabyte"] as const;
  let v = bytes;
  let u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  return new Intl.NumberFormat(lang, {
    style: "unit",
    unit: units[u],
    unitDisplay: "short",
    maximumFractionDigits: v < 10 && u > 0 ? 1 : 0,
  }).format(v);
}
