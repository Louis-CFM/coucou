// Diff card — port of DiffCardView / DiffLineRowView (IslandViewContent.swift).
// Opens in the overview's left card when a diff step of the ticker is clicked;
// its expand control opens the same card full size, as the island's "diff" view.

import { h, svg } from "./dom";
import { ICONS } from "./icons";
import { fileName, type DiffKind, type FileDiff } from "../core/diff";
import { N_, tl } from "../i18n/i18n";

const STRINGS = {
  back: N_("Back"),
  open: N_("Open in VS Code"),
  expand: N_("Details"),
  tooLarge: N_("Diff too large"),
  noChanges: N_("No changes"),
};

const SYMBOLS: Record<DiffKind, string> = { added: "+", removed: "−", context: " " };

export interface DiffCardHooks {
  dismiss(): void;
  /** ↗ — opens the file in the editor. */
  open(path: string): void;
  /** The small card's expand control. Without it, the card is the full-size view. */
  expand?(): void;
}

/** A diff's rows, or why there are none; the full-size view adds line numbers. */
export function diffRows(diff: FileDiff, { numbers }: { numbers: boolean }): HTMLElement {
  if (diff.tooLarge) return h("div", { class: "diff-note", text: tl(STRINGS.tooLarge) });
  if (diff.hunks.every((hunk) => hunk.lines.length === 0)) {
    return h("div", { class: "diff-note", text: tl(STRINGS.noChanges) });
  }
  const num = (n: number) => h("span", { class: "num", text: n === -1 ? "" : String(n) });
  const content = h("div", { class: "diff-lines" });
  diff.hunks.forEach((hunk, i) => {
    // With line numbers, a ⋯ row marks where they jump from one hunk to the next.
    if (numbers && i > 0) content.append(h("div", { class: "diff-line diff-gap", text: "⋯" }));
    for (const line of hunk.lines) {
      content.append(
        h(
          "div",
          { class: `diff-line ${line.kind}` },
          numbers ? num(line.origLine) : null,
          numbers ? num(line.newLine) : null,
          h("span", { class: "sym", text: SYMBOLS[line.kind] }),
          h("span", { class: "txt", text: line.text }),
        ),
      );
    }
  });
  return content;
}

export function buildDiffCard(diff: FileDiff, hooks: DiffCardHooks): HTMLElement {
  const small = hooks.expand != null;
  const head = h(
    "div",
    { class: "diff-head" },
    h(
      "button",
      { class: "diff-back", title: small ? tl(STRINGS.back) : diff.path, onclick: () => hooks.dismiss() },
      svg(ICONS.chevronLeft, 9, { stroke: 2.4 }),
      h("b", { text: fileName(diff.path) }),
    ),
    h("span", { class: "grow" }),
    diff.added > 0 ? h("span", { class: "tick-count plus", text: `+${diff.added}` }) : null,
    diff.removed > 0 ? h("span", { class: "tick-count minus", text: `−${diff.removed}` }) : null,
    small
      ? h(
          "button",
          { class: "icon-btn diff-expand", title: tl(STRINGS.expand), onclick: () => hooks.expand?.() },
          svg(ICONS.expand, 8),
        )
      : null,
    h(
      "button",
      { class: "icon-btn", title: tl(STRINGS.open), onclick: () => hooks.open(diff.path) },
      svg(ICONS.arrowUpRight, 8),
    ),
  );

  const content = diffRows(diff, { numbers: !small });
  // A click in the small card's lines opens them full size too.
  if (small && content.classList.contains("diff-lines")) {
    content.addEventListener("click", () => hooks.expand?.());
  }

  return h("div", { class: "diff-card" }, head, content);
}
