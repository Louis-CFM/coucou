// Wardrobe view — port of WardrobeView (IslandViewContent.swift). Opened with a
// right-click on Mochi or from the tray menu. Resting the pointer on a button
// tries the outfit on Mochi; a click keeps it. Settings shows the same picker
// (settings/extras.ts). It dresses the focused Mochi, named in the header,
// unless every Mochi shares one outfit.

import { h } from "./dom";
import { State } from "../core/state";
import { pillDefinition } from "../core/pills";
import { drawWardrobeIcon } from "../mochi/outfits";
import {
  MAIN_MOCHI, OUTFIT_KEYS, OUTFIT_SELECTIONS, WARDROBE_STRINGS, lookOf, parseWardrobeMode, resolveOutfit,
  seasonalOutfit, wardrobeHeader, type Outfit, type OutfitSelection,
} from "../mochi/wardrobe";
import type { ViewActions, ViewHost } from "./views";
import { language, tl } from "../i18n/i18n";

const ICON = 28;

/** What the picker reads and changes: the island's state, or the Settings window's. */
export interface WardrobeChoices {
  outfit(): OutfitSelection;
  chooseOutfit(selection: OutfitSelection): void;
  /** The island tries an outfit on Mochi while the pointer rests on it; null ends it. */
  previewOutfit?(outfit: Outfit | null): void;
}

export interface WardrobePicker {
  /** The outfit buttons. */
  el: HTMLElement;
  /** The hovered outfit, else the current choice (the wardrobe header's right side). */
  note: HTMLElement;
  sync(): void;
  /** Forgets a hovered outfit (the island dropped its preview). */
  dropHover(): void;
}

export function wardrobePicker(c: WardrobeChoices): WardrobePicker {
  const note = h("span", { class: "wardrobe-note" });
  const outfitGrid = h("div", { class: "wardrobe-grid" });
  const el = h("div", { class: "wardrobe-picker" }, outfitGrid);

  let hoveredOutfit: OutfitSelection | null = null;
  let drawnSeason: Outfit | null = null;
  let drawnLanguage = language();
  const items = new Map<OutfitSelection, { button: HTMLButtonElement; canvas: HTMLCanvasElement }>();

  const updateNote = () => {
    note.textContent = wardrobeHeader(hoveredOutfit, c.outfit(), new Date());
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
      updateNote();
    },
    dropHover() {
      hoveredOutfit = null;
    },
  };
}

/** The Mochi `key` (wardrobe.ts mochiKey) as its pill calls it; the main one is "Mochi". */
export function mochiLabel(key: string): string {
  if (key === MAIN_MOCHI) return "Mochi";
  return pillDefinition(key)?.name ?? State.tasks.find((t) => t.id === key)?.name ?? key;
}

export function buildWardrobe(actions: ViewActions): ViewHost {
  const who = h("span", { class: "wardrobe-title", style: "color:var(--dim-2)" });
  const picker = wardrobePicker({
    outfit: () => lookOf(State.settings, State.focusMochi).outfit,
    chooseOutfit: (sel) => actions.chooseOutfit(sel),
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
      who.textContent = parseWardrobeMode(State.settings.wardrobeMode) === "all" ? "" : mochiLabel(State.focusMochi);
    },
  };
}
