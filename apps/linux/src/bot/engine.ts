import type { BotEmote, BotState, EyeShape } from "../core/types.js";

/** Mochi track (Swift MochiConst + BotStates). */
export const MochiConst = {
  eyeW: 0.25,
  eyeH: 0.27,
  eyeSp: 0.37,
  eyeP: -0.12,
  baseTop: "#EDEDEF",
  baseBottom: "#C4C5CA",
  ink: "#1A1412",
  miniInk: "#10131A",
} as const;

export type BadgeKind = "dots" | "dot" | "bang" | "q";

export interface BotStateConfig {
  label: string;
  col: string;
  tint: number;
  eye: EyeShape;
  badge: [BadgeKind, string] | null;
  glow: string;
  glowOpacity: number;
  bounce: boolean;
  scan: boolean;
  breathe: boolean;
  zz: boolean;
  sweat: boolean;
  look: [number, number] | null;
  tilt: number;
  sound: string | null;
}

export const BOT_STATES: Record<BotState, BotStateConfig> = {
  idle: {
    label: "Au repos",
    col: "#E6E9EE",
    tint: 0,
    eye: "pill",
    badge: null,
    glow: "rgba(255,255,255,0.35)",
    glowOpacity: 0.25,
    bounce: false,
    scan: false,
    breathe: false,
    zz: false,
    sweat: false,
    look: null,
    tilt: 0,
    sound: null,
  },
  working: {
    label: "Travaille",
    col: "#3B9EFF",
    tint: 0.72,
    eye: "pill",
    badge: ["dots", "#3B9EFF"],
    glow: "#3B9EFF",
    glowOpacity: 0.55,
    bounce: false,
    scan: false,
    breathe: false,
    zz: false,
    sweat: false,
    look: null,
    tilt: 0,
    sound: "work",
  },
  thinking: {
    label: "Réfléchit",
    col: "#8B5CF6",
    tint: 0.72,
    eye: "pill",
    badge: ["dots", "#8B5CF6"],
    glow: "#8B5CF6",
    glowOpacity: 0.5,
    bounce: false,
    scan: false,
    breathe: false,
    zz: false,
    sweat: false,
    look: [0.55, 0.55],
    tilt: 0,
    sound: "think",
  },
  searching: {
    label: "Cherche",
    col: "#6366F1",
    tint: 0.72,
    eye: "pill",
    badge: ["dots", "#6366F1"],
    glow: "#6366F1",
    glowOpacity: 0.55,
    bounce: false,
    scan: true,
    breathe: false,
    zz: false,
    sweat: false,
    look: null,
    tilt: 0,
    sound: "search",
  },
  approval: {
    label: "Attend ton feu vert",
    col: "#F5A524",
    tint: 0.78,
    eye: "wide",
    badge: ["bang", "#F5A524"],
    glow: "#F5A524",
    glowOpacity: 0.6,
    bounce: true,
    scan: false,
    breathe: false,
    zz: false,
    sweat: false,
    look: null,
    tilt: 0,
    sound: "approval",
  },
  question: {
    label: "Pose une question",
    col: "#22D3EE",
    tint: 0.75,
    eye: "pill",
    badge: ["q", "#22D3EE"],
    glow: "#22D3EE",
    glowOpacity: 0.55,
    bounce: false,
    scan: false,
    breathe: false,
    zz: false,
    sweat: false,
    look: null,
    tilt: 0.17,
    sound: "question",
  },
  error: {
    label: "Erreur",
    col: "#F4505E",
    tint: 0.78,
    eye: "flat",
    badge: ["dot", "#F4505E"],
    glow: "#F4505E",
    glowOpacity: 0.55,
    bounce: false,
    scan: false,
    breathe: false,
    zz: false,
    sweat: false,
    look: null,
    tilt: 0,
    sound: "error",
  },
  finished: {
    label: "Terminé",
    col: "#34D399",
    tint: 0.35,
    eye: "happy",
    badge: ["dot", "#34D399"],
    glow: "#34D399",
    glowOpacity: 0.5,
    bounce: false,
    scan: false,
    breathe: false,
    zz: false,
    sweat: false,
    look: null,
    tilt: 0,
    sound: "finish",
  },
  ratelimit: {
    label: "Limite atteinte",
    col: "#FB923C",
    tint: 0.72,
    eye: "tired",
    badge: ["dot", "#FB923C"],
    glow: "#FB923C",
    glowOpacity: 0.45,
    bounce: false,
    scan: false,
    breathe: false,
    zz: false,
    sweat: true,
    look: null,
    tilt: 0,
    sound: "rate",
  },
  sleeping: {
    label: "Dort",
    col: "#94A3B8",
    tint: 0.32,
    eye: "closed",
    badge: null,
    glow: "#94A3B8",
    glowOpacity: 0.2,
    bounce: false,
    scan: false,
    breathe: true,
    zz: true,
    sweat: false,
    look: null,
    tilt: 0,
    sound: "sleep",
  },
  dizzy: {
    label: "Sonné",
    col: "#F472B6",
    tint: 0.7,
    eye: "spiral",
    badge: null,
    glow: "#F472B6",
    glowOpacity: 0.55,
    bounce: false,
    scan: false,
    breathe: false,
    zz: false,
    sweat: false,
    look: null,
    tilt: 0,
    sound: "dizzy",
  },
};

export const BOT_EMOTES: Record<
  BotEmote,
  { label?: string; eye: EyeShape; snd?: string; c?: string }
> = {
  love: { label: "Amour", eye: "heart", snd: "love", c: "#FF4D6D" },
  surprised: { label: "Surpris", eye: "dot", snd: "pop", c: "#FFFFFF" },
  proud: { label: "Fier", eye: "star", snd: "proud", c: "#F7B32B" },
  wink: { label: "Clin d'œil", eye: "wink", snd: "wink", c: "#A78BFA" },
  yawn: { label: "Bâille", eye: "tired", snd: "yawn", c: "#94A3B8" },
  happy: { eye: "happy" },
  annoyed: { eye: "line" },
};

const E = {
  out: (t: number) => 1 - Math.pow(1 - t, 3),
  inOut: (t: number) =>
    t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2,
  back: (t: number) => {
    const c1 = 1.7;
    const c3 = c1 + 1;
    return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2);
  },
  lin: (t: number) => t,
};

type EasingFn = (t: number) => number;

type AnimKey =
  | "yaw"
  | "pitch"
  | "roll"
  | "tilt"
  | "open"
  | "sx"
  | "sy"
  | "oy"
  | "ox"
  | "tint"
  | "morph"
  | "hands"
  | "blush"
  | "es"
  | "badgeS";

interface Tween {
  p: AnimKey;
  keys: [number, number, EasingFn][];
  i: number;
  from: number;
  t0: number;
  after?: () => void;
}

interface Particle {
  type: "heart" | "star" | "spark" | "sweat" | "z";
  x: number;
  y: number;
  vx: number;
  vy: number;
  age: number;
  life: number;
  rot: number;
  sz: number;
}

function clamp(v: number, a: number, b: number): number {
  return Math.max(a, Math.min(b, v));
}

function lerp(a: number, b: number, t: number): number {
  return a + (b - a) * t;
}

function hexRgb(hex: string): [number, number, number] {
  const h = hex.replace("#", "");
  const n =
    h.length === 3
      ? h
          .split("")
          .map((c) => c + c)
          .join("")
      : h;
  const v = parseInt(n, 16);
  return [(v >> 16) & 255, (v >> 8) & 255, v & 255];
}

function rgba(rgb: [number, number, number], a: number): string {
  return `rgba(${rgb[0]},${rgb[1]},${rgb[2]},${a})`;
}

function mixRgb(
  a: [number, number, number],
  b: [number, number, number],
  t: number,
): [number, number, number] {
  return [
    a[0] + (b[0] - a[0]) * t,
    a[1] + (b[1] - a[1]) * t,
    a[2] + (b[2] - a[2]) * t,
  ];
}

function rr(
  ctx: CanvasRenderingContext2D,
  X: number,
  Y: number,
  W: number,
  H: number,
  R: number,
): void {
  R = Math.max(0, Math.min(R, W / 2, H / 2));
  ctx.beginPath();
  ctx.moveTo(X + R, Y);
  ctx.arcTo(X + W, Y, X + W, Y + H, R);
  ctx.arcTo(X + W, Y + H, X, Y + H, R);
  ctx.arcTo(X, Y + H, X, Y, R);
  ctx.arcTo(X, Y, X + W, Y, R);
  ctx.closePath();
}

function heartPath(ctx: CanvasRenderingContext2D, s: number): void {
  ctx.beginPath();
  ctx.moveTo(0, s * 0.38);
  ctx.bezierCurveTo(-s * 1.05, -s * 0.15, -s * 0.5, -s * 0.95, 0, -s * 0.38);
  ctx.bezierCurveTo(s * 0.5, -s * 0.95, s * 1.05, -s * 0.15, 0, s * 0.38);
  ctx.closePath();
}

function starPath(ctx: CanvasRenderingContext2D, ro: number, ri: number): void {
  ctx.beginPath();
  for (let i = 0; i < 10; i++) {
    const r = i % 2 ? ri : ro;
    const a = -Math.PI / 2 + i * (Math.PI / 5);
    const px = Math.cos(a) * r;
    const py = Math.sin(a) * r;
    if (i === 0) ctx.moveTo(px, py);
    else ctx.lineTo(px, py);
  }
  ctx.closePath();
}

export interface BotEngineOptions {
  mini?: boolean;
  bodyColor?: string | null;
  playSound?: (name: string) => void;
}

export class BotEngine {
  private c: HTMLCanvasElement;
  private x: CanvasRenderingContext2D;
  readonly mini: boolean;
  private bodyColor: [number, number, number] | null;
  private playSound?: (name: string) => void;

  private s: Record<AnimKey, number> = {
    yaw: 0,
    pitch: 0,
    roll: 0,
    tilt: 0,
    open: 1,
    sx: 1,
    sy: 1,
    oy: 0,
    ox: 0,
    tint: 0,
    morph: 0,
    hands: 0,
    blush: 0,
    es: 1,
    badgeS: 0,
  };
  private tg: Record<AnimKey, number> = { ...this.s };
  private tw: Tween[] = [];
  private lock: Partial<Record<AnimKey, 1>> = {};

  private col: [number, number, number] = hexRgb(BOT_STATES.idle.col);
  private colT: [number, number, number] = this.col;

  state: BotState = "idle";
  cfg: BotStateConfig = BOT_STATES.idle;

  private eyeOv: EyeShape | null = null;
  private ovUntil = 0;
  private badge: BadgeKind | null = null;
  private badgeCol = "#fff";
  private badgeKey = "none";
  private badgeToken = 0;

  private parts: Particle[] = [];
  private nextBlink = 0;
  look = { x: 0, y: 0 };
  private t0 = performance.now() - Math.random() * 5000;
  private waveUntil = 0;
  private lastAmb = 0;
  private timeSec = 0;

  constructor(canvas: HTMLCanvasElement, options: BotEngineOptions = {}) {
    this.c = canvas;
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("BotEngine: 2d context unavailable");
    this.x = ctx;
    this.mini = options.mini ?? false;
    this.bodyColor = options.bodyColor
      ? hexRgb(options.bodyColor)
      : null;
    this.playSound = options.playSound;

    // Bitmap resolution only — display size comes from CSS / layout (botwrap = diameter/0.6).
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const px = this.mini ? 76 : 230;
    canvas.width = px * dpr;
    canvas.height = px * dpr;
    this.x.setTransform(dpr, 0, 0, dpr, 0, 0);

    this.nextBlink = performance.now() + 1500 + Math.random() * 2000;
  }

  setState(n: BotState, force = false): void {
    if (!BOT_STATES[n]) return;
    if (this.state === n && !force) return;
    const prev = this.state;
    this.state = n;
    this.cfg = BOT_STATES[n];
    this.colT = hexRgb(this.cfg.col);
    this.tg.tint = this.cfg.tint;
    this.tg.tilt = this.cfg.tilt;
    this.setBadge(this.cfg.badge);

    if (n === "finished") {
      this.roll(950, 1);
      window.setTimeout(() => this.emit("spark", 5), 500);
    } else if (n === "error") {
      this.anim("ox", [
        [0.08, 50, E.out],
        [-0.08, 70, E.inOut],
        [0.05, 70, E.inOut],
        [0, 90, E.out],
      ]);
    } else if (n === "approval") {
      this.anim("oy", [
        [-0.2, 150, E.out],
        [0, 300, E.back],
      ]);
    } else if (n === "dizzy") {
      this.roll(1300, 2);
    } else if (n === "question") {
      this.blink();
    } else if (n === "ratelimit") {
      this.emit("sweat", 1);
    } else if (prev !== "idle" || n !== "idle") {
      this.blink();
    }
  }

  setBadge(b: [BadgeKind, string] | null): void {
    const key = b ? b.join() : "none";
    if (key === this.badgeKey) return;
    this.badgeKey = key;
    const tok = ++this.badgeToken;
    this.anim("badgeS", [[0, 90, E.inOut]]);
    window.setTimeout(() => {
      if (tok !== this.badgeToken) return;
      this.badge = b ? b[0] : null;
      this.badgeCol = b ? b[1] : "#fff";
      if (b) this.anim("badgeS", [[1, 280, E.back]]);
    }, 100);
  }

  blink(): void {
    if (this.lock.open) return;
    this.anim("open", [
      [0.06, 70, E.inOut],
      [1, 130, E.out],
    ]);
  }

  squash(): void {
    this.anim("sy", [
      [0.78, 70, E.out],
      [1.1, 130, E.out],
      [1, 170, E.inOut],
    ]);
    this.anim("sx", [
      [1.16, 70, E.out],
      [0.95, 130, E.out],
      [1, 170, E.inOut],
    ]);
  }

  roll(d = 900, turns = 1): void {
    this.s.roll = 0;
    this.anim(
      "roll",
      [[Math.PI * 2 * turns, d, E.inOut]],
      () => {
        this.s.roll = 0;
        this.tg.roll = 0;
      },
    );
  }

  greet(): void {
    this.anim("hands", [[1, 280, E.back]]);
    this.waveUntil = performance.now() + 1500;
    this.emote("happy", 1500, true);
    window.setTimeout(() => this.anim("hands", [[0, 240, E.inOut]]), 1550);
  }

  /** Animate morph toward mailbox shape (0 = mochi, 1 = slot). */
  morphTo(target: number, durationMs = 400): void {
    this.anim("morph", [[clamp(target, 0, 1), durationMs, E.inOut]]);
  }

  emote(n: BotEmote, d = 1800, silent = false): void {
    const em = BOT_EMOTES[n];
    if (!em) return;
    this.eyeOv = em.eye;
    this.ovUntil = performance.now() + d;

    if (n === "love") {
      this.anim("blush", [
        [1, 300, E.out],
        [1, d - 600, E.lin],
        [0, 300, E.inOut],
      ]);
      this.emit("heart", 4);
      this.anim("oy", [
        [-0.1, 160, E.out],
        [0, 300, E.back],
      ]);
    }
    if (n === "surprised") {
      this.anim("oy", [
        [-0.3, 140, E.out],
        [0, 380, E.back],
      ]);
      this.anim("es", [
        [1.25, 120, E.out],
        [1, 500, E.inOut],
      ]);
    }
    if (n === "proud") {
      this.emit("star", 5);
      this.anim("tilt", [
        [-0.14, 220, E.out],
        [-0.14, d - 500, E.lin],
        [0, 280, E.inOut],
      ]);
    }
    if (n === "wink") {
      this.anim("tilt", [
        [0.12, 160, E.out],
        [0.12, d - 400, E.lin],
        [0, 240, E.inOut],
      ]);
    }
    if (n === "yawn") {
      this.anim("sy", [
        [1.12, 500, E.inOut],
        [1, 500, E.inOut],
      ]);
      this.anim("sx", [
        [0.94, 500, E.inOut],
        [1, 500, E.inOut],
      ]);
      window.setTimeout(() => {
        this.eyeOv = "closed";
        this.emit("z", 2);
      }, 700);
    }
    if (n === "happy") {
      this.anim("blush", [
        [0.6, 200, E.out],
        [0, 600, E.inOut],
      ]);
    }
    if (!silent && em.snd) this.playSound?.(em.snd);
  }

  /** Normalized look target (-1..1). */
  lookAt(x: number, y: number): void {
    this.look.x = clamp(x, -1, 1);
    this.look.y = clamp(y, -1, 1);
  }

  update(dt: number): void {
    const n = performance.now();
    dt = Math.min(0.05, dt);
    this.timeSec = (n - this.t0) / 1000;

    const s = this.s;
    const tg = this.tg;
    const c = this.cfg;
    const t = this.timeSec;

    for (const tw of [...this.tw]) {
      const k = tw.keys[tw.i];
      const p = clamp((n - tw.t0) / k[1], 0, 1);
      s[tw.p] = tw.from + (k[0] - tw.from) * k[2](p);
      if (p >= 1) {
        tw.from = k[0];
        tw.i++;
        tw.t0 = n;
        if (tw.i >= tw.keys.length) {
          this.tw.splice(this.tw.indexOf(tw), 1);
          delete this.lock[tw.p];
          tg[tw.p] = tw.keys[tw.keys.length - 1][0];
          tw.after?.();
        }
      }
    }

    let ty = this.look.x * 0.62;
    let tp = this.look.y * 0.5;
    if (c.look) {
      ty = ty * 0.35 + c.look[0] * 0.55;
      tp = tp * 0.3 + c.look[1] * 0.5;
    }
    if (c.scan) {
      ty = Math.sin(t * 2.6) * 0.6;
      tp = -0.06;
    }
    if (this.state === "sleeping") {
      ty = 0;
      tp = -0.14;
    }
    if (this.state === "dizzy") {
      ty = Math.sin(t * 9) * 0.25;
    }

    tg.yaw = ty;
    tg.pitch = tp;
    tg.tilt = c.tilt;
    tg.oy = c.bounce ? -Math.abs(Math.sin(t * 5.2)) * 0.07 : 0;
    tg.sy = c.breathe ? 1 + Math.sin(t * 1.8) * 0.035 : 1;
    tg.sx = c.breathe ? 1 - Math.sin(t * 1.8) * 0.02 : 1;

    const kLook = 1 - Math.pow(0.0025, dt);
    const kGen = 1 - Math.pow(0.0008, dt);
    for (const key of Object.keys(tg) as AnimKey[]) {
      if (this.lock[key]) continue;
      const k = key === "yaw" || key === "pitch" ? kLook : kGen;
      s[key] += (tg[key] - s[key]) * k;
    }

    this.col = mixRgb(this.col, this.colT, 1 - Math.pow(0.002, dt));

    if (n > this.nextBlink) {
      if (this.state !== "sleeping" && this.state !== "dizzy") {
        this.blink();
        if (Math.random() < 0.22) {
          window.setTimeout(() => this.blink(), 230);
        }
      }
      this.nextBlink = n + 2200 + Math.random() * 3200;
    }

    if (this.eyeOv && n > this.ovUntil) this.eyeOv = null;

    if (!this.mini && n - this.lastAmb > 1300) {
      this.lastAmb = n;
      if (c.zz) this.emit("z", 1);
      if (c.sweat && Math.random() < 0.5) this.emit("sweat", 1);
    }

    for (const p of this.parts) p.age += dt;
    this.parts = this.parts.filter((p) => p.age < p.life);
  }

  draw(): void {
    const x = this.x;
    const W = this.c.width / (this.x.getTransform().a || 1);
    const H = this.c.height / (this.x.getTransform().d || 1);
    const s = this.s;
    const ink = this.mini ? MochiConst.miniInk : MochiConst.ink;

    x.clearRect(0, 0, W, H);

    const R = W * 0.3;
    let rx = R;
    let ry = R;
    rx *= 1.14;
    ry *= 0.88;

    const cx = W / 2 + s.ox * R;
    const cy = H / 2 + s.oy * R + R * 0.06;

    x.save();
    x.translate(cx, cy);
    x.rotate(s.tilt);
    x.scale(s.sx, s.sy);

    const m = s.morph;
    const bodyPath = new Path2D();
    if (m < 0.01) {
      for (let i = 0; i <= 72; i++) {
        const a = (i / 72) * Math.PI * 2;
        const ca = Math.cos(a);
        const sa = Math.sin(a);
        const px = rx * Math.sign(ca) * Math.pow(Math.abs(ca), 2 / 2.7);
        const py = ry * Math.sign(sa) * Math.pow(Math.abs(sa), 2 / 2.7);
        if (i === 0) bodyPath.moveTo(px, py);
        else bodyPath.lineTo(px, py);
      }
      bodyPath.closePath();
    }

    const bc = this.bodyColor;

    const traceBody = (): void => {
      if (m < 0.01) return;
      const w = lerp(rx, R * 1.02, m);
      const h = lerp(ry, R * 0.94, m);
      const r = lerp(Math.min(rx, ry), R * 0.34, m);
      x.beginPath();
      rr(x, -w, -h, 2 * w, 2 * h, r);
    };

    const fillBody = (): void => {
      if (m < 0.01) x.fill(bodyPath);
      else {
        traceBody();
        x.fill();
      }
    };

    let c0: [number, number, number];
    let c1: [number, number, number];
    if (bc) {
      c0 = mixRgb(bc, [255, 255, 255], 0.35);
      c1 = mixRgb(bc, [0, 0, 0], 0.18);
    } else {
      c0 = hexRgb(MochiConst.baseTop);
      c1 = hexRgb(MochiConst.baseBottom);
    }

    const g = x.createLinearGradient(rx * 0.7, -ry * 0.85, -rx * 0.8, ry * 0.9);
    g.addColorStop(0, rgba(c0, 1));
    g.addColorStop(1, rgba(c1, 1));
    x.fillStyle = g;
    fillBody();

    if (!bc && s.tint > 0.01) {
      const tg2 = x.createLinearGradient(0, ry, 0, -ry * 0.25);
      tg2.addColorStop(0, rgba(this.col, 0.92 * s.tint));
      tg2.addColorStop(1, rgba(this.col, 0));
      x.fillStyle = tg2;
      fillBody();
    }

    const sh = x.createRadialGradient(
      rx * 0.25,
      -ry * 0.32,
      R * 0.15,
      0,
      0,
      R * 1.25,
    );
    sh.addColorStop(0, "rgba(255,255,255,0)");
    sh.addColorStop(0.6, "rgba(0,0,0,0)");
    sh.addColorStop(1, "rgba(0,0,0,0.2)");
    x.fillStyle = sh;
    fillBody();

    const hl = x.createRadialGradient(
      rx * 0.34,
      -ry * 0.46,
      0,
      rx * 0.34,
      -ry * 0.46,
      R * 0.42,
    );
    hl.addColorStop(0, "rgba(255,255,255,0.55)");
    hl.addColorStop(1, "rgba(255,255,255,0)");
    x.fillStyle = hl;
    fillBody();

    const bl = Math.max(s.blush, 0.35) * (1 - m);
    if (bl > 0.01) {
      x.save();
      if (m < 0.01) x.clip(bodyPath);
      else {
        traceBody();
        x.clip();
      }
      const yo = Math.sin(s.yaw) * rx * 0.8;
      x.fillStyle = `rgba(255,120,150,${0.5 * bl})`;
      for (const sd of [-1, 1]) {
        x.beginPath();
        x.ellipse(sd * rx * 0.55 + yo, ry * 0.2, R * 0.17, R * 0.1, 0, 0, Math.PI * 2);
        x.fill();
      }
      x.restore();
    }

    x.save();
    if (m < 0.01) x.clip(bodyPath);
    else {
      traceBody();
      x.clip();
    }
    x.fillStyle = ink;
    x.strokeStyle = ink;

    const shape = this.eyeOv ?? this.cfg.eye;
    for (const sd of [-1, 1]) {
      const yaw = sd * MochiConst.eyeSp + s.yaw;
      let pitch = MochiConst.eyeP + s.pitch + s.roll;
      pitch =
        ((((pitch + Math.PI) % (2 * Math.PI)) + 2 * Math.PI) % (2 * Math.PI)) -
        Math.PI;
      const cp = Math.cos(pitch);
      if (Math.cos(yaw) * cp < 0.04) continue;
      let px = Math.sin(yaw) * cp * rx;
      let py = -Math.sin(pitch) * ry;
      if (m > 0) py += ry * 0.14 * m;
      const fx = lerp(Math.max(0.18, Math.cos(yaw)), 1, m * 0.7);
      const fy = lerp(Math.max(0.18, cp), 1, m * 0.7);
      x.save();
      x.translate(px, py);
      x.scale(fx, fy);
      this.drawEye(
        shape,
        R * MochiConst.eyeW * s.es,
        R * MochiConst.eyeH * s.es,
        s.open,
        sd,
      );
      x.restore();
    }
    x.restore();

    if (m > 0.02) {
      const sw = R * 1.5 * m;
      const shh = R * 0.22 * m;
      x.fillStyle = ink;
      rr(x, -sw / 2, -R * 0.94 * 1 + R * 0.14, sw, shh, shh / 2);
      x.fill();
    }

    x.restore();

    if (s.hands > 0.01) {
      const hr = R * 0.2 * s.hands;
      const hc0 = bc
        ? mixRgb(bc, [255, 255, 255], 0.35)
        : hexRgb(MochiConst.baseTop);
      const hc1 = bc ?? hexRgb(MochiConst.baseBottom);
      const tt = performance.now() / 1000;
      for (const sd of [-1, 1]) {
        let hx = cx + sd * rx * 1.25 * s.sx;
        let hy = cy + ry * 0.42;
        if (sd === 1 && performance.now() < this.waveUntil) {
          hy -= R * 0.38 + Math.sin(tt * 13) * R * 0.16;
          hx += Math.cos(tt * 13) * R * 0.06;
        }
        const hg = x.createLinearGradient(hx + hr, hy - hr, hx - hr, hy + hr);
        hg.addColorStop(0, rgba(hc0, 1));
        hg.addColorStop(1, rgba(hc1, 1));
        x.fillStyle = hg;
        x.beginPath();
        x.arc(hx, hy, hr, 0, Math.PI * 2);
        x.fill();
      }
    }

    if (this.badge && s.badgeS > 0.01) {
      const bs = s.badgeS * (this.mini ? 1.25 : 1);
      const bx = cx - rx * 0.76 * s.sx;
      const by = cy - ry * 0.72 * s.sy;
      x.save();
      x.translate(bx, by);
      x.scale(bs, bs);
      const bcol = this.badgeCol;
      if (this.badge === "dots" && !this.mini) {
        const bw = R * 0.74;
        const bh = R * 0.42;
        x.fillStyle = "#000";
        rr(x, -bw / 2 - R * 0.07, -bh / 2 - R * 0.07, bw + R * 0.14, bh + R * 0.14, (bh + R * 0.14) / 2);
        x.fill();
        x.fillStyle = bcol;
        rr(x, -bw / 2, -bh / 2, bw, bh, bh / 2);
        x.fill();
        const tt = performance.now() / 1000;
        for (let i = 0; i < 3; i++) {
          const ph = (((tt * 2.4 - i * 0.22) % 1) + 1) % 1;
          const r = R * 0.06 * (1 + 0.4 * Math.max(0, Math.sin(ph * Math.PI * 2)));
          x.fillStyle = "rgba(255,255,255,0.95)";
          x.beginPath();
          x.arc((i - 1) * R * 0.19, 0, r, 0, Math.PI * 2);
          x.fill();
        }
      } else if (this.badge === "bang" || this.badge === "q") {
        x.fillStyle = "#000";
        x.beginPath();
        x.arc(0, 0, R * 0.3, 0, Math.PI * 2);
        x.fill();
        x.fillStyle = bcol;
        x.beginPath();
        x.arc(0, 0, R * 0.23, 0, Math.PI * 2);
        x.fill();
        if (!this.mini) {
          x.fillStyle = "#fff";
          x.font = `800 ${R * 0.32}px system-ui,sans-serif`;
          x.textAlign = "center";
          x.textBaseline = "middle";
          x.fillText(this.badge === "bang" ? "!" : "?", 0, R * 0.02);
        }
      } else {
        x.fillStyle = "#000";
        x.beginPath();
        x.arc(0, 0, R * 0.2, 0, Math.PI * 2);
        x.fill();
        x.fillStyle = bcol;
        x.beginPath();
        x.arc(0, 0, R * 0.135, 0, Math.PI * 2);
        x.fill();
      }
      x.restore();
    }

    for (const p of this.parts) {
      if (p.age < 0) continue;
      const k = p.age / p.life;
      const a = k < 0.2 ? k / 0.2 : 1 - (k - 0.2) / 0.8;
      const px = cx + (p.x + p.vx * p.age) * R * 1.3;
      const py = cy + (p.y + p.vy * p.age) * R * 1.3;
      const sz = R * p.sz * (1 + k * 0.4);
      x.save();
      x.translate(px, py);
      x.globalAlpha = clamp(a, 0, 1);
      if (p.type === "heart") {
        x.fillStyle = "#FF4D6D";
        x.rotate(Math.sin(p.age * 6) * 0.3);
        heartPath(x, sz);
        x.fill();
      } else if (p.type === "star") {
        x.fillStyle = "#F7B32B";
        x.rotate(p.rot + p.age * 2);
        starPath(x, sz, sz * 0.45);
        x.fill();
      } else if (p.type === "spark") {
        x.fillStyle = "#fff";
        x.rotate(p.rot);
        starPath(x, sz * 0.8, sz * 0.18);
        x.fill();
      } else if (p.type === "sweat") {
        x.fillStyle = "#7CC7FF";
        x.beginPath();
        x.moveTo(0, -sz);
        x.quadraticCurveTo(sz * 0.8, sz * 0.2, 0, sz * 0.6);
        x.quadraticCurveTo(-sz * 0.8, sz * 0.2, 0, -sz);
        x.fill();
      } else if (p.type === "z") {
        x.fillStyle = "rgba(210,220,235,1)";
        x.font = `700 ${sz * 1.9}px system-ui,sans-serif`;
        x.fillText("z", 0, 0);
      }
      x.restore();
    }
  }

  private anim(p: AnimKey, keys: [number, number, EasingFn][], after?: () => void): void {
    this.tw = this.tw.filter((t) => t.p !== p);
    this.tw.push({ p, keys, i: 0, from: this.s[p], t0: performance.now(), after });
    this.lock[p] = 1;
  }

  private emit(type: Particle["type"], n: number): void {
    for (let i = 0; i < n; i++) {
      this.parts.push({
        type,
        x: (Math.random() - 0.5) * 0.9 + (type === "z" ? 0.55 : 0),
        y: -0.7 - Math.random() * 0.2,
        vx: (Math.random() - 0.5) * 0.35 + (type === "z" ? 0.18 : 0),
        vy: -(0.45 + Math.random() * 0.35),
        age: -i * 0.14,
        life: 1.3 + Math.random() * 0.5,
        rot: Math.random() * 6,
        sz: 0.15 + Math.random() * 0.08,
      });
    }
  }

  private drawEye(
    shape: EyeShape,
    w: number,
    h: number,
    open: number,
    sd: number,
  ): void {
    const ctx = this.x;
    const t = performance.now() / 1000;
    switch (shape) {
      case "wide":
      case "pill": {
        if (shape === "wide") {
          w *= 1.16;
          h *= 1.12;
        }
        const hh = Math.max(h * open, w * 0.3);
        rr(ctx, -w / 2, -hh / 2, w, hh, Math.min(w / 2, hh / 2));
        ctx.fill();
        break;
      }
      case "dot":
        ctx.beginPath();
        ctx.arc(0, 0, w * 0.45, 0, Math.PI * 2);
        ctx.fill();
        break;
      case "line":
        ctx.rotate(-sd * 0.2);
        rr(ctx, -w * 0.78, -w * 0.21, w * 1.56, w * 0.42, w * 0.21);
        ctx.fill();
        break;
      case "flat":
        rr(ctx, -w * 0.72, -w * 0.2, w * 1.44, w * 0.4, w * 0.2);
        ctx.fill();
        break;
      case "happy":
        ctx.lineWidth = w * 0.5;
        ctx.lineCap = "round";
        ctx.beginPath();
        ctx.arc(0, h * 0.18, w * 0.82, Math.PI * 1.12, Math.PI * 1.88);
        ctx.stroke();
        break;
      case "closed":
        ctx.lineWidth = w * 0.36;
        ctx.lineCap = "round";
        ctx.beginPath();
        ctx.arc(0, -h * 0.08, w * 0.78, Math.PI * 0.15, Math.PI * 0.85);
        ctx.stroke();
        break;
      case "spiral": {
        ctx.lineWidth = w * 0.22;
        ctx.lineCap = "round";
        ctx.beginPath();
        for (let a = 0; a < 4.4 * Math.PI; a += 0.2) {
          const r = w * 0.06 + a * w * 0.058;
          const aa = a + t * 9 * sd;
          const px = Math.cos(aa) * r;
          const py = Math.sin(aa) * r;
          if (a === 0) ctx.moveTo(px, py);
          else ctx.lineTo(px, py);
        }
        ctx.stroke();
        break;
      }
      case "heart":
        ctx.fillStyle = "#FF4D6D";
        heartPath(ctx, w * 1.2);
        ctx.fill();
        ctx.fillStyle = MochiConst.ink;
        break;
      case "star":
        ctx.fillStyle = "#F7B32B";
        ctx.rotate(t * 1.5 * sd);
        starPath(ctx, w * 1.05, w * 0.46);
        ctx.fill();
        ctx.fillStyle = MochiConst.ink;
        break;
      case "tired":
        rr(ctx, -w / 2, -h * 0.02, w, h * 0.38, w / 2);
        ctx.fill();
        rr(ctx, -w * 0.62, -h * 0.1, w * 1.24, w * 0.22, w * 0.11);
        ctx.fill();
        break;
      case "wink":
        if (sd < 0) {
          rr(ctx, -w / 2, -h / 2, w, h, w / 2);
          ctx.fill();
        } else {
          ctx.lineWidth = w * 0.5;
          ctx.lineCap = "round";
          ctx.beginPath();
          ctx.arc(0, h * 0.18, w * 0.82, Math.PI * 1.12, Math.PI * 1.88);
          ctx.stroke();
        }
        break;
      default:
        rr(ctx, -w / 2, -h / 2, w, h, w / 2);
        ctx.fill();
    }
  }
}

/** @deprecated Use BOT_STATES — exported alias for prototype parity. */
export const STATES = BOT_STATES;
export const EMOTES = BOT_EMOTES;
export const TYPES = { states: BOT_STATES, emotes: BOT_EMOTES } as const;
