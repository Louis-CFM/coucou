"use client";

import { type CSSProperties, useLayoutEffect, useRef, useState } from "react";

import { defaultClock, type IslandClock } from "./clock";
import { useIslandContext, useReducedMotion } from "./context";
import { writeBlur } from "./platform";
import { AnimatedValue, type SpringConfig } from "./spring";

/**
 * Content primitives that animate their own updates the way Live Activities do, on the island's
 * clock (so stepped captures stay exact). Use them inside island content; outside a provider they
 * run on requestAnimationFrame.
 */

/**
 * How a changed digit turns over, from the change (seconds). Fitted per frame on alert-t1 with
 * opacity, blur and scale apart (`scripts/fidelity/alert-tracks.py`, judge round 4, finding 3):
 *
 * - the old digit shrinks to `outScale` and blurs to `blurPerEm` over `outShrink` (frames 261 to
 *   266: scale 0.8 to 0.7, blur 2.7 to 3.3 pt on screen), staying bright, then fades out over
 *   `outFade`;
 * - the new one starts `inDelay` after the change (frame 267), small and soft: it fades in fast
 *   over `inFade`, grows from `inScale` over `inGrow` and sharpens linearly over `inSharpen`
 *   (scale 0.75, blur 3.3 pt at 268; scale 1, blur 0.67 pt at 280; sharp by 287).
 *
 * Blur is set before the scale, so the on-screen blur is the filter's times the scale. Unchanged
 * digits stay put.
 */
export const numberMotion = {
  /** Seconds the incoming digit waits; its windows below count from there. */
  inDelay: 0.2,
  /** Peak blur filter in px per px of font size (on screen, times the digit's scale). */
  blurPerEm: 0.14,
  outShrink: [0.03, 0.21],
  /** Scale the outgoing digit shrinks to. */
  outScale: 0.7,
  outFade: [0.19, 0.26],
  /** Scale the incoming digit grows from. */
  inScale: 0.72,
  inGrow: [0, 0.25],
  // Round 21 (r20a finding 7, r19b, r18a at 0.25x): iOS's "3" goes from unreadable to clear over 4
  // to 5 frames (alert-t1, t2, t9: reads as 3 at -0.49, 0.00, 0.40, 0.65, 0.77 on t1 from +20 frames
  // after the shape starts), the web's over about 1.5 (0.03, 0.76, 0.88). When it first reads was
  // already inside the takes' spread (t2 to t9: 266.1 to 268.6, the web 266.7 on t1's timeline);
  // a slower, linear fade keeps that and is inside the spread on 6 of 7 frames, from 2.
  inFade: [0, 0.16],
  /** Ease-out power of the incoming fade: 1 is linear, higher front-loads it. */
  inFadeEase: 1,
  inSharpen: [0, 0.28],
  /** How far a digit travels as it turns over, in em (counting up comes from below). 0 on iOS 27. */
  roll: 0,
  /**
   * Seconds of the quick crossfade a place gets when its value changes again before its last turn
   * has ended (a value updated faster than a turn lasts). The digit in flight fades out from where
   * it is, and the new one fades in sharp at full size, instead of a second blur starting over the
   * first: a value fed faster than a turn lasts would otherwise stay blurred.
   */
  retarget: 0.12,
} as const satisfies Record<string, number | readonly [number, number]>;

const ramp = (t: number, [from, to]: readonly [number, number]) => {
  const u = Math.min(1, Math.max(0, (t - from) / Math.max(to - from, 1e-4)));
  return u * u * (3 - 2 * u);
};

const linear = (t: number, [from, to]: readonly [number, number]) => Math.min(1, Math.max(0, (t - from) / Math.max(to - from, 1e-4)));

const useClock = (): { clock: IslandClock; reduced: boolean } => {
  const context = useIslandContext();
  const reduced = useReducedMotion(context?.reducedMotion ?? "user");
  return { clock: context?.clock ?? defaultClock(), reduced };
};

/** How one digit looks at a moment of its turn. `blur` is a share of the peak blur, `rise` of the roll distance. */
interface DigitPose {
  opacity: number;
  blur: number;
  scale: number;
  rise: number;
}

/** A character a place draws, and how it looks. */
interface Glyph {
  char: string;
  pose: DigitPose;
}

/**
 * A character a retarget fades out: how it looked when its fade began, and how far into that fade
 * (seconds of the turn's pace) it was when this turn began. Each keeps its own fade, so one caught
 * again by a later retarget goes on fading as before and is gone `retarget` after it was first caught.
 */
interface Fading extends Glyph {
  since: number;
}

/**
 * How a place's turn runs: the full turnover out of `from`, or a quick crossfade out of a turn it
 * interrupted, every glyph that turn still drew (`from`, bottom first) fading from how it was caught.
 */
type TurnMotion = { kind: "roll"; from: string } | { kind: "retarget"; from: readonly Fading[] };

interface Turn {
  /** Clock ms when the turn started. */
  at: number;
  motion: TurnMotion;
}

/**
 * The most glyphs a retarget keeps fading out, besides the one coming in: each is a span (a Safari
 * layer) in the place's cell. A turn caught mid-roll draws two, and each retarget after it adds the
 * one it brought in, while each glyph leaves `retarget` after it was caught. A value changing every
 * 50 ms or slower never needs more; a faster one drops the glyph nearest its end, the faintest.
 */
const maxRetained = 4;

/** Seconds a full turn lasts: the incoming digit is sharp and in, and the outgoing one gone. */
const rollEnd = Math.max(
  numberMotion.inDelay + Math.max(numberMotion.inSharpen[1], numberMotion.inFade[1], numberMotion.inGrow[1]),
  numberMotion.outFade[1],
  numberMotion.outShrink[1],
);

const turnLength = (motion: TurnMotion): number => {
  switch (motion.kind) {
    case "roll":
      return rollEnd;
    case "retarget":
      return numberMotion.retarget;
    default: {
      const exhaustive: never = motion;
      return exhaustive;
    }
  }
};

/** The outgoing digit of a full turn, `t` seconds in. */
const rollOut = (t: number, reduced: boolean): DigitPose => {
  const nm = numberMotion;
  const shrink = reduced ? 0 : ramp(t, nm.outShrink);
  return {
    // Reduced motion is a plain crossfade over the incoming digit's window.
    opacity: reduced ? 1 - linear(t, nm.inFade) : 1 - ramp(t, nm.outFade),
    // Once faded out it draws nothing, so the blur comes off.
    blur: t >= nm.outFade[1] ? 0 : shrink,
    scale: 1 - (1 - nm.outScale) * shrink,
    rise: -ramp(t, nm.outFade),
  };
};

/** The incoming digit of a full turn, `t` seconds in. */
const rollIn = (t: number, reduced: boolean): DigitPose => {
  const nm = numberMotion;
  const tIn = t - (reduced ? 0 : nm.inDelay);
  return {
    opacity: 1 - (1 - linear(tIn, nm.inFade)) ** nm.inFadeEase,
    // The blur falls linearly, so the digit reads soft for most of the ramp and snaps sharp late.
    blur: 1 - linear(tIn, nm.inSharpen),
    scale: nm.inScale + (1 - nm.inScale) * (reduced ? 1 : ramp(tIn, nm.inGrow)),
    rise: 1 - ramp(tIn, nm.inFade),
  };
};

/** A place `t` seconds into its turn: the incoming digit's pose, and each outgoing glyph, bottom first. */
const posesAt = (motion: TurnMotion, t: number, reduced: boolean): { incoming: DigitPose; outgoing: Glyph[] } => {
  switch (motion.kind) {
    case "roll":
      return { incoming: rollIn(t, reduced), outgoing: [{ char: motion.from, pose: rollOut(t, reduced) }] };
    case "retarget": {
      const window = [0, numberMotion.retarget] as const;
      return {
        incoming: { opacity: linear(t, window), blur: 0, scale: 1, rise: 0 },
        // Each keeps the blur and size it was caught at while it fades, and drops the blur once gone.
        outgoing: motion.from.map(({ char, pose, since }) => {
          const fade = linear(t + since, window);
          return { char, pose: { ...pose, opacity: pose.opacity * (1 - fade), blur: fade >= 1 ? 0 : pose.blur } };
        }),
      };
    }
    default: {
      const exhaustive: never = motion;
      return exhaustive;
    }
  }
};

interface Change {
  id: number;
  /**
   * The places with a turn in flight: the ones that turned in this change, and earlier turns at
   * this length that had not ended when it came, which carry on where they are.
   */
  turns: ReadonlyMap<number, Turn>;
  /**
   * Places drawn as cells: every place that has turned at this length. A cell stays mounted once
   * its place has turned, so Safari keeps its layers for the next turn.
   */
  cells: ReadonlySet<number>;
}

/**
 * The turn a place starts when its character changes. A place still turning from an earlier
 * change retargets: every glyph it draws now (`from`, the character it was turning to, and those
 * leaving) fades out quickly from how it looks, so what showed goes on showing as it was and
 * fades (keeping only the more visible of two dropped the other at once: 1 to 2, then 3 after
 * 0.24 s, and the outgoing 1 vanished from 0.198).
 */
const startTurn = ({ previous, from, now, reduced, pace }: { previous: Turn | undefined; from: string; now: number; reduced: boolean; pace: number }): Turn => {
  if (previous === undefined) return { at: now, motion: { kind: "roll", from } };
  const t = ((now - previous.at) / 1000) * pace;
  if (t >= turnLength(previous.motion)) return { at: now, motion: { kind: "roll", from } };
  const { incoming, outgoing } = posesAt(previous.motion, t, reduced);
  // What the place draws now, bottom first as its cell stacks it (the incoming digit under the
  // outgoing ones). A glyph a retarget was already fading keeps its fade; the rest start theirs.
  const caught: Fading[] =
    previous.motion.kind === "retarget"
      ? previous.motion.from.map((glyph) => ({ ...glyph, since: glyph.since + t }))
      : outgoing.map((glyph) => ({ ...glyph, since: 0 }));
  const opacityOf = (glyph: Fading) => glyph.pose.opacity * (1 - linear(glyph.since, [0, numberMotion.retarget]));
  const shown = [{ char: from, pose: incoming, since: 0 }, ...caught].filter((glyph) => opacityOf(glyph) > 0);
  const faintest = [...shown].sort((a, b) => opacityOf(a) - opacityOf(b)).slice(0, Math.max(0, shown.length - maxRetained));
  return { at: now, motion: { kind: "retarget", from: shown.filter((glyph) => !faintest.includes(glyph)) } };
};

/** The glyphs a turn draws leaving, for its cell's spans. */
const leavingOf = (turn: Turn | undefined): readonly string[] => {
  if (!turn) return [];
  switch (turn.motion.kind) {
    case "roll":
      return [turn.motion.from];
    case "retarget":
      return turn.motion.from.map((glyph) => glyph.char);
    default: {
      const exhaustive: never = turn.motion;
      return exhaustive;
    }
  }
};

export interface IslandNumberProps {
  /** The value to show. Numbers render with `toString()`; pass a string to format it yourself. */
  value: number | string;
  /** Class on the wrapper. Defaults to none. */
  className?: string;
  /** Style on the wrapper (font size, weight, colour). Defaults to none. */
  style?: CSSProperties;
  /**
   * Seconds a changed character takes to turn over. Defaults to the Live Activity turn measured on
   * the simulator (0.48 s). A clock that ticks every second wants a shorter one, about 0.25 s, so
   * its changing digit is sharp most of the time. The turn keeps its shape, only faster.
   */
  turn?: number;
}

/**
 * Text whose changed characters turn over with a blur, like a Live Activity's numeric text
 * transition. Digits that stay the same don't move. Aligned from the right, so 9 to 10 turns over
 * both places. A value that changes again mid-turn crossfades quickly from where the turn is, so
 * a fast feed never keeps a digit blurred.
 */
export const IslandNumber = ({ value, className, style, turn }: IslandNumberProps) => {
  const text = String(value);
  const { clock, reduced } = useClock();
  // How much faster than the measured turn this one runs; 1 leaves the measured turn exactly as it is.
  const pace = turn === undefined || turn <= 0 ? 1 : rollEnd / turn;
  const [shown, setShown] = useState(text);
  const [change, setChange] = useState<Change | null>(null);
  if (shown !== text) {
    // Adjusting state while rendering puts the old characters in the same commit as the new ones.
    const old = [...shown];
    const pad = Math.max(0, text.length - old.length);
    const from = [...Array<string>(pad).fill(""), ...old].slice(-text.length);
    const now = clock.now();
    // Places count from the left, so a change of length moves every place: start the cells over.
    const sameLength = change !== null && shown.length === text.length;
    const turns = new Map<number, Turn>();
    if (sameLength) {
      // Earlier turns still in flight carry on; ended ones are dropped, so their cells rest.
      for (const [index, turn] of change.turns) {
        if (((now - turn.at) / 1000) * pace < turnLength(turn.motion)) turns.set(index, turn);
      }
    }
    const turning = [...text].flatMap((char, index) => (from[index] === char ? [] : [index]));
    for (const index of turning) {
      // `from` is what the place shows now: what it was turning to, if it was turning.
      turns.set(index, startTurn({ previous: turns.get(index), from: from[index] ?? "", now, reduced, pace }));
    }
    const kept = sameLength ? change.cells : new Set<number>();
    setShown(text);
    setChange({ id: (change?.id ?? 0) + 1, turns, cells: new Set([...kept, ...turning]) });
  }
  // Outgoing spans by `<place>:<k>`, bottom first: a retarget may keep up to `maxRetained` of them.
  const outgoing = useRef(new Map<string, HTMLSpanElement>());
  const incoming = useRef(new Map<number, HTMLSpanElement>());
  const fontSize = useRef<HTMLSpanElement>(null);

  useLayoutEffect(() => {
    if (!change) return;
    const em = fontSize.current ? Number.parseFloat(getComputedStyle(fontSize.current).fontSize) || 16 : 16;
    const blurMax = reduced ? 0 : numberMotion.blurPerEm * em;
    const roll = reduced ? 0 : numberMotion.roll * em;
    const paint = (element: HTMLSpanElement, pose: DigitPose) => {
      element.style.opacity = `${pose.opacity}`;
      // Both digits stay Safari layers between turns (holdLayer): a place that turns every second
      // reuses them, where building new ones each turn stalled the turn's second frame.
      writeBlur(element, blurMax * pose.blur, true);
      element.style.transform = `translateY(${roll * pose.rise}px) scale(${pose.scale})`;
    };
    const rest = (element: HTMLSpanElement) => {
      element.style.opacity = "0";
      writeBlur(element, 0, true);
    };
    // Done once every place's turn has ended. Each turning place's poses are worked out once a frame.
    const write = (nowMs: number) => {
      let done = true;
      for (const [index, turn] of change.turns) {
        const t = ((nowMs - turn.at) / 1000) * pace;
        if (t < turnLength(turn.motion)) done = false;
        const poses = posesAt(turn.motion, t, reduced);
        const element = incoming.current.get(index);
        if (element) paint(element, poses.incoming);
        for (let k = 0; k < maxRetained; k++) {
          const out = outgoing.current.get(`${index}:${k}`);
          const glyph = poses.outgoing[k];
          if (out && glyph) paint(out, glyph.pose);
          else if (out) rest(out);
        }
      }
      return done;
    };
    // A cell with no turn in this change may have been left mid-turn: put it at rest.
    for (const [index, element] of incoming.current) {
      if (change.turns.has(index)) continue;
      element.style.opacity = "1";
      writeBlur(element, 0, true);
      element.style.transform = "none";
    }
    for (const [key, element] of outgoing.current) {
      if (change.turns.has(Number(key.split(":")[0]))) continue;
      rest(element);
    }
    if (write(clock.now())) return;
    let stop: (() => void) | null = clock.onFrame((now) => {
      if (write(now)) {
        stop?.();
        stop = null;
      }
    });
    return () => {
      stop?.();
      stop = null;
    };
  }, [change, clock, reduced, pace]);

  const chars = [...text];
  // Plain inline (not flex, not inline-block, both of which make one atomic box), so the
  // characters are their container's own text and a slot cut to fit ends them in an ellipsis like
  // plain text: the split capsule shows "4…", not "4:5" clipped mid-digit. A turning cell is one
  // atomic box, so the ellipsis replaces it whole.
  return (
    <span ref={fontSize} className={className} style={{ display: "inline", whiteSpace: "pre", ...style }} aria-label={text} role="text">
      {chars.map((char, index) => {
        const turn = change?.turns.get(index);
        if (!change?.cells.has(index)) {
          return (
            <span key={index} aria-hidden="true">
              {char}
            </span>
          );
        }
        // Old and new share one cell, centred on each other. Keyed by place, not by change, so the
        // next turn of this place reuses the cell and its Safari layers. A resting cell draws only
        // its character: its one outgoing span is empty. A retarget adds a span per glyph it keeps.
        const leaving = leavingOf(turn);
        return (
          <span key={`cell:${index}`} aria-hidden="true" style={{ display: "inline-grid" }}>
            <span
              ref={(element) => {
                if (element) incoming.current.set(index, element);
                else incoming.current.delete(index);
              }}
              style={{ gridArea: "1 /", justifySelf: "center", opacity: turn ? 0 : 1 }}
            >
              {char}
            </span>
            {Array.from({ length: Math.max(1, leaving.length) }, (_, k) => (
              <span
                key={k}
                ref={(element) => {
                  if (element) outgoing.current.set(`${index}:${k}`, element);
                  else outgoing.current.delete(`${index}:${k}`);
                }}
                style={{ gridArea: "1 /", justifySelf: "center" }}
              >
                {leaving[k] ?? ""}
              </span>
            ))}
          </span>
        );
      })}
    </span>
  );
};

export interface IslandProgressProps {
  /** Fill from 0 to 1. Changes ease to the new value. */
  value: number;
  /** Fill colour. Defaults to "#30D158". */
  color?: string;
  /** Track colour. Defaults to "#414141". */
  track?: string;
  /** Bar height in px. Defaults to 8. */
  height?: number;
  /** Corner radius in px. Defaults to half the height (a capsule). */
  radius?: number;
  /**
   * How the fill moves to a new value. Defaults to response 0.97, dampingFraction 0.74: alert-t1's
   * fill end, 0.6 to 0.8, fitted on its 12 fresh frames to 0.3 pt RMS (judge round 3, finding 3).
   */
  spring?: SpringConfig;
  /** Class on the track. Defaults to none. */
  className?: string;
  /** Style on the track. Defaults to none. */
  style?: CSSProperties;
}

const progressSpring: SpringConfig = { response: 0.97, dampingFraction: 0.74 };

/** A capsule progress bar whose fill eases to each new value, as a Live Activity's does. */
export const IslandProgress = ({
  value,
  color = "#30D158",
  track = "#414141",
  height = 8,
  radius,
  spring = progressSpring,
  className,
  style,
}: IslandProgressProps) => {
  const { clock, reduced } = useClock();
  const target = Math.min(1, Math.max(0, value));
  const fill = useRef<HTMLSpanElement>(null);
  const [animated] = useState(() => new AnimatedValue(target, 0.0005));

  useLayoutEffect(() => {
    const element = fill.current;
    if (!element) return;
    const start = clock.now() / 1000;
    animated.set(target, start, reduced ? { kind: "tween", duration: 0.2 } : { kind: "spring", spring });
    const write = (nowMs: number) => {
      const t = nowMs / 1000;
      element.style.width = `${(animated.valueAt(t) * 100).toFixed(3)}%`;
      return animated.isAtRest(t);
    };
    if (write(clock.now())) return;
    let stop: (() => void) | null = clock.onFrame((now) => {
      if (write(now)) {
        stop?.();
        stop = null;
      }
    });
    return () => {
      stop?.();
      stop = null;
    };
  }, [animated, clock, reduced, spring, target]);

  const r = radius ?? height / 2;
  return (
    <span
      className={className}
      role="progressbar"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(target * 100)}
      style={{ display: "block", width: "100%", height, borderRadius: r, background: track, overflow: "hidden", ...style }}
    >
      <span ref={fill} style={{ display: "block", height: "100%", width: `${target * 100}%`, background: color, borderRadius: r }} />
    </span>
  );
};
