// The wheel's shapes: n wedges in a ring around a hub, starting at the top and
// going clockwise, with a small gap between them. All in the SVG's own units.

export interface Ring {
  cx: number;
  cy: number;
  /** The wedges' inner and outer radius. */
  inner: number;
  outer: number;
  /** The gap between two wedges, in units: as wide by the hub as at the rim. */
  gap: number;
  /** How round a wedge's corners are, in units. */
  corner: number;
}

const rad = (deg: number) => ((deg - 90) * Math.PI) / 180;

function point(r: Ring, radius: number, deg: number): [number, number] {
  return [r.cx + radius * Math.cos(rad(deg)), r.cy + radius * Math.sin(rad(deg))];
}

/** Where wedge i's side (0 its start, 1 its end) is at `radius`, in degrees:
 *  half the gap in from the dividing line, so the gap stays even. */
function side(ring: Ring, i: number, n: number, edge: 0 | 1, radius: number): number {
  const inset = (Math.asin(Math.min(1, ring.gap / 2 / radius)) * 180) / Math.PI;
  return edge === 0 ? i * (360 / n) + inset : (i + 1) * (360 / n) - inset;
}

/** Wedge i of n as an SVG path: a ring sector with round corners. */
export function wedgePath(ring: Ring, i: number, n: number): string {
  const { outer, inner, corner: c } = ring;
  const f = (v: number) => v.toFixed(2);
  const at = (radius: number, deg: number) => point(ring, radius, deg).map(f).join(" ");
  // A corner's ends along the arcs, in degrees.
  const along = (radius: number) => (c / radius) * (180 / Math.PI);
  const oa = side(ring, i, n, 0, outer);
  const ob = side(ring, i, n, 1, outer);
  const ia = side(ring, i, n, 0, inner);
  const ib = side(ring, i, n, 1, inner);
  const large = ob - oa - 2 * along(outer) > 180 ? 1 : 0;
  return [
    `M${at(outer - c, side(ring, i, n, 0, outer - c))}`,
    `Q${at(outer, oa)} ${at(outer, oa + along(outer))}`,
    `A${outer} ${outer} 0 ${large} 1 ${at(outer, ob - along(outer))}`,
    `Q${at(outer, ob)} ${at(outer - c, side(ring, i, n, 1, outer - c))}`,
    `L${at(inner + c, side(ring, i, n, 1, inner + c))}`,
    `Q${at(inner, ib)} ${at(inner, ib - along(inner))}`,
    `A${inner} ${inner} 0 ${large} 0 ${at(inner, ia + along(inner))}`,
    `Q${at(inner, ia)} ${at(inner + c, side(ring, i, n, 0, inner + c))}`,
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
