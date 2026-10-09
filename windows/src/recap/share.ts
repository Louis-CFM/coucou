// The 1080 × 1920 image of the week, drawn once into an offscreen canvas —
// port of RecapShareImageView in WeeklyRecapView.swift. Same colours, sizes
// and order; Nova comes from the island's own engine.

import { BotEngine } from "../nova/engine";
import { formatCount, formatDuration, weekRangeLabel, type WeeklySummary } from "./summary";
import { t } from "../i18n/i18n";
import { SCRIPT_FONTS } from "../core/fonts";

export const SHARE_W = 1080;
export const SHARE_H = 1920;

const FONT = `system-ui, "Segoe UI Variable Display", "Segoe UI", "Cantarell", "Ubuntu", ${SCRIPT_FONTS}, sans-serif`;
const MONO = `"Cascadia Mono", "Consolas", "DejaVu Sans Mono", ui-monospace, monospace`;

const INK = "#F1F2F4";
const DIM = "#8E939C";
const INDIGO_TEXT = "#818CF8";

/** Strings drawn into the image, in the current language (src/i18n). */
const T = {
  get title() { return t("Weekly recap"); },
  get timeCoding() { return t("TIME CODING"); },
  get sessions() { return t("SESSIONS"); },
  get files() { return t("FILES"); },
  get commands() { return t("COMMANDS"); },
  get topAgent() { return t("Top agent"); },
  get topProject() { return t("Top project"); },
  get busiestDay() { return t("Busiest day"); },
  get longestSession() { return t("Longest session"); },
  get approved() { return t("Approved"); },
  get denied() { return t("Denied"); },
  footer: "Nova · personal desktop island",
};

/**
 * Scripts whose letters join or stack (Arabic, Devanagari, Bengali) must be
 * drawn whole, and CJK has no letter spacing to speak of.
 */
const JOINED_SCRIPT = /[\u0590-\u08FF\u0900-\u0DFF\u3000-\u9FFF\uAC00-\uD7AF\uFB1D-\uFEFF]/;

type Ctx = CanvasRenderingContext2D;

function font(x: Ctx, weight: number, size: number, family = FONT) {
  x.font = `${weight} ${size}px ${family}`;
}

/** Shrinks the font until `text` fits in `maxW` (minimumScaleFactor). */
function fitFont(x: Ctx, text: string, weight: number, size: number, maxW: number, minScale: number) {
  let s = size;
  font(x, weight, s);
  while (x.measureText(text).width > maxW && s > size * minScale) {
    s -= 2;
    font(x, weight, s);
  }
}

/**
 * Text with letter spacing, centred on `cx` — `letterSpacing` is not everywhere
 * yet. A translation wider than `maxW` gets a smaller font first.
 */
function spaced(x: Ctx, text: string, cx: number, y: number, spacing: number, maxW = Infinity) {
  if (JOINED_SCRIPT.test(text)) {
    shrinkToFit(x, text, maxW);
    x.textAlign = "center";
    x.fillText(text, cx, y);
    return;
  }
  shrinkToFit(x, text, maxW, spacing);
  const chars = [...text];
  const widths = chars.map((c) => x.measureText(c).width);
  const total = widths.reduce((a, b) => a + b, 0) + spacing * (chars.length - 1);
  let at = cx - total / 2;
  x.textAlign = "left";
  chars.forEach((c, i) => {
    x.fillText(c, at, y);
    at += widths[i] + spacing;
  });
}

/** Lowers the current font's size until `text` (plus its letter spacing) fits `maxW`. */
function shrinkToFit(x: Ctx, text: string, maxW: number, spacing = 0) {
  if (!Number.isFinite(maxW)) return;
  const match = /^(\S+) (\d+(?:\.\d+)?)px (.*)$/.exec(x.font);
  if (!match) return;
  const [, weight, sizeText, family] = match;
  const size = Number(sizeText);
  const extra = spacing * Math.max(0, [...text].length - 1);
  let s = size;
  while (x.measureText(text).width + extra > maxW && s > size * 0.6) {
    s -= 1;
    x.font = `${weight} ${s}px ${family}`;
  }
}

/** Cuts `text` with an ellipsis so it fits `maxW` in the current font. */
function ellipsize(x: Ctx, text: string, maxW: number): string {
  if (x.measureText(text).width <= maxW) return text;
  let t = text;
  while (t.length > 1 && x.measureText(`${t}…`).width > maxW) t = t.slice(0, -1);
  return `${t}…`;
}

function roundRect(x: Ctx, left: number, top: number, w: number, h: number, r: number) {
  x.beginPath();
  x.moveTo(left + r, top);
  x.arcTo(left + w, top, left + w, top + h, r);
  x.arcTo(left + w, top + h, left, top + h, r);
  x.arcTo(left, top + h, left, top, r);
  x.arcTo(left, top, left + w, top, r);
  x.closePath();
}

const BADGE_H = 66;
const BADGE_GAP = 16;

function badge(x: Ctx, left: number, top: number, w: number, label: string, value: string) {
  x.fillStyle = "rgba(255,255,255,0.05)";
  roundRect(x, left, top, w, BADGE_H, 18);
  x.fill();
  const mid = top + BADGE_H / 2;
  x.textBaseline = "middle";
  font(x, 400, 24);
  x.fillStyle = DIM;
  x.textAlign = "left";
  x.fillText(label, left + 32, mid);
  const labelW = x.measureText(label).width;
  font(x, 600, 24);
  x.fillStyle = INK;
  x.textAlign = "right";
  x.fillText(ellipsize(x, value, w - 64 - labelW - 16), left + w - 32, mid);
}

/** A still Nova, drawn by the same engine as the island's. */
function drawNova(x: Ctx, cx: number, top: number, size: number) {
  const engine = new BotEngine();
  engine.setState("idle", true);
  engine.update(1 / 60);
  x.save();
  x.translate(cx - size / 2, top);
  engine.draw(x, size, size);
  x.restore();
}

export function renderShareImage(s: WeeklySummary, hideProjects: boolean): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.width = SHARE_W;
  canvas.height = SHARE_H;
  const x = canvas.getContext("2d");
  if (!x) return canvas;
  const W = SHARE_W;
  const cx = W / 2;

  // Background: near-black with an indigo glow low in the frame.
  x.fillStyle = "#0B0C0E";
  x.fillRect(0, 0, W, SHARE_H);
  const glow = x.createRadialGradient(cx, SHARE_H * 0.75, 0, cx, SHARE_H * 0.75, 900);
  glow.addColorStop(0, "rgba(99,102,241,0.30)");
  glow.addColorStop(0.65, "rgba(99,102,241,0)");
  x.fillStyle = glow;
  x.fillRect(0, 0, W, SHARE_H);

  // What goes in the badge list.
  const badges: [string, string][] = [];
  if (s.topAgent) badges.push([T.topAgent, s.topAgent]);
  if (!hideProjects && s.topProject) badges.push([T.topProject, s.topProject]);
  if (s.busiestDay) badges.push([T.busiestDay, t(s.busiestDay)]);
  if (s.longestSessionMinutes > 1) badges.push([T.longestSession, formatDuration(s.longestSessionMinutes)]);
  const decisions = s.permissionsAllowed + s.permissionsDenied > 0;
  const badgeRows = badges.length + (decisions ? 1 : 0);
  const hasLines = s.linesAdded + s.linesRemoved > 0;

  // Heights of each block, so the whole stack can be centred like the VStack.
  // Nova's body fills ~60 % of the square the engine draws into.
  const NOVA = 220;
  const NOVA_DRAW = 320;
  const blockH =
    NOVA + 20 + 62 + 6 + 36 + 14 + 29 + 80 + // Nova, Nova, title, range
    110 + 6 + 26 + // time + caption
    56 + 94 + // stat row
    (hasLines ? 24 + 34 : 0) +
    (badgeRows > 0 ? 56 + badgeRows * BADGE_H + (badgeRows - 1) * BADGE_GAP : 0);
  const footerTop = SHARE_H - 60 - 24;
  let y = Math.max(40, (footerTop - blockH) / 2);

  x.textBaseline = "top";

  drawNova(x, cx, y + NOVA / 2 - NOVA_DRAW / 2 - NOVA_DRAW * 0.02, NOVA_DRAW);
  y += NOVA + 20;

  x.fillStyle = INK;
  x.textAlign = "center";
  font(x, 900, 52);
  x.fillText("Nova", cx, y);
  y += 62 + 6;

  x.fillStyle = DIM;
  fitFont(x, T.title, 500, 30, W - 120, 0.6);
  x.fillText(T.title, cx, y);
  y += 36 + 14;

  x.fillStyle = INDIGO_TEXT;
  font(x, 400, 24);
  x.fillText(weekRangeLabel(s), cx, y);
  y += 29 + 80;

  // Time — the headline number.
  const time = formatDuration(s.totalMinutes);
  x.fillStyle = INK;
  fitFont(x, time, 900, 100, W - 120, 0.4);
  x.textAlign = "center";
  x.fillText(time, cx, y);
  y += 110 + 6;
  x.fillStyle = DIM;
  font(x, 600, 22);
  spaced(x, T.timeCoding, cx, y, 3, W - 120);
  y += 26 + 56;

  // Sessions | files | commands
  const stats: [string, string][] = [
    [formatCount(s.sessionCount), T.sessions],
    [formatCount(s.filesChanged), T.files],
  ];
  if (s.commandsRun > 0) stats.push([formatCount(s.commandsRun), T.commands]);
  const rowLeft = 40;
  const colW = (W - rowLeft * 2) / stats.length;
  stats.forEach(([value, label], i) => {
    const colCx = rowLeft + colW * (i + 0.5);
    if (i > 0) {
      x.fillStyle = "rgba(255,255,255,0.08)";
      x.fillRect(rowLeft + colW * i, y + 7, 1, 80);
    }
    x.fillStyle = INK;
    fitFont(x, value, 900, 64, colW - 24, 0.5);
    x.textAlign = "center";
    x.fillText(value, colCx, y);
    x.fillStyle = DIM;
    font(x, 600, 18);
    spaced(x, label, colCx, y + 72, 2, colW - 24);
  });
  y += 94;

  // Lines added / removed
  if (hasLines) {
    y += 24;
    const plus = `+${formatCount(s.linesAdded)}`;
    const minus = `−${formatCount(s.linesRemoved)}`;
    font(x, 600, 28, MONO);
    const pw = x.measureText(plus).width;
    const mw = x.measureText(minus).width;
    const start = cx - (pw + 24 + mw) / 2;
    x.textAlign = "left";
    x.fillStyle = "#4ADE80";
    x.fillText(plus, start, y);
    x.fillStyle = "#F87171";
    x.fillText(minus, start + pw + 24, y);
    y += 34;
  }

  // Badges
  if (badgeRows > 0) {
    y += 56;
    const left = 60;
    const w = W - left * 2;
    for (const [label, value] of badges) {
      badge(x, left, y, w, label, value);
      y += BADGE_H + BADGE_GAP;
    }
    if (decisions) {
      const half = (w - BADGE_GAP) / 2;
      badge(x, left, y, half, T.approved, formatCount(s.permissionsAllowed));
      badge(x, left + half + BADGE_GAP, y, half, T.denied, formatCount(s.permissionsDenied));
    }
  }

  // Footer
  x.textBaseline = "top";
  x.textAlign = "center";
  x.fillStyle = "rgba(142,147,156,0.6)";
  font(x, 500, 20, MONO);
  x.fillText(T.footer, cx, footerTop);

  return canvas;
}

/** The canvas as a PNG data URL, for Rust to write to disk. */
export function toPngDataUrl(canvas: HTMLCanvasElement): string {
  return canvas.toDataURL("image/png");
}

/** The canvas as a PNG blob, for the clipboard. */
export function toPngBlob(canvas: HTMLCanvasElement): Promise<Blob | null> {
  return new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
}
