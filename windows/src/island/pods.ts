// AirPods. When music starts, Mochi's head opens like the case, the buds rise
// out of their wells and shoot off to the edges of the monitor (the flight
// itself runs on the screen overlay, roam/pods.ts), and the lid snaps shut.
// Fifteen seconds after the music stops the lid opens again, the buds swoop
// back in from the edges, drop into their wells and the lid shuts on them.
// Music notes float off Mochi while it dances, on a canvas over the whole
// panel so they can leave the island.

import { h } from "../views/dom";
import { Bridge } from "../core/bridge";
import { PANEL_H, PANEL_W } from "../core/layout";
import { Ease, clamp } from "../core/anim";
import { DANCE_BPM, LID_SEAM, type BotEngine } from "../mochi/engine";
import { POD_FLIGHT_MS } from "../mochi/airpod";

const LINGER_S = 15;
const OPEN_S = 0.45; // the lid flips up (with a little overshoot)
const RISE_S = 0.35; // the buds lift out of their wells
const SHUT_S = 0.3; // the lid falls shut
const FLIGHT_S = POD_FLIGHT_MS / 1000;
const NOTE_LIFE = 1.6;
const NOTE_COLORS = ["#FA2D48", "#B07CFF", "#5AC8FA", "#FFD60A"];

// Out: open → rise → launch → shut. In: open → buds arrive → sink → shut.
const OUT_LAUNCH = OPEN_S + RISE_S;
const OUT_SHUT = OUT_LAUNCH + 0.35;
const IN_ARRIVE = OPEN_S + FLIGHT_S;
const IN_SHUT = IN_ARRIVE + RISE_S + 0.1;

interface Note {
  x: number; y: number; vx: number; vy: number;
  age: number; glyph: string; color: string; size: number;
}

export interface PodsFrame {
  /** Music is playing (musicDancing). */
  music: boolean;
  /** Mochi is dancing right now (notes fly). */
  dancing: boolean;
  /** The island is on screen and Mochi is in it. */
  visible: boolean;
  islandW: number;
  /** Mochi's centre and size in island coordinates. */
  botX: number;
  botY: number;
  botSize: number;
}

type Phase = "home" | "out" | "away" | "in";

export class Pods {
  readonly el = h("canvas", { id: "pods-canvas" }) as HTMLCanvasElement;
  private phase: Phase = "home";
  private t = 0;
  private launched = false;
  private lastMusic = -Infinity;
  private wasMusic = false;
  private wakeTimer = 0;
  private notes: Note[] = [];
  private nextNoteBeat = 0;
  private drawn = false;

  /** `wake` restarts the island's frame loop: the 15 s wait runs on a timer, not frames. */
  constructor(private wake: () => void) {
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    this.el.width = PANEL_W * dpr;
    this.el.height = PANEL_H * dpr;
  }

  /** Something is still moving: keeps the island's frame loop running. */
  get busy(): boolean {
    return this.phase === "out" || this.phase === "in" || this.notes.length > 0;
  }

  /** Runs the case and the notes for one frame, and poses `engine`'s lid and buds. */
  step(dt: number, f: PodsFrame, engine: BotEngine) {
    const now = performance.now() / 1000;
    // Frames only run while something moves, so the first one after the music
    // stops is when it stopped.
    if (f.music || this.wasMusic) this.lastMusic = now;
    this.wasMusic = f.music;
    const wanted = now - this.lastMusic < LINGER_S;
    if (this.phase === "away" && wanted && !f.music && !this.wakeTimer) {
      this.wakeTimer = window.setTimeout(() => {
        this.wakeTimer = 0;
        this.wake();
      }, (LINGER_S - (now - this.lastMusic)) * 1000 + 50);
    }
    const R = f.botSize * 0.3;
    // Where the buds leave from and land, in panel coordinates.
    const head = {
      x: (PANEL_W - f.islandW) / 2 + f.botX,
      y: f.botY + R * 0.06 - R * LID_SEAM - R * 0.5,
      size: R * 0.95,
    };

    if (this.phase === "home" && wanted && f.music && f.visible) this.go("out");
    else if (this.phase === "away" && !wanted && f.visible) this.go("in");
    // Off screen nothing animates: settle where the sequence was heading.
    if (!f.visible && this.phase === "out") this.phase = "away";
    if (!f.visible && this.phase === "in") this.phase = "home";

    let lid = 0;
    let rise = 0;
    let shown = false;
    const t = (this.t += dt);
    if (this.phase === "out") {
      lid = t < OUT_SHUT ? Ease.back(clamp(t / OPEN_S, 0, 1)) : 1 - Ease.easeIn(clamp((t - OUT_SHUT) / SHUT_S, 0, 1));
      rise = Ease.out(clamp((t - OPEN_S) / RISE_S, 0, 1));
      shown = t < OUT_LAUNCH;
      if (t >= OUT_LAUNCH && !this.launched) {
        this.launched = true;
        void Bridge.podsFlight(true, head.x, head.y, head.size);
      }
      if (t >= OUT_SHUT + SHUT_S) this.land(engine, "away");
    } else if (this.phase === "in") {
      lid = t < IN_SHUT ? Ease.back(clamp(t / OPEN_S, 0, 1)) : 1 - Ease.easeIn(clamp((t - IN_SHUT) / SHUT_S, 0, 1));
      rise = 1 - Ease.inOut(clamp((t - IN_ARRIVE) / RISE_S, 0, 1));
      shown = t >= IN_ARRIVE;
      if (t >= OPEN_S && !this.launched) {
        this.launched = true;
        void Bridge.podsFlight(false, head.x, head.y, head.size);
      }
      if (t >= IN_SHUT + SHUT_S) this.land(engine, "home");
    }
    engine.lid = lid;
    engine.podsRise = rise;
    engine.podsShown = shown;

    this.stepNotes(dt, f, head.x, head.y + R * 0.5, R);
  }

  private go(phase: Phase) {
    this.phase = phase;
    this.t = 0;
    this.launched = false;
  }

  private land(engine: BotEngine, phase: Phase) {
    this.go(phase);
    engine.clack();
  }

  private stepNotes(dt: number, f: PodsFrame, x: number, y: number, R: number) {
    const beat = performance.now() / 1000 * DANCE_BPM / 60;
    if (f.dancing && f.visible && beat >= this.nextNoteBeat) {
      this.nextNoteBeat = Math.floor(beat) + 1;
      const side = Math.floor(beat) % 2 ? 1 : -1;
      this.notes.push({
        x: x + side * R * 0.7,
        y,
        vx: side * (28 + Math.random() * 22),
        vy: -(10 + Math.random() * 14),
        age: 0,
        glyph: Math.random() < 0.5 ? "♪" : "♫",
        color: NOTE_COLORS[Math.floor(Math.random() * NOTE_COLORS.length)],
        size: 11 + Math.random() * 4,
      });
    }
    for (const n of this.notes) n.age += dt;
    this.notes = this.notes.filter((n) => n.age < NOTE_LIFE);

    const ctx = this.el.getContext("2d");
    if (!ctx) return;
    if (!f.visible || this.notes.length === 0) {
      if (this.drawn) {
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.clearRect(0, 0, this.el.width, this.el.height);
        this.drawn = false;
      }
      return;
    }
    this.drawn = true;
    const dpr = this.el.width / PANEL_W;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, PANEL_W, PANEL_H);
    for (const n of this.notes) {
      const k = n.age / NOTE_LIFE;
      ctx.save();
      ctx.globalAlpha = k < 0.15 ? k / 0.15 : 1 - (k - 0.15) / 0.85;
      ctx.translate(n.x + n.vx * n.age, n.y + n.vy * n.age + Math.sin(n.age * 7) * 2);
      ctx.rotate(Math.sin(n.age * 5) * 0.3);
      ctx.fillStyle = n.color;
      ctx.font = `700 ${n.size}px system-ui, "Segoe UI Symbol", sans-serif`;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(n.glyph, 0, 0);
      ctx.restore();
    }
  }
}
