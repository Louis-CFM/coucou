// Styles: an optional clean-up by Claude (no "um", no repeats, corrections
// applied), as said, natural or polished, per app. Port of the styles part of
// FlowHubWords.swift.

import { h, clear } from "../../views/dom";
import { t } from "../../i18n/i18n";
import { FlowBridge, type AppStyle, type Style } from "../../core/flow";
import type { HubContext } from "../shell";
import { card, divider, iconButton, label, row, select, toggle } from "../ui";

export function styleOptions(): [Style, string][] {
  return [["verbatim", t("As said")], ["natural", t("Natural")], ["polished", t("Polished")]];
}

export async function stylesPage(page: HTMLElement, ctx: HubContext) {
  const status = await ctx.refresh();
  let styles: AppStyle[] = (await FlowBridge.styles()) ?? [];
  const save = () => void FlowBridge.setStyles(styles);
  page.append(ctx.hero("styles", t("Styles"), t("Claude cleans up what you say, in the style of the app you write in.")));

  const perApp = h("div", {});
  const drawApps = () => {
    clear(perApp);
    perApp.classList.toggle("dimmed", !ctx.status.prefs.cleanup);
    styles.forEach((s, i) => {
      if (i > 0) perApp.append(divider());
      perApp.append(row(s.name, null,
        select(styleOptions(), s.style, (style) => {
          styles = styles.map((x) => (x.id === s.id ? { ...x, style } : x));
          save();
        }),
        iconButton("x", t("Delete"), () => {
          styles = styles.filter((x) => x.id !== s.id);
          save();
          drawApps();
        }),
      ));
    });
  };

  const keyNote = h("div", { class: "hub-warn", text: t("The clean-up uses your Claude key. Add it in Notch → Chat.") });
  keyNote.style.display = status.hasClaudeKey ? "none" : "";
  const defaultRow = row(t("Other apps"), null, select(styleOptions(), status.prefs.defaultStyle, (style) => void ctx.setPrefs((p) => (p.defaultStyle = style))));
  page.append(card(
    row(t("Clean up with Claude"), t("Removes the “um”, the repeats and the corrections you made while speaking, and fixes the punctuation."),
      toggle(status.prefs.cleanup, (on) => {
        void ctx.setPrefs((p) => (p.cleanup = on));
        perApp.classList.toggle("dimmed", !on);
      })),
    keyNote,
    divider(),
    defaultRow,
    h("div", { class: "hub-note", text: t("With the clean-up on, the text (never your voice) goes to Anthropic with your Claude key. Off, everything stays on this computer.") }),
  ));

  // "Add an app": the apps with a window right now.
  const add = h("select", { class: "hub-select" }) as HTMLSelectElement;
  const fillAdd = async () => {
    clear(add);
    add.append(h("option", { value: "", text: `+ ${t("Add an app")}` }));
    const running = ((await FlowBridge.runningApps()) ?? []).filter((a) => !styles.some((s) => s.id === a.id));
    if (running.length === 0) add.append(h("option", { value: "-", text: t("No other open app"), disabled: true }));
    for (const a of running) add.append(h("option", { value: `${a.id}\n${a.name}`, text: a.name }));
    add.value = "";
  };
  add.addEventListener("focus", () => void fillAdd());
  add.addEventListener("change", () => {
    const [id, name] = add.value.split("\n");
    if (!id || id === "-") return;
    styles = [...styles, { id, name: name ?? id, style: ctx.status.prefs.defaultStyle }];
    save();
    drawApps();
    void fillAdd();
  });
  void fillAdd();
  page.append(h("div", { class: "hub-row" }, label(t("Style per app")), h("span", { class: "spacer", style: "flex:1" }), add));
  page.append(card(perApp));
  drawApps();
}
