// Draws Nova into the PNG/ICO set Tauri needs. No dependencies: the icons are
// rasterised here and encoded with node:zlib, so the app icon stays "drawn in
// code" like the character itself.
//
//   node scripts/gen-icons.mjs

import { deflateSync } from "node:zlib";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OUT = join(dirname(fileURLToPath(import.meta.url)), "..", "src-tauri", "icons");

// ── Nova ─────────────────────────────────────────────────────────────────────

const BASE_TOP = [255, 250, 245]; // #FFFAF5
const BASE_BOTTOM = [221, 204, 191]; // #DDCCBF
const INK = [26, 20, 18]; // #1A1412
const RIM = [0, 0, 0];

const SS = 4; // supersampling factor

/** Superellipse (exponent 2.7) test in body-local coordinates. */
function insideBody(x, y, rx, ry) {
  const n = 2.7;
  return Math.pow(Math.abs(x / rx), n) + Math.pow(Math.abs(y / ry), n) <= 1;
}

function insidePill(x, y, w, h) {
  const hw = w / 2;
  const hh = h / 2;
  const r = Math.min(hw, hh);
  const cx = Math.max(-hw + r, Math.min(hw - r, x));
  const cy = Math.max(-hh + r, Math.min(hh - r, y));
  return (x - cx) ** 2 + (y - cy) ** 2 <= r * r;
}

function renderNova(size) {
  const px = new Uint8Array(size * size * 4);
  const R = size * 0.34;
  const rx = R * 1.14;
  const ry = R * 0.88;
  const cx = size / 2;
  const cy = size / 2 + R * 0.06;
  const rim = R * 0.055; // dark outline so the tray icon reads on light themes

  // Eyes — same geometry as BotEngine (yaw ±0.37, pitch −0.12)
  const eyeYaw = 0.37;
  const eyePitch = -0.12;
  const cp = Math.cos(eyePitch);
  const ex = Math.sin(eyeYaw) * cp * rx;
  const ey = -Math.sin(eyePitch) * ry;
  const fx = Math.max(0.18, Math.cos(eyeYaw));
  const fy = Math.max(0.18, cp);
  const ew = R * 0.25 * fx;
  const eh = R * 0.27 * fy;

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let bodyHits = 0;
      let rimHits = 0;
      let eyeHits = 0;
      for (let sy = 0; sy < SS; sy++) {
        for (let sx = 0; sx < SS; sx++) {
          const px0 = x + (sx + 0.5) / SS - cx;
          const py0 = y + (sy + 0.5) / SS - cy;
          if (!insideBody(px0, py0, rx + rim, ry + rim)) continue;
          rimHits++;
          if (!insideBody(px0, py0, rx, ry)) continue;
          bodyHits++;
          if (
            insidePill(px0 + ex, py0 - ey, ew, eh) ||
            insidePill(px0 - ex, py0 - ey, ew, eh)
          ) {
            eyeHits++;
          }
        }
      }
      if (rimHits === 0) continue;

      const total = SS * SS;
      const rimA = rimHits / total;
      const bodyA = bodyHits / total;
      const eyeA = eyeHits / total;

      // Body gradient: top-right → bottom-left, like the Canvas gradient.
      const t = Math.min(1, Math.max(0, ((x - cx) * -0.6 + (y - cy) * 0.8) / (2 * ry) + 0.5));
      const body = [0, 1, 2].map((i) => BASE_TOP[i] + (BASE_BOTTOM[i] - BASE_TOP[i]) * t);

      // rim under body, body over rim, eyes over body
      let col = RIM.slice();
      let alpha = rimA;
      if (bodyA > 0) {
        col = col.map((c, i) => c * (1 - bodyA / rimA) + body[i] * (bodyA / rimA));
        alpha = rimA;
      }
      if (eyeA > 0) {
        col = col.map((c, i) => c * (1 - eyeA) + INK[i] * eyeA);
      }

      const o = (y * size + x) * 4;
      px[o] = Math.round(col[0]);
      px[o + 1] = Math.round(col[1]);
      px[o + 2] = Math.round(col[2]);
      px[o + 3] = Math.round(Math.min(1, alpha) * 255);
    }
  }
  return px;
}

// ── PNG ───────────────────────────────────────────────────────────────────────

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

function encodePNG(size, rgba) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  const raw = Buffer.alloc(size * (size * 4 + 1));
  for (let y = 0; y < size; y++) {
    raw[y * (size * 4 + 1)] = 0; // filter: none
    Buffer.from(rgba.buffer, y * size * 4, size * 4).copy(raw, y * (size * 4 + 1) + 1);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

// ── ICO (PNG-in-ICO, Vista and later) ─────────────────────────────────────────

function encodeICO(entries) {
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(entries.length, 4);
  const dir = Buffer.alloc(16 * entries.length);
  let offset = header.length + dir.length;
  entries.forEach((e, i) => {
    const o = i * 16;
    dir[o] = e.size >= 256 ? 0 : e.size;
    dir[o + 1] = e.size >= 256 ? 0 : e.size;
    dir[o + 2] = 0;
    dir[o + 3] = 0;
    dir.writeUInt16LE(1, o + 4);
    dir.writeUInt16LE(32, o + 6);
    dir.writeUInt32LE(e.png.length, o + 8);
    dir.writeUInt32LE(offset, o + 12);
    offset += e.png.length;
  });
  return Buffer.concat([header, dir, ...entries.map((e) => e.png)]);
}

// ── Go ────────────────────────────────────────────────────────────────────────

mkdirSync(OUT, { recursive: true });

const png = (size) => encodePNG(size, renderNova(size));

const files = {
  "32x32.png": png(32),
  "128x128.png": png(128),
  "128x128@2x.png": png(256),
  "icon.png": png(512),
};
for (const [name, data] of Object.entries(files)) {
  writeFileSync(join(OUT, name), data);
  console.log(`${name} — ${data.length} bytes`);
}

const ico = encodeICO([16, 24, 32, 48, 64, 128, 256].map((size) => ({ size, png: png(size) })));
writeFileSync(join(OUT, "icon.ico"), ico);
console.log(`icon.ico — ${ico.length} bytes`);
