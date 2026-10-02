// Mochi's wardrobe: a body shape and a hat.
//
// How hats stay on (the Blooket / Kahoot paper-doll idea, plus a bone):
// - Every hat is drawn on the same template artboard as the reference Mochi,
//   so its offset is baked into the art: at runtime it is only pinned to the
//   head's seat (engine.ts), scaled to the head's real width there.
// - Hats are drawn inside the body's own transform, so they squash, tilt and
//   hop exactly with it and can never drift away from it.
// - Secondary motion only where it's authored: groups marked data-swing (a
//   tassel) hang from a pivot and trail behind the body on a damped spring.
//
// Hats are SVG files in ./wardrobe/head/<id>.svg on a 200×200 artboard around
// a reference Mochi (R = 50 at 100,100; see README.md). They become Path2D parts
// (with their gradients and clips) drawn on Mochi's own canvas: no raster images.

export interface Outfit {
  shape?: string;
  head?: string;
}

// ── Shapes ────────────────────────────────────────────────────────────────────

export interface ShapeDef {
  id: string;
  name: string;
  /** Half-width and half-height, in units of R. */
  rx: number;
  ry: number;
  /** Superellipse exponent: 2 = ellipse, higher = squarer. */
  n: number;
  /** How much narrower the top is than the bottom (0 = symmetric). */
  taper: number;
}

export const SHAPES: ShapeDef[] = [
  { id: "mochi", name: "Mochi", rx: 1.14, ry: 0.88, n: 2.7, taper: 0 },
  { id: "daifuku", name: "Daifuku", rx: 1.04, ry: 0.96, n: 2.15, taper: 0 },
  { id: "bean", name: "Bean", rx: 0.9, ry: 1.02, n: 2.4, taper: 0.08 },
  { id: "tofu", name: "Tofu", rx: 1.04, ry: 0.9, n: 4.6, taper: 0 },
  { id: "onigiri", name: "Onigiri", rx: 1.16, ry: 0.96, n: 3.0, taper: 0.46 },
];

export function shapeOf(id: string | undefined): ShapeDef {
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

// ── Items ─────────────────────────────────────────────────────────────────────

/** A gradient from the SVG (userSpaceOnUse coordinates of the part using it). */
export interface Gradient {
  kind: "linear" | "radial";
  /** linear: x1 y1 x2 y2; radial: cx cy r fx fy. */
  c: number[];
  stops: [number, string][];
  /** Canvas gradients live in user space at fill time, so one per context. */
  cache: WeakMap<CanvasRenderingContext2D, CanvasGradient>;
}

export interface Part {
  /** In the part's own user space; `m` maps it onto the artboard. */
  path: Path2D;
  m: DOMMatrix | null;
  fill: string | Gradient;
  opacity: number;
  rule: CanvasFillRule;
  /** Clip paths, already on the artboard. */
  clip: Path2D[];
}

/** A plain part, or a group that swings around `pivot` (artboard coords). */
export type Piece =
  | { swing: false; part: Part }
  | { swing: true; key: number; pivot: { x: number; y: number }; amp: number; parts: Part[] };

export interface Item {
  id: string;
  name: string;
  credit: string | null;
  back: Piece[];
  front: Piece[];
  /** Number of swinging groups (their keys are 0…swings-1). */
  swings: number;
  /** Hats: where the hat meets the head, and how far down the head it sits. */
  seat: { x: number; y: number; half: number; yn: number; fit: number } | null;
  /** How much shadow the item casts on the body (0 for a thin headband). */
  shadow: number;
}

/** Artboard units per R, and the top of the reference head. */
export const ART_R = 50;
export const HEAD_TOP = { x: 100, y: 56 };

const SOURCES = import.meta.glob("./wardrobe/head/*.svg", {
  query: "?raw",
  import: "default",
  eager: true,
}) as Record<string, string>;

let catalog: Map<string, Item> | null = null;

function load(): Map<string, Item> {
  if (catalog) return catalog;
  catalog = new Map();
  for (const [file, svg] of Object.entries(SOURCES)) {
    const m = /\.\/wardrobe\/head\/([\w-]+)\.svg$/.exec(file);
    if (!m) continue;
    try {
      const item = parseItem(m[1], svg);
      catalog.set(item.id, item);
    } catch (err) {
      console.error(`[coucou] wardrobe item ${file} is invalid`, err);
    }
  }
  return catalog;
}

/** Every hat, in name order. */
export function hats(): Item[] {
  return [...load().values()].sort((a, b) => a.name.localeCompare(b.name));
}

export function hatFor(id: string | undefined): Item | null {
  return id ? load().get(id) ?? null : null;
}

// ── Drawing ───────────────────────────────────────────────────────────────────

function paint(ctx: CanvasRenderingContext2D, fill: string | Gradient): string | CanvasGradient {
  if (typeof fill === "string") return fill;
  let g = fill.cache.get(ctx);
  if (!g) {
    const c = fill.c;
    g = fill.kind === "linear"
      ? ctx.createLinearGradient(c[0], c[1], c[2], c[3])
      : ctx.createRadialGradient(c[3], c[4], 0, c[0], c[1], c[2]);
    for (const [o, col] of fill.stops) g.addColorStop(o, col);
    fill.cache.set(ctx, g);
  }
  return g;
}

function fillParts(ctx: CanvasRenderingContext2D, parts: Part[], alpha: number) {
  const base = ctx.globalAlpha;
  for (const p of parts) {
    const plain = !p.m && p.clip.length === 0;
    if (!plain) {
      ctx.save();
      for (const c of p.clip) ctx.clip(c);
      if (p.m) ctx.transform(p.m.a, p.m.b, p.m.c, p.m.d, p.m.e, p.m.f);
    }
    ctx.globalAlpha = base * alpha * p.opacity;
    ctx.fillStyle = paint(ctx, p.fill);
    ctx.fill(p.path, p.rule);
    if (!plain) ctx.restore();
  }
  ctx.globalAlpha = base;
}

/**
 * Draws pieces in artboard space mapped so `from` lands on (x, y), scaled by
 * (sx, sy). `angle(key)` is each swinging group's current angle.
 */
export function drawPieces(
  ctx: CanvasRenderingContext2D,
  pieces: Piece[],
  from: { x: number; y: number },
  x: number,
  y: number,
  sx: number,
  sy: number,
  alpha: number,
  angle: (key: number) => number,
) {
  if (alpha <= 0.01 || pieces.length === 0) return;
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(sx, sy);
  ctx.translate(-from.x, -from.y);
  for (const piece of pieces) {
    if (!piece.swing) {
      fillParts(ctx, [piece.part], alpha);
      continue;
    }
    ctx.save();
    ctx.translate(piece.pivot.x, piece.pivot.y);
    ctx.rotate(angle(piece.key) * piece.amp);
    ctx.translate(-piece.pivot.x, -piece.pivot.y);
    fillParts(ctx, piece.parts, alpha);
    ctx.restore();
  }
  ctx.restore();
}

/** Hex colour with alpha (gradient stops with stop-opacity). */
function hexA(hex: string, a: number): string {
  const h = hex.replace("#", "");
  const full = h.length === 3 ? h.split("").map((c) => c + c).join("") : h;
  const n = parseInt(full, 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
}

// ── SVG → pieces ──────────────────────────────────────────────────────────────

function nums(s: string | null): number[] {
  return (s ?? "").split(/[\s,]+/).filter(Boolean).map(Number);
}

function parseItem(id: string, svg: string): Item {
  const doc = new DOMParser().parseFromString(svg, "image/svg+xml");
  const root = doc.documentElement;
  if (root.nodeName !== "svg") throw new Error("not an svg");
  const byId = (ref: string | null) => {
    const m = /url\(#([^)]+)\)/.exec(ref ?? "") ?? /^#(.+)$/.exec(ref ?? "");
    return m ? doc.getElementById(m[1]) : null;
  };
  const gradients = new Map<Element, Gradient>();
  const gradient = (el: Element): Gradient => {
    let g = gradients.get(el);
    if (g) return g;
    if (el.getAttribute("gradientUnits") !== "userSpaceOnUse") throw new Error("gradients must use userSpaceOnUse");
    const a = (n: string, d = 0) => Number(el.getAttribute(n) ?? d);
    // Stops can come from another gradient (href), like a shared template.
    let stopsFrom: Element = el;
    while (stopsFrom.querySelector("stop") === null) {
      const next = byId(stopsFrom.getAttribute("href") ?? stopsFrom.getAttribute("xlink:href"));
      if (!next || next === stopsFrom) break;
      stopsFrom = next;
    }
    const stops = Array.from(stopsFrom.querySelectorAll("stop")).map((st): [number, string] => {
      const off = st.getAttribute("offset") ?? "0";
      const color = st.getAttribute("stop-color") ?? "#000";
      const op = Number(st.getAttribute("stop-opacity") ?? 1);
      return [off.endsWith("%") ? parseFloat(off) / 100 : Number(off), op < 1 ? hexA(color, op) : color];
    });
    g = el.nodeName === "linearGradient"
      ? { kind: "linear", c: [a("x1"), a("y1"), a("x2"), a("y2")], stops, cache: new WeakMap() }
      : {
          kind: "radial",
          c: [a("cx"), a("cy"), a("r"), a("fx", a("cx")), a("fy", a("cy"))],
          stops,
          cache: new WeakMap(),
        };
    gradients.set(el, g);
    return g;
  };
  const clipPath = (el: Element, m: DOMMatrix): Path2D => {
    const p = new Path2D();
    for (const c of Array.from(el.children)) {
      const sh = shapeOfElement(c);
      if (sh) p.addPath(sh, c.hasAttribute("transform") ? m.multiply(parseTransform(c.getAttribute("transform")!)) : m);
    }
    return p;
  };

  const back: Piece[] = [];
  const front: Piece[] = [];
  let swings = 0;
  const SKIP = new Set(["defs", "clipPath", "linearGradient", "radialGradient", "title", "desc"]);

  const walk = (el: Element, m: DOMMatrix, inh: Inherited, layer: "back" | "front", swing: Part[] | null) => {
    for (const child of Array.from(el.children)) {
      if (child.getAttribute("id") === "guide" || SKIP.has(child.nodeName)) continue;
      const cm = child.hasAttribute("transform") ? m.multiply(parseTransform(child.getAttribute("transform")!)) : m;
      const clipEl = byId(child.getAttribute("clip-path"));
      const style: Inherited = {
        fill: child.getAttribute("fill") ?? inh.fill,
        opacity:
          inh.opacity * Number(child.getAttribute("opacity") ?? 1) * Number(child.getAttribute("fill-opacity") ?? 1),
        rule: (child.getAttribute("fill-rule") as CanvasFillRule | null) ?? inh.rule,
        clip: clipEl ? [...inh.clip, clipPath(clipEl, cm)] : inh.clip,
      };
      if (child.nodeName === "g") {
        const childLayer = (child.getAttribute("data-layer") as "back" | "front" | null) ?? layer;
        if (child.hasAttribute("data-swing") && !swing) {
          const [px, py] = nums(child.getAttribute("data-swing"));
          const parts: Part[] = [];
          walk(child, cm, style, childLayer, parts);
          (childLayer === "back" ? back : front).push({
            swing: true,
            key: swings++,
            pivot: { x: px, y: py },
            amp: Number(child.getAttribute("data-amp") ?? 1),
            parts,
          });
        } else {
          walk(child, cm, style, childLayer, swing);
        }
        continue;
      }
      const path = shapeOfElement(child);
      if (!path || style.fill === "none") continue;
      const gEl = style.fill.startsWith("url(") ? byId(style.fill) : null;
      const part: Part = {
        path,
        m: cm.isIdentity ? null : cm,
        fill: gEl ? gradient(gEl) : style.fill,
        opacity: style.opacity,
        rule: style.rule,
        clip: style.clip,
      };
      if (swing) swing.push(part);
      else (layer === "back" ? back : front).push({ swing: false, part });
    }
  };
  walk(root, new DOMMatrix(), { fill: "#000", opacity: 1, rule: "nonzero", clip: [] }, "front", null);

  const seatV = nums(root.getAttribute("data-seat"));

  return {
    id,
    name: root.getAttribute("data-name") || id,
    credit: root.getAttribute("data-credit"),
    back,
    front,
    swings,
    seat:
      seatV.length >= 3
        ? {
            x: seatV[0],
            y: seatV[1],
            half: seatV[2],
            yn: Number(root.getAttribute("data-seat-yn") ?? -0.8),
            fit: Number(root.getAttribute("data-fit") ?? 1),
          }
        : null,
    shadow: Number(root.getAttribute("data-shadow") ?? 1),
  };
}

interface Inherited {
  fill: string;
  opacity: number;
  rule: CanvasFillRule;
  clip: Path2D[];
}

function num(el: Element, name: string): number {
  return Number(el.getAttribute(name) ?? 0);
}

function shapeOfElement(el: Element): Path2D | null {
  const p = new Path2D();
  switch (el.nodeName) {
    case "path":
      return new Path2D(el.getAttribute("d") ?? "");
    case "circle":
      p.arc(num(el, "cx"), num(el, "cy"), num(el, "r"), 0, Math.PI * 2);
      return p;
    case "ellipse":
      p.ellipse(num(el, "cx"), num(el, "cy"), num(el, "rx"), num(el, "ry"), 0, 0, Math.PI * 2);
      return p;
    case "rect": {
      const rx = num(el, "rx") || num(el, "ry");
      p.roundRect(num(el, "x"), num(el, "y"), num(el, "width"), num(el, "height"), rx);
      return p;
    }
    default:
      return null;
  }
}

/** SVG transform lists: translate, rotate (with centre), scale, matrix. */
function parseTransform(src: string): DOMMatrix {
  let m = new DOMMatrix();
  for (const [, fn, args] of src.matchAll(/(\w+)\s*\(([^)]*)\)/g)) {
    const v = nums(args);
    switch (fn) {
      case "translate":
        m = m.translate(v[0], v[1] ?? 0);
        break;
      case "rotate":
        m = v.length >= 3 ? m.translate(v[1], v[2]).rotate(v[0]).translate(-v[1], -v[2]) : m.rotate(v[0]);
        break;
      case "scale":
        m = m.scale(v[0], v[1] ?? v[0]);
        break;
      case "matrix":
        m = m.multiply(new DOMMatrix(v));
        break;
    }
  }
  return m;
}
