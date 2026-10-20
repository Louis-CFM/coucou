// The coloured band on top of each page of the Coucou window: a deep black
// with the page's colour breathing in a corner, particles that drift all the
// time and move away from the pointer, and the page's little Mochis walking on
// its floor — they hop, look around, wave, and react when poked. Also the
// glowing cards and the Mochis of empty pages. Port of FlowHubMochis.swift.
//
// One animation loop draws every live canvas; it stops when none is left or
// the window is hidden, so a hidden window costs nothing, and skips the ones
// scrolled out of sight.

import { BotEngine, hexToRGB } from "../mochi/engine";
import { onScreen, shouldAnimate } from "./frames";
import type { BotEmoteName, BotStateName } from "../core/layout";
import type { Outfit } from "../mochi/wardrobe";

interface Animated {
  el: HTMLCanvasElement;
  draw(dt: number, t: number): void;
  /** Pages are built before they are put in the window: dropped only once gone. */
  shown?: boolean;
  born?: number;
}

const live = new Set<Animated>();
let frame: number | null = null;
let last = performance.now();
const start = performance.now();
/** The Coucou window is on screen, as Rust last said (`setWindowShown`). */
let windowShown = true;

function running(): boolean {
  return shouldAnimate(live.size, document.visibilityState, windowShown);
}

function loop(now: number) {
  frame = null;
  const dt = Math.min(0.05, (now - last) / 1000);
  last = now;
  const t = (now - start) / 1000;
  for (const a of live) {
    if (!a.el.isConnected) {
      // Built but not shown yet: wait for it (a few seconds at most).
      if (a.shown || now - (a.born ??= now) > 5000) live.delete(a);
      continue;
    }
    a.shown = true;
    if (onScreen(a.el.getBoundingClientRect(), window.innerWidth, window.innerHeight)) a.draw(dt, t);
  }
  if (running()) frame = requestAnimationFrame(loop);
}

function wake() {
  if (frame === null && running()) {
    last = performance.now();
    frame = requestAnimationFrame(loop);
  }
}

document.addEventListener("visibilitychange", wake);

/** The window was shown or hidden (the `hub-visible` event): hidden, the loop
 *  stops at once; shown, it starts again. */
export function setWindowShown(shown: boolean) {
  windowShown = shown;
  if (!shown && frame !== null) {
    cancelAnimationFrame(frame);
    frame = null;
  }
  wake();
}

function add(a: Animated) {
  live.add(a);
  wake();
}

function fit(canvas: HTMLCanvasElement): { w: number; h: number; ctx: CanvasRenderingContext2D | null } {
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  const w = canvas.clientWidth;
  const h = canvas.clientHeight;
  if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
  }
  const ctx = canvas.getContext("2d");
  ctx?.setTransform(dpr, 0, 0, dpr, 0, 0);
  return { w, h, ctx };
}

/** "r,g,b" of each colour, read once: the particles ask every frame. */
const channels = new Map<string, string>();

function rgba(hex: string, alpha: number): string {
  let rgb = channels.get(hex);
  if (rgb === undefined) {
    const [r, g, b] = hexToRGB(hex);
    rgb = `${Math.round(r * 255)},${Math.round(g * 255)},${Math.round(b * 255)}`;
    channels.set(hex, rgb);
  }
  return `rgba(${rgb},${Math.max(0, Math.min(1, alpha))})`;
}

// ── The backdrop ──────────────────────────────────────────────────────────────

interface Particle {
  x: number;
  y: number;
  vx: number;
  vy: number;
  r: number;
  depth: number;
  phase: number;
  white: boolean;
}

/** The deep black, the colour and the particles, on `canvas`; `pointerFrom` is
 *  the element whose pointer pushes the particles. */
export function backdrop(canvas: HTMLCanvasElement, color: string, pointerFrom: HTMLElement, radius = 18) {
  let particles: Particle[] = [];
  let pointer: { x: number; y: number } | null = null;
  let strength = 0;
  pointerFrom.addEventListener("pointermove", (e) => {
    const r = canvas.getBoundingClientRect();
    pointer = { x: e.clientX - r.left, y: e.clientY - r.top };
  });
  pointerFrom.addEventListener("pointerleave", () => (pointer = null));

  const seed = (w: number, h: number) => {
    const count = Math.round(Math.min(90, Math.max(24, (w * h) / 2600)));
    particles = Array.from({ length: count }, () => ({
      x: Math.random() * w,
      y: Math.random() * h,
      vx: (Math.random() - 0.5) * 6,
      vy: -2 - Math.random() * 6,
      r: 0.5 + Math.random() * 1.4,
      depth: 0.35 + Math.random() * 0.65,
      phase: Math.random() * Math.PI * 2,
      white: Math.random() < 0.35,
    }));
  };

  add({
    el: canvas,
    draw(dt, t) {
      const { w, h, ctx } = fit(canvas);
      if (!ctx || w === 0) return;
      if (particles.length === 0) seed(w, h);
      strength += ((pointer ? 1 : 0) - strength) * Math.min(1, dt * 4);
      ctx.clearRect(0, 0, w, h);
      ctx.save();
      ctx.beginPath();
      ctx.roundRect(0, 0, w, h, radius);
      ctx.clip();
      ctx.fillStyle = "#020203";
      ctx.fillRect(0, 0, w, h);
      const lin = ctx.createLinearGradient(w, 0, w * 0.35, h);
      lin.addColorStop(0, rgba(color, 0.1));
      lin.addColorStop(1, "rgba(0,0,0,0)");
      ctx.fillStyle = lin;
      ctx.fillRect(0, 0, w, h);
      const breath = 0.85 + 0.15 * Math.sin(t * 0.9);
      const rad = ctx.createRadialGradient(w * 0.92, -h * 0.15, 0, w * 0.92, -h * 0.15, Math.max(w, h) * 0.55 * breath);
      rad.addColorStop(0, rgba(color, 0.3 * breath));
      rad.addColorStop(0.5, rgba(color, 0.08));
      rad.addColorStop(1, "rgba(0,0,0,0)");
      ctx.fillStyle = rad;
      ctx.fillRect(0, 0, w, h);

      for (const p of particles) {
        // Drift, always; the pointer pushes them away.
        p.x += p.vx * dt * p.depth;
        p.y += p.vy * dt * p.depth;
        let alpha = (0.22 + 0.5 * (0.5 + 0.5 * Math.sin(t * (1.2 + p.depth) + p.phase))) * p.depth;
        let r = p.r;
        if (pointer && strength > 0.01) {
          const dx = p.x - pointer.x;
          const dy = p.y - pointer.y;
          const d = Math.hypot(dx, dy);
          if (d < 140 && d > 0.1) {
            const push = (1 - d / 140) * 90 * strength * dt;
            p.x += (dx / d) * push;
            p.y += (dy / d) * push;
          }
          if (d < 200) {
            const near = (1 - d / 200) * strength;
            alpha += near * 0.6;
            r *= 1 + near * 0.8;
          }
        }
        if (p.y < -4) p.y = h + 4;
        if (p.y > h + 4) p.y = -4;
        if (p.x < -4) p.x = w + 4;
        if (p.x > w + 4) p.x = -4;
        const tint = p.white ? "#FFFFFF" : color;
        if (r > 1.1) {
          ctx.fillStyle = rgba(tint, Math.min(1, alpha) * 0.12);
          ctx.beginPath();
          ctx.arc(p.x, p.y, r * 2.6, 0, Math.PI * 2);
          ctx.fill();
        }
        ctx.fillStyle = rgba(tint, Math.min(1, alpha));
        ctx.beginPath();
        ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.restore();
    },
  });
}

// ── The Mochis ────────────────────────────────────────────────────────────────

export interface MochiSpec {
  color: string;
  /** Body width in CSS pixels. */
  size: number;
  /** Where he starts along the floor, 0…1. */
  start: number;
  outfit?: Outfit;
  state?: BotStateName;
  /** False: he stays where he is (working, thinking, asleep). */
  roams?: boolean;
}

const EMOTES: BotEmoteName[] = ["love", "happy", "wink", "proud", "surprised"];

class Walker {
  engine = new BotEngine();
  x = 0;
  target = 0;
  dir = 1;
  hop = 0;
  hopV = 0;
  pause = 1 + Math.random() * 2;
  nextEvent = 2 + Math.random() * 4;
  waving = 0;

  constructor(public spec: MochiSpec) {
    this.engine.bodyColor = hexToRGB(spec.color);
    this.engine.setState(spec.state ?? "idle", true);
    if (spec.outfit && spec.outfit !== "none") this.engine.setOutfit(spec.outfit, false);
  }
}

/** The page's Mochis on the band's floor, in the right part of `canvas`. */
export function troupe(canvas: HTMLCanvasElement, cast: MochiSpec[], width: number) {
  const walkers = cast.map((spec) => new Walker(spec));
  let pointer: { x: number; y: number } | null = null;
  let placed = false;
  canvas.addEventListener("pointermove", (e) => {
    const r = canvas.getBoundingClientRect();
    pointer = { x: e.clientX - r.left, y: e.clientY - r.top };
  });
  canvas.addEventListener("pointerleave", () => (pointer = null));
  canvas.addEventListener("click", (e) => {
    const r = canvas.getBoundingClientRect();
    const px = e.clientX - r.left;
    for (const w of walkers) {
      if (Math.abs(px - w.x) < w.spec.size * 0.4) {
        w.engine.slap();
        w.hopV = 260;
      }
    }
  });

  add({
    el: canvas,
    draw(dt, t) {
      const { w: cw, h: ch, ctx } = fit(canvas);
      if (!ctx || cw === 0) return;
      const left = Math.max(0, cw - width - 18);
      const right = cw - 18;
      if (!placed) {
        placed = true;
        for (const w of walkers) {
          w.x = left + w.spec.size / 2 + (right - left - w.spec.size) * w.spec.start;
          w.target = w.x;
        }
      }
      ctx.clearRect(0, 0, cw, ch);
      for (const w of walkers) {
        const s = w.spec.size;
        const lo = left + s / 2;
        const hi = right - s / 2;
        if (w.spec.roams !== false) {
          if (Math.abs(w.target - w.x) < 1) {
            w.pause -= dt;
            if (w.pause <= 0) {
              w.target = lo + Math.random() * Math.max(1, hi - lo);
              w.pause = 1.5 + Math.random() * 3.5;
            }
          } else {
            const step = Math.sign(w.target - w.x) * Math.min(Math.abs(w.target - w.x), 28 * dt);
            w.x += step;
            w.dir = Math.sign(step) || w.dir;
            // A little bounce in the walk.
            if (w.hop === 0 && w.hopV === 0) w.hopV = 70;
          }
        }
        w.nextEvent -= dt;
        if (w.nextEvent <= 0) {
          w.nextEvent = 4 + Math.random() * 6;
          const roll = Math.random();
          if (roll < 0.35) w.hopV = 200;
          else if (roll < 0.6) w.engine.triggerEmote(EMOTES[Math.floor(Math.random() * EMOTES.length)]);
          else if (roll < 0.75) w.engine.greet();
        }
        // Hops: a simple ballistic jump.
        if (w.hopV !== 0 || w.hop > 0) {
          w.hopV -= 900 * dt;
          w.hop = Math.max(0, w.hop + w.hopV * dt);
          if (w.hop === 0 && w.hopV < 0) {
            w.hopV = 0;
            w.engine.squash();
          }
        }
        // Eyes: the pointer when it is over the band, else where they walk.
        if (pointer) {
          w.engine.lookX = Math.max(-1, Math.min(1, (pointer.x - w.x) / 160));
          w.engine.lookY = Math.max(-1, Math.min(1, (pointer.y - (ch - s * 0.6)) / 120));
        } else {
          w.engine.lookX = w.dir * 0.5;
          w.engine.lookY = 0.1 + 0.1 * Math.sin(t + w.spec.start * 7);
        }
        w.engine.update(dt);
        // `size` is the drawing's square, as on the Mac; the body is about 0.68 of it.
        const box = s;
        const floor = ch - 8;
        ctx.save();
        ctx.translate(w.x - box / 2, floor - box * 0.78 - w.hop);
        // A soft shadow on the floor.
        ctx.fillStyle = `rgba(0,0,0,${0.35 * (1 - Math.min(1, w.hop / 60))})`;
        ctx.beginPath();
        ctx.ellipse(box / 2, box * 0.78 + w.hop - 1, s * 0.3, s * 0.05, 0, 0, Math.PI * 2);
        ctx.fill();
        w.engine.draw(ctx, box, box);
        ctx.restore();
      }
    },
  });
}

/** One Mochi alone (the sidebar's logo, an empty page). */
export function liveMochi(canvas: HTMLCanvasElement, color = "#F5F6F8", state: BotStateName = "idle") {
  const engine = new BotEngine();
  engine.bodyColor = hexToRGB(color);
  engine.setState(state, true);
  canvas.addEventListener("click", () => engine.slap());
  let mouse: { x: number; y: number } | null = null;
  window.addEventListener("pointermove", (e) => {
    const r = canvas.getBoundingClientRect();
    mouse = { x: e.clientX - (r.left + r.width / 2), y: e.clientY - (r.top + r.height / 2) };
  });
  add({
    el: canvas,
    draw(dt) {
      const { w, h, ctx } = fit(canvas);
      if (!ctx || w === 0) return;
      if (mouse) {
        engine.lookX = Math.max(-1, Math.min(1, mouse.x / 300));
        engine.lookY = Math.max(-1, Math.min(1, mouse.y / 300));
      }
      engine.update(dt);
      ctx.clearRect(0, 0, w, h);
      engine.draw(ctx, w, h);
    },
  });
  return engine;
}

// ── Page themes ───────────────────────────────────────────────────────────────

export interface Theme {
  color: string;
  cast: MochiSpec[];
}

const m = (color: string, size: number, start: number, extra: Partial<MochiSpec> = {}): MochiSpec => ({
  color, size, start, ...extra,
});

export const THEMES: Record<string, Theme> = {
  dictation: { color: "#FB923C", cast: [m("#F5F6F8", 66, 0.2), m("#FB923C", 52, 0.65), m("#F472B6", 44, 0.95, { outfit: "bow" })] },
  notes: { color: "#3B9EFF", cast: [m("#3B9EFF", 58, 0.1, { outfit: "roundGlasses" }), m("#34D399", 50, 0.5), m("#A78BFA", 46, 0.9)] },
  insights: { color: "#34D399", cast: [m("#F7B32B", 62, 0.3, { outfit: "crown" }), m("#34D399", 48, 0.75), m("#F5F6F8", 40, 1)] },
  dictionary: { color: "#A78BFA", cast: [m("#A78BFA", 60, 0.2, { outfit: "roundGlasses" }), m("#F5F6F8", 48, 0.8, { outfit: "beanie" })] },
  snippets: { color: "#F7B32B", cast: [m("#F7B32B", 56, 0.15, { state: "working" }), m("#FB923C", 46, 0.6), m("#F5F6F8", 40, 0.95)] },
  styles: { color: "#F472B6", cast: [m("#F472B6", 60, 0.25, { outfit: "sunglasses" }), m("#F5F6F8", 48, 0.7, { outfit: "bow" }), m("#22D3EE", 42, 1, { outfit: "partyHat" })] },
  flowsettings: { color: "#8E939C", cast: [m("#F5F6F8", 56, 0.3), m("#8E939C", 46, 0.95, { state: "sleeping", roams: false })] },
  general: { color: "#8E939C", cast: [m("#F5F6F8", 60, 0.4, { outfit: "scarf" }), m("#FB923C", 46, 0.85)] },
  pills: {
    color: "#F5A524",
    cast: [m("#F5A524", 44, 0.05), m("#3B9EFF", 44, 0.3), m("#34D399", 44, 0.55), m("#E07950", 44, 0.8), m("#A78BFA", 44, 1)],
  },
  agents: {
    color: "#3B9EFF",
    cast: [m("#3B9EFF", 56, 0.1, { state: "working", roams: false }), m("#E07950", 50, 0.5, { state: "thinking", roams: false }), m("#34D399", 50, 0.9)],
  },
  chat: { color: "#E07950", cast: [m("#E07950", 58, 0.3, { state: "thinking", roams: false }), m("#F5F6F8", 48, 0.85)] },
  integrations: { color: "#7C5CFF", cast: [m("#7C5CFF", 54, 0.15), m("#22D3EE", 46, 0.55), m("#F7B32B", 42, 0.95)] },
  phone: { color: "#3DDC84", cast: [m("#3DDC84", 56, 0.25), m("#F5F6F8", 46, 0.8, { outfit: "beanie" })] },
  voice: { color: "#F97316", cast: [m("#F97316", 60, 0.3), m("#F5F6F8", 48, 0.85, { outfit: "roundGlasses" })] },
  shortcuts: { color: "#6366F1", cast: [m("#6366F1", 56, 0.2, { outfit: "sunglasses" }), m("#F5F6F8", 46, 0.8)] },
};

/** The band itself: title, line, actions, and the Mochis. */
export function hero(page: string, title: string, subtitle: string | null, actions: HTMLElement[] = [], compact = false): HTMLElement {
  const theme = THEMES[page] ?? THEMES.general;
  const el = document.createElement("div");
  el.className = compact ? "hub-hero compact" : "hub-hero";
  el.style.setProperty("--hero-line", rgba(theme.color, 0.16));
  const back = document.createElement("canvas");
  back.className = "backdrop";
  const mochis = document.createElement("canvas");
  mochis.className = "troupe";
  const copy = document.createElement("div");
  copy.className = "copy";
  const h1 = document.createElement("h1");
  h1.textContent = title;
  copy.append(h1);
  if (subtitle) {
    const p = document.createElement("p");
    p.textContent = subtitle;
    copy.append(p);
  }
  if (actions.length) {
    const row = document.createElement("div");
    row.className = "actions";
    row.append(...actions);
    copy.append(row);
  }
  el.append(back, mochis, copy);
  backdrop(back, theme.color, el);
  troupe(mochis, theme.cast, compact ? 280 : 340);
  return el;
}

/** A card in a colour: the band's black and particles behind `content`. */
export function glowCard(color: string, ...content: (HTMLElement | string)[]): HTMLElement {
  const el = document.createElement("div");
  el.className = "hub-glow";
  el.style.setProperty("--glow-line", rgba(color, 0.18));
  const canvas = document.createElement("canvas");
  const inner = document.createElement("div");
  inner.className = "inner";
  inner.append(...content);
  el.append(canvas, inner);
  backdrop(canvas, color, el, 14);
  return el;
}

/** An empty page: a Mochi asleep, and a line. */
export function emptyState(text: string, state: BotStateName = "sleeping", color = "#F5F6F8"): HTMLElement {
  const el = document.createElement("div");
  el.className = "hub-empty";
  const canvas = document.createElement("canvas");
  const p = document.createElement("div");
  p.textContent = text;
  el.append(canvas, p);
  liveMochi(canvas, color, state);
  return el;
}
