// The AirPods' flight on the screen overlay (island/pods.ts starts it). Out:
// both buds burst from Mochi's head, grow as they swoop down across the
// screen, spinning, and shoot off its left and right edges. In: they come
// back from the edges the same way and shrink into the open case. A short
// motion trail and sparkles follow them. Their own canvas, over the roam's.

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { Ease } from "../core/anim";
import { POD_FLIGHT_MS, drawAirPod } from "../mochi/airpod";

const BIG = 76; // a bud's height mid-flight, CSS px
const TRAIL = 6;
const SPARK_LIFE = 0.55;

interface Flight { out: boolean; x: number; y: number; size: number; at: number }
interface Spark { x: number; y: number; vx: number; vy: number; age: number }

const canvas = document.createElement("canvas");
canvas.style.cssText = "position:fixed;inset:0;width:100vw;height:100vh;pointer-events:none;";
document.body.append(canvas);
const ctx = canvas.getContext("2d")!;

let flight: Flight | null = null;
let sparks: Spark[] = [];
let last = 0;

void listen<Omit<Flight, "at">>("pods-flight", (e) => {
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.round(innerWidth * dpr);
  canvas.height = Math.round(innerHeight * dpr);
  const running = flight !== null;
  flight = { ...e.payload, at: performance.now() };
  sparks = [];
  last = performance.now();
  if (!running) requestAnimationFrame(frame);
});

const bez = (a: number, b: number, c: number, d: number, t: number) => {
  const m = 1 - t;
  return m * m * m * a + 3 * m * m * t * b + 3 * m * t * t * c + t * t * t * d;
};

/** Where a bud is `u` of the way from the head (0) to off screen (1). */
function pose(f: Flight, side: number, u: number) {
  const W = innerWidth;
  const H = innerHeight;
  const off = side < 0 ? -BIG * 2 : W + BIG * 2;
  // Out they dive low and leave mid-height; back in they come from higher up.
  const [y1, y2, y3] = f.out ? [0.5, 0.78, 0.3] : [0.35, 0.55, 0.12];
  const x = bez(f.x + side * f.size * 0.4, f.x + side * W * 0.05, side < 0 ? W * 0.1 : W * 0.9, off, u);
  const y = bez(f.y, f.y + H * y1, H * y2, H * y3, u);
  const grow = Ease.out(Math.min(1, u / 0.4));
  return { x, y, size: f.size + (BIG - f.size) * grow, rot: side * u * Math.PI * 3 };
}

function frame(nowMs: number) {
  const f = flight;
  if (!f) return;
  const dt = Math.min(0.05, (nowMs - last) / 1000);
  last = nowMs;
  const k = Math.min(1, (nowMs - f.at) / POD_FLIGHT_MS);
  // Out: a quick launch that keeps speeding off. In: fast entry, soft landing.
  const ease = (t: number) => (t * t * (3 - 2 * t));
  const at = (t: number) => (f.out ? ease(t) : 1 - Ease.out(t));
  const u = at(k);

  const dpr = canvas.width / innerWidth;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, innerWidth, innerHeight);

  for (const s of sparks) s.age += dt;
  sparks = sparks.filter((s) => s.age < SPARK_LIFE);
  for (const s of sparks) {
    const a = 1 - s.age / SPARK_LIFE;
    const r = 2 + 4 * a;
    const x = s.x + s.vx * s.age;
    const y = s.y + s.vy * s.age;
    ctx.fillStyle = `rgba(255,255,255,${0.9 * a})`;
    ctx.beginPath();
    ctx.moveTo(x, y - r);
    ctx.quadraticCurveTo(x, y, x + r, y);
    ctx.quadraticCurveTo(x, y, x, y + r);
    ctx.quadraticCurveTo(x, y, x - r, y);
    ctx.quadraticCurveTo(x, y, x, y - r);
    ctx.fill();
  }

  if (k < 1) {
    for (const side of [-1, 1]) {
      // A fading trail of where it just was.
      for (let i = TRAIL; i >= 1; i--) {
        const ghost = at(Math.max(0, k - i * 0.022));
        const p = pose(f, side, ghost);
        drawAirPod(ctx, p.x, p.y, p.size, side, p.rot, 0.16 * (1 - i / (TRAIL + 1)));
      }
      const p = pose(f, side, u);
      ctx.save();
      ctx.shadowColor = "rgba(0,0,0,0.35)";
      ctx.shadowBlur = p.size * 0.18;
      ctx.shadowOffsetY = p.size * 0.08;
      drawAirPod(ctx, p.x, p.y, p.size, side, p.rot);
      ctx.restore();
      if (Math.random() < 0.7) {
        sparks.push({
          x: p.x + (Math.random() - 0.5) * p.size * 0.4,
          y: p.y + (Math.random() - 0.5) * p.size * 0.4,
          vx: (Math.random() - 0.5) * 60,
          vy: (Math.random() - 0.5) * 60,
          age: 0,
        });
      }
    }
  }

  if (k >= 1 && sparks.length === 0) {
    ctx.clearRect(0, 0, innerWidth, innerHeight);
    flight = null;
    void invoke("pods_flight_end");
    return;
  }
  requestAnimationFrame(frame);
}
