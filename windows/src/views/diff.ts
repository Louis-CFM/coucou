// Full session and source review surface for a selected file edit.

import { h, svg } from "./dom";
import { ICONS } from "./icons";
import { fileName, isDiffStep, type DiffKind, type DiffLine, type FileDiff } from "../core/diff";
import type { AgentTask } from "../core/state";
import { N_, tl } from "../i18n/i18n";

const STRINGS = {
  back: N_("Back to session"),
  open: N_("Open in editor"),
  activity: N_("Session activity"),
  noActivity: N_("No activity details yet"),
  tooLarge: N_("Diff is too large to display; line counts are shown."),
  noChanges: N_("No changes to display."),
  working: N_("Working"),
  finished: N_("Finished"),
  waiting: N_("Waiting for you"),
  project: N_("Workspace"),
};

const SYMBOLS: Record<DiffKind, string> = { added: "+", removed: "−", context: " " };

export interface DiffWorkspaceHooks {
  back(): void;
  open(path: string): void;
}

export function buildDiffWorkspace(
  diff: FileDiff,
  task: AgentTask,
  agentLabel: string,
  hooks: DiffWorkspaceHooks,
): HTMLElement {
  const path = diff.path.replaceAll("\\", "/");
  const project = task.sessionCwd?.split(/[\\/]/).filter(Boolean).at(-1) ?? task.name;
  const stateText = task.state === "working" || task.state === "thinking" || task.state === "searching"
    ? tl(STRINGS.working)
    : task.state === "approval" || task.state === "question"
      ? tl(STRINGS.waiting)
      : task.state === "finished" ? tl(STRINGS.finished) : task.state;
  const sidebar = h(
    "aside",
    { class: "diff-sidebar" },
    h("div", { class: "diff-sidebar-title", text: project }),
    h("div", { class: "diff-sidebar-agent", text: agentLabel }),
    h(
      "div",
      { class: "diff-project" },
      h("span", { class: "diff-project-label", text: tl(STRINGS.project) }),
      h("span", { class: "diff-project-name", title: task.sessionCwd ?? "", text: project }),
    ),
    h(
      "div",
      { class: "diff-status" },
      h("span", { class: `diff-status-dot ${task.state}`, "aria-hidden": "true" }),
      h("span", { text: stateText }),
    ),
  );

  const activity = h(
    "section",
    { class: "diff-activity" },
    h("h2", { text: tl(STRINGS.activity) }),
  );
  const steps = task.steps.filter((step) => !isDiffStep(step)).slice(-5);
  if (steps.length === 0) {
    activity.append(h("div", { class: "diff-activity-empty", text: tl(STRINGS.noActivity) }));
  } else {
    const rows = h("div", { class: "diff-activity-list" });
    steps.forEach((step, i) => {
      const current = i === steps.length - 1 && ["working", "thinking", "searching"].includes(task.state);
      rows.append(
        h(
          "div",
          { class: current ? "diff-activity-row current" : "diff-activity-row" },
          h("span", { class: "diff-activity-mark", text: current ? "◌" : "✓", "aria-hidden": "true" }),
          h("span", { class: "diff-activity-text", text: step }),
        ),
      );
    });
    activity.append(rows);
  }
  sidebar.append(activity);

  const extension = fileName(diff.path).split(".").pop()?.toUpperCase() ?? "FILE";
  const tab = h(
    "div",
    { class: "diff-file-tab" },
    h("span", { class: "diff-file-type", text: extension.slice(0, 3) }),
    h("span", { class: "diff-file-name", title: fileName(diff.path), text: fileName(diff.path) }),
    h("span", { class: "diff-unsaved", title: tl("Changed by agent") }),
  );
  const toolbar = h(
    "div",
    { class: "diff-toolbar" },
    h("span", { class: "diff-file-path", title: diff.path, text: path }),
    h("span", { class: "diff-toolbar-spacer" }),
    diff.added > 0 ? h("span", { class: "diff-total added", text: `+${diff.added}` }) : null,
    diff.removed > 0 ? h("span", { class: "diff-total removed", text: `−${diff.removed}` }) : null,
    h(
      "button",
      { class: "diff-open", title: tl(STRINGS.open), onclick: () => hooks.open(diff.path) },
      svg(ICONS.arrowUpRight, 11),
    ),
  );

  const lines = h("div", { class: "diff-code" });
  if (diff.tooLarge) {
    lines.append(h("div", { class: "diff-code-note", text: tl(STRINGS.tooLarge) }));
  } else {
    const allLines = diff.hunks.flatMap((hunk) => hunk.lines);
    if (allLines.length === 0) {
      lines.append(h("div", { class: "diff-code-note", text: tl(STRINGS.noChanges) }));
    } else {
      for (const line of allLines) lines.append(codeRow(line));
    }
  }

  const editor = h(
    "main",
    { class: "diff-editor" },
    h("div", { class: "diff-editor-tabs" }, tab),
    toolbar,
    lines,
  );

  const back = h(
    "button",
    { class: "diff-back-button", onclick: hooks.back },
    svg(ICONS.chevronLeft, 12, { stroke: 2.4 }),
    h("span", { text: tl(STRINGS.back) }),
  );
  return h("div", { class: "diff-workspace" }, back, sidebar, editor);
}

function codeRow(line: DiffLine): HTMLElement {
  const number = line.kind === "removed" ? line.origLine : line.newLine;
  const row = h(
    "div",
    { class: `diff-code-row ${line.kind}` },
    h("span", { class: "diff-code-number", text: number > 0 ? String(number) : "" }),
    h("span", { class: "diff-code-symbol", text: SYMBOLS[line.kind] }),
    h("code", { class: "diff-code-text" }, ...highlight(line.text)),
  );
  return row;
}

function highlight(text: string): Node[] {
  const token = /\/\/.*$|\/\*.*?\*\/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\b(?:import|from|export|default|function|return|const|let|var|if|else|class|type|interface|async|await|new|true|false|null|undefined|as|extends)\b|\b\d+(?:\.\d+)?\b|\b[A-Z][A-Za-z0-9_]*\b|\b[A-Za-z_$][\w$]*(?=\s*\()|[{}()[\].,:;=+*/<>!-]/g;
  const nodes: Node[] = [];
  let offset = 0;
  for (const match of text.matchAll(token)) {
    const index = match.index ?? 0;
    if (index > offset) nodes.push(document.createTextNode(text.slice(offset, index)));
    const value = match[0];
    const kind = value.startsWith("//") || value.startsWith("/*") ? "comment"
      : /^["'`]/.test(value) ? "string"
        : /^(?:import|from|export|default|function|return|const|let|var|if|else|class|type|interface|async|await|new|true|false|null|undefined|as|extends)$/.test(value) ? "keyword"
          : /^\d/.test(value) ? "number"
            : /^[A-Z]/.test(value) ? "type"
              : /^[A-Za-z_$]/.test(value) ? "call" : "punctuation";
    nodes.push(h("span", { class: `syntax-${kind}`, text: value }));
    offset = index + value.length;
  }
  if (offset < text.length) nodes.push(document.createTextNode(text.slice(offset)));
  return nodes;
}
