// The chat moods (engine.ts MOOD_ACTS) on a live Mochi, big, island-sized and
// small (the simple effects). `npx vite`, then open /dev/emotes-preview.html,
// /dev/emotes-preview.html#hype to play one on load, #hype@900 for a still
// 900 ms in (setTimeout steps, like the sleepy eyes, are skipped). Not shipped.

import { BotEngine, MOOD_ACTS } from "../src/mochi/engine";

const OVERHANG = 40;
const dpr = window.devicePixelRatio || 1;
const bots = [220, 90, 44].map((W) => {
  const canvas = document.createElement("canvas");
  const H = W + OVERHANG;
  canvas.width = W * dpr;
  canvas.height = H * dpr;
  canvas.style.width = `${W}px`;
  const fig = document.createElement("figure");
  fig.append(canvas, `${W}px`);
  document.getElementById("stage")!.append(fig);
  const engine = new BotEngine();
  engine.particleOverhang = OVERHANG;
  return { engine, ctx: canvas.getContext("2d")!, W, H };
});

const play = (mood: string) => bots.forEach((b) => MOOD_ACTS[mood](b.engine));
for (const mood of Object.keys(MOOD_ACTS)) {
  const button = document.createElement("button");
  button.textContent = mood;
  button.onclick = () => play(mood);
  document.getElementById("moods")!.append(button);
}

const draw = (dt: number) => {
  for (const { engine, ctx, W, H } of bots) {
    engine.update(dt);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, W, H);
    engine.draw(ctx, W, H);
  }
};

// #hype plays a mood on load; #hype@900 draws a still, 900 ms in, on a fake clock.
const [mood, at] = decodeURIComponent(location.hash.slice(1)).split("@");
if (MOOD_ACTS[mood] && at) {
  let clock = 0;
  performance.now = () => clock;
  play(mood);
  for (; clock < Number(at); clock += 16) draw(0.016);
} else {
  let last = performance.now();
  requestAnimationFrame(function frame(t) {
    draw(Math.min(0.05, (t - last) / 1000));
    last = t;
    requestAnimationFrame(frame);
  });
  if (MOOD_ACTS[mood]) setTimeout(() => play(mood), 300);
}
