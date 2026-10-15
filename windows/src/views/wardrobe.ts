// Wardrobe view — port of WardrobeView (IslandViewContent.swift). Opened with a
// right-click on Mochi or from the tray menu. Resting the pointer on a button
// tries the outfit on Mochi; a click keeps it. Below the outfits, the body
// shapes. Settings shows the same picker (settings/extras.ts). it dresses
// the focused Mochi, named in the header, unless every Mochi shares one look.

import { h } from "./dom";
import { State } from "../core/state";
import { drawShapeIcon, drawWardrobeIcon } from "../mochi/outfits";
import {
  OUTFIT_KEYS, OUTFIT_SELECTIONS, SHAPE_KEYS, WARDROBE_STRINGS, lookOf, parseWardrobeMode, resolveOutfit,
  seasonalOutfit, wardrobeHeader, type Outfit, type OutfitSelection,
} from "../mochi/wardrobe";
import { SHAPES, shapeOf } from "../mochi/shapes";
import type { ViewActions, ViewHost } from "./views";
import { language, t, tl } from "../i18n/i18n";

const ICON = 28;

/** What the picker reads and changes: the island's state, or the Settings window's. */
export interface WardrobeChoices {
  outfit(): OutfitSelection;
  /** The stored shape id ("" = the classic Mochi). */
  shape(): string;
  chooseOutfit(selection: OutfitSelection): void;
  chooseShape(id: string): void;
  /** The island tries an outfit on Mochi while the pointer rests on it; null ends it. */
  previewOutfit?(outfit: Outfit | null): void;
}

export interface WardrobePicker {
  /** The outfit buttons, then the shape buttons. */
  el: HTMLElement;
  /** The hovered item, else the current choice (the wardrobe header's right side). */
  note: HTMLElement;
  sync(): void;
  /** Forgets a hovered outfit (the island dropped its preview). */
  dropHover(): void;
}

export function wardrobePicker(c: WardrobeChoices): WardrobePicker {
  const note = h("span", { class: "wardrobe-note" });
  const outfitGrid = h("div", { class: "wardrobe-grid" });
  const shapeGrid = h("div", { class: "wardrobe-grid" });
  const el = h("div", { class: "wardrobe-picker" }, outfitGrid, shapeGrid);

  let hoveredOutfit: OutfitSelection | null = null;
  let hoveredShape: string | null = null;
  let drawnSeason: Outfit | null = null;
  let drawnLanguage = language();
  const items = new Map<OutfitSelection, { button: HTMLButtonElement; canvas: HTMLCanvasElement }>();
  const shapes = new Map<string, HTMLButtonElement>();

  const updateNote = () => {
    note.textContent = hoveredShape != null
      ? t(SHAPE_KEYS[shapeOf(hoveredShape).id])
      : wardrobeHeader(hoveredOutfit, c.outfit(), new Date());
  };

  const iconCanvas = () => {
    const canvas = h("canvas");
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    canvas.width = Math.round(ICON * dpr);
    canvas.height = Math.round(ICON * dpr);
    const ctx = canvas.getContext("2d");
    ctx?.setTransform(dpr, 0, 0, dpr, 0, 0);
    return { canvas, ctx };
  };

  for (const sel of OUTFIT_SELECTIONS) {
    const canvas = h("canvas");
    const button = h(
      "button",
      { class: "wardrobe-item", title: tl(OUTFIT_KEYS[sel]), "aria-label": tl(OUTFIT_KEYS[sel]) },
      canvas,
    );
    button.addEventListener("mouseenter", () => {
      hoveredOutfit = sel;
      c.previewOutfit?.(resolveOutfit(sel, new Date()));
      updateNote();
    });
    button.addEventListener("mouseleave", () => {
      if (hoveredOutfit !== sel) return;
      hoveredOutfit = null;
      c.previewOutfit?.(null);
      updateNote();
    });
    button.addEventListener("click", () => c.chooseOutfit(sel));
    items.set(sel, { button, canvas });
    outfitGrid.append(button);
  }

  for (const shape of SHAPES) {
    const { canvas, ctx } = iconCanvas();
    if (ctx) drawShapeIcon(ctx, ICON, shape);
    // The classic body is stored as "".
    const id = shape === SHAPES[0] ? "" : shape.id;
    const button = h(
      "button",
      { class: "wardrobe-item", title: tl(SHAPE_KEYS[shape.id]), "aria-label": tl(SHAPE_KEYS[shape.id]) },
      canvas,
    );
    button.addEventListener("mouseenter", () => {
      hoveredShape = id;
      updateNote();
    });
    button.addEventListener("mouseleave", () => {
      if (hoveredShape !== id) return;
      hoveredShape = null;
      updateNote();
    });
    button.addEventListener("click", () => c.chooseShape(id));
    shapes.set(id, button);
    shapeGrid.append(button);
  }

  /** Icons are drawn once; only "auto" changes, with the season and its badge's language. */
  const drawIcons = () => {
    const season = seasonalOutfit(new Date());
    if (season === drawnSeason && drawnLanguage === language()) return;
    const first = drawnSeason == null;
    drawnSeason = season;
    drawnLanguage = language();
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    for (const [sel, { canvas }] of items) {
      if (!first && sel !== "auto") continue;
      canvas.width = Math.round(ICON * dpr);
      canvas.height = Math.round(ICON * dpr);
      const ctx = canvas.getContext("2d");
      if (!ctx) continue;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      drawWardrobeIcon(ctx, ICON, sel, season, WARDROBE_STRINGS.autoBadge);
    }
  };

  return {
    el,
    note,
    sync() {
      drawIcons();
      const current = c.outfit();
      for (const [sel, { button }] of items) button.classList.toggle("on", sel === current);
      const shape = shapeOf(c.shape()) === SHAPES[0] ? "" : c.shape();
      for (const [id, button] of shapes) button.classList.toggle("on", id === shape);
      updateNote();
    },
    dropHover() {
      hoveredOutfit = null;
    },
  };
}

export function buildWardrobe(actions: ViewActions): ViewHost {
  const who = h("span", { class: "wardrobe-title", style: "color:var(--dim-2)" });
  const picker = wardrobePicker({
    outfit: () => lookOf(State.settings, State.focusMochi).outfit,
    shape: () => lookOf(State.settings, State.focusMochi).shape,
    chooseOutfit: (sel) => actions.chooseOutfit(sel),
    chooseShape: (id) => actions.chooseShape(id),
    previewOutfit: (outfit) => actions.previewOutfit(outfit),
  });
  const el = h(
    "div",
    { class: "view wardrobe" },
    h(
      "div",
      { class: "card" },
      h(
        "div",
        { class: "stack wardrobe-stack" },
        h("div", { class: "wardrobe-head" }, h("span", { class: "wardrobe-title", text: tl("Wardrobe") }), who, picker.note),
        picker.el,
      ),
    ),
  );

  return {
    el,
    sync() {
      // The island drops the preview when the view closes: so does the hover.
      if (State.wardrobePreview == null) picker.dropHover();
      picker.sync();
      who.textContent = parseWardrobeMode(State.settings.wardrobeMode) === "all" ? "" : State.mochiNameOf(State.focusMochi);
    },
  };
}
