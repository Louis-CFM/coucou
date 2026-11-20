export interface SpringConfig {
  /** Seconds for one undamped oscillation. Smaller is faster. */
  response: number;
  /** Damping ratio. 1 settles without overshoot; 0.7 overshoots a little. */
  dampingFraction: number;
  /**
   * Seconds over which a retarget blends from the motion already in flight into the new spring.
   * SwiftUI uses this to soften interruptions. Defaults to 0.
   */
  blendDuration?: number;
}

interface SpringState {
  /** Displacement from the target. */
  x: number;
  v: number;
}

/** Displacement and velocity `t` seconds after release from `x0` with velocity `v0`. */
export const solveSpring = (config: SpringConfig, x0: number, v0: number, t: number): SpringState => {
  const response = Math.max(config.response, 1e-4);
  const zeta = Math.max(config.dampingFraction, 0);
  const w0 = (2 * Math.PI) / response;
  if (t <= 0) return { x: x0, v: v0 };

  if (zeta < 1) {
    const wd = w0 * Math.sqrt(1 - zeta * zeta);
    const decay = Math.exp(-zeta * w0 * t);
    const b = (v0 + zeta * w0 * x0) / wd;
    const cos = Math.cos(wd * t);
    const sin = Math.sin(wd * t);
    const x = decay * (x0 * cos + b * sin);
    const v = decay * (-zeta * w0 * (x0 * cos + b * sin) + (-x0 * wd * sin + b * wd * cos));
    return { x, v };
  }

  if (zeta === 1) {
    const decay = Math.exp(-w0 * t);
    const b = v0 + w0 * x0;
    const x = decay * (x0 + b * t);
    const v = decay * (b - w0 * (x0 + b * t));
    return { x, v };
  }

  const root = Math.sqrt(zeta * zeta - 1);
  const r1 = -w0 * (zeta - root);
  const r2 = -w0 * (zeta + root);
  const c2 = (v0 - r1 * x0) / (r2 - r1);
  const c1 = x0 - c2;
  const e1 = Math.exp(r1 * t);
  const e2 = Math.exp(r2 * t);
  return { x: c1 * e1 + c2 * e2, v: c1 * r1 * e1 + c2 * r2 * e2 };
};

/** How a value moves to a new target. */
export type Transition =
  | { kind: "spring"; spring: SpringConfig; delay?: number }
  /** Eased, no overshoot. Used for reduced motion. A duration of 0 is a step after `delay`. */
  | { kind: "tween"; duration: number; delay?: number }
  | { kind: "instant" };

type Segment =
  | { kind: "static"; value: number }
  | {
      kind: "spring";
      /** Seconds on the island clock when the spring starts. */
      start: number;
      from: number;
      to: number;
      v0: number;
      spring: SpringConfig;
      /** Motion that was in flight when this segment took over, used before `start` and while blending. */
      previous: Segment | null;
      /** Clock time the segment was asked for (before its delay). */
      issued: number;
    }
  | { kind: "tween"; start: number; from: number; to: number; duration: number; previous: Segment | null; issued: number };

const easeOutCubic = (u: number) => 1 - (1 - u) ** 3;
const smoothstep = (u: number) => u * u * (3 - 2 * u);

const sample = (segment: Segment, t: number): { value: number; velocity: number } => {
  switch (segment.kind) {
    case "static":
      return { value: segment.value, velocity: 0 };
    case "tween": {
      if (t < segment.start) {
        return segment.previous ? sample(segment.previous, t) : { value: segment.from, velocity: 0 };
      }
      // A tween of no duration is a step at its start (a lobe absorbed in one go, no in-between).
      if (segment.duration <= 0) return { value: segment.to, velocity: 0 };
      const u = Math.min(1, (t - segment.start) / Math.max(segment.duration, 1e-4));
      const value = segment.from + (segment.to - segment.from) * easeOutCubic(u);
      const velocity = u >= 1 ? 0 : ((segment.to - segment.from) * 3 * (1 - u) ** 2) / segment.duration;
      return { value, velocity };
    }
    case "spring": {
      if (t < segment.start) {
        return segment.previous ? sample(segment.previous, t) : { value: segment.from, velocity: 0 };
      }
      const elapsed = t - segment.start;
      const { x, v } = solveSpring(segment.spring, segment.from - segment.to, segment.v0, elapsed);
      const next = { value: segment.to + x, velocity: v };
      const blend = segment.spring.blendDuration ?? 0;
      if (blend <= 0 || !segment.previous || elapsed >= blend) return next;
      // Blend from the old motion (still heading to its old target) into the new spring.
      const old = sample(segment.previous, t);
      const u = elapsed / blend;
      const w = smoothstep(u);
      const dw = (6 * u * (1 - u)) / blend;
      return {
        value: old.value + (next.value - old.value) * w,
        velocity: old.velocity + (next.velocity - old.velocity) * w + (next.value - old.value) * dw,
      };
    }
    default: {
      const exhaustive: never = segment;
      return exhaustive;
    }
  }
};

const settledAfter = (segment: Segment): number => {
  switch (segment.kind) {
    case "static":
      return -Infinity;
    case "tween":
      return segment.start + segment.duration;
    case "spring":
      return segment.start + (segment.spring.blendDuration ?? 0);
    default: {
      const exhaustive: never = segment;
      return exhaustive;
    }
  }
};

/**
 * One animated number. Retargeting mid-flight starts the new spring from the current value and
 * velocity, so an interrupted expand turns into a collapse without a jump.
 */
export class AnimatedValue {
  private segment: Segment;
  private readonly precision: number;

  /**
   * @param value Starting value.
   * @param precision Distance from the target (and speed) below which the value counts as at rest.
   */
  constructor(value: number, precision = 0.01) {
    this.segment = { kind: "static", value };
    this.precision = precision;
  }

  /** The value the motion is heading to. */
  get target(): number {
    return this.segment.kind === "static" ? this.segment.value : this.segment.to;
  }

  /** Value at `t` seconds on the island clock. */
  valueAt(t: number): number {
    return sample(this.segment, t).value;
  }

  velocityAt(t: number): number {
    return sample(this.segment, t).velocity;
  }

  /**
   * Moves to `to`, starting at clock time `t` (seconds). Delays push the start later. `from`
   * replaces the value and velocity the motion starts with, for a hand-off from another value
   * (the long-press swell folding into the expansion).
   */
  set(to: number, t: number, transition: Transition, from?: { value: number; velocity: number }): void {
    if (transition.kind === "instant") {
      this.segment = { kind: "static", value: to };
      return;
    }
    const start = t + (transition.delay ?? 0);
    const pending = this.segment.kind !== "static" && this.segment.start > t;
    // Legs planned together (same call time, each starting after the last) queue up: a value can
    // head somewhere, then somewhere else, then settle. Any other retarget replaces a pending leg.
    const queued = pending && this.segment.kind !== "static" && this.segment.issued === t && start >= this.segment.start;
    // A pending leg that started from rest has no predecessor: what an earlier call's leg replaces
    // is the value it starts from. Kept as the motion in flight, it still ran: a card whose cut
    // waited on an alert's lag came back on the next change and was cut anyway 1.1 frames later
    // (seed 5511). Legs set in the same call keep the order they were planned in.
    const pendingPrevious: Segment =
      !queued && this.segment.kind !== "static" && this.segment.start > t
        ? (this.segment.previous ?? (this.segment.issued !== t ? { kind: "static", value: this.segment.from } : this.segment))
        : this.segment;
    // A hand-off (`from`) is the value at `t`, the call. A leg that waits (`delay`) drew the motion
    // in flight until it started and then jumped to the hand-off: a long-press swell folded into a
    // swap 0.22 s ahead of its body leg, mid-collapse, put the pill back 13.6 pt taller in one frame
    // (seed 369). A motion still in flight takes the hand-off at `t` instead, and the leg starts
    // from where that has got to. Over a value at rest the hand-off waits for the leg as before
    // (a tap's swell into an expansion, 0.019 s: every canonical expand and press draws it so).
    const flying = sample(pendingPrevious, t);
    const restingAt = pendingPrevious.kind === "static" ? pendingPrevious.value : pendingPrevious.to;
    const moving = Math.abs(flying.value - restingAt) >= this.precision || Math.abs(flying.velocity) >= this.precision * 10;
    const handOff =
      from !== undefined && start > t && moving && (Math.abs(from.value - flying.value) >= this.precision || Math.abs(from.velocity - flying.velocity) >= this.precision * 10);
    const inFlight: Segment = handOff
      ? {
          kind: "spring",
          start: t,
          from: from.value,
          to: pendingPrevious.kind === "static" ? pendingPrevious.value : pendingPrevious.to,
          v0: from.velocity,
          // The motion in flight's own spring; from rest or a tween, the leg's (a tween's as a spring of its length).
          spring:
            pendingPrevious.kind === "spring"
              ? pendingPrevious.spring
              : transition.kind === "spring"
                ? transition.spring
                : { response: Math.max(transition.duration, 1e-3), dampingFraction: 1 },
          previous: null,
          issued: t,
        }
      : pendingPrevious;
    const now = handOff ? sample(inFlight, start) : (from ?? sample(inFlight, start));
    if (to === this.target && Math.abs(now.value - to) < this.precision && Math.abs(now.velocity) < this.precision) {
      return;
    }
    if (transition.kind === "tween") {
      this.segment = { kind: "tween", start, from: now.value, to, duration: transition.duration, previous: inFlight, issued: t };
      return;
    }
    this.segment = {
      kind: "spring",
      start,
      from: now.value,
      to,
      v0: now.velocity,
      spring: transition.spring,
      // A queued leg keeps the leg before it whole, which still needs its own predecessor until it
      // starts. So does a leg after one that starts no earlier than this call: a change stamped
      // ahead of the clock (an alert's `lag`) is drawn before its first leg starts, and without
      // that leg's predecessor those frames held the leg's start value (the pill jumped 22 pt).
      previous: inFlight.kind === "static" ? null : queued || inFlight.start >= t ? inFlight : stripPrevious(inFlight),
      issued: t,
    };
  }

  /** Whether the value has settled by clock time `t`; settled values collapse to static. */
  isAtRest(t: number): boolean {
    if (this.segment.kind === "static") return true;
    if (t < settledAfter(this.segment)) return false;
    const { value, velocity } = sample(this.segment, t);
    const rest = Math.abs(value - this.segment.to) < this.precision && Math.abs(velocity) < this.precision * 10;
    if (rest) this.segment = { kind: "static", value: this.segment.to };
    return rest;
  }
}

/** Keeps the history one level deep so long chains of retargets don't grow without bound. */
const stripPrevious = (segment: Segment): Segment => {
  if (segment.kind === "static") return segment;
  return { ...segment, previous: null };
};
