// The beat Mochi dances to. beat.rs sends the tempo and the moment of one beat
// about once a second; the clock below keeps counting beats between those
// messages and eases toward each new one, so a rough estimate never makes him
// jump. Without any (the setting is off, nothing is heard) it counts 112 BPM
// from the wall clock, the Mac's fixed bounce.

export const DEFAULT_BPM = 112;

export interface BeatMessage {
  bpm: number;
  /** Unix time in ms of one beat; the others follow every 60000 / bpm. */
  beatAtMs: number;
  confidence?: number;
}

/** How much of the gap to a new estimate is closed at once. */
const NUDGE = 0.3;
/** Estimates this close to the tempo in use are blended in; farther ones replace it. */
const SAME_TEMPO = 0.06;

let fed = false;
let bpm = DEFAULT_BPM;
/** Beats counted at `t0` (ms). */
let phase0 = 0;
let t0 = 0;

/** Beats since the clock started, as a continuous count: whole numbers are beats. */
export function beatPosition(nowMs: number): number {
  if (!fed) return (nowMs / 1000) * DEFAULT_BPM / 60;
  return phase0 + ((nowMs - t0) / 60000) * bpm;
}

function wrapHalf(x: number): number {
  return x - Math.round(x);
}

/** A new estimate from the listener. */
export function feedBeat(msg: BeatMessage, nowMs: number = Date.now()): void {
  if (!(msg.bpm > 0) || !Number.isFinite(msg.beatAtMs)) return;
  const targetFrac = ((nowMs - msg.beatAtMs) / 60000) * msg.bpm;
  if (!fed) {
    fed = true;
    bpm = msg.bpm;
    phase0 = targetFrac;
    t0 = nowMs;
    return;
  }
  const current = beatPosition(nowMs);
  const err = wrapHalf(targetFrac - current);
  bpm = Math.abs(msg.bpm - bpm) / bpm < SAME_TEMPO ? bpm + 0.5 * (msg.bpm - bpm) : msg.bpm;
  phase0 = current + NUDGE * err;
  t0 = nowMs;
}

/** Back to the fixed bounce: the music stopped, or the listening did. */
export function resetBeat(): void {
  fed = false;
  bpm = DEFAULT_BPM;
}

export function currentBpm(): number {
  return bpm;
}
