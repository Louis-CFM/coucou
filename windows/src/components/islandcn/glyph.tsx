"use client";

import { type ComponentType, type CSSProperties, useId } from "react";

import { continuousRectPath, islandMetrics } from "@/lib/island/index";

import type { IslandGlyph } from "./glyphs";
import { islandInk, islandSize } from "./theme";

/**
 * An icon component from another set: anything that takes a size, a colour and a weight. Kept so
 * code written against other icon packages still compiles. For a new icon, prefer an islandcn
 * glyph made from any Hugeicons icon with `glyphFrom` (in `./glyphs`), which draws at the island's
 * weight.
 */
export type ForeignIcon = ComponentType<{ size?: number | string; color?: string; weight?: "fill" | "bold"; style?: CSSProperties }>;

/** What `Glyph` and `IconTile` draw: an islandcn glyph (from `./glyphs`), or an icon from another set. */
export type GlyphIcon = IslandGlyph | ForeignIcon;

/** True for islandcn glyphs (from `./glyphs`), which are drawn for the box and need no scaling. */
export const isIslandGlyph = (icon: GlyphIcon): icon is IslandGlyph => "islandGlyph" in icon && icon.islandGlyph === true;

interface GlyphProps {
  /** An islandcn glyph such as `TimerGlyph`, or an icon component from another set. */
  icon: GlyphIcon;
  /** Icon colour. Defaults to white. */
  color?: string;
  /** Box size in pt. Defaults to 22, the compact glyph, which sits concentric with the pill ends. */
  size?: number;
  /** Weight for icons from another set; islandcn glyphs carry their own. Defaults to "fill". */
  weight?: "fill" | "bold";
}

/**
 * Most icon sets draw inside a grid with padding, so their ink is about 80% of the box.
 * Drawing them 10% larger than the box (overflowing into the padding) puts the ink at about
 * 19.5 pt in a 22 pt box. islandcn glyphs are drawn to the box and skip this.
 */
const foreignInkScale = 1.1;

/** An icon sized for the island, concentric with the pill ends at the default size. */
export const Glyph = ({ icon, color = islandInk.primary, size = islandSize.compactGlyph, weight = "fill" }: GlyphProps) => {
  if (isIslandGlyph(icon)) {
    const Drawn = icon;
    return (
      <span aria-hidden style={{ display: "block", width: size, height: size, flex: "none", color }}>
        <Drawn size={size} />
      </span>
    );
  }
  const Foreign = icon;
  return (
    <span aria-hidden style={{ display: "grid", placeItems: "center", width: size, height: size, flex: "none", color, overflow: "visible" }}>
      <Foreign size={Math.round(size * foreignInkScale)} weight={weight} color="currentColor" style={{ margin: (-size * (foreignInkScale - 1)) / 2 }} />
    </span>
  );
};

interface IconTileProps {
  /** An islandcn glyph, or an icon from another set. */
  icon: GlyphIcon;
  /** The activity's accent: the tile's fill, lit from the top. */
  accent: string;
  /** Tile size in pt. Defaults to 52, the expanded leading tile. */
  size?: number;
  /** "squircle" for an app-style tile, "circle" for a round one (a device in a ring). Defaults to "squircle". */
  shape?: "squircle" | "circle";
}

/**
 * The glyph's share of the tile. An islandcn glyph's ink fills about 80 to 90% of its box (lighter than a
 * filled icon from another set), so it takes a slightly larger box to carry the same presence. A round
 * tile has less room at its corners, so its glyph is a little smaller.
 */
const tileShare = {
  squircle: { island: 0.58, foreign: 0.54 },
  circle: { island: 0.5, foreign: 0.48 },
} as const satisfies Record<NonNullable<IconTileProps["shape"]>, Record<"island" | "foreign", number>>;

/**
 * The tile's corner radius as a share of its side: 12 pt on the 52 pt expanded tile, as the reference
 * still draws it, so the tile's corner sits concentric inside the island's with an even gap.
 */
const tileCorner = islandSize.expandedTileRadius / islandSize.expandedTile;

/** Parses #rgb or #rrggbb into channels, or null for anything else (a CSS variable, a named colour). */
const channels = (hex: string): readonly [number, number, number] | null => {
  const match = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(hex);
  if (!match?.[1]) return null;
  const digits = match[1].length === 3 ? [...match[1]].map((d) => d + d).join("") : match[1];
  const value = Number.parseInt(digits, 16);
  return [(value >> 16) & 255, (value >> 8) & 255, value & 255];
};

/** Moves a colour toward white (amount > 0) or black (amount < 0), so the tile's gradient stays in its hue. */
const shade = (hex: string, amount: number): string => {
  const rgb = channels(hex);
  if (!rgb) return hex;
  const target = amount > 0 ? 255 : 0;
  const t = Math.abs(amount);
  const [r, g, b] = rgb.map((c) => Math.round(c + (target - c) * t));
  return `rgb(${r}, ${g}, ${b})`;
};

/**
 * White ink on most accents; dark ink on the light ones (yellow, mint), where white would wash out.
 * The cut-off is relative luminance 0.6: green (0.5) keeps white, yellow (0.7) goes dark.
 */
const inkOn = (hex: string): string => {
  const rgb = channels(hex);
  if (!rgb) return islandInk.primary;
  const [r, g, b] = rgb.map((c) => {
    const v = c / 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  const luminance = 0.2126 * (r ?? 0) + 0.7152 * (g ?? 0) + 0.0722 * (b ?? 0);
  return luminance > 0.6 ? "rgba(0, 0, 0.82)" : islandInk.primary;
};

/**
 * An app-style tile for the expanded view's leading region: a continuous-corner square filled with
 * the accent, lit faintly from the top (a few percent lighter there, darker at the foot), and the
 * glyph in white (or dark ink on a light accent) with a faint shadow so it sits on the surface. No rim of light: on the black island a bright top edge reads as a bevel jammed into
 * the corner, and the reference tile has none. Drawn as one SVG, so the edge is as crisp as the path.
 */
export const IconTile = ({ icon, accent, size = islandSize.expandedTile, shape = "squircle" }: IconTileProps) => {
  const id = `icn-tile${useId().replace(/[^a-zA-Z0-9_-]/g, "")}`;
  const share = tileShare[shape];
  const outline =
    shape === "circle"
      ? `M ${size / 2} 0 A ${size / 2} ${size / 2} 0 1 1 ${size / 2} ${size} A ${size / 2} ${size / 2} 0 1 1 ${size / 2} 0 Z`
      : continuousRectPath(0, 0, size, size, size * tileCorner, islandMetrics.corner.smoothing);
  const ink = inkOn(accent);
  const drawn = (() => {
    // Whole points keep the glyph's stems on the pixel grid inside the tile.
    if (isIslandGlyph(icon)) {
      const Drawn = icon;
      return <Drawn size={Math.round(size * share.island)} />;
    }
    const Foreign = icon;
    return <Foreign size={Math.round(size * share.foreign)} weight="fill" color="currentColor" />;
  })();
  return (
    <span aria-hidden style={{ position: "relative", display: "grid", placeItems: "center", width: size, height: size, flex: "none", color: ink }}>
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} style={{ position: "absolute", inset: 0, display: "block" }}>
        <defs>
          <linearGradient id={`${id}-fill`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor={shade(accent, 0.06)} />
            <stop offset="1" stopColor={shade(accent, -0.06)} />
          </linearGradient>
        </defs>
        <path d={outline} fill={`url(#${id}-fill)`} />
      </svg>
      <span style={{ position: "relative", display: "grid", placeItems: "center", filter: "drop-shadow(0 0.5px 1px rgba(0, 0, 0.22))" }}>{drawn}</span>
    </span>
  );
};
