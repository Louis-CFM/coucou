// Wardrobe view — port of WardrobeView (IslandViewContent.swift). Opened with a
// right-click on Mochi or from the tray menu. Resting the pointer on a button
// tries the outfit on Mochi; a click keeps it.

import { h } from "./dom";
import { State } from "../core/state";
import { drawWardrobeIcon } from "../mochi/skin-outfits";
import { loadUserSkins } from "../mochi/skin-loader";
import { isSkinSelection, onSkinsChange, skinLabel, skinSelections } from "../mochi/skins";
import {
  OUTFIT_KEYS, OUTFIT_SELECTIONS, WARDROBE_STRINGS, parseOutfit, resolveOutfit, seasonalOutfit,
  wardrobeHeader, type Outfit, type OutfitSelection,
} from "../mochi/wardrobe";
import type { ViewActions, ViewHost } from "./views";
import { language, tl } from "../i18n/i18n";

const ICON = 28;

export function buildWardrobe(actions: ViewActions): ViewHost {
  const note = h("span", { class: "wardrobe-note" });
  const grid = h("div", { class: "wardrobe-grid" });
  const el = h(
    "div",
    { class: "view wardrobe" },
    h(
      "div",
      { class: "card" },
      h(
        "div",
        { class: "stack wardrobe-stack" },
        h("div", { class: "wardrobe-head" }, h("span", { class: "wardrobe-title", text: tl("Wardrobe") }), note),
        grid,
      ),
    ),
  );

  let hovered: OutfitSelection | null = null;
  let drawnSeason: Outfit | null = null;
  let drawnLanguage = language();
  let drawnDpr = 0;
  const items = new Map<OutfitSelection, { button: HTMLButtonElement; canvas: HTMLCanvasElement }>();

  const updateNote = () => {
    note.textContent = wardrobeHeader(hovered, parseOutfit(State.settings.mochiOutfit), new Date());
  };

  /** The names of the buttons: a skin carries its own, a built-in outfit is translated. */
  const nameOf = (sel: OutfitSelection) => (isSkinSelection(sel) ? skinLabel(sel) : tl(OUTFIT_KEYS[sel]));
  const drawn = new Set<OutfitSelection>();

  const addItem = (sel: OutfitSelection) => {
    const canvas = h("canvas");
    const button = h(
      "button",
      { class: "wardrobe-item", title: nameOf(sel), "aria-label": nameOf(sel) },
      canvas,
    );
    button.addEventListener("mouseenter", () => {
      hovered = sel;
      actions.previewOutfit(resolveOutfit(sel, new Date()));
      updateNote();
    });
    button.addEventListener("mouseleave", () => {
      if (hovered !== sel) return;
      hovered = null;
      actions.previewOutfit(null);
      updateNote();
    });
    button.addEventListener("click", () => actions.chooseOutfit(sel));
    items.set(sel, { button, canvas });
    grid.append(button);
  };
  for (const sel of OUTFIT_SELECTIONS) addItem(sel);

  /** The skins (shipped, and the user's folder) follow the collection: new ones appear, gone ones leave. */
  const syncSkins = () => {
    const want = new Set(skinSelections() as OutfitSelection[]);
    for (const [sel, { button }] of items) {
      if (isSkinSelection(sel) && !want.has(sel)) {
        button.remove();
        items.delete(sel);
        drawn.delete(sel);
      }
    }
    for (const sel of want) if (!items.has(sel)) addItem(sel);
  };
  syncSkins();
  onSkinsChange(() => {
    syncSkins();
    State.notify();
  });
  let lastReload = 0;

  /** Icons are drawn once; only "auto" changes, with the season and its badge's language. */
  const drawIcons = () => {
    const season = seasonalOutfit(new Date());
    const pending = [...items.keys()].some((sel) => !drawn.has(sel));
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    if (season === drawnSeason && drawnLanguage === language() && drawnDpr === dpr && !pending) return;
    // On a monitor of another scale every icon is drawn again, sharp and whole.
    const first = drawnSeason == null || drawnDpr !== dpr;
    drawnSeason = season;
    drawnLanguage = language();
    drawnDpr = dpr;
    for (const [sel, { canvas }] of items) {
      if (!first && sel !== "auto" && drawn.has(sel)) continue;
      drawn.add(sel);
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
    sync() {
      // The user's folder is read again now and then while the wardrobe is open:
      // a skin dropped there shows up without restarting.
      if (State.view === "wardrobe" && Date.now() - lastReload > 3000) {
        lastReload = Date.now();
        void loadUserSkins();
      }
      drawIcons();
      // The island drops the preview when the view closes: so does the hover.
      if (State.wardrobePreview == null) hovered = null;
      const current = parseOutfit(State.settings.mochiOutfit);
      for (const [sel, { button }] of items) button.classList.toggle("on", sel === current);
      updateNote();
    },
  };
}
