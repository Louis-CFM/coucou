// One AirPod, drawn in code like Mochi: the glossy bulb with its black
// speaker grille and sensor, the long stem with a highlight down its side, and
// the silver tip with the microphone. Shared by the case in Mochi's head and
// the flight across the screen (roam/pods.ts).

/** How long the buds take to cross the screen, out or back. */
export const POD_FLIGHT_MS = 1500;

/**
 * Draws a bud `size` px tall with its centre at (x, y). `side` is -1 for the
 * left bud (mirrored), 1 for the right; `rot` turns it about its centre.
 */
export function drawAirPod(
  ctx: CanvasRenderingContext2D, x: number, y: number, size: number, side: number, rot = 0, alpha = 1,
) {
  if (size < 0.5 || alpha <= 0) return;
  ctx.save();
  ctx.globalAlpha *= alpha;
  ctx.translate(x, y);
  ctx.rotate(rot);
  ctx.scale(size * side, size);
  const line = Math.min(0.03, 1.2 / size);

  // Stem, then the bulb over its top; one gradient runs across both.
  const stem = new Path2D();
  stem.moveTo(-0.075, -0.2);
  stem.bezierCurveTo(-0.07, 0, -0.062, 0.25, -0.06, 0.4);
  stem.lineTo(0.06, 0.4);
  stem.bezierCurveTo(0.064, 0.25, 0.072, 0, 0.09, -0.2);
  const bulb = new Path2D();
  bulb.ellipse(0.02, -0.29, 0.215, 0.195, -0.35, 0, Math.PI * 2);

  const shade = ctx.createLinearGradient(-0.22, 0, 0.24, 0);
  shade.addColorStop(0, "#FFFFFF");
  shade.addColorStop(0.55, "#F1F2F5");
  shade.addColorStop(1, "#C9CCD3");
  ctx.strokeStyle = "rgba(60,64,72,0.35)";
  ctx.lineWidth = line;
  ctx.fillStyle = shade;
  ctx.fill(stem);
  ctx.stroke(stem);
  ctx.fill(bulb);
  const round = ctx.createRadialGradient(-0.04, -0.36, 0.02, 0.02, -0.29, 0.24);
  round.addColorStop(0, "rgba(255,255,255,0.9)");
  round.addColorStop(0.6, "rgba(255,255,255,0)");
  round.addColorStop(1, "rgba(150,155,165,0.35)");
  ctx.fillStyle = round;
  ctx.fill(bulb);
  ctx.stroke(bulb);
  // Where the stem meets the bulb, no seam.
  ctx.fillStyle = shade;
  ctx.fillRect(-0.068, -0.2, 0.15, 0.06);

  // Speaker grille on the inner face, and the proximity sensor.
  const grille = ctx.createRadialGradient(-0.13, -0.31, 0, -0.13, -0.31, 0.09);
  grille.addColorStop(0, "#3A3D44");
  grille.addColorStop(1, "#111216");
  ctx.fillStyle = grille;
  ctx.beginPath();
  ctx.ellipse(-0.125, -0.31, 0.055, 0.085, -0.25, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = "#1A1B1F";
  ctx.beginPath();
  ctx.ellipse(0.1, -0.38, 0.022, 0.026, 0, 0, Math.PI * 2);
  ctx.fill();

  // The gloss down the stem.
  ctx.strokeStyle = "rgba(255,255,255,0.95)";
  ctx.lineWidth = line * 1.6;
  ctx.lineCap = "round";
  ctx.beginPath();
  ctx.moveTo(-0.04, -0.12);
  ctx.bezierCurveTo(-0.036, 0.05, -0.032, 0.22, -0.03, 0.34);
  ctx.stroke();

  // Silver tip and its microphone.
  const tip = ctx.createLinearGradient(-0.06, 0, 0.06, 0);
  tip.addColorStop(0, "#E4E6EA");
  tip.addColorStop(0.5, "#B8BCC4");
  tip.addColorStop(1, "#8E939C");
  ctx.fillStyle = tip;
  ctx.beginPath();
  ctx.moveTo(-0.06, 0.39);
  ctx.lineTo(0.06, 0.39);
  ctx.lineTo(0.058, 0.45);
  ctx.quadraticCurveTo(0, 0.49, -0.058, 0.45);
  ctx.closePath();
  ctx.fill();
  ctx.fillStyle = "#2A2C31";
  ctx.beginPath();
  ctx.ellipse(0, 0.455, 0.022, 0.012, 0, 0, Math.PI * 2);
  ctx.fill();
  ctx.restore();
}
