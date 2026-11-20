const fmt = (n: number) => (Math.round(n * 1000) / 1000).toString();

/** Corner shape: semi-axes along the horizontal and vertical edges, and the superellipse exponent. */
export interface CornerShape {
  rx: number;
  ry: number;
  exponent: number;
  /**
   * Continuous-corner smoothing, 0 to 1. Above 0 the corner is an arc of radius `rx` with eased
   * transitions (and `ry` and `exponent` are ignored). Default 0.
   */
  smoothing?: number;
}

/** One side of a continuous corner: where it leaves the edge and how it reaches the arc. */
interface EdgeEase {
  /** Distance from the corner, along the edge, where the curve leaves it. */
  p: number;
  /** Bezier handle lengths along the edge, from `p` toward the corner. */
  a: number;
  b: number;
  /** The arc's end on this side: distance from the corner along the edge, and in from it. */
  along: number;
  across: number;
}

const edgeEase = (r: number, smoothing: number, room: number): EdgeEase => {
  // Only as much smoothing as this edge has room for: the curve may use half its length.
  const s = Math.max(0, Math.min(smoothing, room / r - 1));
  const angle = (Math.PI / 4) * s;
  const p = (1 + s) * r;
  const along = r * (1 - Math.sin(angle));
  const across = r * (1 - Math.cos(angle));
  const c = r * Math.tan(angle / 2) * Math.cos(angle);
  const b = Math.max(0, (p - c - along) / 3);
  return { p, a: 2 * b, b, along, across };
};

interface Vec {
  x: number;
  y: number;
}

/**
 * A rectangle with continuous corners of radius `r`, drawn clockwise from the top edge. `r` clamps
 * to half the shorter side; each edge's smoothing clamps to the room that edge has. `leading`
 * (optional, defaults to `radius`) is the two left corners' radius: a shrinking island's leading end
 * can stay rounder than its trailing one (round 43, `islandMotion.cornerLead`).
 */
export const continuousRectPath = (x: number, y: number, width: number, height: number, radius: number, smoothing: number, leading: number = radius): string => {
  const w = Math.max(0, width);
  const h = Math.max(0, height);
  if (w === 0 || h === 0) return "";
  const r = Math.max(0, Math.min(radius, w / 2, h / 2));
  const rl = Math.max(0, Math.min(leading, w / 2, h / 2));
  if (r < 1e-3 && rl < 1e-3) return `M ${fmt(x)} ${fmt(y)} H ${fmt(x + w)} V ${fmt(y + h)} H ${fmt(x)} Z`;
  const across = edgeEase(r, smoothing, w / 2);
  const down = edgeEase(r, smoothing, h / 2);
  const acrossL = rl === r ? across : edgeEase(rl, smoothing, w / 2);
  const downL = rl === r ? down : edgeEase(rl, smoothing, h / 2);
  const pt = (k: Vec, u: Vec, du: number, v: Vec, dv: number) => `${fmt(k.x + u.x * du + v.x * dv)} ${fmt(k.y + u.y * du + v.y * dv)}`;
  // `u` points back along the edge the path arrives on, `v` along the edge it leaves on.
  const corner = (k: Vec, u: Vec, v: Vec, inc: EdgeEase, out: EdgeEase, rc: number) =>
    `L ${pt(k, u, inc.p, v, 0)} ` +
    `C ${pt(k, u, inc.p - inc.a, v, 0)} ${pt(k, u, inc.p - inc.a - inc.b, v, 0)} ${pt(k, u, inc.along, v, inc.across)} ` +
    `A ${fmt(rc)} ${fmt(rc)} 0 0 1 ${pt(k, v, out.along, u, out.across)} ` +
    `C ${pt(k, v, out.p - out.a - out.b, u, 0)} ${pt(k, v, out.p - out.a, u, 0)} ${pt(k, v, out.p, u, 0)} `;
  const right = x + w;
  const bottom = y + h;
  return (
    `M ${fmt(x + acrossL.p)} ${fmt(y)} ` +
    corner({ x: right, y }, { x: -1, y: 0 }, { x: 0, y: 1 }, across, down, r) +
    corner({ x: right, y: bottom }, { x: 0, y: -1 }, { x: -1, y: 0 }, down, across, r) +
    corner({ x, y: bottom }, { x: 1, y: 0 }, { x: 0, y: -1 }, acrossL, downL, rl) +
    corner({ x, y }, { x: 0, y: 1 }, { x: 1, y: 0 }, downL, acrossL, rl) +
    "Z"
  );
};

// Segments per corner when the corner isn't a circular arc. At island sizes the polyline sits
// well under a hundredth of a point from the true curve.
const segments = 24;

/** One quadrant centred at (cx, cy), starting at angle `from` (radians, clockwise on screen). */
const cornerPath = (cx: number, cy: number, c: CornerShape, from: number): string => {
  if (c.rx <= 0 || c.ry <= 0) return "";
  if (Math.abs(c.exponent - 2) < 1e-3) {
    const end = from + Math.PI / 2;
    return `A ${fmt(c.rx)} ${fmt(c.ry)} 0 0 1 ${fmt(cx + c.rx * Math.cos(end))} ${fmt(cy + c.ry * Math.sin(end))} `;
  }
  const power = 2 / c.exponent;
  let out = "";
  for (let i = 1; i <= segments; i += 1) {
    const angle = from + (Math.PI / 2) * (i / segments);
    const cos = Math.cos(angle);
    const sin = Math.sin(angle);
    const x = cx + c.rx * Math.sign(cos) * Math.abs(cos) ** power;
    const y = cy + c.ry * Math.sign(sin) * Math.abs(sin) ** power;
    out += `L ${fmt(x)} ${fmt(y)} `;
  }
  return out;
};

/**
 * A rectangle with superellipse corners, drawn clockwise. Corner axes clamp to half each side.
 * `leading` (optional, defaults to `corner`) shapes the two left corners.
 */
export const roundedRectPath = (x: number, y: number, width: number, height: number, corner: CornerShape, leading: CornerShape = corner): string => {
  if ((corner.smoothing ?? 0) > 0) return continuousRectPath(x, y, width, height, corner.rx, corner.smoothing ?? 0, leading.rx);
  const w = Math.max(0, width);
  const h = Math.max(0, height);
  if (w === 0 || h === 0) return "";
  const clampTo = (k: CornerShape): CornerShape => ({
    rx: Math.max(0, Math.min(k.rx, w / 2)),
    ry: Math.max(0, Math.min(k.ry, h / 2)),
    exponent: k.exponent,
  });
  const c = clampTo(corner);
  const l = leading === corner ? c : clampTo(leading);
  const r = x + w;
  const b = y + h;
  return (
    `M ${fmt(x + l.rx)} ${fmt(y)} ` +
    `L ${fmt(r - c.rx)} ${fmt(y)} ` +
    cornerPath(r - c.rx, y + c.ry, c, -Math.PI / 2) +
    `L ${fmt(r)} ${fmt(b - c.ry)} ` +
    cornerPath(r - c.rx, b - c.ry, c, 0) +
    `L ${fmt(x + l.rx)} ${fmt(b)} ` +
    cornerPath(x + l.rx, b - l.ry, l, Math.PI / 2) +
    `L ${fmt(x)} ${fmt(y + l.ry)} ` +
    cornerPath(x + l.rx, y + l.ry, l, Math.PI) +
    "Z"
  );
};

/** A capsule: round ends on the shorter side, semicircles unless `smoothing` (0 to 1) eases the shoulders. */
export const capsulePath = (x: number, y: number, width: number, height: number, smoothing = 0): string => {
  const r = Math.min(width, height) / 2;
  return roundedRectPath(x, y, width, height, { rx: r, ry: r, exponent: 2, smoothing });
};

interface Circle {
  x: number;
  y: number;
  r: number;
}

interface BridgeOptions {
  /** Handle length factor for the connecting curves. */
  handleSize: number;
  /** 0 to 1. How far round each circle the neck attaches. 0 pinches the neck to a line. */
  spread: number;
  /** Gap between the circles' edges past which there is no bridge. */
  maxGap: number;
  /** How the neck thins toward `maxGap`: 1.5 fades it to a hairline, lower keeps it until it breaks. Default 1.5. */
  power?: number;
}

const polar = (c: { x: number; y: number }, angle: number, length: number) => ({
  x: c.x + length * Math.cos(angle),
  y: c.y + length * Math.sin(angle),
});

/**
 * The gooey neck between two circles (a metaball bridge), drawn as a closed path that overlaps
 * both circles. Fill it with the circles and the union reads as one liquid shape. The neck
 * thins to nothing as the gap reaches `maxGap`, so the pinch-off has no pop.
 */
export const bridgePath = (a: Circle, b: Circle, options: BridgeOptions): string => {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const d = Math.hypot(dx, dy);
  if (a.r <= 0 || b.r <= 0 || d <= Math.abs(a.r - b.r)) return "";
  const gap = d - a.r - b.r;
  if (gap >= options.maxGap) return "";

  // Fade the spread to 0 across the last part of the reach so the neck pinches smoothly.
  const reach = Math.max(0, gap) / options.maxGap;
  const v = options.spread * (1 - reach) ** (options.power ?? 1.5);
  if (v <= 1e-4) return "";

  let u1 = 0;
  let u2 = 0;
  if (d < a.r + b.r) {
    u1 = Math.acos(Math.min(1, Math.max(-1, (a.r * a.r + d * d - b.r * b.r) / (2 * a.r * d))));
    u2 = Math.acos(Math.min(1, Math.max(-1, (b.r * b.r + d * d - a.r * a.r) / (2 * b.r * d))));
  }
  const between = Math.atan2(dy, dx);
  const maxSpread = Math.acos(Math.min(1, Math.max(-1, (a.r - b.r) / d)));

  const angle1 = between + u1 + (maxSpread - u1) * v;
  const angle2 = between - u1 - (maxSpread - u1) * v;
  const angle3 = between + Math.PI - u2 - (Math.PI - u2 - maxSpread) * v;
  const angle4 = between - Math.PI + u2 + (Math.PI - u2 - maxSpread) * v;

  const p1 = polar(a, angle1, a.r);
  const p2 = polar(a, angle2, a.r);
  const p3 = polar(b, angle3, b.r);
  const p4 = polar(b, angle4, b.r);

  const total = a.r + b.r;
  const handle = Math.min(v * options.handleSize, Math.hypot(p1.x - p3.x, p1.y - p3.y) / total) * Math.min(1, (d * 2) / total);
  const h1 = polar(p1, angle1 - Math.PI / 2, a.r * handle);
  const h2 = polar(p2, angle2 + Math.PI / 2, a.r * handle);
  const h3 = polar(p3, angle3 + Math.PI / 2, b.r * handle);
  const h4 = polar(p4, angle4 - Math.PI / 2, b.r * handle);

  const pt = (p: { x: number; y: number }) => `${fmt(p.x)} ${fmt(p.y)}`;
  return `M ${pt(p1)} C ${pt(h1)} ${pt(h3)} ${pt(p3)} L ${pt(p4)} C ${pt(h4)} ${pt(h2)} ${pt(p2)} Z`;
};

/**
 * A short pointed nub on circle `c`, aimed at `toward`, its tip `length` past the circle: what a
 * split neck leaves on each end when it first snaps (round 40). Its sides leave the circle `base`
 * radians either side of the aim and hug it before they rise to the tip, so the nub is concave and
 * narrow. Drawn as a closed path through the circle's centre, so filled with the circle it adds
 * only the nub. Empty for a length under 0.01 pt.
 */
export const cuspPath = (c: Circle, toward: { x: number; y: number }, length: number, base = 0.5): string => {
  const d = Math.hypot(toward.x - c.x, toward.y - c.y);
  if (c.r <= 0 || d < 1e-6 || length < 0.01) return "";
  const aim = Math.atan2(toward.y - c.y, toward.x - c.x);
  const tip = polar(c, aim, c.r + length);
  const pt = (p: { x: number; y: number }) => `${fmt(p.x)} ${fmt(p.y)}`;
  // The control points sit on the circle near the aim, which bends each side in toward the cap.
  return (
    `M ${pt(polar(c, aim + base, c.r))} Q ${pt(polar(c, aim + base * 0.25, c.r))} ${pt(tip)} ` +
    `Q ${pt(polar(c, aim - base * 0.25, c.r))} ${pt(polar(c, aim - base, c.r))} L ${pt(c)} Z`
  );
};

/**
 * A rectangle with its corners cut at 45 degrees, legs `leg` long: the island's content mask.
 * The simulator clips expanded content this way (the 52 pt square and the bar lose their outer
 * corners along x + y = r).
 */
export const chamferPath = (x: number, y: number, width: number, height: number, leg: number): string => {
  const w = Math.max(0, width);
  const h = Math.max(0, height);
  if (w === 0 || h === 0) return "";
  const c = Math.max(0, Math.min(leg, w / 2, h / 2));
  const r = x + w;
  const b = y + h;
  return (
    `M ${fmt(x + c)} ${fmt(y)} L ${fmt(r - c)} ${fmt(y)} L ${fmt(r)} ${fmt(y + c)} L ${fmt(r)} ${fmt(b - c)} ` +
    `L ${fmt(r - c)} ${fmt(b)} L ${fmt(x + c)} ${fmt(b)} L ${fmt(x)} ${fmt(b - c)} L ${fmt(x)} ${fmt(y + c)} Z`
  );
};
