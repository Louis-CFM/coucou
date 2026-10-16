// Settings sections for the Windows and Linux additions, drawn like the
// rest of the window: Mochi (the wardrobe with outfits and body shapes, for
// every Mochi or each its own).
//
// The page's `settings` object is replaced whenever another window saves, so
// every section reads it through `ctx.settings()`.

import type { Settings } from "../core/state";
import { MAIN_MOCHI, lookOf, parseWardrobeMode, setLook } from "../mochi/wardrobe";
import { pillDefinition, sanitizeDeclared } from "../core/pills";
import { pillColor } from "../core/pill-colors";
import { wardrobePicker } from "../views/wardrobe";
import { h } from "../views/dom";
import { t } from "../i18n/i18n";

export interface ExtrasContext {
  settings(): Settings;
  save(): void;
}

/** Redraws what follows other windows' saves. */
export function extrasSettingsChanged() {
  syncWardrobe();
}

// ── Wardrobe ──────────────────────────────────────────────────────────────────

/** Follows the island's choices (a right-click on Mochi saves too). */
let syncWardrobe: () => void = () => {};

/** The user's Mochis, as the wardrobe keys them: the main one, then each declared pill's. */
export function yourMochis(s: Settings): { key: string; name: string; color: string }[] {
  const d = sanitizeDeclared(s);
  const mochi = (id: string, key: string, name?: string) => {
    const def = pillDefinition(id);
    return { key, name: name || def?.name || id, color: pillColor(id, def?.color ?? "#888888", s.pillColors) };
  };
  return [mochi(d.mainPill, MAIN_MOCHI, "Mochi"), ...d.activeIntegrations.map((id) => mochi(id, id))];
}

/**
 * Mochi: the island's wardrobe, the same picker as a right-click on Mochi,
 * outfits then body shapes. Either every Mochi wears one look, or each its
 * own: then the row of Mochis picks whom the picker dresses. Switching keeps
 * both sets (each Mochi's own looks are in wardrobe-looks.json, settings.rs).
 * The island and the desktop Mochi follow at once.
 */
export function mochiSection(ctx: ExtrasContext): HTMLElement {
  let who = MAIN_MOCHI;
  const mode = h("select", {}) as HTMLSelectElement;
  for (const [value, text] of [
    ["perMochi", t("Each Mochi has its own outfit")],
    ["all", t("Same outfit for every Mochi")],
  ]) mode.append(h("option", { value, text }));
  mode.addEventListener("change", () => {
    ctx.settings().wardrobeMode = mode.value;
    ctx.save();
    sync();
  });
  const mochis = h("div", { class: "row" });
  const choose = (change: { outfit?: string; shape?: string }) => {
    setLook(ctx.settings(), who, change);
    ctx.save();
    sync();
  };
  const picker = wardrobePicker({
    outfit: () => lookOf(ctx.settings(), who).outfit,
    shape: () => lookOf(ctx.settings(), who).shape,
    chooseOutfit: (outfit) => choose({ outfit }),
    chooseShape: (shape) => choose({ shape }),
  });

  function sync() {
    const s = ctx.settings();
    const all = parseWardrobeMode(s.wardrobeMode) === "all";
    mode.value = all ? "all" : "perMochi";
    const list = yourMochis(s);
    if (!list.some((m) => m.key === who)) who = MAIN_MOCHI;
    mochis.style.display = all ? "none" : "";
    mochis.replaceChildren(h("label", {}), ...list.map((m) => {
      const button = h(
        "button",
        { class: m.key === who ? "primary" : "", "aria-pressed": String(m.key === who) },
        h("i", { class: "dot", style: `background:${m.color};margin-right:6px` }),
        m.name,
      );
      button.addEventListener("click", () => {
        who = m.key;
        sync();
      });
      return button;
    }));
    picker.sync();
  }
  syncWardrobe = sync;
  sync();

  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "Mochi" })),
    h("div", { class: "row" }, h("label", { text: t("Wardrobe") }), mode),
    mochis,
    h("div", { class: "hint" }, picker.note),
    picker.el,
  );
}
