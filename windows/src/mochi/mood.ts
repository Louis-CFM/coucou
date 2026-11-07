// Mochi feels the computer — port of NotchBuddy/Sources/CoucouKit/MochiMood.swift.
//
// A busy processor makes him panic (hops, darting eyes, sweat), a warm machine
// flushes him, short memory puffs him up, a low battery gives him heavy eyelids
// and, nearly empty, puts him to sleep. The levels come from Rust
// (src-tauri/src/vitals.rs) through `engine.moodTarget`; everything here is
// animation, eased frame by frame like the Mac's extension of BotEngine.

import { Ease } from "../core/anim";
import type { BotEngine, TweenKey } from "./engine";

/** How the computer is doing, as Mochi shows it (MochiMood). */
export interface MochiMood {
  /** The processor is at full load: Mochi sweats and hops about. */
  busy: number;
  /** The machine is warm: Mochi flushes red, with heat waves above his head. */
  hot: number;
  /** Memory is short: Mochi puffs up, like after a big meal. */
  full: number;
  /** The battery is low: heavy eyelids, a yawn now and then. */
  tired: number;
  /** The battery is nearly empty: Mochi sleeps. */
  asleep: boolean;
}

export const CALM: MochiMood = { busy: 0, hot: 0, full: 0, tired: 0, asleep: false };

/** A drop of sweat thrown from Mochi's side, in his units (R) from his resting centre. */
export interface MoodDrop {
  x: number; y: number; vx: number; vy: number;
  born: number; size: number; stretch: number; tint: number; alpha: number; wobble: number;
}

/** One of Mochi's stressed hops, from side to side. */
export interface MoodHop {
  from: number; to: number; start: number; duration: number; height: number; rest: number; landed: boolean;
}

export const restingHop = (): MoodHop => ({ from: 0, to: 0, start: 0, duration: 0.2, height: 0, rest: 0, landed: true });

/** Gravity of the sweat drops, in R per second². */
const DROP_GRAVITY = 6.0;

const rand = (a: number, b: number) => a + Math.random() * (b - a);

const DOUBLE_BLINK: TweenKey[] = [
  [0.06, 60, Ease.inOut], [1, 90, Ease.out], [0.06, 60, Ease.inOut], [1, 120, Ease.out],
];

/** States where the computer's mood shows: Mochi is not asking for anything. */
function moodShows(e: BotEngine): boolean {
  return e.state === "idle" || e.state === "working" || e.state === "thinking" ||
    e.state === "searching" || e.state === "finished";
}

/** True while a mood still has something to animate (keeps the frame loop alive). */
export function moodAnimating(e: BotEngine): boolean {
  if (e.isMini) return false;
  const t = e.moodTarget;
  return e.moodDrops.length > 0 || !e.hop.landed || Math.abs(e.hop.to) > 0.005 ||
    t.busy > 0 || t.hot > 0 || t.full > 0 || t.tired > 0 || t.asleep ||
    e.moodBusy > 0.01 || e.moodHot > 0.01 || e.moodFull > 0.01 || e.moodTired > 0.01;
}

/** Takes back last frame's hop offset before anything else moves Mochi. */
export function undoMoodOffsets(e: BotEngine) {
  if (e.moodShiftApplied !== 0) { e.ox -= e.moodShiftApplied; e.moodShiftApplied = 0; }
  if (e.moodLiftApplied !== 0) { e.oy -= e.moodLiftApplied; e.moodLiftApplied = 0; }
}

/** Eases the mood levels towards `moodTarget` and plays their animations. */
export function updateMood(e: BotEngine, dt: number, now: number) {
  if (e.isMini) return;
  const shows = moodShows(e);
  const calmState = e.state === "idle" || e.state === "finished";
  const target = e.moodTarget;
  const k = 1 - Math.pow(0.25, dt);
  e.moodBusy += ((shows ? target.busy : 0) - e.moodBusy) * k;
  e.moodHot += ((shows ? target.hot : 0) - e.moodHot) * k;
  e.moodFull += ((shows ? target.full : 0) - e.moodFull) * k;
  e.moodTired += ((calmState ? target.tired : 0) - e.moodTired) * k;
  const sleeping = calmState && target.asleep;

  updateStress(e, now);

  // Full memory: puffed up.
  if (e.moodFull > 0.02) {
    e.tgSx *= 1 + 0.07 * e.moodFull;
    e.tgSy *= 1 - 0.035 * e.moodFull;
  }

  // Sweat: drops thrown from his sides, in bursts while the processor is at full
  // load, now and then when the machine is only warm.
  if (now > e.nextMoodDrop) {
    if (e.moodBusy > 0.4) {
      throwDrop(e, now);
      if (Math.random() < 0.35) throwDrop(e, now);
      e.nextMoodDrop = now + rand(0.18, 0.4);
    } else if (e.moodHot > 0.6) {
      throwDrop(e, now);
      e.nextMoodDrop = now + rand(0.6, 1.1);
    } else {
      e.nextMoodDrop = now + 0.3;
    }
  }
  e.moodDrops = e.moodDrops.filter((d) => {
    const a = now - d.born;
    return !(a > 1.6 || d.y + d.vy * a + (DROP_GRAVITY * a * a) / 2 > 1.05);
  });

  // Low battery: heavy eyes, the odd yawn; nearly empty: asleep with his z's.
  const ownEye = e.eyeOverride == null || e.eyeOverride === "tired" || e.eyeOverride === "closed";
  if (sleeping) {
    if (ownEye) { e.eyeOverride = "closed"; e.eyeOverrideUntil = now + 0.4; }
    e.tgYaw = 0;
    e.tgPitch = -0.14;
    if (now > e.nextMoodYawn) {
      e.emit("z", 1);
      e.nextMoodYawn = now + 1.6;
    }
  } else if (e.moodTired > 0.5) {
    if (ownEye) { e.eyeOverride = "tired"; e.eyeOverrideUntil = now + 0.4; }
    e.tgPitch -= 0.06 * e.moodTired;
    if (now > e.nextMoodYawn) {
      if (e.nextMoodYawn > 0) e.triggerEmote("yawn");
      e.nextMoodYawn = now + 24 + Math.random() * 12;
    }
  }
}

/**
 * The processor at full load: Mochi panics, hopping from side to side at random,
 * quick and short, leaning into each hop, squashing when he lands, eyes darting.
 */
function updateStress(e: BotEngine, now: number) {
  const level = e.moodBusy;
  const hop = e.hop;
  if (!(level > 0.02 || Math.abs(hop.to) > 0.005 || !hop.landed)) {
    e.stressTremble = { x: 0, y: 0 };
    return;
  }
  const p = hop.duration > 0 ? Math.min(1, (now - hop.start) / hop.duration) : 1;
  if (p >= 1) {
    if (!hop.landed) {
      hop.landed = true;
      // The landing squash.
      e.anim("sy", [[0.86, 60, Ease.out], [1.0, 140, Ease.out]]);
      e.anim("sx", [[1.1, 60, Ease.out], [1.0, 140, Ease.out]]);
    }
    if (now > hop.start + hop.duration + hop.rest) {
      // Next hop: somewhere else on the floor, never twice the same.
      let next = 0;
      if (level > 0.3) {
        do { next = rand(-0.28, 0.28); } while (Math.abs(next - hop.to) < 0.12);
      }
      e.hop = {
        from: hop.to, to: next, start: now, duration: rand(0.22, 0.4),
        height: level > 0.3 ? rand(0.07, 0.18) : 0.05, rest: rand(0.1, 0.55), landed: false,
      };
    }
  }
  const h = e.hop;
  const q = Math.min(1, h.duration > 0 ? (now - h.start) / h.duration : 1);
  const eased = q < 0.5 ? 2 * q * q : 1 - Math.pow(-2 * q + 2, 2) / 2;
  const x = h.from + (h.to - h.from) * eased;
  const lift = Math.sin(Math.PI * q) * h.height * (h.landed ? 0 : 1);
  const dir = h.to >= h.from ? 1 : -1;
  const amount = Math.min(1, level * 1.4);
  if (!e.locks.has("ox")) {
    e.moodShiftApplied = x * amount;
    e.ox += e.moodShiftApplied;
  }
  if (!e.locks.has("oy")) {
    e.moodLiftApplied = -lift * amount;
    e.oy += e.moodLiftApplied;
  }
  if (!h.landed) e.tgTilt += dir * 0.12 * Math.sin(Math.PI * q) * amount;

  // A scared look: the eyes dart from spot to spot, quick and jerky, tremble,
  // and blink nervously, sometimes twice.
  if (level > 0.3) {
    if (now > e.nextStressLook) {
      const back = Math.random() < 0.3;
      e.stressLook = {
        x: back ? -e.stressLook.x * 0.8 : rand(-0.85, 0.85),
        y: rand(-0.3, 0.18),
      };
      e.nextStressLook = now + rand(0.16, 0.45);
    }
    e.tgYaw = e.stressLook.x;
    e.tgPitch = e.stressLook.y;
    // Snap towards the new spot faster than a calm look.
    if (!e.locks.has("yaw")) e.yaw += (e.tgYaw - e.yaw) * 0.2 * amount;
    if (!e.locks.has("pitch")) e.pitch += (e.tgPitch - e.pitch) * 0.2 * amount;
    if (now > e.nextNervousBlink) {
      if (e.nextNervousBlink > 0 && !e.locks.has("open")) {
        if (Math.random() < 0.3) e.anim("open", DOUBLE_BLINK);
        else e.blink();
      }
      e.nextNervousBlink = now + rand(1.0, 2.4);
    }
  }
  const tremble = Math.min(1, level * 1.3);
  e.stressTremble = tremble > 0.01
    ? { x: Math.sin(now * 63) * 0.012 * tremble, y: Math.cos(now * 51) * 0.01 * tremble }
    : { x: 0, y: 0 };
}

function throwDrop(e: BotEngine, now: number) {
  const side = Math.random() < 0.5 ? 1 : -1;
  // Now and then a small round droplet, mostly a full drop.
  const small = Math.random() < 0.3;
  e.moodDrops.push({
    x: side * rand(0.92, 1.05) + e.ox, y: rand(-0.5, -0.25) + e.oy,
    vx: side * rand(0.5, 1.0), vy: -rand(1.5, 2.4),
    born: now,
    size: small ? rand(0.09, 0.13) : rand(0.15, 0.26),
    stretch: small ? rand(0.75, 0.95) : rand(1.0, 1.55),
    tint: Math.random(), alpha: rand(0.7, 1), wobble: Math.random() * 2 * Math.PI,
  });
  if (e.moodDrops.length > 28) e.moodDrops.shift();
}

/** Red flush on the body while the machine is warm (inside the body's transform). */
export function drawMoodTint(e: BotEngine, x: CanvasRenderingContext2D, body: Path2D, ry: number) {
  if (e.moodHot <= 0.01 || e.morph >= 0.5 || e.isMini) return;
  const a = e.moodHot * (1 - e.morph * 2);
  const g = x.createLinearGradient(0, ry, 0, -ry * 0.6);
  g.addColorStop(0, `rgba(255,92,61,${0.42 * a})`);
  g.addColorStop(1, "rgba(255,92,61,0)");
  x.save();
  x.fillStyle = g;
  x.fill(body);
  x.restore();
}

/** What goes over Mochi in world space: sweat drops and heat waves. */
export function drawMoodExtras(
  e: BotEngine, x: CanvasRenderingContext2D, R: number, ry: number, cx: number, cy: number, now: number,
) {
  if (e.isMini || e.morph >= 0.3) return;
  const t = now - e.t0;

  // Sweat: each drop follows its arc from where it left Mochi's side.
  if (e.moodDrops.length > 0) {
    const baseX = cx - e.ox * R;
    const baseY = cy - e.oy * R;
    for (const d of e.moodDrops) {
      const a = now - d.born;
      if (a < 0) continue;
      const px = d.x + d.vx * a;
      const py = d.y + d.vy * a + (DROP_GRAVITY * a * a) / 2;
      const vy = d.vy + DROP_GRAVITY * a;
      x.save();
      x.globalAlpha = d.alpha * Math.min(1, a / 0.06) * Math.min(1, Math.max(0, (1.05 - py) / 0.25));
      x.translate(baseX + px * R, baseY + py * R);
      x.rotate(Math.atan2(vy, d.vx) - Math.PI / 2);
      // It wobbles a little as it flies.
      const wob = 1 + Math.sin(a * 22 + d.wobble) * 0.08;
      const s = R * d.size;
      const long = d.stretch * wob;
      const tear = new Path2D();
      tear.moveTo(0, -s * 1.15 * long);
      tear.quadraticCurveTo((s * 0.9) / wob, s * 0.2, 0, s * 0.7);
      tear.quadraticCurveTo((-s * 0.9) / wob, s * 0.2, 0, -s * 1.15 * long);
      // From a pale sky blue to a deeper blue, lighter at the top.
      const g = x.createLinearGradient(0, -s * long, 0, s * 0.7);
      g.addColorStop(0, `rgb(${255 * (0.72 - 0.2 * d.tint)},${255 * (0.88 - 0.12 * d.tint)},255)`);
      g.addColorStop(1, `rgb(${255 * (0.36 - 0.12 * d.tint)},${255 * (0.68 - 0.14 * d.tint)},250)`);
      x.fillStyle = g;
      x.fill(tear);
      x.fillStyle = `rgba(255,255,255,${0.4 + 0.35 * d.tint})`;
      x.beginPath();
      x.ellipse(-s * 0.25, -s * 0.1 * long + s * 0.16 * long, s * 0.11, s * 0.16 * long, 0, 0, Math.PI * 2);
      x.fill();
      x.restore();
    }
  }

  // Heat waves: three wavy lines rising above the head.
  if (e.moodHot > 0.5) {
    const a = (e.moodHot - 0.5) * 2;
    for (let i = 0; i < 3; i++) {
      const x0 = cx + (i - 1) * R * 0.42;
      const phase = t * 3 + i * 1.7;
      const rise = (t * 0.6 + i * 0.33) % 1;
      const top = cy - ry * 1.18 - R * 0.55 * rise;
      const len = R * 0.5;
      x.save();
      x.globalAlpha = a * Math.sin(rise * Math.PI);
      x.strokeStyle = "rgb(255,140,77)";
      x.lineWidth = Math.max(1, R * 0.07);
      x.lineCap = "round";
      x.beginPath();
      for (let s = 0; s <= 12; s++) {
        const f = s / 12;
        const wx = x0 + Math.sin(phase + f * 6) * R * 0.07;
        const wy = top - f * len;
        if (s === 0) x.moveTo(wx, wy); else x.lineTo(wx, wy);
      }
      x.stroke();
      x.restore();
    }
  }
}
