// The session view: while Claude Code works, the island becomes a small editor —
// the file it just changed (a few lines of context, the removed lines in red, the
// added ones in green) and under it the last command with what it printed — next
// to Mochi and the phases of the turn.
//
// Every session keeps its own data, keyed by its session id: with several running
// at once the view shows the one that was active last, and a new prompt in another
// session cannot wipe it. Everything comes from the hooks. `tool_input` carries the edit itself; the
// surrounding lines are read from the file by Rust (snippet.rs), the last lines a
// command printed arrive in `tool_tail`. All text goes in as text nodes: a file's
// content is not ours to trust as HTML.

import { Bridge, type Snippet } from "../core/bridge";
import { localized } from "../core/i18n";
import { State } from "../core/state";
import { h, clear, dot } from "./dom";
import { fa } from "./fa";
import type { ViewActions, ViewHost } from "./views";

export interface EditShown {
  kind: "edit" | "write";
  /** Relative to the session's folder when it lies inside it. */
  file: string;
  removed: string;
  added: string;
  snippet?: Snippet | null;
}

export interface CommandShown {
  command: string;
  tail: string[];
  status: "running" | "ok" | "failed";
}

export type Phase = "read" | "edit" | "bash";

export interface SessionData {
  /** The project's name, from the folder the session started in. */
  project: string;
  /** That folder: files are shown relative to it and read from inside it, however often the shell `cd`s. */
  root: string;
  /** When the session last did anything (epoch ms), to pick the active one. */
  touchedAt: number;
  edit?: EditShown;
  command?: CommandShown;
  /** Which of Read / Edit / Bash this turn has used, and which it is in now. */
  seen: Phase[];
  current: Phase | null;
  finished: boolean;
}

const str = (v: unknown): string => (typeof v === "string" ? v : "");

const PHASE_OF: Record<string, Phase> = {
  Read: "read", Glob: "read", Grep: "read", LS: "read", WebFetch: "read", WebSearch: "read",
  Edit: "edit", MultiEdit: "edit", Write: "edit", NotebookEdit: "edit",
  Bash: "bash", PowerShell: "bash",
};

/** Sessions that did nothing for this long are forgotten (a session that never sent Stop or SessionEnd). */
const FORGET_AFTER_MS = 30 * 60_000;

const sessions = new Map<string, SessionData>();

/** The session's data, created on its first event. `cwd` of that event is its root. */
function sessionFor(id: string, cwd: string, project: string): SessionData {
  let s = sessions.get(id);
  if (!s) {
    s = { project, root: cwd, touchedAt: 0, seen: [], current: null, finished: false };
    sessions.set(id, s);
  }
  s.touchedAt = Date.now();
  for (const [other, o] of sessions) if (s.touchedAt - o.touchedAt > FORGET_AFTER_MS) sessions.delete(other);
  return s;
}

/** The session the view shows: the last active one that has something to show. */
function active(): SessionData | null {
  let best: SessionData | null = null;
  for (const s of sessions.values()) {
    if ((s.edit || s.command) && (!best || s.touchedAt > best.touchedAt)) best = s;
  }
  return best;
}

/** A new prompt starts a new turn of that session: its old code and phases go. */
export function beginTurn(id: string, cwd: string, project: string) {
  const s = sessionFor(id, cwd, project);
  Object.assign(s, { edit: undefined, command: undefined, seen: [], current: null, finished: false });
}

export function endTurn(id: string) {
  const s = sessions.get(id);
  if (s) s.finished = true;
}

/** The session is over (or its finished view has been shown long enough). */
export function dropSession(id: string) {
  sessions.delete(id);
}

/** True once some session has shown something worth a view of its own. */
export function hasSession(): boolean {
  return active() !== null;
}

/** A tool is about to run: note it, and what the session view will show of it. */
export function toolStarted(id: string, tool: string, input: Record<string, unknown>, cwd: string, project: string) {
  const s = sessionFor(id, cwd, project);
  s.finished = false;
  const phase = PHASE_OF[tool];
  if (phase) {
    s.current = phase;
    if (!s.seen.includes(phase)) s.seen.push(phase);
  }

  const file = relativeTo(str(input.file_path), s.root, cwd);
  switch (tool) {
    case "Edit":
      s.edit = { kind: "edit", file, removed: str(input.old_string), added: str(input.new_string) };
      break;
    case "MultiEdit": {
      const edits = Array.isArray(input.edits) ? (input.edits as Record<string, unknown>[]) : [];
      // The first edit stands for the call: the pane has room for a handful of lines.
      s.edit = { kind: "edit", file, removed: str(edits[0]?.old_string), added: str(edits[0]?.new_string) };
      break;
    }
    case "Write":
      s.edit = { kind: "write", file, removed: "", added: str(input.content) };
      break;
    case "Bash":
    case "PowerShell":
      if (str(input.command)) s.command = { command: str(input.command), tail: [], status: "running" };
      break;
  }
}

/** `abs` relative to the session's folder, else to the shell's current one, else as it is. */
function relativeTo(abs: string, root: string, cwd: string): string {
  for (const base of [root, cwd]) {
    if (base && abs.startsWith(base + "/")) return abs.slice(base.length + 1);
  }
  return abs;
}

/** A tool finished (or failed): fill in what only exists afterwards. */
export function toolFinished(
  id: string,
  tool: string,
  input: Record<string, unknown>,
  cwd: string,
  extra: { tail?: string[]; failed?: boolean; error?: string },
) {
  const s = sessions.get(id);
  if (!s) return;
  if ((tool === "Bash" || tool === "PowerShell") && s.command) {
    s.command.status = extra.failed ? "failed" : "ok";
    s.command.tail = extra.tail ?? (extra.error ? [extra.error.split("\n")[0].slice(0, 160)] : []);
    State.notify();
  } else if (tool === "Edit" && s.edit?.kind === "edit" && !extra.failed && s.edit.added) {
    const edit = s.edit;
    const path = str(input.file_path);
    // Read from inside the session's folder; the shell's folder only if the file is not in it.
    const inRoot = s.root && path.startsWith(s.root + "/");
    void Bridge.fileSnippet(inRoot ? s.root : cwd, path, edit.added, 3).then((snip) => {
      // Only if it is still the edit this answer belongs to.
      if (snip && sessions.get(id)?.edit === edit) {
        edit.snippet = snip;
        State.notify();
      }
    });
  }
}

// ── Rendering ───────────────────────────────────────────────────────────────

const TOKEN =
  /(\/\/.*|^\s*#.*)|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`[^`]*`)|\b(\d+(?:\.\d+)?)\b|\b(const|let|var|function|return|import|export|from|if|else|for|while|class|new|async|await|def|fn|pub|use|type|interface|struct|impl|enum|match|in|of|true|false|null|None)\b|\b([A-Z][A-Za-z0-9_]*)\b|\b([a-z_][A-Za-z0-9_]*)(?=\()/g;

/** One line of code as coloured spans (comment, string, number, keyword). */
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

interface Row {
  kind: "ctx" | "add" | "del";
  n: number | null;
  text: string;
}

const lines = (text: string): string[] => text.replace(/\n$/, "").split("\n");

/** The rows of the editor pane for one edit, in file order. */
function codeRows(e: EditShown): Row[] {
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
    if (i === snip.at) {
      removed.forEach((r, k) => rows.push({ kind: "del", n: snip.start + snip.at + k, text: r }));
    }
    const inBlock = i >= snip.at && i < snip.at + snip.len;
    rows.push({ kind: inBlock ? "add" : "ctx", n: snip.start + i, text });
  });
  return rows;
}

/** Keeps the changed rows and as much context as fits, dropping the far context first. */
function fit(rows: Row[], max: number): Row[] {
  let from = 0;
  let to = rows.length;
  while (to - from > max) {
    if (rows[from].kind === "ctx") from++;
    else if (rows[to - 1].kind === "ctx") to--;
    else to--; // only changed rows left: keep the start of the change
  }
  return rows.slice(from, to);
}

const CHIPS: Record<string, [string, string]> = {
  ts: ["TS", "#3b82f6"], tsx: ["TS", "#3b82f6"], js: ["JS", "#eab308"], jsx: ["JS", "#eab308"],
  py: ["PY", "#38bdf8"], rs: ["RS", "#f97316"], go: ["GO", "#22d3ee"], md: ["MD", "#9ca3af"],
  json: ["{}", "#a3a3a3"], css: ["CS", "#a78bfa"], html: ["<>", "#fb923c"], sh: ["SH", "#86efac"],
  yml: ["YM", "#f472b6"], yaml: ["YM", "#f472b6"], toml: ["TM", "#fbbf24"],
};

function tab(e: EditShown | undefined): HTMLElement {
  if (!e) return h("div", { class: "ed-tab" }, h("span", { class: "ed-name", text: "terminal" }));
  const name = e.file.split("/").pop() || e.file;
  const dir = e.file;
  const [label, color] = CHIPS[(name.split(".").pop() ?? "").toLowerCase()] ?? ["·", "#6b7079"];
  const chip = h("span", { class: "ed-chip", text: label });
  chip.style.background = `${color}2e`;
  chip.style.color = color;
  return h(
    "div",
    { class: "ed-tab" },
    h("span", { class: "ed-file" }, chip, h("span", { class: "ed-name", text: name }), h("span", { class: "ed-dot", text: "●" })),
    h("span", { class: "ed-dir", text: dir }),
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
  const box = h("div", { class: "term" }, h(
    "div",
    { class: "term-line cmd" },
    h("span", { class: "prompt", text: "$" }),
    h("span", { class: "term-cmd", text: c.command.replace(/\s+/g, " ") }),
    c.status === "running" ? h("span", { class: "term-run", text: "…" }) : null,
  ));
  const tail = c.tail.slice(-2);
  for (const l of tail) box.append(tailLine(l));
  if (c.status === "failed" && tail.length === 0) box.append(h("div", { class: "term-line bad", text: "✗ failed" }));
  return box;
}

const DONE = { en: "Done", de: "Fertig", fr: "Terminé" };

const PHASES: { id: Phase; label: string }[] = [
  { id: "read", label: "Read" },
  { id: "edit", label: "Edit" },
  { id: "bash", label: "Bash" },
];

const GLYPHS: Record<Phase, "fileLines" | "pen" | "terminal"> = { read: "fileLines", edit: "pen", bash: "terminal" };

function phaseIcon(state: "done" | "active" | "todo", phase: Phase): HTMLElement {
  if (state === "done") return h("span", { class: "ph-icon ok" }, fa("circleCheck", 16));
  if (state === "active") return h("span", { class: "ph-icon spin" }, fa("circleNotch", 16));
  return h("span", { class: "ph-icon todo" }, fa(GLYPHS[phase], 9));
}

function phaseList(s: SessionData): HTMLElement {
  const doneLabel = localized(DONE);
  const list = h("div", { class: "phases" });
  for (const { id, label } of PHASES) {
    const active = !s.finished && s.current === id;
    const state = active ? "active" : s.seen.includes(id) ? "done" : "todo";
    list.append(h(
      "div",
      { class: `phase ${state}` },
      phaseIcon(state, id),
      h("span", { text: label }),
    ));
  }
  list.append(h(
    "div",
    { class: `phase ${s.finished ? "done" : "todo"}` },
    h("span", { class: s.finished ? "ph-icon ok" : "ph-icon done-todo" }, fa("circleCheck", 16)),
    h("span", { text: doneLabel }),
  ));
  return list;
}

const CODE_ROWS = 11;

export function buildSession(actions: ViewActions): ViewHost {
  const left = h("div", { class: "sess-left" });
  const editor = h("div", { class: "editor" });
  const el = h("div", { class: "view" }, h("div", { class: "card" }, h("div", { class: "sess" }, left, editor)));
  let key = "";

  return {
    el,
    sync() {
      const s = active();
      if (!s) return;
      const next = JSON.stringify(s);
      if (next === key) return;
      key = next;

      clear(left);
      left.append(
        h("div", { class: "sess-name" }, dot(State.claudeTask?.color ?? "#ffffff", 7), h("span", { text: s.project })),
        h("div", { class: "sess-tool" },
          h("span", { text: "Claude Code" }),
          h("button", { class: "sess-back", title: "Back", onclick: () => actions.setView("overview") }, fa("compress", 11)),
        ),
        phaseList(s),
      );

      clear(editor);
      editor.append(tab(s.edit));
      const rows = s.edit ? fit(codeRows(s.edit), s.command ? CODE_ROWS - 3 : CODE_ROWS) : [];
      if (rows.length) editor.append(h("div", { class: "ed-code" }, ...rows.map(codeRow)));
      if (s.command) editor.append(terminal(s.command));
    },
  };
}
