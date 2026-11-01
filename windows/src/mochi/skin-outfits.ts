// The one place where skins meet the built-in outfits (outfits.ts). The engine
// and the wardrobe import these instead of outfits.ts: a skin ("skin:<id>") is
// drawn from its file, anything else by the built-in code, so outfits.ts is left
// as it is and only this file knows both.

import {
  PUMPKIN_BODY,
  drawOutfitBehind as drawBuiltInBehind,
  drawOutfitFront as drawBuiltInFront,
  drawWardrobeIcon as drawBuiltInIcon,
  makeHead,
} from "./outfits";
import { botGlowColor, type BotStateName } from "../core/layout";
import { drawSkin, drawSkinIcon, skinBody, skinFor } from "./skins";
import type { Outfit, OutfitSelection } from "./wardrobe";

export { PUMPKIN_BODY, makeHead };

/** How far the eyes may look up and down in this outfit (1 = the full range). */
export function outfitLookRange(outfit: Outfit): number {
  return skinFor(outfit)?.lookRange ?? 1;
}

/** Attention states keep their own colour on any skin: they must stand out. */
const STATE_KEEPS: ReadonlySet<BotStateName> = new Set(["error", "ratelimit", "approval"]);

/** The colour of the halo behind Mochi: the worn skin's own, unless his state must show. */
export function glowColor(state: BotStateName, outfit: Outfit): string {
  const own = skinFor(outfit)?.glow ?? null;
  return own && !STATE_KEEPS.has(state) ? own : botGlowColor(state);
}

/**
 * How much of the state's colour tints Mochi's body: a skin that recolours the body
 * (a fruit, a robot) would turn muddy under it, so it gets a little, except in the
 * states that must show.
 */
export function stateTintScale(state: BotStateName, outfit: Outfit): number {
  return skinBody(outfit) !== null && !STATE_KEEPS.has(state) ? 0.3 : 1;
}

/** The body colours of the worn outfit when it recolours the character (the pumpkin, some skins). */
export function outfitBodyColors(outfit: Outfit): readonly [string, string] | null {
  return outfit === "pumpkin" ? PUMPKIN_BODY : skinBody(outfit);
}

type Ctx = CanvasRenderingContext2D;
type Head = Parameters<typeof drawBuiltInBehind>[2];
type State = Parameters<typeof drawBuiltInBehind>[3];

export function drawOutfitBehind(ctx: Ctx, outfit: Outfit, H: Head, st: State) {
  const skin = skinFor(outfit);
  if (skin) drawSkin(ctx, skin, H, st, "behind");
  else drawBuiltInBehind(ctx, outfit, H, st);
}

/** Skins only: what sits on the body itself, between the body and the eyes. */
export function drawOutfitBody(ctx: Ctx, outfit: Outfit, H: Head, st: State) {
  const skin = skinFor(outfit);
  if (skin) drawSkin(ctx, skin, H, st, "body");
}

export function drawOutfitFront(ctx: Ctx, outfit: Outfit, H: Head, st: State) {
  const skin = skinFor(outfit);
  if (skin) drawSkin(ctx, skin, H, st, "front");
  else drawBuiltInFront(ctx, outfit, H, st);
}

export function drawWardrobeIcon(ctx: Ctx, size: number, selection: OutfitSelection, seasonal: Outfit, autoLabel: string) {
  const skin = skinFor(selection);
  if (skin) drawSkinIcon(ctx, size, skin);
  else {
    // The built-in pictures are drawn for 28 px and reach the bottom edge (the body
    // ends at 29): scaled to the button, shrunk a little and centred on their content.
    const k = (size / 28) * 1.0;
    ctx.save();
    ctx.translate(size / 2, size / 2);
    ctx.scale(k, k);
    ctx.translate(-14, -14.5);
    drawBuiltInIcon(ctx, 28, selection, seasonal, autoLabel);
    ctx.restore();
  }
}
