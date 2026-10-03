// AirPods: when music starts, Mochi's head opens like the case and two buds
// fly out to either side of the island, bobbing to the beat. Fifteen seconds
// after the music stops they fly home and the lid shuts. Music notes float off
// Mochi while it dances. Drawn on a canvas over the whole panel, so the buds and
// notes can leave the island.

import { h } from "../views/dom";
import { PANEL_H, PANEL_W } from "../core/layout";
import { DANCE_BPM, LID_SEAM } from "../mochi/engine";

const LINGER_S = 15;
const LID_S = 0.35;
const FLY_S = 0.75;
const NOTE_COLORS = ["#FA2D48", "#B07CFF", "#5AC8FA", "#FFD60A"];

interface Note {
  x: number; y: number; vx: number; vy: number;
  age: number; glyph: string; color: string; size: number;
}

export interface PodsFrame {
  /** Music is playing (musicDancing). */
  music: boolean;
  /** Mochi is dancing right now (notes fly). */
  dancing: boolean;
  /** Nothing to draw (hidden island, roaming Mochi). */
  visible: boolean;
  islandW: number;
  /** Mochi's centre and size in island coordinates. */
  botX: number;
  botY: number;
  botSize: number;
}

const easeInOut = (t: number) => (t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2);

export class Pods {
  readonly el = h("canvas", { id: "pods-canvas" }) as HTMLCanvasElement;
  /** The lid, 0 shut … 1 open: the engine draws it. */
  lid = 0;
  /** The buds, 0 in the head … 1 at the island's sides. */
  private out = 0;
  private lastMusic = -Infinity;
  private notes: Note[] = [];
  private nextNoteBeat = 0;
  private drawn = false;

  constructor() {
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    this.el.width = PANEL_W * dpr;
    this.el.height = PANEL_H * dpr;
  }

  /** Something is still moving: keeps the island's frame loop running. */
  get busy(): boolean {
    return this.lid > 0 || this.notes.length > 0;
  }

  /** Wants to open (or stay open): music now, or within the last 15 s. */
  private wanted(t: number, music: boolean): boolean {
    if (music) this.lastMusic = t;
    return t - this.lastMusic < LINGER_S;
  }

  step(dt: number, f: PodsFrame) {
    const t = performance.now() / 1000;
    const beat = t * DANCE_BPM / 60;
    // Open: lid first, then the buds. Close: buds home first, then the lid.
    if (this.wanted(t, f.music)) {
      if (this.lid < 1) this.lid = Math.min(1, this.lid + dt / LID_S);
      else this.out = Math.min(1, this.out + dt / FLY_S);
    } else if (this.out > 0) {
      this.out = Math.max(0, this.out - dt / FLY_S);
    } else {
      this.lid = Math.max(0, this.lid - dt / LID_S);
    }

    const ox = (PANEL_W - f.islandW) / 2;
    const R = f.botSize * 0.3;
    const headX = ox + f.botX;
    const headY = f.botY + R * 0.06 - R * LID_SEAM;

    if (f.dancing && f.visible && beat >= this.nextNoteBeat) {
      this.nextNoteBeat = Math.floor(beat) + 1;
      const side = Math.floor(beat) % 2 ? 1 : -1;
      this.notes.push({
        x: headX + side * R * 0.7,
        y: headY,
        vx: side * (28 + Math.random() * 22),
        vy: -(10 + Math.random() * 14),
        age: 0,
        glyph: Math.random() < 0.5 ? "♪" : "♫",
        color: NOTE_COLORS[Math.floor(Math.random() * NOTE_COLORS.length)],
        size: 11 + Math.random() * 4,
      });
    }
    for (const n of this.notes) n.age += dt;
    this.notes = this.notes.filter((n) => n.age < 1.6);

    const ctx = this.el.getContext("2d");
    if (!ctx) return;
    const show = f.visible && (this.out > 0 || this.notes.length > 0);
    if (!show) {
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
      const k = n.age / 1.6;
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

    if (this.out <= 0) return;
    const k = easeInOut(this.out);
    const bob = f.music ? Math.abs(Math.sin(Math.PI * beat)) * 3 : Math.sin(t * 2) * 1.5;
    for (const side of [-1, 1]) {
      const tx = Math.min(PANEL_W - 14, Math.max(14, PANEL_W / 2 + side * (f.islandW / 2 + 22)));
      const ty = 17;
      const sx = headX + side * R * 0.25;
      const cx = (sx + tx) / 2;
      const cy = Math.max(4, Math.min(headY, ty) - 26);
      // A quadratic arc out of the head, one flip on the way.
      const x = (1 - k) * (1 - k) * sx + 2 * (1 - k) * k * cx + k * k * tx;
      const y = (1 - k) * (1 - k) * headY + 2 * (1 - k) * k * cy + k * k * ty - bob * k;
      const spin = (1 - k) * Math.PI * 2 * side;
      const sway = f.music ? Math.sin(Math.PI * beat) * 0.12 : 0;
      drawPod(ctx, x, y, side, 0.35 + 0.65 * k, spin + sway * k);
    }
  }
}

/** One bud: a round head with its speaker grille and a stem that points down and in. */
function drawPod(ctx: CanvasRenderingContext2D, x: number, y: number, side: number, s: number, rot: number) {
  ctx.save();
  ctx.translate(x, y);
  ctx.rotate(rot);
  ctx.scale(s * side, s);
  ctx.fillStyle = "#F4F4F6";
  ctx.strokeStyle = "rgba(0,0,0,0.25)";
  ctx.lineWidth = 0.8;
  // Stem (right-hand bud; the left is mirrored).
  ctx.beginPath();
  ctx.roundRect(-1.5, -1, 4.6, 13, 2.3);
  ctx.fill();
  ctx.stroke();
  ctx.beginPath();
  ctx.ellipse(-1, -3.5, 5.4, 5, 0, 0, Math.PI * 2);
  ctx.fill();
  ctx.stroke();
  ctx.fillStyle = "#2A2C32";
  ctx.beginPath();
  ctx.ellipse(-3.2, -3.8, 1.6, 2.2, 0, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = "#B8BAC0";
  ctx.beginPath();
  ctx.arc(0.8, 11, 1.2, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();
}
