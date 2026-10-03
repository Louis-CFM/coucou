// Easing + spring helpers.
// Ease.* mirrors BotEngine.swift `enum Ease` (itself the prototype's `E`).
// Spring mirrors SwiftUI `.spring(response:dampingFraction:)` so open/close motion
// matches the macOS app exactly.

export const Ease = {
  out: (t: number) => 1 - Math.pow(1 - t, 3),
  inOut: (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2),
  back: (t: number) => {
    const c1 = 1.7;
    const c3 = c1 + 1;
    return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2);
  },
  lin: (t: number) => t,
  easeIn: (t: number) => t * t * t,
};

export type EaseFn = (t: number) => number;

export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
export const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));
export const seg = (t: number, a: number, b: number) => clamp((t - a) / (b - a), 0, 1);

// ── Colour blending ───────────────────────────────────────────────────────────
// Mixing two colours channel by channel in sRGB dips through a dark, muddy
// middle — GitHub red to green passes through brown. OKLab is built so equal
// steps look equal, which keeps a colour change bright and even throughout.

type Triple = readonly [number, number, number];

const toLinear = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
const toGamma = (c: number) => (c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055);

function rgbToOklab([r, g, b]: Triple): Triple {
  const [lr, lg, lb] = [toLinear(r), toLinear(g), toLinear(b)];
  const l = Math.cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb);
  const m = Math.cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb);
  const s = Math.cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb);
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
}

function oklabToRgb([L, a, b]: Triple): [number, number, number] {
  const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3;
  const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3;
  const s = (L - 0.0894841775 * a - 1.291485548 * b) ** 3;
  return [
    clamp(toGamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s), 0, 1),
    clamp(toGamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s), 0, 1),
    clamp(toGamma(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s), 0, 1),
  ];
}

/** a → b by t, blended in OKLab. Components 0…1, like the engine's RGB. */
export function mixColor(a: Triple, b: Triple, t: number): [number, number, number] {
  const [la, aa, ba] = rgbToOklab(a);
  const [lb, ab, bb] = rgbToOklab(b);
  return oklabToRgb([lerp(la, lb, t), lerp(aa, ab, t), lerp(ba, bb, t)]);
}

/** cubic-bezier(x1,y1,x2,y2) — used for the 340 ms close curve (.45,0,.2,1). */
export function cubicBezier(x1: number, y1: number, x2: number, y2: number): EaseFn {
  const cx = (t: number) => ((1 - t) ** 2 * 3 * t * x1) + (3 * (1 - t) * t * t * x2) + t ** 3;
  const cy = (t: number) => ((1 - t) ** 2 * 3 * t * y1) + (3 * (1 - t) * t * t * y2) + t ** 3;
  return (x) => {
    // Newton-ish bisection on x — 12 iterations is plenty at 60 fps.
    let lo = 0;
    let hi = 1;
    let t = x;
    for (let i = 0; i < 12; i++) {
      const v = cx(t);
      if (v < x) lo = t;
      else hi = t;
      t = (lo + hi) / 2;
    }
    return cy(t);
  };
}

export const closeCurve = cubicBezier(0.45, 0, 0.2, 1);

/**
 * SwiftUI-equivalent spring: ω₀ = 2π / response, ζ = dampingFraction.
 * Integrated per frame (sub-stepped) so a dropped frame never destabilises it.
 */
export class Spring {
  value: number;
  target: number;
  velocity = 0;
  omega: number;
  zeta: number;

  constructor(value: number, response = 0.5, damping = 0.72) {
    this.value = value;
    this.target = value;
    this.omega = (2 * Math.PI) / response;
    this.zeta = damping;
  }

  configure(response: number, damping: number) {
    this.omega = (2 * Math.PI) / response;
    this.zeta = damping;
  }

  set(value: number) {
    this.value = value;
    this.target = value;
    this.velocity = 0;
  }

  get settled(): boolean {
    return Math.abs(this.target - this.value) < 0.01 && Math.abs(this.velocity) < 0.05;
  }

  step(dt: number) {
    const steps = Math.max(1, Math.ceil(dt / (1 / 240)));
    const h = dt / steps;
    for (let i = 0; i < steps; i++) {
      const acc =
        this.omega * this.omega * (this.target - this.value) -
        2 * this.zeta * this.omega * this.velocity;
      this.velocity += acc * h;
      this.value += this.velocity * h;
    }
  }
}

/**
 * Value driven either by a spring (growing) or a timed curve (shrinking) —
 * matches IslandContainer: openSpring for grow, closeEase 340 ms for shrink.
 */
export class Tracked {
  private spring: Spring;
  private curveFrom = 0;
  private curveTo = 0;
  private curveStart = 0;
  private curveDur = 0;
  private mode: "spring" | "curve" | "idle" = "idle";

  constructor(value: number) {
    this.spring = new Spring(value);
  }

  get value(): number {
    return this.spring.value;
  }

  get animating(): boolean {
    return this.mode !== "idle";
  }

  jump(v: number) {
    this.spring.set(v);
    this.mode = "idle";
  }

  /** Spring to `v` (open / grow). */
  springTo(v: number, response = 0.5, damping = 0.72) {
    this.spring.configure(response, damping);
    this.spring.target = v;
    this.mode = "spring";
  }

  /** Timed curve to `v` (close / shrink), no overshoot. */
  curveTowards(v: number, durationMs = 340, now = performance.now()) {
    this.curveFrom = this.spring.value;
    this.curveTo = v;
    this.curveStart = now;
    this.curveDur = durationMs;
    this.spring.target = v;
    this.spring.velocity = 0;
    this.mode = "curve";
  }

  step(dt: number, now = performance.now()) {
    if (this.mode === "spring") {
      this.spring.step(dt);
      if (this.spring.settled) {
        this.spring.value = this.spring.target;
        this.spring.velocity = 0;
        this.mode = "idle";
      }
    } else if (this.mode === "curve") {
      const p = clamp((now - this.curveStart) / this.curveDur, 0, 1);
      this.spring.value = lerp(this.curveFrom, this.curveTo, closeCurve(p));
      if (p >= 1) {
        this.spring.velocity = 0;
        this.mode = "idle";
      }
    }
  }
}
