// Settings sections for the Windows and Linux additions, drawn like the
// rest of the window: Mochi (the emote tester).

import { MOOD_ACTS } from "../mochi/engine";
import { emit } from "@tauri-apps/api/event";
import { h } from "../views/dom";
import { t } from "../i18n/i18n";

/**
 * Mochi: a button per chat mood plays it on the island's Mochi, to try them
 * out.
 */
export function mochiSection(): HTMLElement {
  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "Mochi" })),
    h("div", { class: "subhead", text: t("Play an emote") }),
    h("div", { class: "row" }, ...Object.keys(MOOD_ACTS).map((mood) => {
      const button = h("button", { text: mood });
      button.addEventListener("click", () => void emit("mochi-mood", mood));
      return button;
    })),
  );
}
