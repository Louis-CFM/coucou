import { h, svg } from "./dom";
import { ICONS } from "./icons";
import type { ModelInfo } from "../core/bridge";
import { State } from "../core/state";
import { codexModelLabel, effortLabel } from "../core/codex";
import { t, tl } from "../i18n/i18n";

/** The compact effort card; its model link opens a separate list. */
export function codexControls(model: ModelInfo, openModels: () => void, changed: (save: boolean) => void): HTMLElement {
  const efforts = model.reasoningEfforts ?? [];
  const label = h("span", { class: "codex-effort-value", "aria-live": "polite" });
  const modelButton = h("button", { class: "codex-model-link", onclick: openModels, "aria-expanded": "false" },
    h("span", { text: model.label || codexModelLabel(model.id) }), svg(ICONS.chevronRight, 10, { stroke: 1.7 }));
  const note = h("span", { class: "codex-usage-note", text: tl("Consumes usage limits faster") });
  const caption = h("div", { class: "codex-caption" }, modelButton, note);
  const bolt = h("button", { class: "codex-bolt", "aria-label": tl("Fast"), title: tl("Fast uses more of your plan.") },
    svg("M13.5 2 4 13h6l-1 9 11-13h-7l.5-7z", 17, { stroke: 1.6 }));
  bolt.disabled = !model.serviceTiers?.length;
  const reset = h("button", { class: "codex-reset", title: tl("Reset to model default"), "aria-label": tl("Reset to model default") },
    svg(ICONS.arrowClockwise, 17, { stroke: 1.5 }));
  const header = h("div", { class: "codex-control-heading" }, bolt, label, reset);
  const slider = h("input", { class: "codex-effort-slider", type: "range", min: "0", step: "1",
    max: String(Math.max(0, efforts.length - 1)), "aria-label": tl("Reasoning effort") }) as HTMLInputElement;
  slider.disabled = efforts.length < 2;
  const ticks = h("div", { class: "codex-effort-ticks", "aria-hidden": "true" });
  for (const effort of efforts) ticks.append(h("i", { title: t(effortLabel(effort)) }));
  const sparks = h("div", { class: "codex-sparks", "aria-hidden": "true" });
  for (let i = 0; i < 17; i++) sparks.append(h("i", { style: `--x:${(i * 47 + 13) % 97}%;--y:${(i * 31 + 19) % 79}%;--delay:${-i * .19}s;--duration:${1.2 + (i % 5) * .24}s` }));
  const fill = h("div", { class: "codex-range-fill" }, sparks);
  const thumb = h("div", { class: "codex-range-thumb" });
  const range = h("div", { class: "codex-range" }, fill, ticks, thumb, slider);
  const el = h("div", { class: "codex-effort-card" }, header, caption, range);
  let hintTimer: ReturnType<typeof setTimeout> | undefined;
  function paint(showUsage = false) {
    const effort = State.settings.codexReasoningEffort;
    const percent = efforts.length > 1 ? Math.max(0, efforts.indexOf(effort)) / (efforts.length - 1) * 100 : 0;
    slider.value = String(Math.max(0, efforts.indexOf(effort)));
    label.textContent = t(effortLabel(effort));
    slider.setAttribute("aria-valuetext", label.textContent);
    range.style.setProperty("--position", `calc(${percent}% + ${14 - percent * .28}px)`);
    const fast = !!State.settings.codexServiceTier;
    bolt.classList.toggle("on", fast);
    bolt.setAttribute("aria-pressed", String(fast));
    el.classList.toggle("ultra", effort === "ultra");
    el.classList.toggle("fast", fast);
    if (hintTimer) clearTimeout(hintTimer);
    caption.classList.toggle("usage", showUsage && (effort === "ultra" || fast));
    if (showUsage) hintTimer = setTimeout(() => caption.classList.remove("usage"), 1500);
  }
  slider.addEventListener("input", () => {
    State.settings = { ...State.settings, codexReasoningEffort: efforts[Number(slider.value)] ?? model.defaultEffort ?? "" };
    paint(true); changed(false);
  });
  slider.addEventListener("change", () => changed(true));
  bolt.addEventListener("click", () => {
    if (!model.serviceTiers?.length) return;
    State.settings = { ...State.settings, codexServiceTier: State.settings.codexServiceTier ? "" : model.serviceTiers[0].id };
    paint(true); changed(true);
  });
  reset.addEventListener("click", () => {
    State.settings = { ...State.settings, codexReasoningEffort: model.defaultEffort ?? efforts[0] ?? "", codexServiceTier: "" };
    paint(); changed(true);
  });
  paint();
  return el;
}
