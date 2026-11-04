// The update card — port of UpdateCardView (MacUpdateViews.swift): the
// one-time question, "Coucou X is out" with Update now · What's new · Later,
// then the download's progress, or what went wrong. Same green wash and the
// same left inset as the other cards, Mochi on the left.

import { h, clear } from "./dom";
import { washRGBA } from "../core/layout";
import { headerLine, percent } from "../core/update";
import { Updates } from "../island/update";
import type { ViewHost } from "./views";
import { language, t } from "../i18n/i18n";

function btn(label: string, kind: "primary" | "secondary", onClick: () => void): HTMLButtonElement {
  return h("button", { class: `btn ${kind}`, onclick: onClick }, h("span", { text: label }));
}

export function buildUpdate(): ViewHost {
  const title = h("div", { class: "title one-line" });
  const line = h("div", { class: "sub update-line" });
  const fill = h("div", { class: "fill" });
  const bar = h("div", { class: "update-bar" }, fill);
  const row = h("div", { class: "actions" });
  const stack = h("div", { class: "stack" }, title, line, bar, row);
  stack.style.padding = "4px 16px 4px 116px";
  const card = h("div", { class: "card wash" }, stack);
  card.style.setProperty("--wash", washRGBA("green"));
  const el = h("div", { class: "view" }, card);

  // The buttons are only rebuilt when what they offer changes: rebuilding them
  // between a mouse-down and a mouse-up would swallow the click.
  let rowKey = "";
  function buttons(state: string, make: () => HTMLElement[]) {
    const key = `${state}~${language()}`;
    if (key === rowKey) return;
    rowKey = key;
    clear(row);
    row.append(...make());
  }

  return {
    el,
    sync() {
      const s = Updates.status;
      const r = s.latest;
      const youHave = t("You have {version}", { version: s.current });
      bar.style.display = "none";
      title.title = "";

      if (Updates.asking) {
        title.textContent = t("Get new versions from the island?");
        line.textContent = t("Mochi checks Coucou's releases on GitHub a few times a day and tells you when one is out. Nothing about you is sent.");
        buttons("ask", () => [
          btn(t("Yes, tell me"), "primary", () => Updates.answer(true)),
          btn(t("No thanks"), "secondary", () => Updates.answer(false)),
        ]);
        return;
      }

      const phase = s.phase;
      if (phase.kind === "error") {
        title.textContent = t("The update didn't go through");
        line.textContent = phase.message;
        buttons("error", () => [
          btn(t("Get it on GitHub"), "primary", () => Updates.openPage()),
          btn(t("OK"), "secondary", () => Updates.dismiss()),
        ]);
        return;
      }

      if (!r) {
        title.textContent = t("Coucou is up to date");
        line.textContent = youHave;
        buttons("none", () => [btn(t("OK"), "secondary", () => Updates.dismiss())]);
        return;
      }

      title.textContent = t("Coucou {version} is out", { version: r.version });
      title.title = title.textContent;
      switch (phase.kind) {
        case "downloading": {
          bar.style.display = "";
          fill.style.width = `${percent(phase.fraction)}%`;
          line.textContent = t("Downloading from GitHub… {percent} %", { percent: percent(phase.fraction) });
          buttons("busy", () => []);
          return;
        }
        case "verifying":
          line.textContent = t("Checking the download…");
          buttons("busy", () => []);
          return;
        case "installing":
          line.textContent = t("Installing… Coucou closes and comes back by itself.");
          buttons("busy", () => []);
          return;
        case "idle":
          line.textContent = headerLine(r.headline, youHave);
          // The portable exe and Linux update the way they were installed: the release page.
          buttons(s.canInstall ? "install" : "page", () => s.canInstall
            ? [
              btn(t("Update now"), "primary", () => Updates.install()),
              btn(t("What's new"), "secondary", () => Updates.openPage()),
              btn(t("Later"), "secondary", () => Updates.later()),
            ]
            : [
              btn(t("Get it on GitHub"), "primary", () => Updates.openPage()),
              btn(t("Later"), "secondary", () => Updates.later()),
            ]);
          return;
      }
    },
  };
}
