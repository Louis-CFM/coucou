import { Bridge } from "../core/bridge";
import { State } from "../core/state";
import { applyTheme, nextTheme, normalizeTheme } from "../core/theme";
import { t } from "../i18n/i18n";
import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";

/** The close button quits the application; it is not the island collapse action. */
export function buildAppearanceControls() {
  const toggle = h("button", { class: "theme-toggle", type: "button" });
  const quit = h("button", { class: "quit-button", type: "button", onclick: () => void Bridge.quit() }, svg(ICONS.xmark, 13));
  toggle.addEventListener("click", () => {
    State.settings = { ...State.settings, theme: nextTheme(State.settings.theme) };
    applyTheme(State.settings.theme);
    sync();
    State.notify();
    void Bridge.saveSettings(State.settings);
  });
  function sync() {
    const light = normalizeTheme(State.settings.theme) === "light";
    const label = light ? t("Switch to dark mode") : t("Switch to light mode");
    toggle.setAttribute("title", label); toggle.setAttribute("aria-label", label);
    toggle.setAttribute("aria-pressed", String(light));
    clear(toggle); toggle.append(svg(light ? ICONS.moon : ICONS.sun, 15, { stroke: 1.8 }));
    quit.setAttribute("title", t("Quit Nova")); quit.setAttribute("aria-label", t("Quit Nova"));
  }
  sync();
  return { toggle, quit, sync };
}
