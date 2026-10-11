#!/usr/bin/env node
// Runs the PC's outfit drawing (windows/src/mochi/outfits.ts) against a recording context and prints every
// drawing call as JSON. The Kotlin port (mochi/outfit/Outfits.kt) is replayed on the same cases and its calls
// are compared number by number (OutfitParityTest), so the phone draws what the PC draws.
//
//   node --import windows/tests/setup.mjs android/tools/outfit-trace.mjs > trace.json
//
// The case list is part of the output: the Kotlin test replays exactly those cases.
import { drawOutfitBehind, drawOutfitFront, drawWardrobeIcon, makeHead } from "../../windows/src/mochi/outfits.ts";

// ── CSS colours (the same forms the outfits use) ─────────────────────────────────
function css(s) {
  const t = s.trim();
  if (t.startsWith("#")) {
    const h = t.slice(1);
    if (h.length === 3) return [...h].map((c) => parseInt(c + c, 16)).concat(1);
    return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)).concat(1);
  }
  const m = /^(rgba?)\((.*)\)$/.exec(t);
  if (!m) throw new Error(`colour ${s}`);
  const p = m[2].split(",").map((x) => Number(x.trim()));
  return m[1] === "rgb" ? [p[0], p[1], p[2], 1] : [p[0], p[1], p[2], p[3]];
}

// ── Recording Path2D and context ─────────────────────────────────────────────────
class RecPath {
  constructor() { this.segs = []; }
  moveTo(...a) { this.segs.push(["M", ...a]); }
  lineTo(...a) { this.segs.push(["L", ...a]); }
  quadraticCurveTo(...a) { this.segs.push(["Q", ...a]); }
  bezierCurveTo(...a) { this.segs.push(["C", ...a]); }
  arcTo(...a) { this.segs.push(["AT", ...a]); }
  arc(...a) { this.segs.push(["A", ...a]); }
  ellipse(...a) { this.segs.push(["E", ...a]); }
  rect(...a) { this.segs.push(["R", ...a]); }
  closePath() { this.segs.push(["Z"]); }
  addPath(p) { this.segs.push(...p.segs); }
}
globalThis.Path2D = RecPath;

function gradient(kind, args) {
  return { kind, args, stops: [], addColorStop(o, c) { this.stops.push([o, ...css(c)]); } };
}
const styleOf = (s) => (typeof s === "string" ? ["solid", ...css(s)] : [s.kind, ...s.args, s.stops]);

class Rec {
  constructor(log) {
    this.log = log;
    this.canvas = { width: 640, height: 480 };
    this.cur = new RecPath();
    this.stack = [];
    this.fillStyle = "#000000";
    this.strokeStyle = "#000000";
    this.lineWidth = 1;
    this.lineCap = "butt";
    this.lineJoin = "miter";
    this.globalAlpha = 1;
    this.skipRestore = false;
    this.scratchLog = null;
  }
  save() {
    this.stack.push([this.fillStyle, this.strokeStyle, this.lineWidth, this.lineCap, this.lineJoin, this.globalAlpha]);
    this.log.push(["save"]);
  }
  restore() {
    const s = this.stack.pop();
    if (s) [this.fillStyle, this.strokeStyle, this.lineWidth, this.lineCap, this.lineJoin, this.globalAlpha] = s;
    if (this.skipRestore) { this.skipRestore = false; return; }
    this.log.push(["restore"]);
  }
  translate(x, y) { this.log.push(["translate", x, y]); }
  scale(x, y) { this.log.push(["scale", x, y]); }
  rotate(a) { this.log.push(["rotate", a]); }
  setTransform() {}
  getTransform() { return {}; }
  clearRect() {}
  beginPath() { this.cur = new RecPath(); }
  moveTo(...a) { this.cur.moveTo(...a); }
  lineTo(...a) { this.cur.lineTo(...a); }
  quadraticCurveTo(...a) { this.cur.quadraticCurveTo(...a); }
  bezierCurveTo(...a) { this.cur.bezierCurveTo(...a); }
  arcTo(...a) { this.cur.arcTo(...a); }
  arc(...a) { this.cur.arc(...a); }
  ellipse(...a) { this.cur.ellipse(...a); }
  closePath() { this.cur.closePath(); }
  fill(p) { this.log.push(["fill", (p ?? this.cur).segs.slice(), styleOf(this.fillStyle)]); }
  stroke(p) { this.log.push(["stroke", (p ?? this.cur).segs.slice(), styleOf(this.strokeStyle), this.lineWidth, this.lineCap, this.lineJoin]); }
  clip(p, rule) { this.log.push(["clip", p.segs.slice(), rule === "evenodd"]); }
  fillRect(x, y, w, h) { this.log.push(["fill", [["R", x, y, w, h]], styleOf(this.fillStyle)]); }
  createLinearGradient(...a) { return gradient("lin", a); }
  createRadialGradient(x, y, r0, x2, y2, r1) { return gradient("rad", [x, y, r0, r1]); }
  drawImage() {
    // withLayer: save(); setTransform(); globalAlpha *= alpha; drawImage(scratch); restore().
    const last = this.log.pop();
    if (!last || last[0] !== "save") throw new Error("unexpected layer sequence");
    this.log.push(["layer", this.globalAlpha, this.scratchLog.splice(0)]);
    this.skipRestore = true;
  }
}

// outfits.ts keeps one scratch canvas for good, so there is one scratch recorder too.
const scratchLog = [];
const scratch = new Rec(scratchLog);
globalThis.document = { createElement: () => ({ width: 0, height: 0, getContext: () => scratch }) };

function newMain() {
  const log = [];
  scratchLog.length = 0;
  const main = new Rec(log);
  main.scratchLog = scratchLog;
  return { main, log };
}

// ── The cases ────────────────────────────────────────────────────────────────────
export const OUTFITS = ["partyHat", "beanie", "crown", "sunglasses", "roundGlasses", "bow", "scarf", "witchHat", "pumpkin", "santaHat", "bunnyEars"];
const HEADS = [
  { R: 40, yaw: 0, pitch: 0, physDx: 0, physDy: 0 },
  { R: 60, yaw: 0.4, pitch: -0.2, physDx: 0.3, physDy: -0.2 },
  { R: 12, yaw: 0, pitch: 0, physDx: 0, physDy: 0 },
  { R: 50, yaw: 2.2, pitch: 0.1, physDx: 0, physDy: 0 },
  { R: 45, yaw: -0.7, pitch: 0.3, physDx: -0.4, physDy: 0.5 },
];
const STATES = [
  { presence: 1, morph: 0 },
  { presence: 0.6, morph: 0 },
  { presence: 0.3, morph: 0 },
  { presence: 1, morph: 0.4 },
  { presence: 1, morph: 0.6 },
];

const cases = [];
for (const outfit of OUTFITS) {
  HEADS.forEach((head, hi) => {
    STATES.forEach((state, si) => {
      if (si > 0 && hi > 1) return; // the transitions are checked on two heads
      for (const part of ["behind", "front"]) cases.push({ kind: part, outfit, head, state });
    });
  });
}
for (const outfit of OUTFITS) cases.push({ kind: "icon", outfit, size: 40 });

function run(c) {
  const { main, log } = newMain();
  if (c.kind === "icon") {
    drawWardrobeIcon(main, c.size, c.outfit, "none", "AUTO"); // a chosen outfit: the little Mochi, no label
  } else {
    const h = makeHead(c.head.R, c.head.yaw, c.head.pitch, c.head.physDx, c.head.physDy);
    (c.kind === "behind" ? drawOutfitBehind : drawOutfitFront)(main, c.outfit, h, c.state);
  }
  return log;
}

process.stdout.write(JSON.stringify(cases.map((c) => ({ ...c, ops: run(c) }))));
