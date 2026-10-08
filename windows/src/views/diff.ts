// Diff card — port of DiffCardView / DiffLineRowView (IslandViewContent.swift).
// Opens in the overview's left card when a diff step of the ticker is clicked.

import { h, svg } from "./dom";
import { ICONS } from "./icons";
import { fileName, type DiffKind, type FileDiff } from "../core/diff";
import { N_, tl } from "../i18n/i18n";

const STRINGS = {
  back: N_("Back"),
  open: N_("Open in VS Code"),
  tooLarge: N_("Diff too large"),
  noChanges: N_("No changes"),
};

const SYMBOLS: Record<DiffKind, string> = { added: "+", removed: "−", context: " " };

export interface DiffCardHooks {
  dismiss(): void;
  /** ↗ — opens the file in the editor. */
  open(path: string): void;
}

export function buildDiffCard(diff: FileDiff, hooks: DiffCardHooks): HTMLElement {
  const head = h(
    "div",
    { class: "diff-head" },
    h(
      "button",
      { class: "diff-back", title: tl(STRINGS.back), onclick: () => hooks.dismiss() },
      svg(ICONS.chevronLeft, 9, { stroke: 2.4 }),
      h("b", { text: fileName(diff.path) }),
    ),
    h("span", { class: "grow" }),
    diff.added > 0 ? h("span", { class: "tick-count plus", text: `+${diff.added}` }) : null,
    diff.removed > 0 ? h("span", { class: "tick-count minus", text: `−${diff.removed}` }) : null,
    h(
      "button",
      { class: "icon-btn", title: tl(STRINGS.open), onclick: () => hooks.open(diff.path) },
      svg(ICONS.arrowUpRight, 8),
    ),
  );

  const lines = diff.hunks.flatMap((hunk) => hunk.lines);
  let content: HTMLElement;
  if (diff.tooLarge) {
    content = h("div", { class: "diff-note", text: tl(STRINGS.tooLarge) });
  } else if (lines.length === 0) {
    content = h("div", { class: "diff-note", text: tl(STRINGS.noChanges) });
  } else {
    content = h("div", { class: "diff-lines" });
    const rows = document.createDocumentFragment();
    for (const line of lines) {
      rows.append(
        h(
          "div",
          { class: `diff-line ${line.kind}` },
          h("span", { class: "sym", text: SYMBOLS[line.kind] }),
          h("span", { class: "txt", text: line.text }),
        ),
      );
    }
    content.append(rows);
  }

  return h("div", { class: "diff-card" }, head, content);
}
