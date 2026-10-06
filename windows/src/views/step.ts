// A step of a Claude Code session, as the prototype shows it: the tool by its
// icon and its name, what it is at — a file, a command — and under it a look
// at what it did: the lines of the file it read, the diff of its edit, the
// command it ran with the end of what that printed.
//
// Everything here comes with the hooks. coucou-hook forwards a few lines of a
// tool's result and no more; none of it is fetched, and none of it is kept
// once the session is gone.

import { h, svg } from "./dom";
import { diffLine, fileKind, readPatch } from "./code";
import { ICONS } from "./icons";
import type { SessionStep } from "../core/state";

/** Tools by a name short enough for a column, where their own is not. */
const STEP_NAMES: Record<string, string> = {
  AskUserQuestion: "Question",
  NotebookEdit: "Notebook",
  MultiEdit: "Edit",
  TodoWrite: "Todos",
  WebSearch: "Search",
  WebFetch: "Fetch",
  PowerShell: "Shell",
};

export const stepName = (step: SessionStep) => STEP_NAMES[step.tool] ?? step.tool;

const STEP_ICONS: Record<SessionStep["kind"], { path: string; stroke: number }> = {
  read: { path: ICONS.doc, stroke: 0 },
  edit: { path: ICONS.pencil, stroke: 2 },
  command: { path: ICONS.terminal, stroke: 2.2 },
  search: { path: ICONS.search, stroke: 2.2 },
  other: { path: ICONS.pulse, stroke: 2 },
  prompt: { path: ICONS.bubble, stroke: 0 },
  reply: { path: ICONS.check, stroke: 3 },
  note: { path: ICONS.bang, stroke: 0 },
};

/** The mark of what a step does: a page read, a pencil, a prompt, a lens. */
export function stepIcon(step: SessionStep, size = 12): SVGSVGElement {
  // A question is something said, whatever its tool is filed under.
  const icon = step.questions ? STEP_ICONS.prompt : STEP_ICONS[step.kind];
  return svg(icon.path, size, icon.stroke ? { stroke: icon.stroke } : {});
}

/** A line of a terminal: the prompt and the command, or a line it printed. */
function termLine(text: string, command = false): HTMLElement {
  return h("div", { class: command ? "term-line cmd" : "term-line" }, h("span", { class: "p", text: command ? "$" : "" }), h("span", { class: "t", text }));
}

/** A command as one line: its first, with a mark when it goes on. */
function oneLine(command: string): string {
  const lines = command.trim().split("\n");
  return lines.length > 1 ? `${lines[0]} …` : lines[0];
}

/** A line still to be typed: its row, empty for now, and what goes in it. */
export interface ToType {
  row: HTMLElement;
  number: number | null;
  text: string;
}

/** True when the step has something to look at. */
export function hasPreview(step: SessionStep): boolean {
  return step.patch != null || step.result != null || (step.kind === "command" && step.target != null);
}

/**
 * What a step did, to look at. With `limit`, only that many lines, and the
 * ones that say the most: an edit from its first changed line, a file from
 * its top, a command with the end of what it printed. With `typed`, an
 * edit's new lines come out empty and hidden, and are handed back to be typed.
 */
export function stepPreview(step: SessionStep, limit?: number, typed?: ToType[]): HTMLElement | null {
  const rows: HTMLElement[] = [];
  const result = step.result?.text.split("\n") ?? [];

  if (step.patch != null) {
    const kind = fileKind(step.target ?? "");
    const lines = [...readPatch(step.patch)].flatMap((line) => ("hunk" in line ? [] : [line]));
    // A line of context above the first change, when there is one.
    const first = Math.max(0, lines.findIndex((line) => line.sign !== "") - 1);
    const shown = limit ? lines.slice(first, first + limit) : lines;
    for (const line of shown) {
      const number = line.new ?? line.old;
      const row = diffLine(number, line.sign, typed && line.sign === "+" ? "" : line.text, kind);
      if (typed && line.sign === "+") {
        row.classList.add("untyped");
        typed.push({ row, number, text: line.text });
      }
      rows.push(row);
    }
    if (shown.length < lines.length - first) rows.push(termLine(`… ${lines.length - first - shown.length} more lines`));
  } else if (step.kind === "command") {
    if (step.target) rows.push(termLine(oneLine(step.target), true));
    // Short of room, an empty line is one line less of what was printed.
    const printed = limit ? result.filter((line) => line.trim()) : result;
    const room = limit ? Math.max(0, limit - rows.length) : printed.length;
    for (const line of room > 0 ? printed.slice(-room) : []) rows.push(termLine(line));
  } else if (step.kind === "read" && step.result) {
    const kind = fileKind(step.target ?? "");
    const start = step.result.start ?? 1;
    result.slice(0, limit ?? result.length).forEach((line, i) => rows.push(diffLine(start + i, "", line, kind)));
  } else {
    for (const line of result.slice(0, limit ?? result.length)) rows.push(termLine(line));
  }

  if (rows.length === 0) return null;
  return h("div", { class: step.state === "failed" ? "gh-diff step-preview failed" : "gh-diff step-preview" }, ...rows);
}
