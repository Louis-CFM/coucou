// Settings sections for the Windows and Linux additions, drawn like the
// rest of the window: Mochi (his name, and the wardrobe with outfits and body
// shapes, for every Mochi or each its own), and the name box each coloured
// Mochi gets under Integrations.
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
import { MOOD_ACTS } from "../mochi/engine";
import { emit } from "@tauri-apps/api/event";

export interface ExtrasContext {
  settings(): Settings;
  save(): void;
  /** The window's on/off switch. */
  toggle(on: boolean, onChange: (v: boolean) => void): HTMLElement;
}

/** A name box: saves on change; empty falls back to `fallback`. */
export function nameInput(value: string, fallback: string, apply: (v: string) => void, save: () => void): HTMLInputElement {
  const input = h("input", {
    type: "text",
    value,
    placeholder: fallback,
    maxlength: "32",
    spellcheck: "false",
    style: "flex:1 1 auto;min-width:0",
  }) as HTMLInputElement;
  input.addEventListener("change", () => {
    apply(input.value.trim());
    save();
  });
  return input;
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
    h("div", { class: "row" },
      h("label", { text: t("Mochi's name") }),
      nameInput(ctx.settings().mochiName ?? "", "Mochi", (v) => { ctx.settings().mochiName = v; }, ctx.save),
    ),
    h("div", { class: "hint", text: t("What the chat calls itself, and the main Mochi's pill when nothing runs. Each coloured Mochi's name is under Integrations.") }),
    h("div", { class: "row" }, h("label", { text: t("Wardrobe") }), mode),
    mochis,
    h("div", { class: "hint" }, picker.note),
    picker.el,    h("div", { class: "subhead", text: t("Play an emote") }),
    h("div", { class: "row" }, ...Object.keys(MOOD_ACTS).map((mood) => {
      const button = h("button", { text: mood });
      button.addEventListener("click", () => void emit("mochi-mood", mood));
      return button;
    })),
    h("div", { class: "row" },
      h("label", { text: t("Quick screenshot") }),
      ctx.toggle(ctx.settings().quickScan ?? false, (v) => {
        ctx.settings().quickScan = v;
        ctx.save();
      }),
    ),
    h("div", { class: "hint", text: t("Ctrl+drag Mochi out of the island and drop him for a screenshot; this skips his scan and captures right after the drop.") }),
  );
}
