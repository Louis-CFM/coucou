// Room for the minis' outfits (src/mochi/minibots.ts miniLayout, outfits.ts
// outfitFit): every outfit, on every body shape, fits in a pill Mochi's canvas.
// The outfits are drawn into a fake 2D context that only records how high they
// go (control points and clips count, so it errs on the tall side); the SVG
// hats, which need a DOM to load, are measured from their files.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { OUTFIT_SELECTIONS } from "../src/mochi/wardrobe.ts";
import { SHAPES, halfWidthAt } from "../src/mochi/shapes.ts";
import { SVG_OUTFITS, drawOutfitBehind, drawOutfitFront, makeHead, outfitFit } from "../src/mochi/outfits.ts";
import { miniLayout } from "../src/mochi/minibots.ts";

class FakePath {
  pts = [];
  moveTo(x, y) { this.pts.push([x, y]); }
  lineTo(x, y) { this.pts.push([x, y]); }
  bezierCurveTo(a, b, c, d, x, y) { this.pts.push([a, b], [c, d], [x, y]); }
  quadraticCurveTo(a, b, x, y) { this.pts.push([a, b], [x, y]); }
  arcTo(a, b, x, y) { this.pts.push([a, b], [x, y]); }
  arc(x, y, r) { this.pts.push([x, y - r], [x, y + r]); }
  ellipse(x, y, rx, ry, rot = 0) { const r = rot ? Math.max(rx, ry) : ry; this.pts.push([x, y - r], [x, y + r]); }
  rect(x, y, w, h) { this.pts.push([x, y], [x + w, y + h]); }
  roundRect(x, y, w, h) { this.rect(x, y, w, h); }
  closePath() {}
  addPath(p) { this.pts.push(...p.pts); }
}
globalThis.Path2D = FakePath;

/** A 2D context that keeps the topmost y anything was painted at. */
function recorder() {
  let m = [1, 0, 0, 1, 0, 0];
  let clipTop = -Infinity;
  const stack = [];
  let cur = new FakePath();
  const mul = (n) => {
    const [a, b, c, d, e, f] = m;
    m = [a * n[0] + c * n[1], b * n[0] + d * n[1], a * n[2] + c * n[3], b * n[2] + d * n[3],
      a * n[4] + c * n[5] + e, b * n[4] + d * n[5] + f];
  };
  const topOf = (p) => Math.min(...p.pts.map(([x, y]) => m[1] * x + m[3] * y + m[5]));
  const ctx = {
    top: Infinity,
    lineWidth: 1,
    save() { stack.push([m, clipTop, ctx.lineWidth]); },
    restore() { [m, clipTop, ctx.lineWidth] = stack.pop(); },
    translate(x, y) { mul([1, 0, 0, 1, x, y]); },
    scale(x, y) { mul([x, 0, 0, y, 0, 0]); },
    rotate(a) { mul([Math.cos(a), Math.sin(a), -Math.sin(a), Math.cos(a), 0, 0]); },
    transform(...n) { mul(n); },
    beginPath() { cur = new FakePath(); },
    clip(p) { clipTop = Math.max(clipTop, topOf(p instanceof FakePath ? p : cur)); },
    fill(p) { ctx.top = Math.min(ctx.top, Math.max(clipTop, topOf(p instanceof FakePath ? p : cur))); },
    stroke(p) {
      const w = (ctx.lineWidth / 2) * Math.sqrt(Math.abs(m[0] * m[3] - m[1] * m[2]));
      ctx.top = Math.min(ctx.top, Math.max(clipTop, topOf(p instanceof FakePath ? p : cur) - w));
    },
    fillRect(x, y, w, h) { const p = new FakePath(); p.rect(x, y, w, h); ctx.fill(p); },
    createLinearGradient: () => ({ addColorStop() {} }),
    createRadialGradient: () => ({ addColorStop() {} }),
  };
  for (const k of ["moveTo", "lineTo", "bezierCurveTo", "quadraticCurveTo", "arcTo", "arc", "ellipse", "rect", "roundRect", "closePath"]) {
    ctx[k] = (...a) => cur[k](...a);
  }
  return ctx;
}

/** An SVG hat's top on its 200×200 artboard (its guide and clip rings left out). */
function svgTop(id) {
  const text = readFileSync(new URL(`../src/mochi/outfits/${id}.svg`, import.meta.url), "utf8")
    .replace(/<g id="guide"[\s\S]*?<\/g>/, "").replace(/<defs>[\s\S]*?<\/defs>/g, "");
  let top = Infinity;
  const take = (y) => { if (y > -50) top = Math.min(top, y); };
  for (const [, d] of text.matchAll(/ d="([^"]*)"/g)) {
    const tok = d.match(/[A-Za-z]|-?[\d.]+(?:e-?\d+)?/g);
    let cmd = "";
    let y0 = 0;
    for (let i = 0; i < tok.length;) {
      if (/[A-Za-z]/.test(tok[i])) cmd = tok[i++];
      const n = () => Number(tok[i++]);
      if (cmd === "M" || cmd === "L") { n(); y0 = n(); take(y0); }
      else if (cmd === "C") for (let k = 0; k < 3; k++) { n(); y0 = n(); take(y0); }
      else if (cmd === "A") { n(); const ry = n(); n(); n(); n(); n(); const y = n(); take(Math.min(y0, y) - ry); y0 = y; }
      else if (cmd === "Z") continue;
      else throw new Error(`${id}.svg: path command ${cmd} not measured`);
    }
  }
  for (const [, tag, a] of text.matchAll(/<(ellipse|circle|rect)\b([^>]*)>/g)) {
    const v = (k) => Number(new RegExp(` ${k}="([^"]*)"`).exec(a)?.[1] ?? 0);
    take(tag === "ellipse" ? v("cy") - v("ry") : tag === "circle" ? v("cy") - v("r") : v("y"));
  }
  const seat = text.match(/data-seat="([^"]*)"/)[1].split(" ").map(Number);
  return { top, seat, yn: Number(text.match(/data-seat-yn="([^"]*)"/)[1]) };
}

/** How far above the body centre `outfit` reaches on `shape`, in R (as outfits.ts draws it at rest). */
function reach(outfit, shape, R = 12) {
  if (SVG_OUTFITS.has(outfit)) {
    // svgOutfit: the seat on the head at the head's width there.
    const { top, seat, yn } = svgTop(outfit);
    const sc = (halfWidthAt(shape, yn) * R) / seat[2];
    return -(yn * shape.ry * R + (top - seat[1]) * sc) / R;
  }
  const ctx = recorder();
  const H = makeHead(R, 0, 0, 0, 0, shape);
  const st = { presence: 1, morph: 0 };
  drawOutfitBehind(ctx, outfit, H, st);
  drawOutfitFront(ctx, outfit, H, st);
  return ctx.top === Infinity ? Number.NaN : -ctx.top / R;
}

const OUTFITS = OUTFIT_SELECTIONS.filter((o) => o !== "auto" && o !== "none");

test("every outfit fits a pill Mochi's canvas, on every body shape, at full size", () => {
  for (const bodySize of [24, 13]) {
    const { room } = miniLayout(bodySize);
    for (const outfit of OUTFITS) {
      for (const shape of SHAPES) {
        const r = reach(outfit, shape, bodySize / 2);
        assert.ok(!Number.isNaN(r), `${outfit} was measured`);
        assert.ok(r <= room, `${outfit} on ${shape.id} reaches ${r.toFixed(2)} R, the canvas ${room.toFixed(2)} R`);
        assert.equal(outfitFit(r, shape.ry, room), 1);
      }
    }
  }
});

test("the tall hats really were taller than the old square canvas", () => {
  const oldRoom = 0.5 / 0.3 + 0.06; // body centre below the top of a bodySize / 0.6 square, in R
  for (const outfit of ["witchHat", "partyHat", "chefHat", "sprout"]) {
    assert.ok(reach(outfit, SHAPES[0]) > oldRoom, outfit);
  }
});

test("the bigger canvas leaves the body where it was", () => {
  for (const bodySize of [24, 13]) {
    const { size, R, top, height, shiftY } = miniLayout(bodySize);
    // Canvas centred on the slot, moved by shiftY; the engine puts the body
    // centre at height / 2 + overhang / 2 + 0.06 R with overhang = top.
    const bodyY = -height / 2 + shiftY + height / 2 + top / 2 + 0.06 * R;
    const oldBodyY = -size / 2 + size / 2 + 0.06 * R;
    assert.ok(Math.abs(bodyY - oldBodyY) < 1e-9);
  }
});

test("a hat with no room above it shrinks about the top of the head, just enough", () => {
  assert.equal(outfitFit(2, 0.88, 3), 1);
  const k = outfitFit(2.3, 0.88, 1.29);
  assert.ok(Math.abs(0.88 + k * (2.3 - 0.88) - 1.29) < 1e-9);
  assert.equal(outfitFit(2, 0.88, 0.5), 0);
});
