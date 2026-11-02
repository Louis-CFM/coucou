// Settings parts for the Windows and Linux additions, drawn like the rest of
// the window: Mochi's name, and the name box each coloured Mochi gets under
// Integrations.
//
// The page's `settings` object is replaced whenever another window saves, so
// every section reads it through `ctx.settings()`.

import type { Settings } from "../core/state";
import { h } from "../views/dom";

export interface ExtrasContext {
  settings(): Settings;
  save(): void;
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

/** Mochi: his name, the chat's persona. */
export function mochiSection(ctx: ExtrasContext): HTMLElement {
  const s = ctx.settings();
  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "Mochi" })),
    h("div", { class: "row" },
      h("label", { text: "Mochi's name" }),
      nameInput(s.mochiName ?? "", "Mochi", (v) => { ctx.settings().mochiName = v; }, ctx.save),
    ),
    h("div", { class: "hint", text: "What the chat calls itself, and the main Mochi's pill when nothing runs. Each coloured Mochi's name is under Integrations." }),
  );
}
