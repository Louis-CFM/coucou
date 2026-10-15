// Mochi's body shapes, picked in the wardrobe (stored as `mochiShape`, "" =
// the classic Mochi; names in ./wardrobe.ts SHAPE_KEYS). The body is a
// superellipse. Kept apart from wardrobe.ts so the desktop and screen windows
// draw shapes without loading the translations.

export interface ShapeDef {
  id: string;
  /** Half-width and half-height, in units of R. */
  rx: number;
  ry: number;
  /** Superellipse exponent: 2 = ellipse, higher = squarer. */
  n: number;
  /** How much narrower the top is than the bottom (0 = symmetric). */
  taper: number;
}

/** The first is the classic body, the same as upstream's (rx 1.14, ry 0.88, n 2.7). */
export const SHAPES: readonly ShapeDef[] = [
  { id: "mochi", rx: 1.14, ry: 0.88, n: 2.7, taper: 0 },
  { id: "daifuku", rx: 1.04, ry: 0.96, n: 2.15, taper: 0 },
  { id: "bean", rx: 0.9, ry: 1.02, n: 2.4, taper: 0.08 },
  { id: "tofu", rx: 1.04, ry: 0.9, n: 4.6, taper: 0 },
  { id: "onigiri", rx: 1.16, ry: 0.96, n: 3.0, taper: 0.46 },
];

/** A stored shape id → its shape; anything unknown is the classic Mochi. */
export function shapeOf(id: unknown): ShapeDef {
  return SHAPES.find((s) => s.id === id) ?? SHAPES[0];
}

/** Width factor at height `yn` (-1 top … 1 bottom): the onigiri's narrow top. */
export function taperAt(shape: ShapeDef, yn: number): number {
  return 1 - shape.taper * (1 - yn) * 0.5;
}

/** Half-width of the outline at height `yn` (-1 top … 1 bottom), units of R. */
export function halfWidthAt(shape: ShapeDef, yn: number): number {
  const y = Math.min(1, Math.abs(yn));
  return shape.rx * Math.pow(1 - Math.pow(y, shape.n), 1 / shape.n) * taperAt(shape, yn);
}

/** A point on the outline in the direction (ca, sa), in units of R. */
export function shapePoint(shape: ShapeDef, ca: number, sa: number): { x: number; y: number } {
  const e = 2 / shape.n;
  const ux = ca >= 0 ? Math.pow(ca, e) : -Math.pow(-ca, e);
  const uy = sa >= 0 ? Math.pow(sa, e) : -Math.pow(-sa, e);
  return { x: shape.rx * ux * taperAt(shape, uy), y: shape.ry * uy };
}
