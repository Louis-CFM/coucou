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
    const val = Number.isFinite(value) ? value : 0;
    this.value = val;
    this.target = val;
    const r = Math.max(0.001, Number.isFinite(response) ? response : 0.5);
    const d = Math.max(0, Number.isFinite(damping) ? damping : 0.72);
    this.omega = (2 * Math.PI) / r;
    this.zeta = d;
  }

  configure(response: number, damping: number) {
    const r = Math.max(0.001, Number.isFinite(response) ? response : 0.5);
    const d = Math.max(0, Number.isFinite(damping) ? damping : 0.72);
    this.omega = (2 * Math.PI) / r;
    this.zeta = d;
  }

  set(value: number) {
    const val = Number.isFinite(value) ? value : 0;
    this.value = val;
    this.target = val;
    this.velocity = 0;
  }

  get settled(): boolean {
    if (!Number.isFinite(this.value) || !Number.isFinite(this.target) || !Number.isFinite(this.velocity)) {
      return true;
    }
    return Math.abs(this.target - this.value) < 0.01 && Math.abs(this.velocity) < 0.05;
  }

  step(dt: number) {
    if (!Number.isFinite(dt) || dt <= 0) return;
    const clampedDt = Math.min(dt, 0.1);
    if (!Number.isFinite(this.value) || !Number.isFinite(this.target) || !Number.isFinite(this.velocity)) {
      this.value = Number.isFinite(this.target) ? this.target : 0;
      this.velocity = 0;
      return;
    }
    const steps = Math.max(1, Math.ceil(clampedDt / (1 / 240)));
    const h = clampedDt / steps;
    for (let i = 0; i < steps; i++) {
      const acc =
        this.omega * this.omega * (this.target - this.value) -
        2 * this.zeta * this.omega * this.velocity;
      this.velocity += acc * h;
      this.value += this.velocity * h;
    }
    if (!Number.isFinite(this.value) || !Number.isFinite(this.velocity)) {
      this.value = this.target;
      this.velocity = 0;
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

  get target(): number {
    return this.spring.target;
  }

  get animating(): boolean {
    return this.mode !== "idle";
  }

  jump(v: number) {
    const val = Number.isFinite(v) ? v : 0;
    this.spring.set(val);
    this.mode = "idle";
  }

  /** Spring to `v` (open / grow). */
  springTo(v: number, response = 0.5, damping = 0.72) {
    const val = Number.isFinite(v) ? v : 0;
    this.spring.configure(response, damping);
    this.spring.target = val;
    this.mode = "spring";
  }

  /** Timed curve to `v` (close / shrink), no overshoot. */
  curveTowards(v: number, durationMs = 340, now = performance.now()) {
    const val = Number.isFinite(v) ? v : 0;
    const dur = Math.max(1, Number.isFinite(durationMs) ? durationMs : 340);
    this.curveFrom = Number.isFinite(this.spring.value) ? this.spring.value : val;
    this.curveTo = val;
    this.curveStart = Number.isFinite(now) ? now : performance.now();
    this.curveDur = dur;
    this.spring.target = val;
    this.spring.velocity = 0;
    this.mode = "curve";
  }

  step(dt: number, now = performance.now()) {
    if (!Number.isFinite(dt) || dt <= 0) return;
    if (this.mode === "spring") {
      this.spring.step(dt);
      if (this.spring.settled) {
        this.spring.value = this.spring.target;
        this.spring.velocity = 0;
        this.mode = "idle";
      }
    } else if (this.mode === "curve") {
      const curNow = Number.isFinite(now) ? now : performance.now();
      const p = clamp((curNow - this.curveStart) / this.curveDur, 0, 1);
      this.spring.value = lerp(this.curveFrom, this.curveTo, closeCurve(p));
      if (p >= 1 || !Number.isFinite(this.spring.value)) {
        this.spring.value = this.curveTo;
        this.spring.velocity = 0;
        this.mode = "idle";
      }
    }
  }
}
