// Styles: an optional clean-up by Claude (no "um", no repeats, corrections
// applied), as said, natural or polished, per app. Port of the styles part of
// FlowHubWords.swift.

import { h, clear } from "../../views/dom";
import { t } from "../../i18n/i18n";
import { FlowBridge, type AppStyle, type Style } from "../../core/flow";
import type { HubContext } from "../shell";
import { pageSave } from "../save";
import { card, divider, iconButton, label, row, select, toggle } from "../ui";
import { dropdown } from "../../views/dropdown";

export function styleOptions(): [Style, string][] {
  return [["verbatim", t("As said")], ["natural", t("Natural")], ["polished", t("Polished")]];
}

export async function stylesPage(page: HTMLElement, ctx: HubContext) {
  const status = await ctx.refresh();
  let styles: AppStyle[] = (await FlowBridge.styles()) ?? [];
  page.append(ctx.hero("styles", t("Styles"), t("Claude cleans up what you say, in the style of the app you write in.")));
  const write = pageSave(page);
  const save = async (next: AppStyle[]) => {
    const result = await write(() => FlowBridge.setStyles(next));
    if (result === "pending") return;
    if (result === "saved") styles = next;
    // Restore the actual selection as well when the native store rejects it.
    drawApps();
  };

  const perApp = h("div", {});
  const drawApps = () => {
    clear(perApp);
    perApp.classList.toggle("dimmed", !ctx.status.prefs.cleanup);
    styles.forEach((s, i) => {
      if (i > 0) perApp.append(divider());
      perApp.append(row(s.name, null,
        select(styleOptions(), s.style, (style) => {
          void save(styles.map((x) => (x.id === s.id ? { ...x, style } : x)));
        }),
        iconButton("x", t("Delete"), () => {
          void save(styles.filter((x) => x.id !== s.id));
        }),
      ));
    });
  };

  const keyNote = h("div", { class: "hub-warn", text: t("The clean-up uses your Claude key. Add it in Notch → Chat.") });
  keyNote.style.display = status.hasClaudeKey ? "none" : "";
  const defaultRow = row(t("Other apps"), null, select(styleOptions(), status.prefs.defaultStyle, (style) => void ctx.setPrefs((p) => (p.defaultStyle = style))));
  const stylesCard = card(
    row(t("Clean up with Claude"), t("Removes the “um”, the repeats and the corrections you made while speaking, and fixes the punctuation."),
      toggle(status.prefs.cleanup, (on) => {
        void ctx.setPrefs((p) => (p.cleanup = on));
        perApp.classList.toggle("dimmed", !on);
      })),
    keyNote,
    divider(),
    defaultRow,
    h("div", { class: "hub-note", text: t("With the clean-up on, the text (never your voice) goes to Anthropic with your Claude key. Off, everything stays on this computer.") }),
  );
  stylesCard.dataset.anchor = "flow.styles";
  page.append(stylesCard);

  // "Add an app": the apps with a window right now, using Liquid Glass dropdown.
  const selectFallback = h("select", {
    class: "hub-select",
    style: "display:none;position:absolute;opacity:0;pointer-events:none",
    tabIndex: -1,
    "aria-hidden": "true",
  }) as HTMLSelectElement;

  const addBtn = h("button", {
    class: "dd-trigger hub-select",
    type: "button",
  },
    h("span", { class: "dd-trigger-text", text: `+ ${t("Add an app")}` }),
    selectFallback,
  ) as HTMLButtonElement;

  const chevron = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  chevron.setAttribute("viewBox", "0 0 24 24");
  chevron.setAttribute("width", "12");
  chevron.setAttribute("height", "12");
  chevron.setAttribute("fill", "none");
  chevron.setAttribute("stroke", "currentColor");
  chevron.setAttribute("stroke-width", "2.5");
  chevron.setAttribute("stroke-linecap", "round");
  const cp = document.createElementNS("http://www.w3.org/2000/svg", "path");
  cp.setAttribute("d", "M6 9l6 6 6-6");
  chevron.append(cp);
  addBtn.append(chevron);

  const fillAdd = async () => {
    while (selectFallback.firstChild) selectFallback.removeChild(selectFallback.firstChild);
    selectFallback.append(h("option", { value: "", text: `+ ${t("Add an app")}` }));
    const running = ((await FlowBridge.runningApps()) ?? []).filter((a) => !styles.some((s) => s.id === a.id));
    if (running.length === 0) selectFallback.append(h("option", { value: "-", text: t("No other open app"), disabled: true }));
    for (const a of running) selectFallback.append(h("option", { value: `${a.id}\n${a.name}`, text: a.name }));
    selectFallback.value = "";
  };

  selectFallback.addEventListener("change", async () => {
    const [id, name] = selectFallback.value.split("\n");
    if (!id || id === "-") return;
    await save([...styles, { id, name: name ?? id, style: ctx.status.prefs.defaultStyle }]);
    void fillAdd();
  });
  void fillAdd();

  addBtn.addEventListener("click", async () => {
    await fillAdd();
    const running = ((await FlowBridge.runningApps()) ?? []).filter((a) => !styles.some((s) => s.id === a.id));
    const entries = running.length === 0
      ? [{ label: t("No other open app"), disabled: true, onClick: () => {} }]
      : running.map((a) => ({
          label: a.name,
          onClick: async () => {
            await save([...styles, { id: a.id, name: a.name ?? a.id, style: ctx.status.prefs.defaultStyle }]);
            void fillAdd();
          },
        }));
    const menu = dropdown(entries);
    menu.open(addBtn);
  });

  page.append(h("div", { class: "hub-row" }, label(t("Style per app")), h("span", { class: "spacer", style: "flex:1" }), addBtn));
  page.append(card(perApp));
  drawApps();
}
