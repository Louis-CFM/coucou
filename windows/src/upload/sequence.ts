// The drop choreography — port of UploadSequenceEngine.swift, itself a port of
// design/prototype/upload-sequence.html.
//
// The engine is pure arithmetic: it owns no DOM and draws nothing. It takes the
// cursor and a drop time, and hands `frame()` back everything the canvas needs
// for one frame. All coordinates are island points (the island is 640 × 176),
// so every constant below is the macOS constant unchanged.

/** Constants — exact mirror of USC in UploadSequenceEngine.swift. */
export const USC = {
  W: 640,
  ISL_H: 176,
  CARD_X: 10,
  CARD_Y: 42,
  CARD_W: 620,
  CARD_H: 124,
  CARD_R: 20,
  REST_X: 140,
  REST_Y: 104,
  D_BOX: 62,
  FOLLOW_MIN: 60, // CARD_X + 50
  FOLLOW_MAX: 580, // CARD_X + CARD_W - 50
  TEXT_X: 196,
  TEXT_Y: 94,
  BAR_X0: 46,
  BAR_X1: 520,
  BAR_Y: 118,
  CHOOSE_X: 60,
  CHOOSE_Y: 101,
  CHOOSE_D: 62,
  LOCK_IN: 60,
  LOCK_OUT: 90,
  MOUTH_AJAR: 0.2,
  MOUTH_OPEN: 0.42,
  MOUTH_MAX: 0.5,
  // Phase timestamps, in seconds on the reference timeline (drop = 1.95).
  T_DROP: 1.95,
  T_SUCK_START: 2.03,
  T_SUCK_END: 2.33,
  T_CLOSE_END: 2.42,
  T_CHEW1: 2.6,
  T_CHEW_END: 2.88,
  T_SHRINK_END: 3.23,
  T_BAR_IN: 3.0,
  T_PROG_START: 3.25,
  DT: 1 / 240,
  /** Entry offset: gives 0.40 s of following before the drop. */
  ENTRY_T_REF: 1.95 - 0.4,
} as const;

// ── Easing ──────────────────────────────────────────────────────────────────

export const eOut = (t: number) => 1 - Math.pow(1 - t, 3);
export const eIn = (t: number) => t * t * t;
export const eInOut = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
export const eBack = (t: number) => {
  const c1 = 1.70158;
  const c3 = c1 + 1;
  return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2);
};

export const seg = (t: number, a: number, b: number) => Math.max(0, Math.min(1, (t - a) / (b - a)));
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

/** Squeeze keyframes for the suckEnd → chew1 phase. */
function squeezeY(t: number): number {
  const t0 = USC.T_SUCK_END, t1 = t0 + 0.07, t2 = t0 + 0.2, t3 = USC.T_CHEW1;
  if (t <= t0) return 1.06;
  if (t <= t1) return lerp(1.06, 0.82, eOut(seg(t, t0, t1)));
  if (t <= t2) return lerp(0.82, 1.1, eOut(seg(t, t1, t2)));
  if (t <= t3) return lerp(1.1, 1.0, eInOut(seg(t, t2, t3)));
  return 1.0;
}

function squeezeX(t: number): number {
  const t0 = USC.T_SUCK_END, t1 = t0 + 0.07, t2 = t0 + 0.2, t3 = USC.T_CHEW1;
  if (t <= t0) return 0.97;
  if (t <= t1) return lerp(0.97, 1.14, eOut(seg(t, t0, t1)));
  if (t <= t2) return lerp(1.14, 0.95, eOut(seg(t, t1, t2)));
  if (t <= t3) return lerp(0.95, 1.0, eInOut(seg(t, t2, t3)));
  return 1.0;
}

/**
 * Progress curve of the upload bar: quick to 60 %, an unhurried middle, then a
 * last push. A plain ease-out reads as a different animation entirely.
 */
export function uploadProgressCurve(u: number): number {
  if (u < 0.4) return 0.6 * eOut(u / 0.4);
  if (u < 0.85) return 0.6 + 0.32 * eInOut((u - 0.4) / 0.45);
  return 0.92 + 0.08 * eIn((u - 0.85) / 0.15);
}

export function progressAt(t: number, progStart: number, progEnd: number): number {
  return t < progStart ? 0 : uploadProgressCurve(seg(t, progStart, progEnd));
}

// ── Spring ──────────────────────────────────────────────────────────────────

/** The reference `spring(s, target, response, damping, dt)`, integrated by hand. */
class USSpring {
  vel = 0;
  constructor(public v: number) {}

  step(target: number, response: number, damping: number, dt: number) {
    const k = Math.pow((2 * Math.PI) / response, 2);
    const c = 2 * damping * Math.sqrt(k);
    const a = k * (target - this.v) - c * this.vel;
    this.vel += a * dt;
    this.v += this.vel * dt;
  }
}

// ── Frame ───────────────────────────────────────────────────────────────────

export type UploadEyeShape = "pill" | "cup" | "content";

export interface MouthRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface UploadFrame {
  t: number;
  cursorX: number;
  cursorY: number;
  morph: number;
  x: number;
  y: number;
  d: number;
  sx: number;
  sy: number;
  tilt: number;
  hop: number;
  mouth: number;
  mouthRect: MouthRect;
  eye: UploadEyeShape;
  lookX: number;
  lookY: number;
  fileVisible: boolean;
  suck: number;
  zoneOver: boolean;
  zoneAlpha: number;
  textAlpha: number;
  barReveal: number;
  barAlpha: number;
  progress: number;
  flash: number;
  check: number;
  greenWash: number;
  chooseAlpha: number;
  progEnd: number;
  growStart: number;
  growEnd: number;
}

function restFrame(): UploadFrame {
  return {
    t: 0,
    cursorX: 600,
    cursorY: 280,
    morph: 0,
    x: USC.REST_X,
    y: USC.REST_Y,
    d: USC.D_BOX,
    sx: 1,
    sy: 1,
    tilt: 0,
    hop: 0,
    mouth: 0,
    mouthRect: { x: 0, y: 0, w: 0, h: 0 },
    eye: "pill",
    lookX: 0,
    lookY: 0,
    fileVisible: true,
    suck: 0,
    zoneOver: false,
    zoneAlpha: 1,
    textAlpha: 1,
    barReveal: 0,
    barAlpha: 0,
    progress: 0,
    flash: 0,
    check: 0,
    greenWash: 0,
    chooseAlpha: 0,
    progEnd: USC.T_PROG_START + 2.4,
    growStart: USC.T_PROG_START + 2.4 + 0.25,
    growEnd: USC.T_PROG_START + 2.4 + 0.7,
  };
}

// ── Engine ──────────────────────────────────────────────────────────────────

class UploadSequence {
  uploadDuration = 2.4;

  get progEnd() {
    return USC.T_PROG_START + this.uploadDuration;
  }
  get growStart() {
    return this.progEnd + 0.25;
  }
  get growEnd() {
    return this.progEnd + 0.7;
  }

  isActive = false;

  cursorX = 600;
  cursorY = 280;

  private entryWall = 0;
  private dropWall: number | null = null;

  private t = 0;
  private bx = new USSpring(USC.REST_X);
  private by = new USSpring(USC.REST_Y);
  private tilt = 0;
  private mouth = new USSpring(0);
  private locked = false;
  private lockAt = -9;
  private entered = -9;

  private prevX = 600;
  private prevY = 280;
  private prevT = 0;
  private speed = 0;

  private now(): number {
    return performance.now() / 1000;
  }

  // ── Session lifecycle ─────────────────────────────────────────────────────

  /** A file entered the island. Coordinates are island points. */
  enterZone(x: number, y: number) {
    const now = this.now();
    this.cursorX = x;
    this.cursorY = y;
    this.prevX = x;
    this.prevY = y;
    this.prevT = now;
    this.speed = 0;

    this.t = USC.ENTRY_T_REF;
    this.entered = USC.ENTRY_T_REF;
    this.bx = new USSpring(USC.REST_X);
    this.by = new USSpring(USC.REST_Y);
    this.tilt = 0;
    this.mouth = new USSpring(0);
    this.locked = false;
    this.lockAt = -9;

    this.entryWall = now;
    this.dropWall = null;
    this.isActive = true;
  }

  updateCursor(x: number, y: number) {
    const now = this.now();
    const dt = now - this.prevT;
    if (dt > 0.001) {
      this.speed = Math.hypot(x - this.prevX, y - this.prevY) / dt;
    }
    this.prevX = x;
    this.prevY = y;
    this.prevT = now;
    this.cursorX = x;
    this.cursorY = y;
  }

  /** The island stays open per the spec, so leaving the zone changes nothing. */
  exitZone() {}

  performDrop(uploadDuration: number) {
    this.uploadDuration = uploadDuration;
    this.dropWall = this.now();
    // Restart the canonical post-drop timeline however long the user hovered.
    // Spring state (position and velocity) is deliberately preserved.
    this.t = USC.T_DROP;
  }

  deactivate() {
    this.isActive = false;
    this.dropWall = null;
  }

  // ── Reference time from the wall clock ────────────────────────────────────

  private tRef(): number {
    if (!this.isActive) return 0;
    const now = this.now();
    if (this.dropWall != null) return USC.T_DROP + Math.max(0, now - this.dropWall);
    // No cap: the springs keep stepping as long as the user hovers. computeFrame
    // clamps every phase-sensitive output back to the pre-drop state.
    return USC.ENTRY_T_REF + Math.max(0, now - this.entryWall);
  }

  /** True once the file has been dropped (the post-drop timeline is running). */
  get dropped(): boolean {
    return this.dropWall != null;
  }

  /** Seconds since the drop, or null while still dragging. */
  sinceDrop(): number | null {
    return this.dropWall == null ? null : this.now() - this.dropWall;
  }

  // ── Public entry point ────────────────────────────────────────────────────

  frame(): UploadFrame {
    if (!this.isActive) return restFrame();
    const t = this.tRef();
    this.simulateTo(t);
    return this.computeFrame(t);
  }

  // ── Simulation ────────────────────────────────────────────────────────────

  private simulateTo(target: number) {
    // A long stall (a background tab, a dragged window) must not spin here.
    if (target - this.t > 2) this.t = target - 2;
    while (this.t < target - 1e-10) {
      const dt = Math.min(USC.DT, target - this.t);
      this.stepOnce(dt);
      this.t += dt;
    }
  }

  private stepOnce(dt: number) {
    const isDragging = this.dropWall == null;

    // Horizontal follow and lock, only while dragging inside the zone.
    if (isDragging && this.entered >= 0) {
      const dist = Math.hypot(this.cursorX - this.bx.v, this.cursorY + 14 - this.by.v);
      if (!this.locked && dist < USC.LOCK_IN && this.speed < 180) {
        this.locked = true;
        this.lockAt = this.t;
      }
      if (this.locked && dist > USC.LOCK_OUT) this.locked = false;
      const tx = Math.max(USC.FOLLOW_MIN, Math.min(USC.FOLLOW_MAX, this.cursorX));
      const response = this.locked ? 0.18 : 0.35;
      const damping = this.locked ? 0.75 : 0.7;
      this.bx.step(tx, response, damping, dt);
      this.by.step(USC.REST_Y, response, damping, dt);
    }

    // Tilt follows how fast Nova is sliding.
    const tiltTarget = isDragging ? Math.max(-0.18, Math.min(0.18, this.bx.vel * 0.0015)) : 0;
    this.tilt = lerp(this.tilt, tiltTarget, 1 - Math.pow(0.0005, dt));

    // Mouth. The post-drop close only runs once the drop has actually happened.
    const t = this.t;
    if (!isDragging && t >= USC.T_SUCK_END) {
      this.mouth.v = Math.max(0, lerp(USC.MOUTH_MAX, 0, eIn(seg(t, USC.T_SUCK_END, USC.T_CLOSE_END))));
    } else {
      let mt = 0;
      if (this.entered >= 0) mt = this.locked || !isDragging ? USC.MOUTH_OPEN : USC.MOUTH_AJAR;
      if (!isDragging && t < USC.T_SUCK_END) mt = USC.MOUTH_MAX;
      this.mouth.step(mt, 0.25, 0.6, dt);
      if (this.mouth.v < 0) this.mouth.v = 0;
    }
  }

  // ── Frame computation ─────────────────────────────────────────────────────

  private computeFrame(t: number): UploadFrame {
    const f = restFrame();
    f.t = t;
    f.cursorX = this.cursorX;
    f.cursorY = this.cursorY;
    const progEnd = this.progEnd;
    const growStart = this.growStart;
    const growEnd = this.growEnd;
    f.progEnd = progEnd;
    f.growStart = growStart;
    f.growEnd = growEnd;

    const entered = this.entered >= 0 ? this.entered : 1e9;
    const isDragging = this.dropWall == null;
    // Clamp the phase clock to just before the drop while still dragging, so a
    // long hover never trips the post-drop visuals.
    const pt = isDragging ? Math.min(t, USC.T_DROP - USC.DT) : t;

    // Morph: 0→1 on entry, 1→0 shrinking to a ball, 0→1 growing back at choose.
    let morph: number;
    if (pt < USC.T_CHEW_END) morph = eBack(seg(pt, entered, entered + 0.38));
    else if (pt < growStart) morph = 1 - eOut(seg(pt, USC.T_CHEW_END, USC.T_SHRINK_END));
    else morph = eBack(seg(pt, growStart, growEnd));
    f.morph = Math.max(0, Math.min(morph, 1.08));

    // Position and diameter.
    let x = this.bx.v;
    let y = this.by.v;
    let d: number = USC.D_BOX;
    if (pt >= USC.T_CHEW_END && pt < USC.T_PROG_START) {
      const k = eInOut(seg(pt, USC.T_CHEW_END, USC.T_SHRINK_END));
      x = lerp(this.bx.v, USC.BAR_X0, k);
      y = lerp(this.by.v, USC.BAR_Y, k);
      d = lerp(USC.D_BOX, 14, k);
    }
    if (pt >= USC.T_PROG_START) {
      const p = progressAt(pt, USC.T_PROG_START, progEnd);
      x = lerp(USC.BAR_X0, USC.BAR_X1, p);
      y = USC.BAR_Y;
      d = 14;
    }
    if (pt >= progEnd) {
      x = USC.BAR_X1;
      y = USC.BAR_Y - 8 * Math.sin(Math.PI * seg(pt, progEnd, progEnd + 0.2));
    }
    if (pt >= growStart) {
      const k = eInOut(seg(pt, growStart, growEnd));
      x = lerp(USC.BAR_X1, USC.CHOOSE_X, k);
      y = lerp(USC.BAR_Y, USC.CHOOSE_Y, k);
      d = lerp(14, USC.CHOOSE_D, eBack(seg(pt, growStart, growEnd)));
    }
    f.x = x;
    f.y = y;
    f.d = d;

    // Squeeze.
    let sx = 1;
    let sy = 1;
    if (pt >= USC.T_DROP && pt < USC.T_SUCK_START) {
      const k = eOut(seg(pt, USC.T_DROP, USC.T_SUCK_START));
      sy = lerp(1, 0.92, k);
      sx = lerp(1, 1.06, k);
    }
    if (pt >= USC.T_SUCK_START && pt < USC.T_SUCK_END) {
      const k = eInOut(seg(pt, USC.T_SUCK_START, USC.T_SUCK_END));
      sy = lerp(0.92, 1.06, k);
      sx = lerp(1.06, 0.97, k);
    }
    if (pt >= USC.T_SUCK_END && pt < USC.T_CHEW1) {
      sy = squeezeY(pt);
      sx = squeezeX(pt);
    }
    if (pt >= USC.T_CHEW1 && pt < USC.T_CHEW_END) {
      const k = ((pt - USC.T_CHEW1) % 0.14) / 0.14;
      sy = 1 - 0.05 * Math.sin(Math.PI * k);
      sx = 1 + 0.03 * Math.sin(Math.PI * k);
    }
    if (pt >= USC.T_CHEW_END && pt < USC.T_SHRINK_END) {
      const k = seg(pt, USC.T_CHEW_END, USC.T_SHRINK_END);
      sy = 1 + 0.12 * Math.sin(Math.PI * k);
      sx = 1 - 0.06 * Math.sin(Math.PI * k);
    }
    if (pt >= USC.T_PROG_START && pt < progEnd) {
      const v =
        (progressAt(pt + 0.01, USC.T_PROG_START, progEnd) -
          progressAt(pt, USC.T_PROG_START, progEnd)) / 0.01;
      const st = Math.max(0, Math.min(1, v * 0.18));
      sx = 1 + 0.25 * st;
      sy = 1 - 0.15 * st;
    }
    if (pt >= growStart && pt < growEnd) {
      sy = 1 + 0.06 * Math.sin(Math.PI * seg(pt, growStart, growEnd));
    }
    f.sx = sx;
    f.sy = sy;
    f.tilt = this.tilt;
    f.hop =
      this.lockAt > 0 && isDragging
        ? -5 * Math.sin(Math.PI * seg(pt, this.lockAt, this.lockAt + 0.15))
        : 0;

    f.mouth = this.mouth.v;

    // Eyes.
    let eye: UploadEyeShape = "pill";
    if (this.locked && pt < USC.T_SUCK_END) eye = "cup";
    if (pt >= USC.T_SUCK_END && pt < USC.T_CHEW_END + 0.1) eye = "content";
    if (pt >= progEnd && pt < growEnd + 0.3) eye = "content";
    f.eye = eye;

    const lkx = pt < USC.T_SUCK_END ? this.cursorX - x : pt < USC.T_PROG_START ? 0 : 40;
    const lky = pt < USC.T_SUCK_END ? this.cursorY + 10 - y : 0;
    f.lookX = Math.max(-1, Math.min(1, lkx / 200));
    f.lookY = Math.max(-1, Math.min(1, lky / 150));

    f.fileVisible = pt < USC.T_SUCK_END;
    f.suck = seg(pt, USC.T_SUCK_START, USC.T_SUCK_END);

    // Content alphas.
    f.zoneOver = this.entered >= 0 && pt < USC.T_CHEW_END;
    f.zoneAlpha = 1 - seg(pt, USC.T_CHEW_END, USC.T_CHEW_END + 0.2);
    f.textAlpha = f.zoneAlpha * (x > USC.TEXT_X - 40 && isDragging ? 0.25 : 1);
    f.barReveal =
      eOut(seg(pt, USC.T_BAR_IN, USC.T_BAR_IN + 0.25)) * (1 - seg(pt, growStart, growStart + 0.2));
    f.barAlpha =
      seg(pt, USC.T_BAR_IN + 0.05, USC.T_BAR_IN + 0.25) * (1 - seg(pt, growStart, growStart + 0.2));
    f.progress = progressAt(pt, USC.T_PROG_START, progEnd);
    f.flash = pt >= progEnd ? Math.sin(Math.PI * seg(pt, progEnd, progEnd + 0.3)) : 0;
    f.check = pt >= progEnd ? eBack(seg(pt, progEnd, progEnd + 0.25)) : 0;

    const hoverGreen = f.zoneOver ? 0.22 : 0;
    let uploadGreen = 0;
    if (pt >= USC.T_PROG_START) {
      const baseGreen = f.progress * 0.5;
      const flashExtra = pt >= progEnd ? 0.2 * Math.sin(Math.PI * seg(pt, progEnd, progEnd + 0.4)) : 0;
      const fadeOut = 1 - seg(pt, growEnd, growEnd + 0.6);
      uploadGreen = (baseGreen + flashExtra) * fadeOut;
    }
    f.greenWash = Math.max(hoverGreen, uploadGreen);
    f.chooseAlpha = seg(pt, growStart + 0.15, growEnd);

    // Mouth rect in island coordinates — the file is clipped against it.
    const R = f.d / 2 / 1.04;
    const mc = Math.max(0, Math.min(f.morph, 1));
    const rx = R * (1.04 - 0.04 * mc);
    const ry = R * (0.97 - 0.03 * mc);
    const mh = f.mouth * R * mc;
    const mw = 2 * rx - 0.24 * R;
    f.mouthRect = {
      x: x + (-mw / 2) * sx,
      y: y + f.hop + (-ry + 0.1 * R) * sy,
      w: mw * sx,
      h: mh * sy,
    };
    return f;
  }
}

export const UploadSeq = new UploadSequence();
