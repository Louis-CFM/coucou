// The tall overview's work card: an agent at work, seen whole. Mochi and the
// agent's name on the left with its last steps (done ✓, the current one
// turning), and on the right the file it is changing, line numbers and all.
// The island grows to hold it while the focused agent works (State.tallOverview).

import { h, svg, dot } from "./dom";
import { ICONS } from "./icons";
import { buildDiffCard } from "./diff";
import { parseDiffStep, type FileDiff } from "../core/diff";
import { sessionSubtitle } from "../core/pills";
import type { AgentTask } from "../core/state";
import { t } from "../i18n/i18n";

export interface WorkCardHooks {
  /** ↗ on the file: opens it in the editor. */
  open(path: string): void;
}

/** How many steps the side column lists. */
const SHOWN_STEPS = 5;

/** A step as one short line: diff steps read "invoice.ts +1 −1". */
export function stepText(step: string): string {
  const d = parseDiffStep(step);
  if (!d) return step;
  const counts = [d.added > 0 ? `+${d.added}` : "", d.removed > 0 ? `−${d.removed}` : ""].filter(Boolean).join(" ");
  return counts ? `${d.filename} ${counts}` : d.filename;
}

export function buildWorkCard(task: AgentTask, diff: FileDiff | null, hooks: WorkCardHooks): HTMLElement {
  const steps = task.steps.slice(-SHOWN_STEPS);
  const working = task.state === "working" || task.state === "thinking" || task.state === "searching";
  const list = h("div", { class: "work-steps" });
  steps.forEach((step, i) => {
    const current = working && i === steps.length - 1;
    list.append(h("div", { class: current ? "work-step current" : "work-step" },
      current ? h("i", { class: "work-spin" }) : svg(ICONS.check, 9, { stroke: 2.6 }),
      h("span", { text: stepText(step), title: stepText(step) }),
    ));
  });

  const side = h("div", { class: "work-side" },
    h("div", { class: "work-name" }, dot(task.color, 6), h("b", { text: task.name })),
    h("div", { class: "work-tool", text: t(sessionSubtitle(task.id)) }),
    list,
  );

  const main = h("div", { class: "work-main" });
  if (diff) {
    main.append(buildDiffCard(diff, { dismiss: () => {}, open: hooks.open }));
  } else {
    // No edit yet in this session: what it is doing, large.
    const now = steps.length ? stepText(steps[steps.length - 1]) : "";
    main.append(h("div", { class: "work-waiting" },
      h("span", { class: "work-now shimmer", text: now || "…" }),
    ));
  }
  return h("div", { class: "work" }, side, main);
}
