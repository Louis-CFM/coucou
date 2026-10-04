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

/** cubic-bezier(x1,y1,x2,y2). */
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

/** Spring-driven value that knows when it has come to rest. */
export class Tracked {
  private spring: Spring;
  private mode: "spring" | "idle" = "idle";

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

  springTo(v: number, response = 0.5, damping = 0.72) {
    this.spring.configure(response, damping);
    this.spring.target = v;
    this.mode = "spring";
  }

  step(dt: number) {
    if (this.mode === "spring") {
      this.spring.step(dt);
      if (this.spring.settled) {
        this.spring.value = this.spring.target;
        this.spring.velocity = 0;
        this.mode = "idle";
      }
    }
  }
}
