// Mochi — direct port of NotchBuddy/Sources/App/BotEngine.swift to Canvas 2D.
// Same constants, same tweens, same easings, same particles. The only intentional
// difference is the `happy`/`wink` eye arc, which follows the prototype
// (design/prototype/notch-buddy.html, the visual source of truth) — the Swift
// arc angles produce a different shape.

import { Ease, lerp, type EaseFn } from "../core/anim";
import { Sound } from "../core/sound";
import type { BotEmoteName, BotStateName } from "../core/layout";
import { FROG_EYE_SCALE, SKIN_BODY, SKIN_EYE_INK, frogBumps, drawOutfitBehind, drawOutfitFront, drawSkinUnder, makeHead, outfitFit, outfitReach } from "./outfits";
import type { Outfit } from "./wardrobe";
import { shapeOf, shapePoint, taperAt, type ShapeDef } from "./shapes";

// ── Types ─────────────────────────────────────────────────────────────────────

export type EyeShape =
  | "pill" | "wide" | "dot" | "line" | "flat" | "happy" | "closed" | "droop"
  | "spiral" | "heart" | "star" | "tired" | "wink" | "cup"
  // Chat moods: brimming with tears, furrowed, charged up.
  | "teary" | "angry" | "glow";

export type BadgeKind = "dots" | "bang" | "question" | "dot";

export interface Badge {
  kind: BadgeKind;
  color: RGB;
}

export type RGB = readonly [number, number, number]; // components 0…1

export type TweenKey = readonly [target: number, durationMs: number, ease: EaseFn];

interface Tween {
  prop: PropKey;
  keys: TweenKey[];
  index: number;
  from: number;
  startMs: number;
  onComplete?: () => void;
}

type PropKey =
  | "yaw" | "pitch" | "roll" | "tilt" | "open" | "sx" | "sy"
  | "oy" | "ox" | "tint" | "morph" | "hands" | "blush" | "es" | "badgeS"
  | "outfitPresence" | "moodTint";

interface BotStateCfg {
  color: RGB;
  tint: number;
  eye: EyeShape;
  badge: Badge | null;
  bounces: boolean;
  scans: boolean;
  breathes: boolean;
  zz: boolean;
  sweat: boolean;
  look: readonly [number, number] | null;
  tilt: number;
}

/** One visible eye: side (-1 left, 1 right), centre and foreshortening. */
interface EyeSpot {
  sd: number;
  ex: number;
  ey: number;
  fx: number;
  fy: number;
  /** How much the eye faces the viewer (<= 0: rolled out of sight). */
  vis: number;
}

interface Particle {
  type: "heart" | "star" | "spark" | "sweat" | "z" | "steam" | "bolt" | "confetti" | "mark";
  x: number; y: number; vx: number; vy: number;
  age: number; life: number; rot: number; size: number;
  /** A confetti's colour, or the character a mark shows ("!", "?"). */
  c?: string;
}

// ── Constants (MochiConst / PISTES.mochi) ─────────────────────────────────────

const EYE_W = 0.25;
const EYE_H = 0.27;
const EYE_SP = 0.37;
const EYE_P = -0.12;
const BASE_TOP: RGB = [0.929, 0.929, 0.937]; // #EDEDEF
const BASE_BOTTOM: RGB = [0.769, 0.773, 0.792]; // #C4C5CA
const INK = "rgb(26,20,18)"; // #1A1412
const MINI_INK = "rgb(16,19,26)"; // #10131A

const C = {
  idle: [0.902, 0.914, 0.933] as RGB,
  working: [0.231, 0.62, 1] as RGB,
  thinking: [0.545, 0.361, 0.965] as RGB,
  searching: [0.388, 0.396, 0.949] as RGB,
  approval: [0.961, 0.647, 0.141] as RGB,
  question: [0.133, 0.827, 0.933] as RGB,
  error: [0.957, 0.314, 0.369] as RGB,
  finished: [0.204, 0.831, 0.6] as RGB,
  ratelimit: [0.984, 0.573, 0.235] as RGB,
  sleeping: [0.58, 0.635, 0.722] as RGB,
  dizzy: [0.957, 0.447, 0.714] as RGB,
};

const base = {
  bounces: false, scans: false, breathes: false, zz: false, sweat: false,
  look: null, tilt: 0,
};

export const BOT_STATES: Record<BotStateName, BotStateCfg> = {
  idle: { ...base, color: C.idle, tint: 0, eye: "pill", badge: null },
  working: { ...base, color: C.working, tint: 0.72, eye: "pill", badge: { kind: "dots", color: C.working } },
  thinking: { ...base, color: C.thinking, tint: 0.72, eye: "pill", badge: { kind: "dots", color: C.thinking }, look: [0.55, 0.55] },
  searching: { ...base, color: C.searching, tint: 0.72, eye: "pill", badge: { kind: "dots", color: C.searching }, scans: true },
  approval: { ...base, color: C.approval, tint: 0.78, eye: "wide", badge: { kind: "bang", color: C.approval }, bounces: true },
  question: { ...base, color: C.question, tint: 0.75, eye: "pill", badge: { kind: "question", color: C.question }, tilt: 0.17 },
  error: { ...base, color: C.error, tint: 0.78, eye: "flat", badge: { kind: "dot", color: C.error } },
  finished: { ...base, color: C.finished, tint: 0.35, eye: "happy", badge: { kind: "dot", color: C.finished } },
  ratelimit: { ...base, color: C.ratelimit, tint: 0.72, eye: "tired", badge: { kind: "dot", color: C.ratelimit }, sweat: true },
  sleeping: { ...base, color: C.sleeping, tint: 0.32, eye: "closed", badge: null, breathes: true, zz: true },
  dizzy: { ...base, color: C.dizzy, tint: 0.7, eye: "spiral", badge: null },
};

const EMOTE_EYE: Record<BotEmoteName, EyeShape> = {
  love: "heart", surprised: "dot", proud: "star", wink: "wink",
  yawn: "tired", happy: "happy", annoyed: "line",
  sad: "teary", shy: "happy", scared: "wide",
  angry: "angry", hype: "glow", confused: "spiral", sleepy: "tired",
};

/** The colour an emote washes over the body. */
const EMOTE_TINT: Partial<Record<BotEmoteName, RGB>> = {
  sad: [0.3, 0.55, 1], angry: [1, 0.18, 0.12], scared: [0.72, 0.84, 1], hype: [0.72, 0.3, 1],
};

/** What an emote keeps giving off while it lasts: particle, every n seconds, where. */
const EMOTE_EMIT: Partial<Record<BotEmoteName, [Particle["type"], number, (() => Partial<Particle>)?]>> = {
  angry: ["steam", 0.18, () => {
    const sd = Math.random() < 0.5 ? -1 : 1;
    return { x: sd * 0.42, y: -0.62, vx: sd * 0.2, vy: -0.6 };
  }],
  hype: ["bolt", 0.14, () => ({ x: (Math.random() - 0.5) * 1.7, y: -0.1 })],
  confused: ["mark", 0.65, () => ({ c: "?", size: 0.12 })],
  sleepy: ["z", 0.75],
};

/** A chat reply's mood (chat.rs MOODS), acted out. */
export const MOOD_ACTS: Record<string, (e: BotEngine) => void> = {
  happy: (e) => e.triggerEmote("happy", 2),
  sad: (e) => e.triggerEmote("sad", 2.4),
  shy: (e) => e.triggerEmote("shy", 2.2),
  angry: (e) => e.triggerEmote("angry", 2.2),
  thankful: (e) => e.triggerEmote("love", 2.2),
  welcome: (e) => e.triggerEmote("wink", 2),
  scared: (e) => e.triggerEmote("scared", 2),
  surprised: (e) => e.triggerEmote("surprised", 2),
  proud: (e) => e.triggerEmote("proud", 2.2),
  hype: (e) => e.triggerEmote("hype", 2.4),
  confused: (e) => e.triggerEmote("confused", 2.4),
  sleepy: (e) => e.triggerEmote("sleepy", 2.8),
  celebration: (e) => e.celebrate(),
};

const MAX_PARTICLES = 48;
const CONFETTI = ["#FF4D6D", "#F7B32B", "#3DDC97", "#4CC9F0", "#B388FF", "#FF8CC6"];
/** How fast a particle falls instead of floating (fraction of R per s²). */
const FALL: Partial<Record<Particle["type"], number>> = { confetti: 1.5 };
const MARK_COLOR: Record<string, string> = { "!": "#FFD23F", "?": "#8FD3FF" };
/** The hype's fire, back to front: size, colour at the body, colour at the tips. */
const FIRE: [number, string, string][] = [
  [1, "rgba(150,60,255,0.9)", "rgba(110,40,220,0)"],
  [0.72, "rgba(236,72,200,0.95)", "rgba(236,72,200,0)"],
  [0.45, "rgba(255,215,250,1)", "rgba(255,170,240,0)"],
];

// ── Small helpers ─────────────────────────────────────────────────────────────

const now = () => performance.now() / 1000;

/** Eases to `peak`, holds it for the rest of `dur` seconds, then back to `rest`. */
const hold = (peak: number, dur: number, rest = 0, inMs = 250, outMs = 400): TweenKey[] => [
  [peak, inMs, Ease.out], [peak, Math.max(1, dur * 1000 - inMs - outMs), Ease.lin], [rest, outMs, Ease.inOut],
];

/** `n` side-to-side swings of `ms` each, dying down. */
const shake = (amp: number, n: number, ms: number): TweenKey[] => [
  ...Array.from({ length: n }, (_, i): TweenKey => [amp * (i % 2 ? -1 : 1) * (1 - i / n), ms, Ease.inOut]),
  [0, ms, Ease.out],
];

export function hexToRGB(hex: string): RGB {
  const h = hex.replace("#", "");
  const v = parseInt(h, 16);
  return [((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255];
}

const rgba = (c: RGB, a = 1) =>
  `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${a})`;

const mix3 = (a: RGB, b: RGB, t: number): RGB => [
  lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t),
];

function roundRectPath(x: CanvasRenderingContext2D, X: number, Y: number, W: number, H: number, R: number) {
  const r = Math.max(0, Math.min(R, W / 2, H / 2));
  x.beginPath();
  x.moveTo(X + r, Y);
  x.arcTo(X + W, Y, X + W, Y + H, r);
  x.arcTo(X + W, Y + H, X, Y + H, r);
  x.arcTo(X, Y + H, X, Y, r);
  x.arcTo(X, Y, X + W, Y, r);
  x.closePath();
}

function heartPath(x: CanvasRenderingContext2D, s: number) {
  x.beginPath();
  x.moveTo(0, s * 0.38);
  x.bezierCurveTo(-s * 1.05, -s * 0.15, -s * 0.5, -s * 0.95, 0, -s * 0.38);
  x.bezierCurveTo(s * 0.5, -s * 0.95, s * 1.05, -s * 0.15, 0, s * 0.38);
  x.closePath();
}

function starPath(x: CanvasRenderingContext2D, ro: number, ri: number) {
  x.beginPath();
  for (let i = 0; i < 10; i++) {
    const r = i % 2 ? ri : ro;
    const a = -Math.PI / 2 + (i * Math.PI) / 5;
    x.lineTo(Math.cos(a) * r, Math.sin(a) * r);
  }
  x.closePath();
}

const FONT = `system-ui, "Segoe UI Variable Text", "Segoe UI", sans-serif`;

// ── Dance (BotEngine.applyDance, macOS) ──────────────────────────────────────

/** The dance fades in over 0.3 s and out over 0.5 s. */
export function stepDanceLevel(level: number, dancing: boolean, dt: number): number {
  const target = dancing ? 1 : 0;
  if (level < target) return Math.min(target, level + dt / 0.3);
  if (level > target) return Math.max(target, level - dt / 0.5);
  return level;
}

/**
 * The 112-BPM bounce at `seconds`, for a body of radius R and a dance `level`
 * (0…1): a sideways sway, a hop, a tilt, and a squash on landing.
 */
export function danceTransform(seconds: number, level: number, R: number) {
  const beat = (seconds * 112) / 60;
  const hop = Math.abs(Math.sin(Math.PI * beat));
  const land = Math.pow(1 - hop, 6);
  return {
    dx: 0.08 * R * Math.sin(Math.PI * beat) * level,
    dy: -0.2 * R * hop * level,
    rotate: 0.1 * Math.sin(Math.PI * beat) * level,
    sx: 1 + 0.045 * land * level,
    sy: 1 - 0.06 * land * level,
  };
}

// ── Engine ────────────────────────────────────────────────────────────────────

export class BotEngine {
  isMini = false;
  /** Solid body colour for mini bots / integration pills (null = Mochi gradient). */
  bodyColor: RGB | null = null;

  // Animated state (BotEngine `s`)
  yaw = 0; pitch = 0; roll = 0; tilt = 0; open = 1;
  sx = 1; sy = 1; oy = 0; ox = 0;
  tint = 0; morph = 0; hands = 0; blush = 0; es = 1; badgeS = 0;
  /** An emote's colour wash over the body (EMOTE_TINT), 0 to 1. */
  moodTint = 0;
  private moodCol: RGB = [1, 1, 1];
  /** The emote playing, for the effects drawn every frame (fire, tears, steam...). */
  private fx: { name: BotEmoteName; t0: number; t1: number } | null = null;
  private fxNext = 0;
  /** The body radius last drawn at; small ones get the simple effects. */
  private r = 30;

  // Outfit (upstream: the main Mochi only; here, the pills' minis wear their
  // own Mochi's look too, wardrobe.ts lookOf). `outfit` is what is
  // drawn; it changes only once the previous one has left.
  outfit: Outfit = "none";
  /** 0 = gone, 1 = fully on. */
  outfitPresence = 0;
  private outfitTarget: Outfit = "none";
  /** How far above the body centre (in R, at rest) the outfit may reach; a
   *  taller one shrinks to fit. Only the minis set it (minibots.ts). */
  outfitRoom = Number.POSITIVE_INFINITY;

  // Spring lag of the soft parts (pompoms, hat tips, scarf end), −1…1.
  physDx = 0;
  physDy = 0;
  private physVx = 0;
  private physVy = 0;
  private prevYaw = 0;
  private prevOy = 0;
  private prevRoll = 0;

  // Targets
  tgYaw = 0; tgPitch = 0; tgTilt = 0; tgSy = 1; tgSx = 1; tgEs = 1;
  /** Seconds of full-rate drawing still owed to the pointer having moved the eyes. */
  private lookMoving = 0;
  private lookSeenX = 0;
  private lookSeenY = 0;

  /** Extra canvas height above the body so hearts can fly out without clipping. */
  particleOverhang = 0;

  /** Dancing to music; `dancingLevel` follows it, 0→1 in 0.3 s, 1→0 in 0.5 s. */
  isDancing = false;
  dancingLevel = 0;

  /** Body shape id from the wardrobe (shapes.ts SHAPES); "" = the classic Mochi. */
  shape = "";
  /** Velocity the whole canvas is being moved at (px/s), e.g. carried on the
   *  screenshot roam: the body doesn't move then, but the soft parts trail. */
  dragVel = { x: 0, y: 0 };

  // Mouth spring (fraction of R)
  slotH = 0; slotHTarget = 0; slotHVel = 0; isChewing = false;

  col: RGB = C.idle;
  colT: RGB = C.idle;

  state: BotStateName = "idle";
  cfg: BotStateCfg = BOT_STATES.idle;

  eyeOverride: EyeShape | null = null;
  eyeOverrideUntil = 0;
  permanentEye: EyeShape | null = null;
  permanentEmote: BotEmoteName | null = null;
  miniNextBehavior = 0;

  badge: Badge | null = null;
  private badgeKey = "none";
  private badgeToken = 0;

  private tweens = new Map<PropKey, Tween>();
  private locks = new Set<PropKey>();
  private particles: Particle[] = [];

  lookX = 0;
  lookY = 0;

  lastTime = now();
  private t0 = now() - Math.random() * 5;
  private nextBlink = now() + 1.5 + Math.random() * 2;
  waveUntil = 0;
  waveStart = 0;
  private greetToken = 0;
  private lastAmbient = 0;
  private slapTimes: number[] = [];
  private hitTimes: number[] = [];
  private miniLookTarget = { x: 0, y: 0 };
  private miniLookNextTime = 0;

  /** Fired when three slaps land inside 1.7 s (→ dizzy + confused view). */
  onDizzy: (() => void) | null = null;

  // ── Public API ──────────────────────────────────────────────────────────────

  setState(next: BotStateName, force = false) {
    if (this.state === next && !force) return;
    const prev = this.state;
    this.state = next;
    this.cfg = BOT_STATES[next];
    this.colT = this.cfg.color;
    if (!this.locks.has("tint")) this.tint = this.cfg.tint;
    if (!this.locks.has("tilt")) this.tgTilt = this.cfg.tilt;
    this.setBadge(this.cfg.badge);

    switch (next) {
      case "finished":
        this.doRoll(950, 1);
        setTimeout(() => this.emit("spark", 5), 500);
        break;
      case "error":
        this.anim("ox", [
          [0.08, 50, Ease.out], [-0.08, 70, Ease.inOut],
          [0.05, 70, Ease.inOut], [0, 90, Ease.out],
        ]);
        break;
      case "approval":
        this.anim("oy", [[-0.2, 150, Ease.out], [0, 300, Ease.back]]);
        break;
      case "dizzy":
        this.doRoll(1300, 2);
        break;
      case "question":
        this.blink();
        break;
      case "sleeping":
        // Falling asleep. The lids droop, flutter half open once, droop
        // shut, then he sleeps with closed eyes (the head nods down, update).
        this.eyeOverride = "droop";
        this.eyeOverrideUntil = now() + 2.5;
        this.anim("open", [
          [0.5, 700, Ease.inOut], [0.8, 220, Ease.out], [0.3, 650, Ease.inOut],
          [0.45, 200, Ease.out], [0.05, 650, Ease.inOut], [0.05, 200, Ease.lin], [1, 1, Ease.lin],
        ]);
        break;
      case "ratelimit":
        this.emit("sweat", 1);
        break;
      default:
        if (prev !== "idle" || next !== "idle") this.blink();
    }
  }

  /** The chat's celebration mood: a happy party with sparks and confetti, a
   *  proud double bounce, and a kick for the outfit's soft parts. */
  celebrate() {
    this.physVx += Math.random() < 0.5 ? -3 : 3;
    this.squash();
    this.triggerEmote("happy", 2.2);
    this.emit("spark", 6);
    this.burst("confetti", 28, 1.8);
    this.burst("star", 3, 1);
    this.anim("oy", [[-0.34, 170, Ease.out], [0, 240, Ease.inOut], [-0.16, 150, Ease.out], [0, 260, Ease.back]]);
  }

  setBadge(b: Badge | null) {
    const key = b ? `${b.kind}-${b.color.join(",")}` : "none";
    if (key === this.badgeKey) return;
    this.badgeKey = key;
    const tok = ++this.badgeToken;
    this.anim("badgeS", [[0, 90, Ease.inOut]]);
    setTimeout(() => {
      if (tok !== this.badgeToken) return;
      this.badge = b;
      if (b) this.anim("badgeS", [[1, 280, Ease.back]]);
    }, 100);
  }

  blink() {
    if (this.locks.has("open")) return;
    this.anim("open", [[0.06, 70, Ease.inOut], [1, 130, Ease.out]]);
  }

  squash() {
    this.physVy += 0.6;
    this.anim("sy", [[0.78, 70, Ease.out], [1.1, 130, Ease.out], [1, 170, Ease.inOut]]);
    this.anim("sx", [[1.16, 70, Ease.out], [0.95, 130, Ease.out], [1, 170, Ease.inOut]]);
  }

  /** Mailbox swallow — opens the slot, chews, then closes. */
  gulp() {
    this.slotHTarget = 0.42;
    setTimeout(() => {
      this.slotHTarget = 0;
      this.isChewing = true;
      setTimeout(() => { this.isChewing = false; }, 800);
    }, 460);
    this.anim("sy", [[0.78, 80, Ease.out], [1.18, 130, Ease.out], [1, 220, Ease.back]]);
    this.anim("sx", [[1.28, 80, Ease.out], [0.92, 130, Ease.out], [1, 220, Ease.back]]);
    this.blink();
  }

  slap() {
    this.interruptGreet();
    const t = now();
    // Ten hits inside 20 s, dizzy ones included: he has had enough.
    this.hitTimes = this.hitTimes.filter((s) => t - s < 20);
    this.hitTimes.push(t);
    if (this.hitTimes.length >= 10) {
      this.hitTimes = [];
      this.slapTimes = [];
      Sound.play("slap");
      this.triggerEmote("angry", 2.6);
      return;
    }
    if (this.state === "dizzy") return;
    this.slapTimes = this.slapTimes.filter((s) => t - s < 1.7);
    this.slapTimes.push(t);
    Sound.play("slap");
    this.squash();
    this.physVy -= 1.2;
    this.physVx += Math.random() < 0.5 ? 0.7 : -0.7;
    if (this.slapTimes.length >= 3) {
      this.slapTimes = [];
      this.onDizzy?.();
    } else {
      this.eyeOverride = "line";
      this.eyeOverrideUntil = t + 0.8;
      setTimeout(() => Sound.play("annoyed"), 60);
    }
  }

  doRoll(durationMs: number, turns: number) {
    this.roll = 0;
    this.anim("roll", [[Math.PI * 2 * turns, durationMs, Ease.inOut]], () => { this.roll = 0; });
  }

  /** Peek wave — the "coucou". Timings from BotEngine.greet(). */
  greet() {
    const t = now();
    const tok = ++this.greetToken;
    this.waveStart = t + 0.45;
    this.waveUntil = t + 1.55;
    this.physVx += 0.2;

    this.eyeOverride = "happy";
    this.eyeOverrideUntil = t + 2.0;
    this.anim("oy", [[-0.06, 220, Ease.out], [0.0, 220, Ease.back]]);

    setTimeout(() => {
      if (this.greetToken !== tok) return;
      this.anim("hands", [[1, 280, Ease.out]]);
      this.anim("sy", [[0.95, 100, Ease.out], [1.0, 260, Ease.back]]);
      this.anim("sx", [[1.04, 100, Ease.out], [1.0, 260, Ease.back]]);
      Sound.play("greet");
    }, 250);

    setTimeout(() => { if (this.greetToken === tok) this.blink(); }, 550);
    setTimeout(() => { if (this.greetToken === tok) this.blink(); }, 1500);
    setTimeout(() => {
      if (this.greetToken !== tok) return;
      this.waveUntil = 0;
      this.anim("hands", [[0, 200, Ease.inOut]]);
    }, 1550);
    setTimeout(() => {
      if (this.greetToken !== tok) return;
      this.eyeOverride = "happy";
      this.eyeOverrideUntil = now() + 0.3;
    }, 1750);
  }

  interruptGreet() {
    if (this.hands <= 0.01 && now() >= this.waveUntil) return;
    this.greetToken++;
    this.waveUntil = 0;
    this.waveStart = 0;
    this.anim("hands", [[0, 150, Ease.inOut]]);
  }

  setPermanentEmote(emote: BotEmoteName | null) {
    this.permanentEmote = emote;
    if (emote === "wink") {
      this.miniNextBehavior = now() + 0.8 + Math.random() * 1.7;
      return;
    }
    this.permanentEye = emote ? EMOTE_EYE[emote] : null;
    if (this.permanentEye) {
      this.eyeOverride = this.permanentEye;
      this.eyeOverrideUntil = Number.POSITIVE_INFINITY;
    } else if (this.eyeOverrideUntil === Number.POSITIVE_INFINITY) {
      this.eyeOverride = null;
      this.eyeOverrideUntil = 0;
    }
    this.miniNextBehavior = now() + 0.8 + Math.random() * 1.7;
  }

  triggerEmote(emote: BotEmoteName, duration = 1.8) {
    const t = now();
    const fx = this.fx = { name: emote, t0: t, t1: t + duration };
    const later = (ms: number, f: () => void) => setTimeout(() => { if (this.fx === fx) f(); }, ms);
    this.fxNext = t;
    this.eyeOverride = EMOTE_EYE[emote];
    this.eyeOverrideUntil = t + duration;
    const tint = EMOTE_TINT[emote];
    if (tint) {
      this.moodCol = tint;
      this.anim("moodTint", hold(1, duration));
    } else if (this.moodTint > 0) {
      this.anim("moodTint", [[0, 250, Ease.inOut]]);
    }
    // The hype's crouch, spring up and charged hold, as [crouch, peak, held] per prop.
    const charge = (keys: number[]): TweenKey[] => [
      [keys[0], 220, Ease.out], [keys[1], 160, Ease.out],
      [keys[2], Math.max(1, duration * 1000 - 730), Ease.lin], [keys[3], 350, Ease.back],
    ];

    switch (emote) {
      case "love":
        this.anim("blush", [
          [1, 300, Ease.out], [1, (duration - 0.6) * 1000, Ease.lin], [0, 300, Ease.inOut],
        ]);
        this.emit("heart", 4);
        this.anim("oy", [[-0.1, 160, Ease.out], [0, 300, Ease.back]]);
        break;
      case "surprised":
        this.anim("oy", [[-0.3, 140, Ease.out], [0, 380, Ease.back]]);
        this.anim("es", [[1.25, 120, Ease.out], [1, 500, Ease.inOut]]);
        break;
      case "proud":
        this.emit("star", 5);
        this.anim("tilt", [
          [-0.14, 220, Ease.out], [-0.14, (duration - 0.5) * 1000, Ease.lin], [0, 280, Ease.inOut],
        ]);
        this.anim("blush", [
          [0.7, 250, Ease.out], [0.7, (duration - 0.5) * 1000, Ease.lin], [0, 300, Ease.inOut],
        ]);
        break;
      case "wink":
        this.anim("tilt", [
          [0.12, 160, Ease.out], [0.12, (duration - 0.4) * 1000, Ease.lin], [0, 240, Ease.inOut],
        ]);
        break;
      case "yawn":
        this.anim("sy", [[1.12, 500, Ease.inOut], [1, 500, Ease.inOut]]);
        this.anim("sx", [[0.94, 500, Ease.inOut], [1, 500, Ease.inOut]]);
        setTimeout(() => { this.eyeOverride = "closed"; this.emit("z", 2); }, 700);
        break;
      case "happy":
        // Two bouncy hops and a sparkle.
        this.anim("blush", [[0.6, 200, Ease.out], [0, 600, Ease.inOut]]);
        this.anim("oy", [[-0.26, 140, Ease.out], [0, 180, Ease.easeIn], [-0.13, 120, Ease.out], [0, 200, Ease.back]]);
        this.anim("sy", [[1.12, 140, Ease.out], [0.88, 180, Ease.easeIn], [1.06, 120, Ease.out], [1, 200, Ease.back]]);
        this.anim("sx", [[0.92, 140, Ease.out], [1.1, 180, Ease.easeIn], [0.96, 120, Ease.out], [1, 200, Ease.back]]);
        this.emit("spark", 4);
        break;
      case "annoyed":
        this.eyeOverride = "line";
        this.eyeOverrideUntil = t + 0.8;
        setTimeout(() => Sound.play("annoyed"), 60);
        break;
      case "angry":
        // Red, puffed up, shaking, steaming (EMOTE_EMIT).
        this.anim("ox", shake(0.07, 14, 45));
        this.anim("sy", hold(0.92, duration, 1, 150));
        this.anim("sx", hold(1.07, duration, 1, 150));
        setTimeout(() => Sound.play("annoyed"), 60);
        break;
      case "hype":
        // Crouches, springs up tall and stays charged: fire, bolts, a buzz (draw).
        this.anim("sy", charge([0.72, 1.22, 1.12, 1]));
        this.anim("sx", charge([1.2, 0.88, 0.94, 1]));
        this.anim("oy", charge([0.08, -0.12, -0.08, 0]));
        break;
      case "sad":
        // Slowly droops, head down, crying (drawTears).
        this.anim("sy", hold(0.9, duration, 1, 600));
        this.anim("sx", hold(1.04, duration, 1, 600));
        this.anim("pitch", hold(-0.24, duration, 0, 600));
        this.anim("tilt", hold(0.06, duration, 0, 600));
        break;
      case "shy":
        // Blushes and turns its face away.
        this.anim("blush", hold(1, duration, 0, 250, 350));
        this.anim("yaw", hold(-0.5, duration, 0, 300));
        this.anim("tilt", hold(-0.1, duration, 0, 300));
        break;
      case "scared":
        // A jump, then shivering, pale, with a bead of sweat.
        this.anim("oy", [[-0.22, 110, Ease.out], [0, 300, Ease.back]]);
        this.anim("ox", shake(0.05, Math.max(4, Math.round((duration * 1000) / 55) - 2), 55));
        this.anim("sy", hold(0.92, duration, 1, 150));
        this.emit("sweat", 2);
        break;
      case "confused":
        // Spiral eyes, the head rocking side to side, question marks.
        this.anim("tilt", [
          [0.18, 250, Ease.inOut], [-0.18, 450, Ease.inOut], [0.15, 450, Ease.inOut],
          [-0.1, 400, Ease.inOut], [0, 350, Ease.inOut],
        ]);
        this.emit("mark", 1, { c: "?", x: 0.62, y: -0.95, vx: 0, vy: -0.06, life: 1.6, size: 0.3 });
        break;
      case "sleepy":
        // Eyes droop shut, nods off, jerks awake once, drowsy again.
        this.anim("sy", hold(0.94, duration, 1, 500));
        this.anim("pitch", [
          [-0.3, 1300, Ease.inOut], [0.08, 110, Ease.out], [0.08, 300, Ease.lin],
          [-0.12, Math.max(1, duration * 1000 - 2110), Ease.inOut], [0, 400, Ease.inOut],
        ]);
        later(450, () => { this.eyeOverride = "closed"; });
        later(1300, () => { this.eyeOverride = "wide"; });
        later(1650, () => { this.eyeOverride = "tired"; });
        break;
    }
  }

  /** Flung out all at once in an upward fan, instead of one after another. */
  burst(type: Particle["type"], count: number, speed: number) {
    const n = this.isMini || this.r < 16 ? Math.ceil(count / 2) : count;
    for (let i = 0; i < n; i++) {
      const a = -Math.PI / 2 + (Math.random() - 0.5) * 2.4;
      const v = speed * (0.6 + Math.random() * 0.6);
      this.emit(type, 1, { x: 0, y: -0.55, vx: Math.cos(a) * v, vy: Math.sin(a) * v, age: 0, c: CONFETTI[i % CONFETTI.length] });
    }
  }

  emit(type: Particle["type"], count: number, o: Partial<Particle> = {}) {
    for (let i = 0; i < count; i++) {
      if (this.particles.length >= MAX_PARTICLES) return;
      const isZ = type === "z";
      this.particles.push({
        type,
        x: (Math.random() - 0.5) * 0.9 + (isZ ? 0.55 : 0),
        y: -0.7 - Math.random() * 0.2,
        vx: (Math.random() - 0.5) * 0.35 + (isZ ? 0.18 : 0),
        vy: -(0.45 + Math.random() * 0.35),
        age: -i * 0.14,
        life: 1.3 + Math.random() * 0.5,
        rot: Math.random() * Math.PI * 2,
        size: 0.15 + Math.random() * 0.08,
        ...o,
      });
    }
  }

  animateMorph(target: number, durationMs?: number) {
    const dur = durationMs ?? (target > 0.5 ? 550 : 650);
    this.anim("morph", [[target, dur, Ease.inOut]]);
  }

  resetMorph() {
    this.tweens.delete("morph");
    this.locks.delete("morph");
    this.morph = 0;
  }

  /**
   * Dresses Mochi. Animated: the old outfit leaves (180 ms), the new one drops
   * in (350 ms) and Mochi does a little squash — BotEngine.setOutfit on macOS.
   */
  setOutfit(next: Outfit, animated = true) {
    if (next === this.outfitTarget) return;
    this.outfitTarget = next;
    this.tweens.delete("outfitPresence");
    this.locks.delete("outfitPresence");
    const enter = () => {
      this.outfit = next;
      this.anim("outfitPresence", [[1, 350, Ease.inOut]], () => this.squash());
    };
    if (!animated) {
      this.outfit = next;
      this.outfitPresence = next !== "none" ? 1 : 0;
    } else if (next === "none") {
      this.anim("outfitPresence", [[0, 180, Ease.inOut]], () => { this.outfit = "none"; });
    } else if (this.outfit === "none") {
      this.outfitPresence = 0;
      enter();
    } else {
      this.anim("outfitPresence", [[0, 180, Ease.inOut]], enter);
    }
  }

  /** The outfit is drawn: any Mochi, dressed (the minis too). */
  private get wearsOutfit(): boolean {
    return this.outfit !== "none";
  }

  /** Wearing something visible: the body then turns as one piece when it rolls. */
  private get rigidRoll(): boolean {
    return this.wearsOutfit && this.outfitPresence > 0.05;
  }

  /** True while anything is still moving — lets the island stop its RAF loop. */
  get busy(): boolean {
    return this.moving || this.looping || this.pulsing || this.unsettled;
  }

  /**
   * Nothing moves but the working dots: the island still needs frames, though
   * far fewer than the display hands out.
   */
  get onlyPulsing(): boolean {
    return this.pulsing && !this.moving && !this.looping && !this.unsettled;
  }

  /** The motion a state repeats for as long as it lasts: breathing, a bounce, the z's. */
  get looping(): boolean {
    return (
      this.tweens.size > 0 ||
      this.particles.length > 0 ||
      this.fx !== null ||
      this.cfg.bounces || this.cfg.scans || this.cfg.breathes || this.cfg.zz || this.cfg.sweat ||
      this.isMini ||
      this.isDancing || this.dancingLevel > 0.001
    );
  }

  /** The dots pulse on the clock in drawBadge(), with no tween behind them. */
  private get pulsing(): boolean {
    return this.badge?.kind === "dots" && this.badgeS > 0.001;
  }

  /**
   * Something is on its way somewhere: a tween, eyes turning to the pointer, a
   * colour changing. This is what wants every frame. The loops — a breath, a
   * scan, a bounce, the z's drifting up — chase targets that never settle, and
   * read the same at a third of the frames, so they are not counted here.
   */
  get moving(): boolean {
    return (
      this.tweens.size > 0 ||
      this.lookMoving > 0 ||
      Math.abs(this.tgEs - this.es) > 0.002 ||
      this.slotH > 0.001 || Math.abs(this.slotHVel) > 0.001 ||
      Math.abs(this.col[0] - this.colT[0]) > 0.003 ||
      Math.abs(this.col[1] - this.colT[1]) > 0.003 ||
      Math.abs(this.col[2] - this.colT[2]) > 0.003
    );
  }

  /**
   * Everything else that still draws a new frame: particles, the body catching
   * up with where a loop put its targets, costume physics. Yaw, pitch, tilt and
   * the breath's scale stay unsettled for as long as their loop runs, so they
   * are not in `moving`: a loop would otherwise never count as calm.
   */
  private get unsettled(): boolean {
    return (
      this.particles.length > 0 ||
      Math.abs(this.tgYaw - this.yaw) > 0.002 ||
      Math.abs(this.tgPitch - this.pitch) > 0.002 ||
      Math.abs(this.tgTilt - this.tilt) > 0.002 ||
      Math.abs(this.tgSy - this.sy) > 0.002 ||
      Math.abs(this.tgSx - this.sx) > 0.002 ||
      (this.outfit !== "none" && (Math.abs(this.physVx) > 0.01 || Math.abs(this.physVy) > 0.01))
    );
  }

  /**
   * How long until the next blink is due, 0 once it is, null in the states that
   * never blink. Blinks are started by `update()`, so a stopped loop has to come
   * back for them: the Mac draws every frame while the island is on screen, and
   * without this Mochi would stare until the next hook event.
   */
  msUntilBlink(): number | null {
    if (this.state === "sleeping" || this.state === "dizzy") return null;
    return Math.max(0, (this.nextBlink - now()) * 1000);
  }

  // ── Tweens ──────────────────────────────────────────────────────────────────

  anim(prop: PropKey, keys: TweenKey[], onComplete?: () => void) {
    this.tweens.set(prop, {
      prop, keys, index: 0, from: this[prop], startMs: performance.now(), onComplete,
    });
    this.locks.add(prop);
  }

  // ── Update ──────────────────────────────────────────────────────────────────

  update(dt: number) {
    const n = now();
    const nowMs = performance.now();

    for (const tw of [...this.tweens.values()]) {
      const k = tw.keys[tw.index];
      const p = Math.min(1, Math.max(0, (nowMs - tw.startMs) / k[1]));
      this[tw.prop] = tw.from + (k[0] - tw.from) * k[2](p);
      if (p >= 1) {
        tw.from = k[0];
        tw.index += 1;
        tw.startMs = nowMs;
        if (tw.index >= tw.keys.length) {
          this.tweens.delete(tw.prop);
          this.locks.delete(tw.prop);
          tw.onComplete?.();
        }
      }
    }

    const t = n - this.t0;
    // The pointer turning the eyes: every frame while it does, and a moment after.
    if (!this.isMini && (this.lookX !== this.lookSeenX || this.lookY !== this.lookSeenY)) {
      this.lookSeenX = this.lookX;
      this.lookSeenY = this.lookY;
      this.lookMoving = 0.35;
    } else if (this.lookMoving > 0) {
      this.lookMoving = Math.max(0, this.lookMoving - dt);
    }
    let ty = this.lookX * 0.62;
    let tp = this.lookY * 0.5;

    if (this.cfg.look) {
      ty = ty * 0.35 + this.cfg.look[0] * 0.55;
      tp = tp * 0.3 + this.cfg.look[1] * 0.5;
    }
    if (this.cfg.scans) {
      ty = Math.sin(t * 2.6) * 0.6;
      tp = -0.06;
    }
    if (this.state === "sleeping") { ty = 0; tp = -0.14; }
    if (this.state === "dizzy") { ty = Math.sin(t * 9) * 0.25; }

    // Mini bots never follow the mouse — they wander.
    if (this.isMini && !this.cfg.look && !this.cfg.scans && this.state !== "sleeping" && this.state !== "dizzy") {
      if (n > this.miniLookNextTime) {
        this.miniLookTarget = {
          x: -0.88 + Math.random() * 1.76,
          y: -0.55 + Math.random() * 1.0,
        };
        this.miniLookNextTime = n + 0.5 + Math.random() * 1.5;
      }
      ty = this.miniLookTarget.x * 0.62;
      tp = this.miniLookTarget.y * 0.5;
    }

    this.tgYaw = ty;
    this.tgPitch = tp;
    this.tgTilt = this.cfg.tilt;

    if (n > this.waveStart && n < this.waveUntil) {
      const wt = n - this.waveStart;
      this.tgTilt = -0.06 + Math.sin(2 * Math.PI * 1.2 * wt) * 0.07;
    }

    const bounce = this.cfg.bounces ? -Math.abs(Math.sin(t * 5.2)) * 0.07 : 0;
    const kGen = 1 - Math.pow(0.0008, dt);
    if (!this.locks.has("oy")) this.oy += (bounce - this.oy) * kGen;

    if (this.cfg.breathes) {
      const amp = this.isMini ? 0.07 : 0.035;
      this.tgSy = 1 + Math.sin(t * 1.8) * amp;
      this.tgSx = 1 - Math.sin(t * 1.8) * amp * 0.57;
    } else if (this.isMini) {
      this.tgSy = 1 + Math.sin(t * 2.2) * 0.04;
      this.tgSx = 1 - Math.sin(t * 2.2) * 0.02;
    } else {
      this.tgSy = 1;
      this.tgSx = 1;
    }

    if (this.isMini && n > this.miniNextBehavior) this.doMiniBehaviorLoop();

    const kLook = 1 - Math.pow(0.0025, dt);
    if (!this.locks.has("yaw")) this.yaw += (this.tgYaw - this.yaw) * kLook;
    if (!this.locks.has("pitch")) this.pitch += (this.tgPitch - this.pitch) * kLook;
    if (!this.locks.has("tilt")) this.tilt += (this.tgTilt - this.tilt) * kGen;
    if (!this.locks.has("sy")) this.sy += (this.tgSy - this.sy) * kGen;
    if (!this.locks.has("sx")) this.sx += (this.tgSx - this.sx) * kGen;
    if (!this.locks.has("es")) this.es += (this.tgEs - this.es) * kGen;

    this.col = mix3(this.col, this.colT, 1 - Math.pow(0.002, dt));

    if (n > this.nextBlink) {
      if (this.state !== "sleeping" && this.state !== "dizzy") {
        this.blink();
        if (Math.random() < 0.22) setTimeout(() => this.blink(), 230);
      }
      this.nextBlink = n + 2.2 + Math.random() * 3.2;
    }

    if (this.eyeOverride && n > this.eyeOverrideUntil) {
      this.eyeOverride = this.permanentEye;
      if (this.permanentEye) this.eyeOverrideUntil = Number.POSITIVE_INFINITY;
    }

    if (this.fx) {
      const [type, every, at] = EMOTE_EMIT[this.fx.name] ?? [];
      if (type && every && n > this.fxNext && n < this.fx.t1 - 0.5) {
        this.emit(type, 1, at?.());
        this.fxNext = n + every * (this.isMini || this.r < 16 ? 2 : 1);
      }
      if (n > this.fx.t1) this.fx = null;
    }

    if (n - this.lastAmbient > 1.3) {
      this.lastAmbient = n;
      if (this.cfg.zz) this.emit("z", 1);
      if (!this.isMini && this.cfg.sweat && Math.random() < 0.5) this.emit("sweat", 1);
    }

    for (const p of this.particles) p.age += dt;
    this.particles = this.particles.filter((p) => p.age < p.life);

    // Mouth slot spring — ω₀ = 2π/0.25, ζ = 0.6
    const omega = (2 * Math.PI) / 0.25;
    const zeta = 0.6;
    const acc = omega * omega * (this.slotHTarget - this.slotH) - 2 * zeta * omega * this.slotHVel;
    this.slotHVel += acc * dt;
    this.slotH = Math.max(0, this.slotH + this.slotHVel * dt);

    this.dancingLevel = stepDanceLevel(this.dancingLevel, this.isDancing, dt);

    // Soft-part spring: lags behind head turns, hops and rolls (stiffness 60, damping 9).
    if (dt > 0) {
      const yawVel = (this.yaw - this.prevYaw) / dt;
      const oyVel = (this.oy - this.prevOy) / dt;
      // A finished roll snaps from 2π·turns back to 0: that jump is not motion.
      const dRoll = this.roll - this.prevRoll;
      const rollVel = Math.abs(dRoll) > Math.PI ? 0 : dRoll / dt;
      const centrifugal = this.rigidRoll ? rollVel * 0.18 : 0;
      // Carried across the screen (the roam), they trail behind too.
      const tDx = Math.max(-1, Math.min(1, -yawVel * 0.35 - this.tilt * 2 + centrifugal - this.dragVel.x / 700));
      const tDy = Math.max(-1, Math.min(1, oyVel * 0.5));
      this.physVx += (60 * (tDx - this.physDx) - 9 * this.physVx) * dt;
      this.physVy += (60 * (tDy - this.physDy) - 9 * this.physVy) * dt;
      this.physDx += this.physVx * dt;
      this.physDy += this.physVy * dt;
    }
    this.prevYaw = this.yaw;
    this.prevOy = this.oy;
    this.prevRoll = this.roll;

    this.lastTime = n;
  }

  private doMiniBehaviorLoop() {
    const n = now();
    switch (this.permanentEmote) {
      case "happy":
        if (this.locks.has("oy")) { this.miniNextBehavior = n + 0.4; return; }
        this.anim("oy", [[-0.3, 120, Ease.out], [0.03, 200, Ease.inOut], [0, 160, Ease.back]]);
        this.anim("sy", [[0.82, 80, Ease.out], [1.18, 130, Ease.out], [0.88, 160, Ease.inOut], [1, 200, Ease.back]]);
        this.anim("sx", [[1.15, 80, Ease.out], [0.88, 130, Ease.out], [1.06, 160, Ease.inOut], [1, 200, Ease.back]]);
        this.miniNextBehavior = n + 2.2 + Math.random() * 1.2;
        break;
      case "annoyed":
        if (this.locks.has("yaw")) { this.miniNextBehavior = n + 0.5; return; }
        this.anim("yaw", [
          [-0.65, 50, Ease.out], [0.65, 90, Ease.inOut], [-0.5, 80, Ease.inOut],
          [0.4, 75, Ease.inOut], [-0.2, 70, Ease.inOut], [0, 140, Ease.out],
        ]);
        this.miniNextBehavior = n + 3.0 + Math.random() * 2.5;
        break;
      case "wink":
        this.eyeOverride = "wink";
        this.eyeOverrideUntil = n + 0.55;
        this.anim("tilt", [[0.13, 100, Ease.out], [0.13, 320, Ease.lin], [0, 200, Ease.inOut]]);
        this.miniNextBehavior = n + 2.2 + Math.random() * 2.0;
        break;
      case "love":
        this.emit("heart", 2);
        this.anim("tilt", [[-0.1, 180, Ease.out], [0.1, 340, Ease.inOut], [0, 220, Ease.inOut]]);
        this.miniNextBehavior = n + 2.6 + Math.random() * 1.5;
        break;
      default:
        this.miniNextBehavior = n + 3.0 + Math.random() * 2.0;
    }
  }

  // ── Dancing ─────────────────────────────────────────────────────────────────

  setDancing(dancing: boolean) {
    if (this.isDancing !== dancing) this.isDancing = dancing;
  }

  /**
   * Applies the dance bounce and sway around the bottom of the body. Call it on
   * a saved context, before draw(), with the same size (BotEngine.applyDance).
   */
  applyDance(x: CanvasRenderingContext2D, W: number, H: number) {
    if (this.dancingLevel <= 0.001) return;
    const R = W * 0.3;
    const px = W / 2 + this.ox * R;
    const py = H / 2 + this.particleOverhang / 2 + this.oy * R + R * 0.06 + R * 0.88;
    const d = danceTransform(now(), this.dancingLevel, R);
    x.translate(px + d.dx, py + d.dy);
    x.rotate(d.rotate);
    x.scale(d.sx, d.sy);
    x.translate(-px, -py);
  }

  // ── Draw ────────────────────────────────────────────────────────────────────

  /**
   * Draws hands, body, blush, eyes, mouth, badge and particles into a canvas of
   * `w`×`h` CSS pixels (the caller has already applied the DPR transform).
   */
  draw(x: CanvasRenderingContext2D, W: number, H: number) {
    const R = W * 0.3;
    const shape = shapeOf(this.shape);
    const rx = R * shape.rx;
    const ry = R * shape.ry;
    this.r = R;
    // Charged up (hype), the whole body buzzes.
    const buzz = this.fxLevel("hype") * R * 0.025;
    const cx = W / 2 + this.ox * R + Math.sin(now() * 97) * buzz;
    const cy = H / 2 + this.particleOverhang / 2 + this.oy * R + R * 0.06 + Math.sin(now() * 71) * buzz * 0.5;

    // With an outfit on, a roll turns the whole character — hat included — as
    // one piece instead of rolling the eyes over the body (BotCanvasView, macOS).
    x.save();
    if (this.rigidRoll && Math.abs(this.roll) > 0.001) {
      x.translate(cx, cy);
      x.rotate(this.roll);
      x.translate(-cx, -cy);
    }

    this.drawHandsBehind(x, R, rx, ry, cx, cy);

    x.save();
    x.translate(cx, cy);
    if (this.tilt !== 0) x.rotate(this.tilt);
    x.scale(this.sx, this.sy);

    // A mini with too little room above it (the compact grid's top row, under
    // the screen's edge) wears a smaller hat, scaled about the top of its head.
    const fit = this.wearsOutfit && Number.isFinite(this.outfitRoom)
      ? outfitFit(outfitReach(this.outfit, shape), shape.ry, this.outfitRoom)
      : 1;
    const head = this.wearsOutfit && fit > 0.05
      ? makeHead(R, this.yaw, this.pitch, this.physDx, this.physDy, shape)
      : null;
    const outfitState = { presence: this.outfitPresence, morph: this.morph };
    const dress = (part: typeof drawOutfitFront) => {
      if (!head) return;
      x.save();
      if (fit < 1) {
        x.translate(0, -ry);
        x.scale(fit, fit);
        x.translate(0, ry);
      }
      part(x, this.outfit, head, outfitState);
      x.restore();
    };
    this.drawFire(x, R, rx, ry);
    dress(drawOutfitBehind);

    const body = this.bodyPath(R, shape);
    this.drawBody(x, body, R, rx, ry);

    const blushVal = Math.max(this.blush, this.tint * 0.5) * (1 - this.morph);
    if (blushVal > 0.01) {
      x.save();
      x.clip(body);
      const yOffset = Math.sin(this.yaw) * rx * 0.8;
      x.fillStyle = `rgba(255,120,150,${0.5 * blushVal})`;
      const cheekX = rx * 0.55 * taperAt(shape, 0.23);
      for (const sd of [-1, 1]) {
        x.beginPath();
        x.ellipse(sd * cheekX + yOffset, ry * 0.2, R * 0.17, R * 0.1, 0, 0, Math.PI * 2);
        x.fill();
      }
      x.restore();
    }

    // The panda's patches go under the eyes, which turn white to show on them.
    if (head) drawSkinUnder(x, this.outfit, head, { ...outfitState, eyes: this.eyeSize });
    const skinInk = head && this.skinAlpha > 0.5 ? SKIN_EYE_INK[this.outfit] : undefined;

    // The frog wears Mochi's eyes on its bumps (outfits.ts frogBumps): they
    // slide up as the skin fades in, and leave the body's clip once there.
    let eyes = this.eyePoses(rx, ry, shape).filter((e) => e.vis > 0.04);
    const frog = this.outfit === "frog" && head ? this.skinAlpha : 0;
    if (frog > 0.001 && head) {
      const bumps = frogBumps(head);
      eyes = eyes.map((e) => {
        const b = bumps.find((c) => c.sd === e.sd)!;
        return { ...e, ex: lerp(e.ex, b.x, frog), ey: lerp(e.ey, b.y, frog) };
      });
    }
    this.drawEyes(x, body, R, eyes, lerp(1, FROG_EYE_SCALE, frog), frog < 0.5, skinInk);
    this.drawTears(x, body, R, ry, eyes);
    if (this.morph > 0.05) this.drawMouth(x, body, R);

    dress(drawOutfitFront);

    x.restore();
    x.restore();

    if (this.badge && this.badgeS > 0.01 && this.morph < 0.25) {
      this.drawBadge(x, this.badge, R, cx, cy);
    }
    this.drawParticles(x, R, cx, cy);
  }

  /** How strongly `name`'s per-frame effects show: 0 when it isn't playing,
   *  fading in over 0.3 s and out over its last 0.5 s. */
  private fxLevel(name: BotEmoteName): number {
    if (this.fx?.name !== name) return 0;
    const n = now();
    return Math.max(0, Math.min(1, (n - this.fx.t0) / 0.3, (this.fx.t1 - n) / 0.5));
  }

  /** The hype's purple fire, licking up from behind the body (and a glow). */
  private drawFire(x: CanvasRenderingContext2D, R: number, rx: number, ry: number) {
    const lv = this.fxLevel("hype");
    if (lv <= 0) return;
    const t = now();
    const simple = this.isMini || R < 16;
    if (!simple) {
      const g = x.createRadialGradient(0, 0, R * 0.7, 0, 0, R * 1.5);
      g.addColorStop(0, `rgba(230,90,255,${0.5 * lv * (0.8 + 0.2 * Math.sin(t * 29))})`);
      g.addColorStop(1, "rgba(150,60,255,0)");
      x.fillStyle = g;
      x.beginPath();
      x.arc(0, 0, R * 1.5, 0, Math.PI * 2);
      x.fill();
    }
    const n = simple ? 3 : 7;
    for (const [k, hot, tip] of FIRE) {
      const top = -ry * 0.7 - R * 1.3 * k;
      const g = x.createLinearGradient(0, -ry * 0.5, 0, top);
      g.addColorStop(0, hot);
      g.addColorStop(1, tip);
      x.fillStyle = g;
      x.beginPath();
      for (let i = 0; i < n; i++) {
        const u = (i / (n - 1)) * 2 - 1; // -1 to 1 across the back
        // Two out-of-step waves per tongue: a cheap flicker that never repeats exactly.
        const flick = 0.75 + 0.25 * Math.sin(t * (9 + i * 1.7) + i * 2.1) * Math.sin(t * (5.3 + i) + i);
        const h = R * (1.25 - 0.45 * u * u) * flick * k * lv;
        const bx = u * rx * 0.85;
        const by = -ry * 0.2 + Math.abs(u) * ry * 0.3;
        const tx = bx * 1.3 + Math.sin(t * 6 + i * 1.3) * R * 0.12;
        const ty = by - ry * 0.7 - h;
        const w = R * 0.32 * k * (1 - 0.3 * Math.abs(u));
        const d = by - ty;
        x.moveTo(bx - w, by);
        x.bezierCurveTo(bx - w * 1.1, by - d * 0.55, tx - w * 0.3, ty + d * 0.25, tx, ty);
        x.bezierCurveTo(tx + w * 0.3, ty + d * 0.25, bx + w * 1.1, by - d * 0.55, bx + w, by);
        x.closePath();
      }
      x.fill();
    }
  }

  /** The sad emote's tears, streaming down from under both eyes. */
  private drawTears(x: CanvasRenderingContext2D, body: Path2D, R: number, ry: number, eyes: EyeSpot[]) {
    const lv = this.fxLevel("sad");
    if (lv <= 0 || !this.fx) return;
    const t = now();
    const grow = Math.min(1, (t - this.fx.t0) / 0.7) * lv;
    const w = R * EYE_W * this.eyeSize;
    x.save();
    x.clip(body);
    x.lineCap = "round";
    for (const { ex, ey, fx } of eyes) {
      const y0 = ey + w * 0.6;
      const len = ry * 1.3 * grow;
      x.beginPath();
      for (let k = 0; k <= 8; k++) {
        const y = y0 + (len * k) / 8;
        x.lineTo(ex + Math.sin(y * 0.2 - t * 8) * w * 0.08, y);
      }
      x.strokeStyle = `rgba(110,190,255,${0.9 * lv})`;
      x.lineWidth = w * 0.45 * fx;
      x.stroke();
      if (R >= 16) {
        x.strokeStyle = `rgba(235,248,255,${0.7 * lv})`;
        x.lineWidth = w * 0.08 * fx;
        x.stroke();
      }
    }
    x.restore();
  }

  private bodyPath(R: number, shape: ShapeDef): Path2D {
    const n = 72;
    const tw = R * 1.0;
    const th = R * 0.94;
    const tr = R * 0.42;
    const p = new Path2D();
    const m = this.morph;
    for (let i = 0; i <= n; i++) {
      const a = (i / n) * Math.PI * 2;
      const ca = Math.cos(a);
      const sa = Math.sin(a);
      const sp = shapePoint(shape, ca, sa);
      const px0 = sp.x * R;
      const py0 = sp.y * R;
      let px = px0;
      let py = py0;
      if (m >= 0.005) {
        const rr = rrPoint(ca, sa, tw, th, tr);
        px = lerp(px0, rr.x, m);
        py = lerp(py0, rr.y, m);
      }
      if (i === 0) p.moveTo(px, py);
      else p.lineTo(px, py);
    }
    p.closePath();
    return p;
  }

  /** How much of a full skin's colours shows on the body (it comes and goes with the outfit). */
  private get skinAlpha(): number {
    if (this.isMini || !SKIN_BODY[this.outfit]) return 0;
    return Math.min(1, this.outfitPresence * 2.5) * (1 - this.morph);
  }

  private drawBody(x: CanvasRenderingContext2D, body: Path2D, R: number, rx: number, ry: number) {
    const skin = this.skinAlpha;
    if (this.bodyColor) {
      // Mini bots: flat solid fill — no gradient, no reflection, no highlight
      x.fillStyle = rgba(this.bodyColor, 1);
      x.fill(body);
      if (skin <= 0.001) return;
    } else {
      const g = x.createLinearGradient(rx * 0.7, -ry * 0.85, -rx * 0.8, ry * 0.9);
      g.addColorStop(0, rgba(BASE_TOP));
      g.addColorStop(1, rgba(BASE_BOTTOM));
      x.fillStyle = g;
      x.fill(body);
    }
    x.save();
    if (skin > 0.001) {
      const [top, bottom] = SKIN_BODY[this.outfit]!;
      const pg = x.createLinearGradient(rx * 0.7, -ry * 0.85, -rx * 0.8, ry * 0.9);
      pg.addColorStop(0, top);
      pg.addColorStop(1, bottom);
      x.globalAlpha = skin;
      x.fillStyle = pg;
      x.fill(body);
      // A flat-coloured body only gets the shading while it wears a skin.
      x.globalAlpha = this.bodyColor ? skin : 1;
    }

    const effectiveTint = this.tint * (1 - this.morph);
    if (effectiveTint > 0.01) {
      const tg = x.createLinearGradient(0, ry, 0, -ry);
      tg.addColorStop(0, rgba(this.col, 0.72 * effectiveTint));
      tg.addColorStop(1, rgba(this.col, 0));
      x.fillStyle = tg;
      x.fill(body);
    }
    // An emote's colour (EMOTE_TINT); anger pulses.
    const pulse = this.fx?.name === "angry" ? 0.7 + 0.3 * Math.sin(now() * 14) : 1;
    const mood = this.moodTint * (1 - this.morph) * pulse;
    if (mood > 0.01) {
      const mg = x.createLinearGradient(0, ry, 0, -ry);
      mg.addColorStop(0, rgba(this.moodCol, 0.8 * mood));
      mg.addColorStop(1, rgba(this.moodCol, 0.3 * mood));
      x.fillStyle = mg;
      x.fill(body);
    }

    const sh = x.createRadialGradient(0, 0, R * 0.15, 0, 0, R * 1.25);
    sh.addColorStop(0, "rgba(0,0,0,0)");
    sh.addColorStop(0.6, "rgba(0,0,0,0)");
    sh.addColorStop(1, "rgba(0,0,0,0.2)");
    x.fillStyle = sh;
    x.fill(body);

    const hl = x.createRadialGradient(rx * 0.34, -ry * 0.46, 0, rx * 0.34, -ry * 0.46, R * 0.42);
    hl.addColorStop(0, "rgba(255,255,255,0.55)");
    hl.addColorStop(1, "rgba(255,255,255,0)");
    x.fillStyle = hl;
    x.fill(body);
    x.restore();
  }

  /**
   * Where both eyes sit on the body (sphere projection), local coords, with how
   * much each faces the viewer. `form` narrows the top of the round shapes.
   */
  private eyePoses(rx: number, ry: number, form: ShapeDef): EyeSpot[] {    const spots: EyeSpot[] = [];
    for (const sd of [-1, 1]) {
      const eyeYaw = sd * EYE_SP + this.yaw;
      // Rolling with an outfit on, the whole body turns: the eyes must not roll again.
      let eyePitch = EYE_P + this.pitch + (this.rigidRoll ? 0 : this.roll);
      eyePitch = (((eyePitch + Math.PI) % (Math.PI * 2)) + Math.PI * 2) % (Math.PI * 2) - Math.PI;
      const cp = Math.cos(eyePitch);
      const ey = -Math.sin(eyePitch) * ry + (this.morph > 0 ? ry * 0.14 * this.morph : 0);
      // The onigiri's narrow top pulls eyes inward as they rise.
      const ex = Math.sin(eyeYaw) * cp * rx * taperAt(form, ey / ry);      const fx = lerp(Math.max(0.18, Math.cos(eyeYaw)), 1, this.morph * 0.7);
      const fy = lerp(Math.max(0.18, cp), 1, this.morph * 0.7);
      spots.push({ sd, ex, ey, fx, fy, vis: Math.cos(eyeYaw) * cp });
    }
    return spots;
  }

  /** How big the eyes are drawn, 1 = the outfits' own (a mini's are bigger). */  private get eyeSize(): number {
    return (this.isMini ? 1.9 : 1.0) * this.es;
  }

  private drawEyes(
    x: CanvasRenderingContext2D, body: Path2D, R: number, spots: EyeSpot[],
    scale = 1, clip = true, skinInk?: string,
  ) {    let shape: EyeShape = this.eyeOverride ?? this.cfg.eye;
    // Dancing: happy eyes in the calm states.
    if (this.isDancing && this.dancingLevel > 0.15 && !this.isMini && (this.state === "idle" || this.state === "finished")) {
      shape = "happy";
    }
    if (this.morph > 0.5) {
      if (this.isChewing) shape = "happy";
      else if (this.slotHTarget > 0.05 || this.slotH > 0.1) shape = "cup";
    }

    x.save();
    if (clip) x.clip(body);
    const ink = skinInk ?? (this.isMini ? MINI_INK : INK);
    x.fillStyle = ink;
    x.strokeStyle = ink;

    const ew = R * EYE_W * this.eyeSize * scale;
    const eh = R * EYE_H * this.eyeSize * scale;    for (const { sd, ex, ey, fx, fy } of spots) {
      x.save();
      x.translate(ex, ey);
      x.scale(fx, fy);
      this.drawEyeShape(x, shape, ew, eh, sd, ink);
      x.restore();
    }
    x.restore();
  }

  private drawEyeShape(
    x: CanvasRenderingContext2D, shape: EyeShape,
    w: number, h: number, sd: number, ink: string,
  ) {
    const t = now();
    switch (shape) {
      case "wide":
        this.drawEyeShape(x, "pill", w * 1.16, h * 1.12, sd, ink);
        break;
      case "pill": {
        const hh = Math.max(h * this.open, w * 0.3);
        roundRectPath(x, -w / 2, -hh / 2, w, hh, Math.min(w / 2, hh / 2));
        x.fill();
        break;
      }
      case "dot":
        x.beginPath();
        x.arc(0, 0, w * 0.45, 0, Math.PI * 2);
        x.fill();
        break;
      case "line":
        x.rotate(-sd * 0.2);
        roundRectPath(x, -w * 0.78, -w * 0.21, w * 1.56, w * 0.42, w * 0.21);
        x.fill();
        break;
      case "flat":
        roundRectPath(x, -w * 0.72, -w * 0.2, w * 1.44, w * 0.4, w * 0.2);
        x.fill();
        break;
      case "happy":
        x.lineWidth = w * 0.5;
        x.lineCap = "round";
        x.beginPath();
        x.arc(0, h * 0.18, w * 0.82, Math.PI * 1.12, Math.PI * 1.88);
        x.stroke();
        break;
      case "closed":
        x.lineWidth = w * 0.36;
        x.lineCap = "round";
        x.beginPath();
        x.arc(0, -h * 0.08, w * 0.78, Math.PI * 0.15, Math.PI * 0.85);
        x.stroke();
        break;
      case "spiral": {
        x.lineWidth = w * 0.22;
        x.lineCap = "round";
        x.beginPath();
        for (let a = 0; a < 4.4 * Math.PI; a += 0.2) {
          const r = w * 0.06 + a * w * 0.058;
          const aa = a + t * 9 * sd;
          const px = Math.cos(aa) * r;
          const py = Math.sin(aa) * r;
          if (a === 0) x.moveTo(px, py);
          else x.lineTo(px, py);
        }
        x.stroke();
        break;
      }
      case "heart":
        x.fillStyle = "#FF4D6D";
        heartPath(x, w * 1.2);
        x.fill();
        x.fillStyle = ink;
        break;
      case "star":
        x.fillStyle = "#F7B32B";
        x.rotate(t * 1.5 * sd);
        starPath(x, w * 1.05, w * 0.46);
        x.fill();
        x.fillStyle = ink;
        break;
      case "droop": {
        // A pill whose top lid comes down: the bottom edge stays put.
        const hh = Math.max(h * this.open, w * 0.22);
        roundRectPath(x, -w / 2, h / 2 - hh, w, hh, Math.min(w / 2, hh / 2));
        x.fill();
        break;
      }
      case "tired":
        roundRectPath(x, -w / 2, -h * 0.02, w, h * 0.38, w / 2);
        x.fill();
        roundRectPath(x, -w * 0.62, -h * 0.1, w * 1.24, w * 0.22, w * 0.11);
        x.fill();
        break;
      case "wink":
        if (sd < 0) {
          const hh = Math.max(h * this.open, w * 0.3);
          roundRectPath(x, -w / 2, -hh / 2, w, hh, Math.min(w / 2, hh / 2));
          x.fill();
        } else {
          x.lineWidth = w * 0.5;
          x.lineCap = "round";
          x.beginPath();
          x.arc(0, h * 0.18, w * 0.82, Math.PI * 1.12, Math.PI * 1.88);
          x.stroke();
        }
        break;
      case "teary": {
        // Big glossy eyes brimming with tears; the waterline wobbles.
        const r = w * 0.78;
        x.beginPath();
        for (let i = 0; i <= 24; i++) {
          const a = (i / 24) * Math.PI * 2;
          const rr = r * (1 + Math.max(0, Math.sin(a)) * Math.sin(a * 5 + t * 9) * 0.06);
          x.lineTo(Math.cos(a) * rr, Math.sin(a) * rr * 1.08);
        }
        x.fill();
        x.fillStyle = "rgba(120,195,255,0.6)";
        x.beginPath();
        x.arc(0, 0, r, Math.PI * 0.12, Math.PI * 0.88);
        x.fill();
        x.fillStyle = "#fff";
        for (const [dx, dy, dr] of [[0.3, -0.35, 0.3], [-0.3, 0.22, 0.14]]) {
          x.beginPath();
          x.arc(dx * r, dy * r, dr * r, 0, Math.PI * 2);
          x.fill();
        }
        x.fillStyle = ink;
        break;
      }
      case "angry":
      case "glow": {
        // Cut by a line slanting down to the nose: furrowed (angry) or fired up (glow).
        const k = shape === "angry" ? 0.75 : 0.4;
        const yA = -h * 0.2 + sd * w * k;
        const yB = -h * 0.2 - sd * w * k;
        x.save();
        x.beginPath();
        x.moveTo(-w, yA);
        x.lineTo(w, yB);
        x.lineTo(w, h);
        x.lineTo(-w, h);
        x.clip();
        if (shape === "glow") {
          x.fillStyle = "#F6E6FF";
          x.shadowColor = "#E040FB";
          x.shadowBlur = this.isMini ? 0 : w * 1.2;
        }
        roundRectPath(x, -w / 2, -h / 2, w, h, w / 2);
        x.fill();
        x.restore();
        if (shape === "angry") {
          x.lineWidth = w * 0.26;
          x.lineCap = "round";
          x.beginPath();
          x.moveTo(-w * 0.6, (yA * 0.8 + yB * 0.2) - w * 0.3);
          x.lineTo(w * 0.6, (yA * 0.2 + yB * 0.8) - w * 0.3);
          x.stroke();
        }
        break;
      }
      case "cup": {
        // Flat top, rounded bottom corners (U shape) — used while the box is open
        const hh = Math.max(h * this.open, w * 0.3);
        const cr = Math.min(w / 2, hh / 2);
        x.beginPath();
        x.moveTo(-w / 2, -hh / 2);
        x.lineTo(w / 2, -hh / 2);
        x.lineTo(w / 2, hh / 2 - cr);
        x.quadraticCurveTo(w / 2, hh / 2, w / 2 - cr, hh / 2);
        x.lineTo(-w / 2 + cr, hh / 2);
        x.quadraticCurveTo(-w / 2, hh / 2, -w / 2, hh / 2 - cr);
        x.closePath();
        x.fill();
        break;
      }
    }
  }

  /** Mailbox slot: dark pill cut into the box face, with rim and lip highlights. */
  private drawMouth(x: CanvasRenderingContext2D, body: Path2D, R: number) {
    const m = this.morph;
    const hW = R * 1.8 * m;
    const hH = this.slotH * R * m;
    const hX = -hW / 2;
    const boxTop = -R * (0.88 + 0.06 * m);
    const hY = boxTop + R * 0.08 * m;

    x.save();
    x.clip(body);

    x.strokeStyle = `rgba(255,255,255,${0.55 * m})`;
    x.lineWidth = 1;
    x.lineCap = "round";
    x.beginPath();
    x.moveTo(-R * 0.9 * m, boxTop + 1);
    x.lineTo(R * 0.9 * m, boxTop + 1);
    x.stroke();

    if (hH > 0.8) {
      const hR = Math.min(hW / 2, hH / 2);
      const g = x.createLinearGradient(0, hY, 0, hY + hH);
      g.addColorStop(0, "rgb(7,8,10)");
      g.addColorStop(1, "rgb(16,19,26)");
      roundRectPath(x, hX, hY, hW, hH, hR);
      x.fillStyle = g;
      x.fill();
      if (hH > 4) {
        const lipR = Math.min(hR, (hW - 2) / 2);
        x.strokeStyle = `rgba(255,255,255,${0.28 * m})`;
        x.beginPath();
        x.moveTo(hX + lipR, hY + hH - 0.5);
        x.lineTo(hX + hW - lipR, hY + hH - 0.5);
        x.stroke();
      }
    }
    x.restore();
  }

  /** Hands sit behind the body — drawn before it, in world coordinates. */
  private drawHandsBehind(
    x: CanvasRenderingContext2D,
    R: number, rx: number, ry: number, cx: number, cy: number,
  ) {
    if (this.hands <= 0.01 || this.isMini) return;
    if (R <= 14) return; // meaningless at compact/peek sizes

    const n = now();
    const bodyH = 2 * ry;
    const hew = 0.3 * ry * this.hands;
    const heh = 0.26 * ry * this.hands;
    const hwB = rx * this.sx;
    const hhB = ry * this.sy;
    const isWaving = n >= this.waveStart && this.waveStart > 0 && n < this.waveUntil;

    for (const sd of [-1, 1]) {
      let localX: number;
      let localY: number;
      let handRot = 0;

      if (sd > 0 && isWaving) {
        const wt = n - this.waveStart;
        const rise = Math.min(1, wt / 0.18);
        const riseEased = 1 - Math.pow(1 - rise, 3);
        const restX = hwB * 1.08;
        const restY = hhB * 0.7;
        const oscX = Math.cos(13 * wt) * 0.06 * bodyH;
        const oscY = -Math.sin(13 * wt) * 0.14 * bodyH;
        const waveX = hwB * 1.1 + oscX;
        const waveY = -hhB * 0.15 + oscY;
        localX = restX + (waveX - restX) * riseEased;
        localY = restY + (waveY - restY) * riseEased;
        handRot = (-0.5 + Math.sin(13 * wt) * 0.35) * riseEased;
      } else if (sd < 0 && isWaving) {
        const wt = n - this.waveStart;
        localX = -hwB * 1.08;
        localY = hhB * 0.7 + Math.sin(6 * wt) * 0.04 * bodyH;
      } else {
        localX = sd * hwB * 1.08;
        localY = hhB * 0.7;
      }

      const cosT = Math.cos(this.tilt);
      const sinT = Math.sin(this.tilt);
      const worldX = cx + cosT * localX - sinT * localY;
      const worldY = cy + sinT * localX + cosT * localY;

      x.save();
      x.translate(worldX, worldY);
      if (handRot !== 0) x.rotate(handRot);
      const g = x.createLinearGradient(hew * 0.7, -heh * 0.85, -hew * 0.8, heh * 0.9);
      if (this.bodyColor) {
        g.addColorStop(0, rgba(mix3(this.bodyColor, [1, 1, 1], 0.35)));
        g.addColorStop(1, rgba(this.bodyColor));
      } else {
        g.addColorStop(0, rgba(BASE_TOP));
        g.addColorStop(1, rgba(BASE_BOTTOM));
      }
      x.beginPath();
      x.ellipse(0, 0, hew, heh, 0, 0, Math.PI * 2);
      x.fillStyle = g;
      x.fill();
      x.strokeStyle = "rgba(0,0,0,0.08)";
      x.lineWidth = 1;
      x.stroke();
      x.restore();
    }
  }

  private drawBadge(x: CanvasRenderingContext2D, badge: Badge, R: number, cx: number, cy: number) {
    const bs = this.badgeS * (this.isMini ? 1.25 : 1);
    const bx = cx - R * 0.72 * this.sx;
    const by = cy - R * 0.72 * this.sy;
    const t = now();

    x.save();
    x.translate(bx, by);
    x.scale(bs, bs);
    const col = rgba(badge.color);

    if (badge.kind === "dots") {
      if (this.isMini) {
        const phase = (t * 2.4) % 1;
        const dotR = R * 0.22 * (1 + 0.25 * Math.sin(phase * Math.PI * 2));
        x.fillStyle = "#000";
        x.beginPath();
        x.arc(0, 0, R * 0.2, 0, Math.PI * 2);
        x.fill();
        x.fillStyle = col;
        x.beginPath();
        x.arc(0, 0, dotR, 0, Math.PI * 2);
        x.fill();
      } else {
        const pw = R * 0.72;
        const ph = R * 0.36;
        roundRectPath(x, -pw / 2, -ph / 2, pw, ph, ph / 2);
        x.fillStyle = col;
        x.fill();
        for (let i = 0; i < 3; i++) {
          const phase = (((t * 2.4 - i * 0.22) % 1) + 1) % 1;
          const dotR = R * 0.055 * (1 + 0.4 * Math.max(0, Math.sin(phase * Math.PI * 2)));
          x.fillStyle = "#fff";
          x.beginPath();
          x.arc((i - 1) * R * 0.18, 0, dotR, 0, Math.PI * 2);
          x.fill();
        }
      }
    } else if (badge.kind === "bang" || badge.kind === "question") {
      x.fillStyle = "#000";
      x.beginPath();
      x.arc(0, 0, R * 0.3, 0, Math.PI * 2);
      x.fill();
      x.fillStyle = col;
      x.beginPath();
      x.arc(0, 0, R * 0.23, 0, Math.PI * 2);
      x.fill();
      if (!this.isMini) {
        x.fillStyle = "#fff";
        x.font = `900 ${R * 0.32}px ${FONT}`;
        x.textAlign = "center";
        x.textBaseline = "middle";
        x.fillText(badge.kind === "bang" ? "!" : "?", 0, R * 0.02);
      }
    } else {
      x.fillStyle = "#000";
      x.beginPath();
      x.arc(0, 0, R * 0.2, 0, Math.PI * 2);
      x.fill();
      x.fillStyle = col;
      x.beginPath();
      x.arc(0, 0, R * 0.135, 0, Math.PI * 2);
      x.fill();
    }
    x.restore();
  }

  private drawParticles(x: CanvasRenderingContext2D, R: number, cx: number, cy: number) {
    for (const p of this.particles) {
      if (p.age <= 0) continue;
      const k = p.age / p.life;
      const a = k < 0.2 ? k / 0.2 : 1 - (k - 0.2) / 0.8;
      const px = cx + (p.x + p.vx * p.age) * R * 1.3;
      // Confetti falls: it speeds up as it goes down.
      const fall = (FALL[p.type] ?? 0) * p.age * p.age;
      const py = cy + (p.y + p.vy * p.age + fall) * R * 1.3;
      const sz = R * p.size * (1 + k * 0.4);

      x.save();
      x.translate(px, py);
      x.globalAlpha = Math.min(1, Math.max(0, a));
      switch (p.type) {
        case "heart":
          x.rotate(Math.sin(p.age * 6) * 0.3);
          x.fillStyle = "#FF4D6D";
          heartPath(x, sz);
          x.fill();
          break;
        case "star":
          x.rotate(p.rot + p.age * 2);
          x.fillStyle = "#F7B32B";
          starPath(x, sz, sz * 0.45);
          x.fill();
          break;
        case "spark":
          x.rotate(p.rot);
          x.fillStyle = "#fff";
          starPath(x, sz * 0.8, sz * 0.18);
          x.fill();
          break;
        case "sweat":
          x.fillStyle = "#7CC7FF";
          x.beginPath();
          x.moveTo(0, -sz);
          x.quadraticCurveTo(sz * 0.8, sz * 0.2, 0, sz * 0.6);
          x.quadraticCurveTo(-sz * 0.8, sz * 0.2, 0, -sz);
          x.fill();
          break;
        case "z":
          x.fillStyle = "rgb(209,219,235)";
          x.font = `700 ${sz * 1.9}px ${FONT}`;
          x.textAlign = "center";
          x.textBaseline = "middle";
          x.fillText("z", 0, 0);
          break;
        case "steam":
          x.fillStyle = "rgba(240,240,245,0.9)";
          x.beginPath();
          for (const [dx, dy, dr] of [[0, 0, 0.7], [0.5, -0.2, 0.5], [-0.5, -0.1, 0.55]]) {
            const r = dr * sz * (1 + k);
            x.moveTo(dx * sz + r, dy * sz);
            x.arc(dx * sz, dy * sz, r, 0, Math.PI * 2);
          }
          x.fill();
          break;
        case "bolt":
          x.rotate((p.rot - Math.PI) * 0.15);
          x.fillStyle = k < 0.5 ? "#FFE45C" : "#FF8CE6";
          x.beginPath();
          for (const [bx, by] of [[0.1, -1], [-0.45, 0.1], [-0.05, 0.1], [-0.2, 1], [0.45, -0.15], [0.05, -0.15]]) {
            x.lineTo(bx * sz, by * sz);
          }
          x.fill();
          break;
        case "confetti":
          x.rotate(p.rot + p.age * 7);
          x.scale(1, Math.cos(p.age * 11 + p.rot));
          x.fillStyle = p.c ?? CONFETTI[0];
          x.fillRect(-sz * 0.5, -sz * 0.25, sz, sz * 0.5);
          break;
        case "mark": {
          // Pops in with an overshoot, outlined so it reads on any background.
          const pop = Ease.back(Math.min(1, p.age / 0.2));
          x.scale(pop, pop);
          x.font = `900 ${sz * 2.2}px ${FONT}`;
          x.textAlign = "center";
          x.textBaseline = "middle";
          x.lineJoin = "round";
          x.lineWidth = sz * 0.35;
          x.strokeStyle = INK;
          x.strokeText(p.c ?? "!", 0, 0);
          x.fillStyle = MARK_COLOR[p.c ?? "!"] ?? "#fff";
          x.fillText(p.c ?? "!", 0, 0);
          break;
        }
      }
      x.restore();
    }
  }
}

/** Ray → rounded-rect boundary intersection, for the mailbox morph. */
function rrPoint(ca: number, sa: number, W: number, H: number, cr: number): { x: number; y: number } {
  const eps = 1e-6;
  const kx = ca >= 0 ? 1 : -1;
  const ky = sa >= 0 ? 1 : -1;
  const cx = kx * (W - cr);
  const cy = ky * (H - cr);

  const dot = ca * cx + sa * cy;
  const disc = dot * dot - (cx * cx + cy * cy - cr * cr);
  if (disc >= 0) {
    const t = dot + Math.sqrt(disc);
    if (t > eps) {
      const px = ca * t;
      const py = sa * t;
      if (Math.abs(px) >= W - cr - eps && Math.abs(py) >= H - cr - eps) return { x: px, y: py };
    }
  }
  if (Math.abs(sa) > eps) {
    const t = (ky * H) / sa;
    if (t > eps) {
      const px = ca * t;
      if (Math.abs(px) <= W - cr + eps) return { x: px, y: ky * H };
    }
  }
  if (Math.abs(ca) > eps) {
    const t = (kx * W) / ca;
    if (t > eps) {
      const py = sa * t;
      if (Math.abs(py) <= H - cr + eps) return { x: kx * W, y: py };
    }
  }
  return { x: kx * W, y: ky * H };
}
