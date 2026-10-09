import { Bridge } from "../core/bridge";
import { State } from "../core/state";
import { applyTheme, nextTheme, normalizeTheme } from "../core/theme";
import { t } from "../i18n/i18n";
import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";

/** The cross hides the island; only explicit Quit exits the application. */
export function buildAppearanceControls(hide: () => void = () => {}) {
  const toggle = h("button", { class: "theme-toggle", type: "button" });
  const quit = h("button", { class: "quit-button", type: "button", onclick: hide }, svg(ICONS.xmark, 13));
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
    quit.setAttribute("title", t("Hide Nova")); quit.setAttribute("aria-label", t("Hide Nova"));
  }
  sync();
  return { toggle, quit, sync };
}
