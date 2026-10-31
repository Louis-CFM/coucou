// Skins: Mochi's outfits as data files, so they can be swapped at
// run time and survive an update of the built-in wardrobe.
//
// A skin is a small JSON file: an id, a name, and shapes placed with short
// formulas around Mochi's head (R, rx, ry, xs, xShift… see `headVars`). Two
// places feed the wardrobe: the skins shipped in ./skin-files (kept in the
// repository), and the user's own folder (<config>/skins/*.json), read again
// whenever the wardrobe opens — drop a file there and it shows up.
//
// A stored choice is "skin:<id>". If that file is gone, the preference reads as
// "auto" (wardrobe.ts), exactly like any outfit this build does not know.
//
// Formulas are a tiny arithmetic language parsed here — never eval — and every
// number, colour and count of a file is checked, so a broken or hostile file can
// at worst be refused.

import { language } from "../i18n/i18n";
import { Ease } from "../core/anim";
import { BUNDLED_SKINS } from "./skin-files/index";

export const SKIN_PREFIX = "skin:";

type Ctx = CanvasRenderingContext2D;

/** What the engine tells every outfit about the head (see outfits.ts `Head`). */
export interface SkinHead {
  R: number;
  rx: number;
  ry: number;
  yaw: number;
  /** How far the head looks up or down (radians); the eyes follow it, and so do the shapes marked `follow`. */
  pitch?: number;
}

export interface SkinState {
  /** 0 = gone, 1 = fully on. */
  presence: number;
  /** Mochi's mailbox morph: outfits fade away as he turns into a box. */
  morph: number;
}

// ── Formulas ──────────────────────────────────────────────────────────────────

type Env = Readonly<Record<string, number>>;
type Formula = (env: Env) => number;

/** Mochi's head is a superellipse with this exponent (outfits.ts: EXP). */
const HEAD_EXP = 2.7;

const FUNCTIONS: Record<string, (...a: number[]) => number> = {
  sin: Math.sin, cos: Math.cos, abs: Math.abs, floor: Math.floor, round: Math.round,
  min: Math.min, max: Math.max, sqrt: Math.sqrt, pow: Math.pow,
  // head(u): how high Mochi's head reaches at a fraction u of its half width
  // (u = 0 the middle: 1, u = ±1 the sides: 0). Multiply by ry for the silhouette.
  head: (u = 0) => Math.pow(Math.max(0, 1 - Math.pow(Math.min(1, Math.abs(u)), HEAD_EXP)), 1 / HEAD_EXP),
};

const MAX_FORMULA = 200;
const compiled = new Map<string, Formula>();

/** Arithmetic with + - * / ( ), numbers, variables and the functions above. */
export function compileFormula(source: string): Formula {
  const cached = compiled.get(source);
  if (cached) return cached;
  if (source.length > MAX_FORMULA) throw new Error("formula too long");
  const tokens = source.match(/\d+\.?\d*|\.\d+|[A-Za-z_]\w*|[-+*/(),]|\S/g) ?? [];
  let pos = 0;
  const peek = () => tokens[pos];
  const take = (want?: string) => {
    const t = tokens[pos++];
    if (want !== undefined && t !== want) throw new Error(`expected ${want}`);
    return t;
  };

  function expression(): Formula {
    let left = term();
    while (peek() === "+" || peek() === "-") {
      const op = take();
      const l = left;
      const r = term();
      left = op === "+" ? (e) => l(e) + r(e) : (e) => l(e) - r(e);
    }
    return left;
  }
  function term(): Formula {
    let left = unary();
    while (peek() === "*" || peek() === "/") {
      const op = take();
      const l = left;
      const r = unary();
      left = op === "*" ? (e) => l(e) * r(e) : (e) => l(e) / r(e);
    }
    return left;
  }
  function unary(): Formula {
    if (peek() === "-") {
      take();
      const inner = unary();
      return (e) => -inner(e);
    }
    return primary();
  }
  function primary(): Formula {
    const t = take();
    if (t === undefined) throw new Error("unexpected end");
    if (t === "(") {
      const inner = expression();
      take(")");
      return inner;
    }
    if (/^[\d.]/.test(t)) {
      const n = Number(t);
      if (!Number.isFinite(n)) throw new Error(`bad number ${t}`);
      return () => n;
    }
    if (/^[A-Za-z_]/.test(t)) {
      if (peek() === "(") {
        const fn = FUNCTIONS[t];
        if (!fn) throw new Error(`unknown function ${t}`);
        take("(");
        const args: Formula[] = [];
        if (peek() !== ")") {
          args.push(expression());
          while (peek() === ",") {
            take();
            args.push(expression());
          }
        }
        take(")");
        return (e) => fn(...args.map((a) => a(e)));
      }
      return (e) => {
        // Own numbers only: `constructor` and the like live on every object.
        const v = Object.prototype.hasOwnProperty.call(e, t) ? e[t] : undefined;
        if (typeof v !== "number") throw new Error(`unknown variable ${t}`);
        return v;
      };
    }
    throw new Error(`unexpected ${t}`);
  }

  const out = expression();
  if (pos < tokens.length) throw new Error(`unexpected ${tokens[pos]}`);
  compiled.set(source, out);
  return out;
}

/** A number or a formula. */
type Num = number | string;

function num(value: Num | undefined, env: Env, fallback = 0): number {
  if (value === undefined) return fallback;
  const n = typeof value === "number" ? value : compileFormula(value)(env);
  return Number.isFinite(n) ? n : fallback;
}

// ── The file format ───────────────────────────────────────────────────────────

const COLOR = /^(?:#[0-9a-f]{3,8}|rgba?\(\s*[\d.]+\s*(?:,\s*[\d.]+\s*){2,3}\))$/i;

export type Fill = string | { gradient: [string, string]; from: [Num, Num]; to: [Num, Num] };
/** "body" sits on the body, under the eyes, clipped to its outline (a fruit's stripes, a robot's panels). */
export type Layer = "front" | "behind" | "body";

interface ShapeBase {
  /** Drawn only while this formula is above 0: a detail that goes behind the head when it turns. */
  when?: Num;
  fill?: Fill;
  stroke?: string;
  lineWidth?: Num;
  layer?: Layer;
  /** A feature of the face (a nose, a screen): it moves with the eyes when Mochi looks up or down. */
  follow?: boolean;
  /** Kept inside Mochi's outline: a muzzle or a screen that slides must not stick out of the body. */
  clip?: boolean;
}
export type Shape =
  | (ShapeBase & { type: "rect"; x: Num; y: Num; w: Num; h: Num; r?: Num })
  | (ShapeBase & { type: "ellipse"; x: Num; y: Num; w: Num; h: Num })
  | (ShapeBase & { type: "dome"; cx: Num; cy: Num; r: Num; base: Num })
  | (ShapeBase & { type: "heart"; x: Num; y: Num; size: Num })
  | (ShapeBase & { type: "poly"; points: [Num, Num][] })
  // The area between two curves, over u from `from` (-1) to `to` (1): `x`, `top`
  // and `bottom` are formulas of u. This is how a skin follows the head.
  | (ShapeBase & { type: "band"; x: Num; top: Num; bottom: Num; from?: Num; to?: Num; steps?: number })
  // A ribbon down the head's surface at longitude `lon` (radians, 0 faces front) and
  // angular `width`, from height `from` to `to` (-1 top … 1 bottom): a melon's stripe.
  | (ShapeBase & { type: "meridian"; lon: Num; width: Num; from?: Num; to?: Num; steps?: number })
  // `vars` are evaluated for each repetition, after `as` (default "i") is set.
  | { type: "repeat"; count: Num; every?: number; as?: string; vars?: [string, Num][]; shapes: Shape[] };

export interface Skin {
  id: string;
  name: string;
  /** Names in other languages, by language code ("it", "pt-BR"…). */
  names: Record<string, string>;
  /** Hats drop onto the head when put on; "face" things just fade in. */
  kind: "hat" | "face";
  layer: Layer;
  /** Recolours the character's body (top-right, bottom-left), as the pumpkin does. */
  body: [string, string] | null;
  /** The colour of the halo behind Mochi while he wears it (else the colour of his state). */
  glow: string | null;
  /** How far Mochi's eyes may travel up and down while he wears it, 0.1 to 1 (a face feature or a scarf leaves little room). */
  lookRange: number;
  /** Named formulas, evaluated in order, usable by the shapes below them. */
  vars: [string, Num][];
  shapes: Shape[];
}

const MAX_SHAPES = 120;
const MAX_REPEAT = 60;

function isNum(v: unknown): v is Num {
  return (typeof v === "number" && Number.isFinite(v)) || (typeof v === "string" && v.length <= MAX_FORMULA);
}

function checkFormula(v: unknown, what: string): Num {
  if (!isNum(v)) throw new Error(`${what}: not a number or a formula`);
  if (typeof v === "string") compileFormula(v); // throws when it does not parse
  return v;
}

function checkColor(v: unknown, what: string): string {
  if (typeof v !== "string" || !COLOR.test(v)) throw new Error(`${what}: not a colour`);
  return v;
}

function checkFill(v: unknown): Fill {
  if (typeof v === "string") return checkColor(v, "fill");
  const g = v as { gradient?: unknown; from?: unknown; to?: unknown } | null;
  if (!g || !Array.isArray(g.gradient) || g.gradient.length !== 2) throw new Error("fill: a colour or a gradient");
  const point = (p: unknown, what: string): [Num, Num] => {
    if (!Array.isArray(p) || p.length !== 2) throw new Error(`${what}: [x, y]`);
    return [checkFormula(p[0], what), checkFormula(p[1], what)];
  };
  return {
    gradient: [checkColor(g.gradient[0], "gradient"), checkColor(g.gradient[1], "gradient")],
    from: point(g.from, "gradient.from"),
    to: point(g.to, "gradient.to"),
  };
}

let shapeCount = 0;

function checkShape(raw: unknown): Shape {
  if (++shapeCount > MAX_SHAPES) throw new Error("too many shapes");
  const s = raw as Record<string, unknown> | null;
  if (!s || typeof s !== "object") throw new Error("shape: an object");
  if (s.type === "repeat") {
    if (!Array.isArray(s.shapes)) throw new Error("repeat: shapes");
    return {
      type: "repeat",
      count: checkFormula(s.count, "repeat.count"),
      every: typeof s.every === "number" && s.every >= 1 ? Math.floor(s.every) : undefined,
      as: typeof s.as === "string" && /^[A-Za-z_]\w*$/.test(s.as) ? s.as : "i",
      vars: Object.entries((s.vars ?? {}) as Record<string, unknown>).map(([name, value]): [string, Num] => {
        if (!/^[A-Za-z_]\w*$/.test(name)) throw new Error("repeat.vars: a name");
        return [name, checkFormula(value, `repeat.vars.${name}`)];
      }),
      shapes: s.shapes.map(checkShape),
    };
  }
  const base: ShapeBase = {};
  if (s.when !== undefined) base.when = checkFormula(s.when, "when");
  if (s.fill !== undefined) base.fill = checkFill(s.fill);
  if (s.stroke !== undefined) base.stroke = checkColor(s.stroke, "stroke");
  if (s.lineWidth !== undefined) base.lineWidth = checkFormula(s.lineWidth, "lineWidth");
  if (s.layer === "front" || s.layer === "behind" || s.layer === "body") base.layer = s.layer;
  if (s.follow === true) base.follow = true;
  if (s.clip === true) base.clip = true;
  const f = (k: string) => checkFormula(s[k], `${String(s.type)}.${k}`);
  switch (s.type) {
    case "rect":
      return { ...base, type: "rect", x: f("x"), y: f("y"), w: f("w"), h: f("h"), r: s.r === undefined ? undefined : f("r") };
    case "ellipse":
      return { ...base, type: "ellipse", x: f("x"), y: f("y"), w: f("w"), h: f("h") };
    case "dome":
      return { ...base, type: "dome", cx: f("cx"), cy: f("cy"), r: f("r"), base: f("base") };
    case "heart":
      return { ...base, type: "heart", x: f("x"), y: f("y"), size: f("size") };
    case "band":
      return {
        ...base, type: "band", x: f("x"), top: f("top"), bottom: f("bottom"),
        from: s.from === undefined ? undefined : f("from"),
        to: s.to === undefined ? undefined : f("to"),
        steps: typeof s.steps === "number" ? Math.max(4, Math.min(48, Math.floor(s.steps))) : undefined,
      };
    case "meridian":
      return {
        ...base, type: "meridian", lon: f("lon"), width: f("width"),
        from: s.from === undefined ? undefined : f("from"),
        to: s.to === undefined ? undefined : f("to"),
        steps: typeof s.steps === "number" ? Math.max(4, Math.min(40, Math.floor(s.steps))) : undefined,
      };
    case "poly": {
      if (!Array.isArray(s.points) || s.points.length < 3 || s.points.length > 40) throw new Error("poly: 3 to 40 points");
      const points = s.points.map((p): [Num, Num] => {
        if (!Array.isArray(p) || p.length !== 2) throw new Error("poly: [x, y]");
        return [checkFormula(p[0], "poly.x"), checkFormula(p[1], "poly.y")];
      });
      return { ...base, type: "poly", points };
    }
    default:
      throw new Error(`unknown shape ${String(s.type)}`);
  }
}

/** A file's content → a skin, or null when it is not a usable one. */
export function parseSkin(raw: unknown): Skin | null {
  try {
    const s = raw as Record<string, unknown> | null;
    if (!s || typeof s !== "object") return null;
    const id = s.id;
    if (typeof id !== "string" || !/^[A-Za-z0-9_-]{1,40}$/.test(id)) return null;
    if (typeof s.name !== "string" || s.name.length === 0 || s.name.length > 40) return null;
    if (!Array.isArray(s.shapes)) return null;
    shapeCount = 0;
    const vars: [string, Num][] = [];
    for (const [name, value] of Object.entries((s.vars ?? {}) as Record<string, unknown>)) {
      if (!/^[A-Za-z_]\w*$/.test(name)) return null;
      vars.push([name, checkFormula(value, `vars.${name}`)]);
    }
    const names: Record<string, string> = {};
    for (const [lang, text] of Object.entries((s.names ?? {}) as Record<string, unknown>)) {
      if (typeof text === "string" && text.length > 0 && text.length <= 40) names[lang] = text;
    }
    return {
      id,
      name: s.name,
      names,
      kind: s.kind === "face" ? "face" : "hat",
      layer: s.layer === "behind" ? "behind" : "front",
      body: Array.isArray(s.body) && s.body.length === 2
        ? [checkColor(s.body[0], "body"), checkColor(s.body[1], "body")]
        : null,
      glow: s.glow === undefined ? null : checkColor(s.glow, "glow"),
      lookRange: typeof s.lookRange === "number" && Number.isFinite(s.lookRange) ? Math.min(1, Math.max(0.1, s.lookRange)) : 1,
      vars,
      shapes: s.shapes.map(checkShape),
    };
  } catch {
    return null;
  }
}

// ── The collection ────────────────────────────────────────────────────────────

const bundled = new Map<string, Skin>();
let user = new Map<string, Skin>();
const listeners = new Set<() => void>();

function skinsFrom(list: readonly unknown[]): Map<string, Skin> {
  const out = new Map<string, Skin>();
  for (const raw of list) {
    const skin = parseSkin(raw);
    if (skin) out.set(skin.id, skin);
  }
  return out;
}

for (const [id, skin] of skinsFrom(BUNDLED_SKINS)) bundled.set(id, skin);

/** Replaces the skins read from the user's folder, and tells whoever listens. */
export function setUserSkins(list: readonly unknown[]): void {
  const next = skinsFrom(list);
  const same = next.size === user.size && [...next.keys()].every((id) => user.has(id));
  user = next;
  if (!same) for (const fn of [...listeners]) fn();
}

export function onSkinsChange(fn: () => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export function isSkinSelection(raw: unknown): boolean {
  return typeof raw === "string" && raw.startsWith(SKIN_PREFIX) && skinFor(raw) !== undefined;
}

/** The skin behind an outfit value ("skin:<id>"), if there is one right now. */
export function skinFor(outfit: string): Skin | undefined {
  if (!outfit.startsWith(SKIN_PREFIX)) return undefined;
  const id = outfit.slice(SKIN_PREFIX.length);
  return user.get(id) ?? bundled.get(id); // a file of the user's wins over a shipped one
}

/** The body colours a skin gives the character, if it changes them. */
export function skinBody(outfit: string): [string, string] | null {
  return skinFor(outfit)?.body ?? null;
}

/** Every skin offered in the wardrobe, as stored values, in a stable order. */
export function skinSelections(): string[] {
  const ids = new Set([...bundled.keys(), ...user.keys()]);
  return [...ids].sort().map((id) => SKIN_PREFIX + id);
}

export function skinLabel(selection: string): string {
  const skin = skinFor(selection);
  return skin ? (skin.names[language()] ?? skin.name) : selection;
}

// ── Drawing ───────────────────────────────────────────────────────────────────

/**
 * Below this radius Mochi is a dot (hidden, 6 px across) and is not dressed. The
 * compact pill has R ≈ 10 and the wardrobe icons R = 10: a skin must show there
 * too, as the built-in outfits do (they only simplify their details when small).
 */
const MIN_R = 5;

/** The variables every formula can use. */
function headVars(H: SkinHead): Record<string, number> {
  return {
    R: H.R, rx: H.rx, ry: H.ry, yaw: H.yaw, pitch: H.pitch ?? 0,
    xs: Math.cos(H.yaw), // foreshortening as the head turns
    xShift: Math.sin(H.yaw) * H.rx * 0.28, // a hat follows the turn of the head
    dir: H.yaw >= 0 ? 1 : -1, // which way the face looks
  };
}

function fillStyle(ctx: Ctx, fill: Fill, env: Env): string | CanvasGradient {
  if (typeof fill === "string") return fill;
  const g = ctx.createLinearGradient(
    num(fill.from[0], env), num(fill.from[1], env), num(fill.to[0], env), num(fill.to[1], env),
  );
  g.addColorStop(0, fill.gradient[0]);
  g.addColorStop(1, fill.gradient[1]);
  return g;
}

function heart(ctx: Ctx, x: number, y: number, s: number) {
  ctx.save();
  ctx.translate(x, y);
  ctx.beginPath();
  ctx.moveTo(0, s * 0.38);
  ctx.bezierCurveTo(-s * 1.05, -s * 0.15, -s * 0.5, -s * 0.95, 0, -s * 0.38);
  ctx.bezierCurveTo(s * 0.5, -s * 0.95, s * 1.05, -s * 0.15, 0, s * 0.38);
  ctx.closePath();
}

function drawShapes(ctx: Ctx, shapes: readonly Shape[], env: Env, layer: Layer, skinLayer: Layer) {
  for (const shape of shapes) {
    if (shape.type === "repeat") {
      const count = Math.max(0, Math.min(MAX_REPEAT, Math.floor(num(shape.count, env))));
      for (let i = 0; i < count; i++) {
        if (shape.every && i % shape.every !== 0) continue;
        const inner: Record<string, number> = { ...env, [shape.as ?? "i"]: i };
        for (const [name, value] of shape.vars ?? []) inner[name] = num(value, inner);
        drawShapes(ctx, shape.shapes, inner, layer, skinLayer);
      }
      continue;
    }
    if ((shape.layer ?? skinLayer) !== layer) continue;
    if (shape.when !== undefined && num(shape.when, env, 0) <= 0) continue;
    let restore = false;
    const onBody = layer === "body";
    const clipped = onBody || shape.clip === true;
    if (clipped || shape.follow) ctx.save();
    if (clipped) clipToBody(ctx, env);
    if (shape.follow) followEyes(ctx, env);
    ctx.beginPath();
    switch (shape.type) {
      case "rect": {
        const [x, y, w, h] = [num(shape.x, env), num(shape.y, env), num(shape.w, env), num(shape.h, env)];
        const r = Math.max(0, num(shape.r, env));
        if (r > 0 && typeof ctx.roundRect === "function") ctx.roundRect(x, y, w, h, r);
        else ctx.rect(x, y, w, h);
        break;
      }
      case "ellipse": {
        const [x, y, w, h] = [num(shape.x, env), num(shape.y, env), num(shape.w, env), num(shape.h, env)];
        ctx.ellipse(x + w / 2, y + h / 2, Math.abs(w / 2), Math.abs(h / 2), 0, 0, Math.PI * 2);
        break;
      }
      case "dome": {
        const [cx, cy, r, base] = [num(shape.cx, env), num(shape.cy, env), num(shape.r, env), num(shape.base, env)];
        ctx.arc(cx, cy, Math.abs(r), Math.PI, 0, false);
        ctx.lineTo(cx + r, base);
        ctx.lineTo(cx - r, base);
        ctx.closePath();
        break;
      }
      case "heart":
        heart(ctx, num(shape.x, env), num(shape.y, env), num(shape.size, env));
        restore = true;
        break;
      case "band": {
        const steps = shape.steps ?? 24;
        const [from, to] = [num(shape.from, env, -1), num(shape.to, env, 1)];
        const at = (i: number) => from + ((to - from) * i) / steps;
        const e: Record<string, number> = { ...env };
        for (let i = 0; i <= steps; i++) {
          e.u = at(i);
          const [x, y] = [num(shape.x, e), num(shape.top, e)];
          if (i === 0) ctx.moveTo(x, y);
          else ctx.lineTo(x, y);
        }
        for (let i = steps; i >= 0; i--) {
          e.u = at(i);
          ctx.lineTo(num(shape.x, e), num(shape.bottom, e));
        }
        ctx.closePath();
        break;
      }
      case "meridian": {
        const lon = num(shape.lon, env);
        if (Math.cos(lon + env.yaw) < -0.05) break; // round the back
        const w = Math.abs(num(shape.width, env, 0.1));
        const [from, to] = [num(shape.from, env, -0.97), num(shape.to, env, 0.97)];
        const steps = shape.steps ?? 16;
        const edge = (a: number, v: number): [number, number] => {
          const th = Math.max(-Math.PI / 2, Math.min(Math.PI / 2, a + env.yaw)); // folded at the limb
          const ring = Math.pow(1 - Math.pow(Math.min(1, Math.abs(v)), 2.7), 1 / 2.7);
          return [env.rx * ring * Math.sin(th), env.ry * v];
        };
        for (let i = 0; i <= steps; i++) {
          const [x, y] = edge(lon - w, from + ((to - from) * i) / steps);
          if (i === 0) ctx.moveTo(x, y);
          else ctx.lineTo(x, y);
        }
        for (let i = steps; i >= 0; i--) {
          const [x, y] = edge(lon + w, from + ((to - from) * i) / steps);
          ctx.lineTo(x, y);
        }
        ctx.closePath();
        break;
      }
      case "poly": {
        shape.points.forEach(([px, py], i) => {
          const [x, y] = [num(px, env), num(py, env)];
          if (i === 0) ctx.moveTo(x, y);
          else ctx.lineTo(x, y);
        });
        ctx.closePath();
        break;
      }
    }
    if (shape.fill !== undefined) {
      ctx.fillStyle = fillStyle(ctx, shape.fill, env);
      ctx.fill();
    }
    if (shape.stroke !== undefined) {
      ctx.strokeStyle = shape.stroke;
      ctx.lineWidth = num(shape.lineWidth, env, 1);
      ctx.stroke();
    }
    if (restore) ctx.restore();
    if (clipped || shape.follow) ctx.restore();
  }
}

/** Where the engine puts the eyes at rest (engine.ts EYE_P): a feature follows them from there. */
const EYE_REST_PITCH = -0.12;

/**
 * Moves the drawing with the eyes: when Mochi looks up or down the eyes slide over the
 * face (engine.ts drawEyes), so a nose or a screen drawn at a fixed place would end up
 * over them. The same shift, and the same narrowing at the extremes, keep every feature
 * where it is relative to the eyes.
 */
function followEyes(ctx: Ctx, env: Env) {
  const eyePitch = EYE_REST_PITCH + env.pitch;
  const dy = -env.ry * Math.sin(eyePitch) - env.ry * Math.sin(-EYE_REST_PITCH);
  const sx = Math.max(0.18, Math.cos(eyePitch)) / Math.cos(EYE_REST_PITCH);
  ctx.translate(0, dy);
  ctx.scale(sx, 1);
}

/** Mochi's silhouette, |x/rx|^2.7 + |y/ry|^2.7 = 1, as the clip of the "body" layer. */
function clipToBody(ctx: Ctx, env: Env) {
  const [rx, ry] = [env.rx, env.ry];
  ctx.beginPath();
  for (let i = 0; i <= 64; i++) {
    const a = (i / 64) * Math.PI * 2;
    const c = Math.cos(a);
    const s = Math.sin(a);
    const x = rx * Math.sign(c) * Math.pow(Math.abs(c), 2 / 2.7);
    const y = ry * Math.sign(s) * Math.pow(Math.abs(s), 2 / 2.7);
    if (i === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  }
  ctx.closePath();
  ctx.clip();
}

/** Draws one layer of `skin` in body space (the origin is the body's centre). */
export function drawSkin(ctx: Ctx, skin: Skin, H: SkinHead, st: SkinState, layer: Layer): void {
  if (H.R < MIN_R) return;
  const morphFade = 1 - Math.min(1, Math.max(0, (st.morph - 0.3) / 0.2));
  const alpha = morphFade * Math.min(1, st.presence * 2.5);
  if (alpha <= 0.005) return;

  const env: Record<string, number> = headVars(H);
  try {
    for (const [name, value] of skin.vars) env[name] = num(value, env);
  } catch {
    return; // a formula that cannot be computed draws nothing rather than throwing every frame
  }

  ctx.save();
  if (skin.kind === "hat") {
    // The same drop-in as the built-in hats.
    const posP = Ease.back(st.presence);
    const hatScale = 0.85 + 0.15 * posP;
    ctx.translate(0, -(1 - posP) * H.ry);
    ctx.scale(hatScale, hatScale);
  } else if (layer !== "body") {
    ctx.translate(0, (1 - st.presence) * 0.25 * H.ry);
  }
  ctx.globalAlpha *= alpha;
  try {
    drawShapes(ctx, skin.shapes, env, layer, skin.layer);
  } catch {
    /* an unknown variable in a shape: skip the frame */
  }
  ctx.restore();
}

/** A little Mochi wearing the skin, for the wardrobe's buttons. */
export function drawSkinIcon(ctx: Ctx, size: number, skin: Skin): void {
  ctx.clearRect(0, 0, size, size);
  const R = size * 0.32; // big; the wardrobe shrinks any picture that then sticks out
  const H: SkinHead = { R, rx: R * 1.14, ry: R * 0.88, yaw: 0 };
  const st: SkinState = { presence: 1, morph: 0 };
  ctx.save();
  ctx.translate(size / 2, size * 0.60);
  drawSkin(ctx, skin, H, st, "behind");
  const body = ctx.createLinearGradient(H.rx * 0.7, -H.ry * 0.85, -H.rx * 0.8, H.ry * 0.9);
  body.addColorStop(0, skin.body?.[0] ?? "rgb(237,237,239)");
  body.addColorStop(1, skin.body?.[1] ?? "rgb(196,197,202)");
  ctx.fillStyle = body;
  ctx.beginPath();
  ctx.ellipse(0, 0, H.rx, H.ry, 0, 0, Math.PI * 2);
  ctx.fill();
  drawSkin(ctx, skin, H, st, "body");
  ctx.fillStyle = "rgb(26,20,18)";
  for (const side of [-1, 1]) {
    ctx.beginPath();
    ctx.ellipse(side * H.rx * 0.37, H.ry * 0.12, R * 0.12, R * 0.17, 0, 0, Math.PI * 2);
    ctx.fill();
  }
  drawSkin(ctx, skin, H, st, "front");
  ctx.restore();
}
