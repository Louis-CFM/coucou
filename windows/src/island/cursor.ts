// Cursor agent hook events → the Cursor pill.
//
// Observational only. The relay already answered allow / continue before this
// runs, so nothing here may try to approve, deny, or hold the agent.

import { Bridge, onEvent } from "../core/bridge";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import type { Island } from "./island";

const CURSOR_ID = "integration_cursor";

interface CursorPayload {
  hook_event_name?: string;
  conversation_id?: string;
  session_id?: string;
  cwd?: string;
  workspace_roots?: string[];
  prompt?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown> | string;
  subagent_type?: string;
  status?: string;
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
  if (typeof value === "string") return { command: value };
  if (value && typeof value === "object") return value;
  return {};
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
  if (State.paused) return;

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
      State.updateTask(CURSOR_ID, "thinking");
      if (payload.prompt) State.appendStep(CURSOR_ID, payload.prompt.slice(0, 60));
      surface("overview", false);
      break;
    }

    case "preToolUse": {
      cancelFinish();
      upsert(payload);
      State.updateTask(CURSOR_ID, "working");
      const tool = payload.tool_name ?? "Tool";
      State.appendStep(CURSOR_ID, stepLabel(tool, asInput(payload.tool_input)));
      surface("overview", false);
      break;
    }

    case "postToolUseFailure":
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
      if (focused) surface("finished", true);
      else State.setPillBadge(CURSOR_ID, "finished");
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
      break;

    default:
      break;
  }
  State.notify();
}
