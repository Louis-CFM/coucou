// What's new after an update (whats-new/controller.ts decides when): first
// what this version brings — an icon, a title and a line per item — then
// "Your Coucou so far", the numbers this computer kept, and Buy Mochi a
// coffee. Same left inset as the other cards, Mochi on the left.

import { h, clear, svg } from "./dom";
import { washRGBA } from "../core/layout";
import { Updates } from "../island/update";
import { formatCount, formatDuration } from "../recap/summary";
import { STAT_ICONS, WHATS_NEW_ICONS } from "../whats-new/icons";
import { WhatsNew } from "../whats-new/controller";
import { COFFEE_URL, iconName, localized, releasePage, type Stat } from "../whats-new/whats-new";
import type { ViewHost } from "./views";
import { language, t } from "../i18n/i18n";

function btn(label: string, kind: "primary" | "secondary", onClick: () => void): HTMLButtonElement {
  return h("button", { class: `btn ${kind}`, onclick: onClick }, h("span", { text: label }));
}

const plural = (n: number, one: string, many: string) => (n === 1 ? one : many);

function statLabel(s: Stat): string {
  switch (s.kind) {
    case "agentSessions": return plural(s.value, t("agent session"), t("agent sessions"));
    case "agentTime": return t("with your agents");
    case "linesAdded": return t("lines written");
    case "approvals": return plural(s.value, t("approval from the island"), t("approvals from the island"));
    case "words": return t("words dictated");
    case "saved": return t("saved by dictating");
    case "calls": return plural(s.value, t("call transcribed"), t("calls transcribed"));
  }
}

function statValue(s: Stat): string {
  return s.kind === "agentTime" || s.kind === "saved" ? formatDuration(s.value) : formatCount(s.value);
}

export function buildWhatsNew(): ViewHost {
  const stack = h("div", { class: "stack whatsnew-stack" });
  const card = h("div", { class: "card wash" }, stack);
  card.style.setProperty("--wash", washRGBA("indigo"));
  const el = h("div", { class: "view" }, card);

  // Rebuilt only when what it shows changes: rebuilding between a mouse-down
  // and a mouse-up would swallow the click.
  let key = "";

  function stepOne() {
    const release = WhatsNew.release;
    if (!release) return;
    const lang = language();
    const grid = h("div", { class: "whatsnew-items" });
    for (const item of release.items.slice(0, 4)) {
      const title = localized(item.title, lang);
      const detail = localized(item.detail, lang);
      grid.append(h("div", { class: "whatsnew-item" },
        h("span", { class: "whatsnew-icon" }, svg(WHATS_NEW_ICONS[iconName(item.icon)], 16, { stroke: 1.8 })),
        h("div", { class: "whatsnew-text" },
          h("div", { class: "whatsnew-item-title", text: title, title }),
          h("div", { class: "whatsnew-item-detail", text: detail, title: detail }),
        ),
      ));
    }
    const page = releasePage(Updates.status.platform, release.version);
    stack.append(
      h("div", { class: "title one-line", text: t("You're on Coucou {version}", { version: release.version }) }),
      grid,
      h("div", { class: "actions" },
        btn(t("Next"), "primary", () => WhatsNew.next()),
        btn(t("All changes"), "secondary", () => WhatsNew.openReleasePage(page)),
      ),
    );
  }

  function stepTwo() {
    const chips = h("div", { class: "whatsnew-stats" });
    for (const s of WhatsNew.stats) {
      chips.append(h("div", { class: "whatsnew-stat" },
        h("span", { class: "whatsnew-stat-icon" }, svg(STAT_ICONS[s.kind], 12, { stroke: 2 })),
        h("div", {},
          h("div", { class: "v", text: statValue(s) }),
          h("div", { class: "l", text: statLabel(s) }),
        ),
      ));
    }
    stack.append(h("div", { class: "title one-line", text: t("Your Coucou so far") }));
    if (WhatsNew.stats.length > 0) stack.append(chips);
    stack.append(
      h("div", { class: "sub whatsnew-thanks", text: t("Coucou is free and open source. If it saves you time, you can buy Mochi a coffee.") }),
      h("div", { class: "actions" },
        btn(`☕ ${t("Buy Mochi a coffee")}`, "primary", () => WhatsNew.openCoffee(COFFEE_URL)),
        btn(t("OK"), "secondary", () => WhatsNew.done()),
      ),
    );
  }

  return {
    el,
    sync() {
      const next = `${WhatsNew.generation}~${WhatsNew.step}~${language()}`;
      if (next === key) return;
      key = next;
      clear(stack);
      if (WhatsNew.step === 1) stepOne();
      else stepTwo();
    },
  };
}
