"use client";

import { type ReactNode, useId } from "react";

import { continuousRectPath, islandMetrics } from "@/lib/island";

import { continuousCorner } from "./theme";

interface ArtworkProps {
  /** Any string (a track id or title). The same seed always gives the same cover. */
  seed: string;
  /** Your own cover image, drawn over the generated one (which shows while it loads or if it fails). Defaults to none. */
  src?: string;
  /** Size in pt. Defaults to 22, the compact glyph size. */
  size?: number;
  /** Corner radius in pt. Defaults to about a quarter of the size. */
  radius?: number;
}

/** One cover palette: a dark ground, a middle tone, a light tone, a warm or cool glow, and an accent bright enough for text and meters on black. */
interface Palette {
  deep: string;
  mid: string;
  light: string;
  glow: string;
  accent: string;
}

/**
 * Hand-picked palettes, so generated covers have the restraint of designed ones instead of
 * random hues. Each pairs a dark ground with one light family and one contrasting glow.
 */
const palettes = [
  { deep: "#062a33", mid: "#11616b", light: "#5fc8b4", glow: "#f2dfae", accent: "#5fe0c4" },
  { deep: "#24091a", mid: "#7c1a3b", light: "#e8604c", glow: "#ffc68c", accent: "#ff7a5c" },
  { deep: "#16123a", mid: "#43358a", light: "#c06cc4", glow: "#ffb3a0", accent: "#d68cff" },
  { deep: "#0d241a", mid: "#2b6236", light: "#a3c552", glow: "#f1e7c8", accent: "#a9e05a" },
  { deep: "#081a3d", mid: "#1b4a85", light: "#5aa6d6", glow: "#e6f0f2", accent: "#5cb8ff" },
  { deep: "#2e1604", mid: "#a44c17", light: "#eea23f", glow: "#fde7bb", accent: "#ffb547" },
  { deep: "#331a25", mid: "#97445f", light: "#e39ab2", glow: "#fbe3ea", accent: "#ff8fb6" },
  { deep: "#111316", mid: "#363b44", light: "#8a94a6", glow: "#ff6b3d", accent: "#ff7d52" },
] as const satisfies readonly Palette[];

const compositions = ["arcs", "horizon", "rings", "bands"] as const;
type Composition = (typeof compositions)[number];

const seedHash = (seed: string) => {
  let h = 2166136261;
  for (const char of seed) {
    h ^= char.codePointAt(0) ?? 0;
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
};

/** A small seeded generator (mulberry32): the same seed gives the same cover on the server and the client. */
const randomFrom = (seed: number) => {
  let a = seed;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
};

const pick = <T,>(list: readonly [T, ...T[]], index: number): T => list[index % list.length] ?? list[0];

/** The palette a seed picks. */
export const paletteFor = (seed: string): Palette => pick<Palette>(palettes, seedHash(seed));

/** The seed's accent (for meters and text on black) and its light and deep tones. */
export const artworkColors = (seed: string) => {
  const palette = paletteFor(seed);
  return { accent: palette.accent, deep: palette.deep, glow: palette.light };
};

const round = (value: number) => Math.round(value * 100) / 100;

/** What every cover drawing takes. */
interface DrawingProps {
  /** Prefix for this cover's gradient and clip ids, unique per rendered cover. */
  id: string;
  /** The cover's palette. */
  p: Palette;
  /** The cover's seed hash. Each drawing makes its own generator from it, so a render never depends on another. */
  seed: number;
}

/** Fine grain: a tile of tiny light and dark specks. A pattern, not an SVG filter, so it costs nothing per frame. */
const Grain = ({ id, seed }: Omit<DrawingProps, "p">) => {
  const random = randomFrom(seed ^ 0x9e3779b9);
  const specks: ReactNode[] = [];
  for (let i = 0; i < 70; i += 1) {
    const light = i % 2 === 0;
    specks.push(<rect key={i} x={round(random() * 20)} y={round(random() * 20)} width={0.7} height={0.7} fill={light ? "#fff" : "#000"} opacity={light ? 0.5 : 0.6} />);
  }
  return (
    <>
      <defs>
        <pattern id={`${id}-grain`} width={20} height={20} patternUnits="userSpaceOnUse">
          {specks}
        </pattern>
      </defs>
      <rect width={100} height={100} fill={`url(#${id}-grain)`} opacity={0.14} />
    </>
  );
};

interface ToneProps {
  /** Gradient id. */
  id: string;
  /** The tone. */
  color: string;
}

/** One tone, a touch lighter at the top: flat colour that still reads as lit paper. */
const Tone = ({ id, color }: ToneProps) => (
  <linearGradient id={id} x1={0} y1={0} x2={0.3} y2={1}>
    <stop offset={0} stopColor={color} />
    <stop offset={1} stopColor={color} stopOpacity={0.86} />
  </linearGradient>
);

/** A two by two grid of quarter circles, each cell turned a quarter from the last. */
const Arcs = ({ id, p, seed }: DrawingProps) => {
  const tones = [p.deep, p.mid, p.light, p.glow] as const;
  const cells = [
    { x: 0, y: 0 },
    { x: 50, y: 0 },
    { x: 0, y: 50 },
    { x: 50, y: 50 },
  ] as const;
  const start = Math.floor(randomFrom(seed)() * 4);
  return (
    <>
      <defs>
        {tones.map((tone, i) => (
          <Tone key={i} id={`${id}-t${i}`} color={tone} />
        ))}
      </defs>
      <rect width={100} height={100} fill={p.deep} />
      {cells.map(({ x, y }, i) => {
        const back = (start + i) % 4;
        const front = (start + i + 2) % 4;
        // The quarter circle's centre sits on one of the cell's corners, turning cell by cell.
        const turn = (start + i) % 4;
        const cx = x + (turn === 1 || turn === 2 ? 50 : 0);
        const cy = y + (turn >= 2 ? 50 : 0);
        return (
          <g key={i}>
            <rect x={x} y={y} width={50} height={50} fill={`url(#${id}-t${back})`} />
            <clipPath id={`${id}-c${i}`}>
              <rect x={x} y={y} width={50} height={50} />
            </clipPath>
            <circle cx={cx} cy={cy} r={50} fill={`url(#${id}-t${front})`} clipPath={`url(#${id}-c${i})`} />
          </g>
        );
      })}
    </>
  );
};

/** A sun half set behind a horizon, with flat bands of ground below, like a screen print. */
const Horizon = ({ id, p, seed }: DrawingProps) => {
  const random = randomFrom(seed);
  const horizon = round(52 + random() * 10);
  const cx = round(34 + random() * 32);
  const r = round(20 + random() * 6);
  const bands = [p.mid, p.light, p.mid] as const;
  const band = (100 - horizon) / bands.length;
  return (
    <>
      <defs>
        <Tone id={`${id}-sky`} color={p.deep} />
        <Tone id={`${id}-sun`} color={p.glow} />
        <clipPath id={`${id}-above`}>
          <rect width={100} height={horizon} />
        </clipPath>
      </defs>
      <rect width={100} height={100} fill={`url(#${id}-sky)`} />
      <circle cx={cx} cy={horizon} r={r} fill={`url(#${id}-sun)`} clipPath={`url(#${id}-above)`} />
      {bands.map((color, i) => (
        <rect key={i} y={round(horizon + band * i)} width={100} height={round(band + 0.5)} fill={color} opacity={1 - i * 0.18} />
      ))}
    </>
  );
};

/** Concentric rings spreading from one corner, light to dark. */
const Rings = ({ id, p, seed }: DrawingProps) => {
  const random = randomFrom(seed);
  const corner = Math.floor(random() * 4);
  const cx = corner === 1 || corner === 2 ? 100 : 0;
  const cy = corner >= 2 ? 100 : 0;
  const rings = [
    { r: 135, color: p.deep },
    { r: 105, color: p.mid },
    { r: 76, color: p.light },
    { r: 46, color: p.glow },
  ] as const;
  return (
    <>
      <defs>
        {rings.map((ring, i) => (
          <Tone key={i} id={`${id}-r${i}`} color={ring.color} />
        ))}
      </defs>
      <rect width={100} height={100} fill={p.deep} />
      {rings.map((ring, i) => (
        <circle key={i} cx={cx} cy={cy} r={ring.r} fill={`url(#${id}-r${i})`} />
      ))}
    </>
  );
};

/** Wide diagonal bands with one small solid disc set against them. */
const Bands = ({ id, p, seed }: DrawingProps) => {
  const random = randomFrom(seed);
  const tones = [p.deep, p.mid, p.light, p.mid, p.deep] as const;
  const disc = { x: round(28 + random() * 44), y: round(28 + random() * 44), r: round(9 + random() * 4) };
  return (
    <>
      <defs>
        <Tone id={`${id}-disc`} color={p.glow} />
      </defs>
      <g transform="rotate(-35 50 50)">
        {tones.map((tone, i) => (
          <rect key={i} x={-40} y={-40 + i * 36} width={180} height={37} fill={tone} />
        ))}
      </g>
      <circle cx={disc.x} cy={disc.y} r={disc.r} fill={`url(#${id}-disc)`} />
    </>
  );
};

const drawings = { arcs: Arcs, horizon: Horizon, rings: Rings, bands: Bands } as const satisfies Record<Composition, (props: DrawingProps) => ReactNode>;

/**
 * Album art for the now-playing preset: an abstract cover generated from a seed (a palette and a
 * flat geometric composition, softly lit from the upper left, with fine grain and a hairline
 * keyline), or your own
 * image over it. Never ships real cover art. Its corners are continuous, as the reference phone draws album art.
 */
export const Artwork = ({ seed, src, size = 22, radius = Math.round(size * 0.24) }: ArtworkProps) => {
  const id = `icn${useId().replace(/[^a-zA-Z0-9_-]/g, "")}`;
  const hash = seedHash(seed);
  const palette = paletteFor(seed);
  const composition = pick(compositions, hash >>> 8);
  const Drawing = drawings[composition];
  const outline = continuousRectPath(0, 0, size, size, radius, islandMetrics.corner.smoothing);
  return (
    <span
      aria-hidden
      style={{ display: "block", position: "relative", width: size, height: size, flex: "none", clipPath: continuousCorner(size, size, radius), background: palette.deep }}
    >
      <svg width={size} height={size} viewBox="0 100" preserveAspectRatio="none" style={{ position: "absolute", inset: 0, display: "block" }}>
        <defs>
          <radialGradient id={`${id}-light`} cx={0.2} cy={0.1} r={0.9}>
            <stop offset={0} stopColor="#fff" stopOpacity={0.12} />
            <stop offset={1} stopColor="#fff" stopOpacity={0} />
          </radialGradient>
          <radialGradient id={`${id}-shade`} cx={0.5} cy={0.42} r={0.78}>
            <stop offset={0.6} stopColor="#000" stopOpacity={0} />
            <stop offset={1} stopColor="#000" stopOpacity={0.2} />
          </radialGradient>
        </defs>
        <Drawing id={id} p={palette} seed={hash} />
        <rect width={100} height={100} fill={`url(#${id}-light)`} />
        <rect width={100} height={100} fill={`url(#${id}-shade)`} />
        {/* Grain disappears below about 30 pt, so small covers skip it. */}
        {size >= 30 ? <Grain id={id} seed={hash} /> : null}
      </svg>
      {src ? <span style={{ position: "absolute", inset: 0, background: `center / cover no-repeat url(${JSON.stringify(src)})` }} /> : null}
      {/* The hairline keyline follows the corner: a 1 pt stroke on the outline, half of it clipped away. */}
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={{ position: "absolute", inset: 0, display: "block" }}>
        <path d={outline} fill="none" stroke="rgba(255, 255, 0.14)" strokeWidth={1} />
      </svg>
    </span>
  );
};
