// Settings sections for the Windows and Linux additions, drawn like the
// rest of the window: Mochi (the screenshot roam).
//
// The page's `settings` object is replaced whenever another window saves, so
// every section reads it through `ctx.settings()`.

import type { Settings } from "../core/state";
import { h } from "../views/dom";

export interface ExtrasContext {
  settings(): Settings;
  save(): void;
  /** The window's on/off switch. */
  toggle(on: boolean, onChange: (v: boolean) => void): HTMLElement;
}

/** Mochi: the screenshot roam. */
export function mochiSection(ctx: ExtrasContext): HTMLElement {
  const s = ctx.settings();
  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "Mochi" })),
    h("div", { class: "row" },
      h("label", { text: "Quick screenshot" }),
      ctx.toggle(s.quickScan ?? false, (v) => {
        ctx.settings().quickScan = v;
        ctx.save();
      }),
    ),
    h("div", { class: "hint", text: "Ctrl+drag Mochi out of the island and drop him for a screenshot; this skips his scan and captures right after the drop." }),
  );
}
