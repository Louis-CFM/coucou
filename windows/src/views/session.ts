// The code view: what a Claude Code session edits and runs, in a small editor.
// The file it just changed (a few lines of context, removed lines in red, added
// ones in green), under it the last command with what it printed, and next to
// Mochi the phases of the turn.
//
// Each pill keeps its own data, so parallel sessions never mix. Everything comes
// from the hooks: `tool_input` carries the edit, the lines around it are read by
// Rust (snippet.rs, only inside the session's folder), and the last lines a
// command printed arrive in `tool_tail`. All text goes in as text nodes: a
// file's content is not ours to trust as HTML.

import { Bridge, type Snippet } from "../core/bridge";
import { State } from "../core/state";
import { tl } from "../i18n/i18n";
import { h, svg, clear, dot } from "./dom";
import { ICONS } from "./icons";
import type { ViewActions, ViewHost } from "./views";

export interface EditShown {
  kind: "edit" | "write";
  /** Relative to the session's folder when it lies inside it. */
  file: string;
  removed: string;
  added: string;
  snippet?: Snippet | null;
  /** The lines around it are being read: its rows wait for them, so they do not shift. */
  pending?: boolean;
}

export interface CommandShown {
  /** Bash or PowerShell: the terminal tab's name. */
  tool: string;
  command: string;
  tail: string[];
  status: "pending" | "ok" | "failed";
}

export type Phase = "read" | "edit" | "bash";

export interface CodeData {
  sessionId: string;
  /** The project's name, from the folder the session started in. */
  project: string;
  /** That folder: files are shown relative to it and read from inside it, however often the shell `cd`s. */
  root: string;
  /** A session on another machine: its files are not here to read. */
  remote: boolean;
  edit?: EditShown;
  command?: CommandShown;
  /** Which of Read / Edit / Bash this turn has used, and which it is in now. */
  seen: Phase[];
  current: Phase | null;
  finished: boolean;
}

/** Where an event comes from. */
export interface CodeSource {
  sessionId: string;
  cwd: string;
  project: string;
  remote: boolean;
}

const str = (v: unknown): string => (typeof v === "string" ? v : "");

const PHASE_OF: Record<string, Phase> = {
  Read: "read", Glob: "read", Grep: "read", LS: "read", WebFetch: "read", WebSearch: "read",
  Edit: "edit", MultiEdit: "edit", Write: "edit", NotebookEdit: "edit",
  Bash: "bash", PowerShell: "bash",
};

const SNIPPET_CONTEXT = 3;
/** One line of an error stands in for a failed command's output. */
const ERROR_WIDTH = 160;

/** Keyed by pill id. */
const byPill = new Map<string, CodeData>();

/** The pill's data, created on its first event; a new session in the same pill starts afresh. */
function dataFor(pillId: string, src: CodeSource): CodeData {
  const known = byPill.get(pillId);
  if (known && !(src.sessionId && known.sessionId && src.sessionId !== known.sessionId)) {
    known.sessionId ||= src.sessionId;
    return known;
  }
  const fresh: CodeData = {
    sessionId: src.sessionId,
    project: src.project,
    root: src.cwd,
    remote: src.remote,
    seen: [],
    current: null,
    finished: false,
  };
  byPill.set(pillId, fresh);
  return fresh;
}

/** The pill's data, if it has any (tests, the view). */
export function codeFor(pillId: string): CodeData | null {
  return byPill.get(pillId) ?? null;
}

/** True when the pill has an edit or a command to show. */
export function hasCode(pillId: string | null | undefined): boolean {
  const d = pillId ? byPill.get(pillId) : undefined;
  return !!(d && (d.edit || d.command));
}

/** A new prompt starts a new turn: the old code and phases go. */
export function beginTurn(pillId: string, src: CodeSource) {
  const d = dataFor(pillId, src);
  Object.assign(d, { edit: undefined, command: undefined, seen: [], current: null, finished: false });
}

export function endTurn(pillId: string) {
  const d = byPill.get(pillId);
  if (!d) return;
  d.finished = true;
  if (d.edit) d.edit.pending = false;
}

/** The session is over. */
export function dropCode(pillId: string) {
  byPill.delete(pillId);
}

function editOf(tool: string, input: Record<string, unknown>, file: string): EditShown | null {
  switch (tool) {
    case "Edit":
      return { kind: "edit", file, removed: str(input.old_string), added: str(input.new_string) };
    case "MultiEdit": {
      // The first edit stands for the call: the pane has room for a handful of lines.
      const edits = Array.isArray(input.edits) ? (input.edits as Record<string, unknown>[]) : [];
      return { kind: "edit", file, removed: str(edits[0]?.old_string), added: str(edits[0]?.new_string) };
    }
    case "Write":
      return { kind: "write", file, removed: "", added: str(input.content) };
    default:
      return null;
  }
}

/** A tool is about to run: note it, and what the view will show of it. */
export function toolStarted(pillId: string, src: CodeSource, tool: string, input: Record<string, unknown>) {
  const d = dataFor(pillId, src);
  d.finished = false;
  const phase = PHASE_OF[tool];
  if (phase) {
    d.current = phase;
    if (!d.seen.includes(phase)) d.seen.push(phase);
  }

  const edit = editOf(tool, input, relativeTo(str(input.file_path), d.root, src.cwd));
  if (edit) {
    edit.pending = edit.kind === "edit" && !!edit.added && !d.remote;
    d.edit = edit;
  }
  if ((tool === "Bash" || tool === "PowerShell") && str(input.command)) {
    d.command = { tool, command: str(input.command), tail: [], status: "pending" };
  }
}

/** `abs` relative to the session's folder, else to the shell's current one, else as it is. */
function relativeTo(abs: string, root: string, cwd: string): string {
  for (const base of [root, cwd]) {
    if (!base) continue;
    const trimmed = base.replace(/[\\/]+$/, "");
    for (const sep of ["/", "\\"]) {
      if (abs.startsWith(trimmed + sep)) return abs.slice(trimmed.length + 1);
    }
  }
  return abs;
}

function inside(abs: string, base: string): boolean {
  const trimmed = base.replace(/[\\/]+$/, "");
  return !!trimmed && (abs.startsWith(trimmed + "/") || abs.startsWith(trimmed + "\\"));
}

export interface ToolResult {
  /** The last lines a command printed (the relay keeps nothing else of its output). */
  tail?: string[];
  failed?: boolean;
  error?: string;
}

/** A tool finished (or failed): fill in what only exists afterwards. */
export function toolFinished(pillId: string, cwd: string, tool: string, input: Record<string, unknown>, result: ToolResult) {
  const d = byPill.get(pillId);
  if (!d) return;
  if ((tool === "Bash" || tool === "PowerShell") && d.command) {
    d.command.status = result.failed ? "failed" : "ok";
    const tail = (result.tail ?? []).filter((l) => typeof l === "string");
    const error = result.error?.split("\n")[0].slice(0, ERROR_WIDTH);
    d.command.tail = tail.length ? tail : error ? [error] : [];
    return;
  }
  if (result.failed) {
    if (d.edit && editOf(tool, input, "")) d.edit.pending = false;
    return;
  }

  const path = str(input.file_path);
  // After the edit the relay sends its text whole; before, it was cut short.
  const whole = editOf(tool, input, relativeTo(path, d.root, cwd));
  if (!whole) return;
  const find = whole.added;
  // The pane shows a handful of lines: a whole file is not kept for it.
  const shown: EditShown = { ...whole, removed: head(whole.removed), added: head(whole.added) };
  d.edit = shown;
  // A remote session's files are on another machine: nothing to read here.
  if (whole.kind !== "edit" || !find || d.remote) return;
  // Read from inside the session's folder; the shell's folder only if the file is not in it.
  const base = inside(path, d.root) ? d.root : cwd;
  shown.pending = true;
  const settle = (snip: Snippet | null) => {
    // Only if it is still the edit this answer belongs to.
    if (byPill.get(pillId)?.edit !== shown) return;
    if (snip) shown.snippet = snip;
    shown.pending = false;
    State.notify();
  };
  void Bridge.fileSnippet(base, path, find, SNIPPET_CONTEXT).then(settle, () => settle(null));
}

const KEPT_LINES = 40;
const KEPT_CHARS = 8_000;

function head(text: string): string {
  return text.split("\n", KEPT_LINES).join("\n").slice(0, KEPT_CHARS);
}

// ── Rendering ───────────────────────────────────────────────────────────────

const TOKEN =
  /(\/\/.*|^\s*#.*)|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`[^`]*`)|\b(\d+(?:\.\d+)?)\b|\b(const|let|var|function|return|import|export|from|if|else|for|while|class|new|async|await|def|fn|pub|use|type|interface|struct|impl|enum|match|in|of|true|false|null|None)\b|\b([A-Z][A-Za-z0-9_]*)\b|\b([a-z_][A-Za-z0-9_]*)(?=\()/g;

/** One line of code as coloured spans (comment, string, number, keyword, type, call). */
function highlight(line: string): Node[] {
  const out: Node[] = [];
  let last = 0;
  for (const m of line.matchAll(TOKEN)) {
    const at = m.index ?? 0;
    if (at > last) out.push(document.createTextNode(line.slice(last, at)));
    const cls = m[1] != null ? "c" : m[2] != null ? "s" : m[3] != null ? "n" : m[4] != null ? "k" : m[5] != null ? "t" : "f";
    out.push(h("span", { class: `tok-${cls}`, text: m[0] }));
    last = at + m[0].length;
  }
  if (last < line.length) out.push(document.createTextNode(line.slice(last)));
  return out;
}

export interface Row {
  kind: "ctx" | "add" | "del";
  n: number | null;
  text: string;
}

const lines = (text: string): string[] => text.replace(/\n$/, "").split("\n");

/** The rows of the editor pane for one edit, in file order. */
export function codeRows(e: EditShown): Row[] {
  const removed = e.removed ? lines(e.removed) : [];
  const added = e.added ? lines(e.added) : [];
  const snip = e.snippet;
  if (e.kind === "write" || !snip) {
    const from = e.kind === "write" ? 1 : null;
    return [
      ...removed.map((text) => ({ kind: "del" as const, n: null, text })),
      ...added.map((text, i) => ({ kind: "add" as const, n: from == null ? null : from + i, text })),
    ];
  }
  const rows: Row[] = [];
  snip.lines.forEach((text, i) => {
    // The removed lines are no longer in the file: they sit just above what replaced them.
    if (i === snip.at) for (const r of removed) rows.push({ kind: "del", n: null, text: r });
    const changed = i >= snip.at && i < snip.at + snip.len;
    rows.push({ kind: changed ? "add" : "ctx", n: snip.start + i, text });
  });
  return rows;
}

/** Keeps the changed rows and as much context as fits, dropping the far context first, evenly. */
export function fit(rows: Row[], max: number): Row[] {
  let from = 0;
  let to = rows.length;
  let lead = 0;
  while (lead < rows.length && rows[lead].kind === "ctx") lead++;
  let trail = 0;
  while (trail < rows.length - lead && rows[rows.length - 1 - trail].kind === "ctx") trail++;
  while (to - from > max) {
    if (lead > 0 && lead >= trail) {
      from++;
      lead--;
    } else if (trail > 0) {
      to--;
      trail--;
    } else {
      to--; // only changed rows left: keep the start of the change
    }
  }
  return rows.slice(from, to);
}

const CHIPS: Record<string, [string, string]> = {
  ts: ["TS", "#3b82f6"], tsx: ["TS", "#3b82f6"], js: ["JS", "#eab308"], jsx: ["JS", "#eab308"],
  py: ["PY", "#38bdf8"], rs: ["RS", "#f97316"], go: ["GO", "#22d3ee"], md: ["MD", "#9ca3af"],
  json: ["{}", "#a3a3a3"], css: ["CS", "#a78bfa"], html: ["<>", "#fb923c"], sh: ["SH", "#86efac"],
  yml: ["YM", "#f472b6"], yaml: ["YM", "#f472b6"], toml: ["TM", "#fbbf24"],
};

function fileTab(d: CodeData): HTMLElement {
  const e = d.edit;
  if (!e) return h("div", { class: "ed-tab" }, h("span", { class: "ed-name", text: (d.command?.tool ?? "").toLowerCase() }));
  const name = e.file.split(/[\\/]/).pop() || e.file;
  const [label, color] = CHIPS[(name.split(".").pop() ?? "").toLowerCase()] ?? ["·", "#6b7079"];
  const chip = h("span", { class: "ed-chip", text: label });
  chip.style.background = `${color}2e`;
  chip.style.color = color;
  return h(
    "div",
    { class: "ed-tab" },
    h("span", { class: "ed-file" }, chip, h("span", { class: "ed-name", text: name })),
    h("span", { class: "ed-dir", text: e.file }),
  );
}

function codeRow(r: Row): HTMLElement {
  return h(
    "div",
    { class: `ed-row ${r.kind}` },
    h("span", { class: "ed-n", text: r.n == null ? "" : String(r.n) }),
    h("span", { class: "ed-sign", text: r.kind === "add" ? "+" : r.kind === "del" ? "−" : "" }),
    h("span", { class: "ed-text" }, ...highlight(r.text)),
  );
}

/** A line a test runner printed: PASS / FAIL as a badge, ticks and crosses coloured. */
function tailLine(text: string): HTMLElement {
  const m = /^\s*(PASS|FAIL)\b\s*(.*)$/.exec(text);
  if (m) {
    return h(
      "div",
      { class: "term-line" },
      h("span", { class: `badge ${m[1] === "PASS" ? "pass" : "fail"}`, text: m[1] }),
      h("span", { class: "dim", text: m[2] }),
    );
  }
  const tone = /[✓✔]|\bpassed\b|\bok\b/i.test(text) ? "good" : /[✗✘×]|\bfail|\berror\b/i.test(text) ? "bad" : "dim";
  return h("div", { class: `term-line ${tone}`, text: text.trim() });
}

function terminal(c: CommandShown): HTMLElement {
  const box = h(
    "div",
    { class: "term" },
    h(
      "div",
      { class: "term-line cmd" },
      h("span", { class: "prompt", text: "$" }),
      h("span", { class: "term-cmd", text: c.command.replace(/\s+/g, " ") }),
      c.status === "pending" ? h("span", { class: "term-run", text: "…" }) : null,
    ),
  );
  for (const l of c.tail) box.append(tailLine(l));
  if (c.status === "failed" && c.tail.length === 0) box.append(h("div", { class: "term-line bad", text: tl("Failed") }));
  return box;
}

/** Tool names, not translated: they are what Claude Code calls them. */
const PHASES: { id: Phase; label: string; glyph: string }[] = [
  { id: "read", label: "Read", glyph: ICONS.doc },
  { id: "edit", label: "Edit", glyph: ICONS.pencil },
  { id: "bash", label: "Bash", glyph: ICONS.terminal },
];

type PhaseState = "done" | "active" | "todo";

function phaseIcon(state: PhaseState, glyph: string): HTMLElement {
  if (state === "done") return h("span", { class: "ph-icon ok" }, svg(ICONS.check, 10, { stroke: 3 }));
  if (state === "active") return h("span", { class: "ph-icon spin" });
  return h("span", { class: "ph-icon todo" }, svg(glyph, 10, { stroke: 2.2 }));
}

function phaseList(d: CodeData): HTMLElement {
  const list = h("div", { class: "phases" });
  for (const { id, label, glyph } of PHASES) {
    const state: PhaseState = !d.finished && d.current === id ? "active" : d.seen.includes(id) ? "done" : "todo";
    list.append(h("div", { class: `phase ${state}` }, phaseIcon(state, glyph), h("span", { text: label })));
  }
  list.append(h(
    "div",
    { class: `phase ${d.finished ? "done" : "todo"}` },
    h("span", { class: d.finished ? "ph-icon ok" : "ph-icon ok muted" }, svg(ICONS.check, 10, { stroke: 3 })),
    h("span", { text: tl("Done") }),
  ));
  return list;
}

const CODE_ROWS = 11;

/** How many code rows fit above the terminal box. */
export function codeRowBudget(d: CodeData): number {
  return d.command ? CODE_ROWS - 2 - d.command.tail.length : CODE_ROWS;
}

export function buildCodeView(actions: ViewActions): ViewHost {
  const left = h("div", { class: "code-left" });
  const editor = h("div", { class: "editor" });
  const el = h("div", { class: "view" }, h("div", { class: "card" }, h("div", { class: "code-view" }, left, editor)));
  let key = "";

  return {
    el,
    sync() {
      const task = State.focusTask;
      const d = task ? byPill.get(task.id) : undefined;
      if (!task || !d) {
        // The pill in front has nothing to show (yet): no stale code of another one.
        key = "";
        clear(left);
        clear(editor);
        return;
      }
      const next = JSON.stringify([task.id, task.color, d]);
      if (next === key) return;
      key = next;

      clear(left);
      left.append(
        h("div", { class: "code-name" }, dot(task.color, 7), h("span", { text: d.project })),
        h(
          "div",
          { class: "code-tool" },
          h("span", { text: "Claude Code" }),
          h(
            "button",
            { class: "code-back", title: tl("Back"), onclick: () => actions.setView("overview") },
            svg(ICONS.chevronLeft, 9, { stroke: 2.4 }),
          ),
        ),
        phaseList(d),
      );

      clear(editor);
      editor.append(fileTab(d));
      const rows = d.edit && !d.edit.pending ? fit(codeRows(d.edit), codeRowBudget(d)) : [];
      if (rows.length) editor.append(h("div", { class: "ed-code" }, ...rows.map(codeRow)));
      if (d.command) editor.append(terminal(d.command));
    },
  };
}
