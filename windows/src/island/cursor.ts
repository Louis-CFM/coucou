// Cursor agent hook events → the Cursor pill.
//
// Ordinary work is observational: the relay has already answered allow.
// A request_id is a real permission ask — an unsandboxed command, a delete, or
// a file outside the project — and the tool waits for Allow or Deny.

import { Bridge, onEvent } from "../core/bridge";
import {
  fileName,
  fromHunks,
  hasFilePreview,
  withCommand,
  withOutput,
  type Hunk,
  type LiveChange,
} from "../core/liveChange";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import { approvalTarget, showApproval } from "./hooks";
import type { Island } from "./island";

const CURSOR_ID = "integration_cursor";
/** Same window as Claude Code. After this the relay denies, so the card must not linger. */
const VETO_MS = 110_000;

interface CursorPayload {
  hook_event_name?: string;
  request_id?: string;
  conversation_id?: string;
  session_id?: string;
  cwd?: string;
  workspace_roots?: string[];
  prompt?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown> | string;
  subagent_type?: string;
  status?: string;
  file_path?: string;
  filePath?: string;
  path?: string;
  edits?: unknown;
  command?: string;
  output?: string;
  exit_code?: number;
  exitCode?: number;
}

const PROJECT_ALIASES: Record<string, string> = {
  "notch-buddy": "Notch Buddy",
  notchbuddy: "Notch Buddy",
  notch_buddy: "Notch Buddy",
};

const TOOL_LABELS: Record<string, string> = {
  Shell: "Exécute",
  Bash: "Exécute",
  Read: "Lit",
  Write: "Écrit",
  Edit: "Modifie",
  StrReplace: "Modifie",
  Delete: "Supprime",
  Glob: "Cherche",
  Grep: "Recherche",
  WebSearch: "Recherche web",
  WebFetch: "Récupère",
  TodoWrite: "Tâches",
  Task: "Agent",
  EditNotebook: "Notebook",
};

let activeConversation: string | null = null;
let finishTimer: number | null = null;

function lastPathComponent(p: string): string {
  const cleaned = p.replace(/[\\/]+$/, "");
  const idx = Math.max(cleaned.lastIndexOf("\\"), cleaned.lastIndexOf("/"));
  return idx >= 0 ? cleaned.slice(idx + 1) : cleaned;
}

function task() {
  return State.tasks.find((x) => x.id === CURSOR_ID);
}

function cancelFinish() {
  if (finishTimer != null) {
    window.clearTimeout(finishTimer);
    finishTimer = null;
  }
}

/** A new conversation replaces the previous one on the single pill. */
function noteConversation(id: string | undefined) {
  if (!id || id === activeConversation) return;
  activeConversation = id;
  cancelFinish();
  const t = task();
  if (!t) return;
  t.steps = [];
  t.stepIndex = 0;
  t.pillBadge = null;
  resetEdits();
}

function projectOf(payload: CursorPayload): { name: string; cwd: string } {
  const root = payload.workspace_roots?.find((p) => typeof p === "string" && p.length > 0) ?? "";
  const cwd = payload.cwd || root;
  const raw = lastPathComponent(root || cwd);
  const name = raw ? (PROJECT_ALIASES[raw.toLowerCase()] ?? raw) : "Cursor";
  return { name, cwd };
}

function upsert(payload: CursorPayload) {
  const t = task();
  if (!t) return;
  const { name, cwd } = projectOf(payload);
  t.name = name;
  if (cwd) {
    t.sessionCwd = cwd;
    persistProject(cwd);
  }
}

/** Puts the remembered project back on the pill after a restart. */
export function restoreCursorProject() {
  const saved = State.settings.cursorProject;
  if (!saved) return;
  const t = task();
  if (!t || t.sessionCwd) return;
  t.sessionCwd = saved;
  const raw = lastPathComponent(saved);
  if (raw) t.name = PROJECT_ALIASES[raw.toLowerCase()] ?? raw;
}

/** Opens a folder picker and remembers the choice for the Cursor chat. */
export async function chooseCursorProject() {
  const picked = await Bridge.pickProjectFolder();
  if (!picked) return;
  persistProject(picked);
  const t = task();
  if (!t) return;
  t.sessionCwd = picked;
  const raw = lastPathComponent(picked);
  t.name = raw ? (PROJECT_ALIASES[raw.toLowerCase()] ?? raw) : "Cursor";
  State.notify();
}

function persistProject(cwd: string) {
  if (State.settings.cursorProject === cwd) return;
  State.settings.cursorProject = cwd;
  void Bridge.saveSettings(State.settings);
}

function clearSession() {
  cancelFinish();
  activeConversation = null;
  const t = task();
  if (!t) return;
  t.steps = [];
  t.stepIndex = 0;
  t.pillBadge = null;
  resetEdits();
  const saved = t.sessionCwd ?? State.settings.cursorProject;
  if (saved) {
    t.sessionCwd = saved;
    const raw = lastPathComponent(saved);
    t.name = raw ? (PROJECT_ALIASES[raw.toLowerCase()] ?? raw) : "Cursor";
  } else {
    t.name = "Cursor";
  }
}

function asInput(value: CursorPayload["tool_input"]): Record<string, unknown> {
  if (typeof value === "string") {
    const parsed = asRecord(parseJson(value));
    if (parsed) return parsed;
    return value.length > 0 ? { command: value } : {};
  }
  return asRecord(value) ?? {};
}

const EDIT_TOOLS = new Set([
  "Write",
  "Edit",
  "StrReplace",
  "MultiEdit",
  "Delete",
  "EditNotebook",
  "NotebookEdit",
  "ApplyPatch",
]);

const PATH_KEYS = ["path", "file_path", "filePath", "target_file", "relativeWorkspacePath", "uri"];
const OLD_KEYS = ["old_string", "old_str", "oldString", "old_line", "oldLine"];
const NEW_KEYS = ["new_string", "new_str", "newString", "contents", "content", "new_line", "newLine"];

/** An edit shown before it lands. A deny drops it. */
interface StagedEdit {
  path: string;
  hunks: Hunk[];
}

const staged: StagedEdit[] = [];
/** Last edit that actually landed. A denied proposal reverts to this. */
let committed: LiveChange | null = null;

function resetEdits() {
  staged.length = 0;
  committed = null;
  State.cursorChange = null;
}

function parseJson(text: string): unknown {
  const trimmed = text.trim();
  if (!trimmed.startsWith("{") && !trimmed.startsWith("[")) return null;
  try {
    return JSON.parse(trimmed) as unknown;
  } catch {
    return null;
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
}

function textField(input: Record<string, unknown>, keys: string[]): string {
  for (const key of keys) {
    const value = input[key];
    if (typeof value === "string" && value.length > 0) return value;
  }
  return "";
}

function pathsMatch(a: string, b: string): boolean {
  if (!a || !b) return false;
  const norm = (p: string) => p.replace(/\//g, "\\").replace(/\\+$/, "").toLowerCase();
  const na = norm(a);
  const nb = norm(b);
  return na === nb || na.endsWith(`\\${nb}`) || nb.endsWith(`\\${na}`);
}

function useful(hunks: Hunk[]): boolean {
  return hunks.some((h) => (h.old_string ?? "").length > 0 || (h.new_string ?? "").length > 0);
}

/** `+` / `-` lines, when the hook sends a patch instead of old/new strings. */
function fromUnified(text: string): Hunk | null {
  const oldLines: string[] = [];
  const newLines: string[] = [];
  let saw = false;
  for (const line of text.split("\n")) {
    if (/^(diff |--- |\+\+\+ |@@|\*\*\*)/.test(line)) continue;
    if (line.startsWith("+")) {
      newLines.push(line.slice(1));
      saw = true;
    } else if (line.startsWith("-")) {
      oldLines.push(line.slice(1));
      saw = true;
    } else if (line.startsWith(" ")) {
      oldLines.push(line.slice(1));
      newLines.push(line.slice(1));
    }
  }
  if (!saw) return null;
  return { old_string: oldLines.join("\n"), new_string: newLines.join("\n") };
}

function hunkFromRecord(row: Record<string, unknown>): Hunk | null {
  const oldText = textField(row, OLD_KEYS);
  const newText = textField(row, NEW_KEYS);
  if (oldText || newText) return { old_string: oldText, new_string: newText };
  const patch = textField(row, ["diff", "patch", "unified_diff"]);
  return patch ? fromUnified(patch) : null;
}

function normalizeEdits(raw: unknown): Hunk[] {
  if (typeof raw === "string") {
    const parsed = parseJson(raw);
    if (parsed != null) return normalizeEdits(parsed);
    const uni = fromUnified(raw);
    return uni ? [uni] : [];
  }
  if (Array.isArray(raw)) {
    const hunks: Hunk[] = [];
    for (const item of raw) {
      if (typeof item === "string") {
        const uni = fromUnified(item);
        if (uni) hunks.push(uni);
        continue;
      }
      const row = asRecord(item);
      const hunk = row ? hunkFromRecord(row) : null;
      if (hunk) hunks.push(hunk);
    }
    return hunks;
  }
  const one = asRecord(raw);
  const hunk = one ? hunkFromRecord(one) : null;
  return hunk ? [hunk] : [];
}

function hunksOf(input: Record<string, unknown>): Hunk[] {
  const fromEdits = normalizeEdits(input.edits);
  if (useful(fromEdits)) return fromEdits;
  const direct = hunkFromRecord(input);
  return direct ? [direct] : [];
}

function firstLine(hunks: Hunk[]): string {
  for (const hunk of hunks) {
    const source = hunk.new_string || hunk.old_string || "";
    const line = source.split("\n").map((s) => s.trim()).find((s) => s.length > 0);
    if (line) return line.slice(0, 80);
  }
  return "";
}

/** Puts the edit on screen. Returns up to two lines for the approval card. */
function stageEdit(path: string, hunks: Hunk[]): string[] {
  if (!useful(hunks)) return [];
  const file = path || "file";
  const prev = State.cursorChange;
  const next = fromHunks(file, hunks, prev);
  // fromHunks returns the previous change when the hunks carry no lines.
  if (!next || next === prev) return [];
  if (!next.path) next.path = file;
  staged.push({ path: file, hunks });
  if (staged.length > 12) staged.shift();
  State.cursorChange = next;
  return next.preview.slice(0, 2);
}

/** The edit landed. Prefer the hook's hunks, otherwise what preToolUse staged. */
function commitEdit(path: string, eventHunks: Hunk[]) {
  const idx = staged.findIndex((s) => !path || s.path === "file" || pathsMatch(s.path, path));
  const saved = idx >= 0 ? staged.splice(idx, 1)[0] : undefined;
  const hunks = useful(eventHunks) ? eventHunks : saved?.hunks ?? [];
  const file = path || saved?.path || "";
  if (!useful(hunks) || !file) return;
  const base = committed ?? State.cursorChange;
  const next = fromHunks(file, hunks, base);
  if (next && next !== base) {
    if (!next.path) next.path = file;
    State.cursorChange = next;
  }
  committed = State.cursorChange;
}

function revertEdit(path: string) {
  let at = -1;
  for (let i = staged.length - 1; i >= 0; i--) {
    if (!path || staged[i].path === "file" || pathsMatch(staged[i].path, path)) {
      at = i;
      break;
    }
  }
  if (at < 0) return;
  staged.splice(at, 1);
  const shown = State.cursorChange?.path ?? "";
  if (!path || shown === "file" || pathsMatch(shown, path)) State.cursorChange = committed;
}

/** The snippet only exists in the expanded overview. Open it when nobody is approving. */
function showSnippet(island: Island, focused: boolean) {
  if (!hasFilePreview(State.cursorChange)) return;
  if (State.pendingApproval || State.view === "approval") return;
  if (!focused) {
    if (State.mode === "hidden") island.reveal();
    return;
  }
  if (State.view === "diff") return;
  if (State.mode !== "expanded" || State.view !== "overview") island.setView("overview");
}

function rememberCommand(command: string) {
  const trimmed = command.trim();
  if (!trimmed) return;
  State.cursorChange = withCommand(State.cursorChange, trimmed);
}

function rememberOutput(command: string, output: string, exitCode: number | null) {
  State.cursorChange = withOutput(State.cursorChange, command, output, exitCode);
}

function stepLabel(tool: string, input: Record<string, unknown>): string {
  const label = TOOL_LABELS[tool] ?? tool;
  const str = (k: string) => (typeof input[k] === "string" ? (input[k] as string) : null);
  const cmd = str("command");
  if (cmd) return `${label} · ${cmd.slice(0, 40)}`;
  const path = str("path") ?? str("file_path") ?? str("target_file");
  if (path) return `${label} · ${lastPathComponent(path)}`;
  const query = str("query") ?? str("pattern");
  if (query) return `${label} · ${query.slice(0, 40)}`;
  return label;
}

export function registerCursorHandlers(island: Island) {
  void onEvent<CursorPayload>("cursor-hook", (payload) => handle(island, payload));
}

function handle(island: Island, payload: CursorPayload) {
  if (State.paused) {
    // A paused island cannot show the card. Decline so the relay denies: the
    // tool must not run with nobody watching.
    if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
    return;
  }

  const name = payload.hook_event_name ?? "";
  const focused = State.focusId === CURSOR_ID;
  noteConversation(payload.conversation_id ?? payload.session_id);

  const surface = (view: Parameters<Island["alert"]>[0], isAlert: boolean) => {
    if (State.mode === "expanded") {
      if (isAlert) island.setView(view);
    } else if (isAlert) {
      island.alert(view);
    } else if (State.mode === "hidden") {
      island.reveal();
    }
  };

  switch (name) {
    case "sessionStart":
      upsert(payload);
      surface("overview", false);
      Sound.play("work");
      break;

    case "beforeSubmitPrompt": {
      cancelFinish();
      upsert(payload);
      resetEdits();
      if (focused && State.view === "diff") island.setView("overview");
      State.updateTask(CURSOR_ID, "thinking");
      if (payload.prompt) State.appendStep(CURSOR_ID, payload.prompt.slice(0, 60));
      surface("overview", false);
      break;
    }

    case "preToolUse": {
      cancelFinish();
      upsert(payload);
      const tool = payload.tool_name ?? "Tool";
      const input = asInput(payload.tool_input);
      State.appendStep(CURSOR_ID, stepLabel(tool, input));
      const path = textField(input, PATH_KEYS);
      const hunks = hunksOf(input);
      const editing = EDIT_TOOLS.has(tool) || useful(hunks);
      const preview = editing ? stageEdit(path, hunks) : [];
      const requestId = payload.request_id ?? "";
      if (requestId) {
        const line = firstLine(hunks);
        const shown = showApproval(island, {
          requestId,
          sessionId: payload.conversation_id ?? payload.session_id ?? "",
          tool,
          command: line && path ? `${fileName(path)} · ${line}` : approvalTarget(tool, input),
          taskId: CURSOR_ID,
          file: preview.length > 0 ? fileName(path || "file") : undefined,
          preview: preview.length > 0 ? preview : undefined,
        }, { clearAfterMs: VETO_MS, badgeIfUnfocused: false });
        if (!shown) {
          // The card never appeared, so the proposal must not linger.
          if (preview.length > 0) revertEdit(path);
          State.updateTask(CURSOR_ID, "working");
          surface("overview", false);
        }
        break;
      }
      if (!editing && (tool === "Shell" || tool === "Bash")) {
        const command = textField(input, ["command"]);
        if (command) rememberCommand(command);
      }
      State.updateTask(CURSOR_ID, "working");
      if (preview.length > 0) showSnippet(island, focused);
      else surface("overview", false);
      break;
    }

    case "beforeShellExecution": {
      cancelFinish();
      upsert(payload);
      const command = payload.command ?? "";
      const input = command ? { command } : {};
      if (command) State.appendStep(CURSOR_ID, stepLabel("Shell", input));
      const requestId = payload.request_id ?? "";
      if (requestId) {
        const shown = showApproval(island, {
          requestId,
          sessionId: payload.conversation_id ?? payload.session_id ?? "",
          tool: "Shell",
          command: approvalTarget("Shell", input),
          taskId: CURSOR_ID,
        }, { clearAfterMs: VETO_MS, badgeIfUnfocused: false });
        if (!shown) {
          State.updateTask(CURSOR_ID, "working");
          surface("overview", false);
        }
        break;
      }
      if (command) rememberCommand(command);
      State.updateTask(CURSOR_ID, "working");
      surface("overview", false);
      break;
    }

    case "afterFileEdit": {
      cancelFinish();
      upsert(payload);
      const path = payload.file_path || payload.filePath || payload.path || "";
      commitEdit(path, normalizeEdits(payload.edits));
      if (path) {
        const label = `Modifie · ${fileName(path)}`;
        if (task()?.steps.at(-1) !== label) State.appendStep(CURSOR_ID, label);
      }
      State.updateTask(CURSOR_ID, "working");
      if (hasFilePreview(State.cursorChange)) showSnippet(island, focused);
      else surface("overview", false);
      break;
    }

    case "afterShellExecution": {
      const command = payload.command ?? "";
      rememberOutput(command, payload.output ?? "", payload.exit_code ?? payload.exitCode ?? null);
      break;
    }

    case "postToolUseFailure":
      if (EDIT_TOOLS.has(payload.tool_name ?? "")) {
        revertEdit(textField(asInput(payload.tool_input), PATH_KEYS));
      }
      State.updateTask(CURSOR_ID, "working");
      State.appendStep(CURSOR_ID, "⚠ failed");
      break;

    case "subagentStart": {
      const kind = payload.subagent_type?.trim();
      State.appendStep(CURSOR_ID, kind ? `+ ${kind}` : "+ subagent");
      break;
    }

    case "subagentStop":
      State.appendStep(CURSOR_ID, "• subagent done");
      break;

    case "stop": {
      const status = payload.status ?? "completed";
      if (status === "aborted") {
        cancelFinish();
        State.updateTask(CURSOR_ID, "idle");
        State.setPillBadge(CURSOR_ID, null);
        break;
      }
      if (status === "error") {
        cancelFinish();
        State.updateTask(CURSOR_ID, "error");
        Sound.play("error");
        if (focused) surface("error", true);
        else State.setPillBadge(CURSOR_ID, "error");
        break;
      }
      State.updateTask(CURSOR_ID, "finished");
      Sound.play("finish");
      if (focused && hasFilePreview(State.cursorChange)) {
        // The file snippet is the result. The finished card would title itself
        // with the last tool call ("Recherche · windows") and hide the edit.
        if (State.mode !== "expanded") island.reveal();
        else if (State.view !== "overview" && State.view !== "diff") island.setView("overview");
      } else if (focused) {
        surface("finished", true);
      } else {
        State.setPillBadge(CURSOR_ID, "finished");
      }
      cancelFinish();
      finishTimer = window.setTimeout(() => {
        finishTimer = null;
        State.updateTask(CURSOR_ID, "idle");
        State.setPillBadge(CURSOR_ID, null);
      }, 5200);
      break;
    }

    case "sessionEnd":
      State.updateTask(CURSOR_ID, "idle");
      clearSession();
      if (focused && State.view === "diff") island.setView("overview");
      break;

    default:
      break;
  }
  State.notify();
}
