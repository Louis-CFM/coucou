// Claude Code / Codex hook events → island state.
// Port of HookServer.processEvent / processPermissionRequest from the macOS app.
// Difference from macOS: no terminal filter. On Windows the hook fires from any
// terminal (Windows Terminal, VS Code, PowerShell…) and all of them are handled.

import { Bridge, onEvent } from "../core/bridge";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import type { Island } from "./island";

const completionTimers = new Map<string, number>();

/** Clears the approval card if no decision was made before the hook gave up. */
let pendingTimeout: number | null = null;

export interface HookPayload {
  agent_provider?: "claude" | "codex";
  last_assistant_message?: string;
  hook_event_name?: string;
  request_id?: string;
  session_id?: string;
  cwd?: string;
  message?: string;
  /** UserPromptSubmit carries `prompt`; `message` belongs to Notification/Stop. */
  prompt?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
}

const PROJECT_ALIASES: Record<string, string> = {
  "notch-buddy": "Notch Buddy",
  notchbuddy: "Notch Buddy",
  notch_buddy: "Notch Buddy",
};

function aliasProjectName(name: string): string {
  return PROJECT_ALIASES[name.toLowerCase()] ?? name;
}

function lastPathComponent(p: string): string {
  const cleaned = p.replace(/[\\/]+$/, "");
  const idx = Math.max(cleaned.lastIndexOf("\\"), cleaned.lastIndexOf("/"));
  return idx >= 0 ? cleaned.slice(idx + 1) : cleaned;
}

/** frenchStep() — same labels as the macOS app. */
const TOOL_LABELS: Record<string, string> = {
  Bash: "Exécute",
  Read: "Lit",
  Write: "Écrit",
  Edit: "Modifie",
  Glob: "Cherche",
  Grep: "Recherche",
  WebSearch: "Recherche web",
  WebFetch: "Récupère",
  TodoWrite: "Tâches",
  Task: "Agent",
  LS: "Liste",
  MultiEdit: "Modifie",
  NotebookEdit: "Notebook",
  PowerShell: "Exécute",
  apply_patch: "Modifie",
  exec_command: "Exécute",
  spawn_agent: "Agent",
  Agent: "Agent",
};

function stepLabel(tool: string, input: Record<string, unknown>): string {
  const label = TOOL_LABELS[tool] ?? tool;
  const str = (k: string) => (typeof input[k] === "string" ? (input[k] as string) : null);
  const cmd = str("command");
  if (cmd) return `${label} · ${cmd.slice(0, 40)}`;
  const path = str("path");
  if (path) return `${label} · ${lastPathComponent(path)}`;
  const file = str("file_path");
  if (file) return `${label} · ${lastPathComponent(file)}`;
  const query = str("query");
  if (query) return `${label} · ${query.slice(0, 40)}`;
  return label;
}

/**
 * What the Allow button actually authorises. Approving "Write" tells you nothing
 * — approving `Write · C:\…\.env` tells you everything, and the difference is
 * the whole point of approving from the island rather than blind.
 *
 * Ordered by how specific the field is, so an unfamiliar tool still shows
 * whatever identifying string it carries instead of falling back to its name.
 */
const APPROVAL_FIELDS = [
  "command", // Bash, PowerShell
  "file_path", // Write, Edit, MultiEdit, NotebookEdit
  "path", // Read, LS
  "url", // WebFetch
  "query", // WebSearch
  "pattern", // Glob, Grep
  "prompt", // Task
] as const;

function approvalTarget(tool: string, input: Record<string, unknown>): string {
  for (const field of APPROVAL_FIELDS) {
    const value = input[field];
    if (typeof value === "string" && value.trim()) {
      return `${tool} · ${value.trim()}`;
    }
  }
  return tool;
}

function upsert(taskId: string, projectName: string, cwd: string, sessionId?: string) {
  const t = State.tasks.find((x) => x.id === taskId);
  if (!t) return;
  t.name = projectName;
  if (sessionId) t.sessionId = sessionId;
  if (cwd) t.sessionCwd = cwd;
}

function clearSession(taskId: string) {
  const t = State.tasks.find((x) => x.id === taskId);
  if (!t) return;
  t.steps = [];
  t.stepIndex = 0;
  t.name = taskId === "integration_codex" ? "Codex" : "VS Code";
  t.sessionId = undefined;
  t.sessionCwd = null;
  t.pillBadge = null;
}

export async function registerHookHandlers(island: Island) {
  return onEvent<HookPayload>("hook", (payload) => handleHook(island, payload));
}

export function handleHook(island: Island, value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return;
  const payload = value as HookPayload;
  for (const field of ["hook_event_name", "request_id", "session_id", "cwd", "message", "prompt", "tool_name", "last_assistant_message"] as const) {
    if (payload[field] != null && typeof payload[field] !== "string") return;
  }
  if (payload.tool_input != null && (typeof payload.tool_input !== "object" || Array.isArray(payload.tool_input))) return;
  if (payload.agent_provider !== undefined && payload.agent_provider !== "codex" && payload.agent_provider !== "claude") return;
  const taskId = payload.agent_provider === "codex" ? "integration_codex" : "integration_claude";
  if (taskId === "integration_codex" && !State.paused) State.ensureCodexTask();
  const task = State.tasks.find((t) => t.id === taskId);
  if (!task) {
    if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
    return;
  }
  if (State.paused) {
    // Silence here used to cost Claude Code nearly two minutes: the relay waited
    // for a decision from an island that had already decided not to look. Say so,
    // and the terminal takes the question immediately.
    if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
    return;
  }

  const name = payload.hook_event_name ?? "";
  const cwd = payload.cwd ?? "";
  const raw = lastPathComponent(cwd);
  const projectName = aliasProjectName(raw || "Session");
  const focused = State.focusId === taskId;
  const pending = State.pendingApproval;
  const startsSessionActivity = ["SessionStart", "UserPromptSubmit", "PreToolUse"].includes(name);
  if (pending?.taskId === taskId &&
      (startsSessionActivity || !payload.session_id || pending.sessionId === payload.session_id) &&
      ["SessionStart", "SessionEnd", "Interrupt", "Stop", "PreToolUse", "PostToolUse", "UserPromptSubmit"].includes(name)) {
    void Bridge.approvalDecline(pending.requestId);
    if (pendingTimeout != null) window.clearTimeout(pendingTimeout);
    pendingTimeout = null;
    State.pendingApproval = null;
    State.isPinned = false;
    island.dropPin();
    State.setPillBadge(taskId, null);
    if (State.view === "approval") island.setView(State.defaultView());
  }
  if (name === "PermissionRequest" && State.pendingApproval && State.pendingApproval.requestId !== payload.request_id) {
    if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
    return;
  }
  const startsWork = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest"].includes(name);
  if (!startsWork && payload.session_id && task.sessionId && payload.session_id !== task.sessionId) return;
  if (startsWork || name === "SessionEnd" || name === "Interrupt" || name === "Stop") {
    const timer = completionTimers.get(taskId);
    if (timer != null) window.clearTimeout(timer);
    completionTimers.delete(taskId);
  }
  if (startsWork && payload.session_id && task.sessionId !== payload.session_id) clearSession(taskId);

  /** Alerts force the island open; work events only reveal the compact island. */
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
    case "SessionStart":
      upsert(taskId, projectName, cwd, payload.session_id);
      surface("overview", false);
      Sound.play("work");
      break;

    case "UserPromptSubmit": {
      upsert(taskId, projectName, cwd, payload.session_id);
      State.updateTask(taskId, "thinking");
      // The field is `prompt`; reading `message` meant this step was always blank.
      const asked = payload.prompt ?? payload.message;
      if (asked) State.appendStep(taskId, asked.slice(0, 60));
      surface("overview", false);
      break;
    }

    case "PreToolUse": {
      upsert(taskId, projectName, cwd, payload.session_id);
      State.updateTask(taskId, "working");
      const tool = payload.tool_name ?? "Tool";
      State.appendStep(taskId, stepLabel(tool, payload.tool_input ?? {}));
      surface("overview", false);
      break;
    }

    case "PostToolUse":
      State.updateTask(taskId, "working");
      break;

    case "PostToolUseFailure":
      State.updateTask(taskId, "working");
      State.appendStep(taskId, "⚠ failed");
      break;

    case "Notification": {
      const message = payload.message ?? "";
      const lower = message.toLowerCase();
      if (lower.includes("rate limit") || lower.includes("limite d")) {
        State.updateTask(taskId, "ratelimit");
        Sound.play("rate");
      } else if (message.endsWith("?")) {
        State.updateTask(taskId, "question");
        State.appendStep(taskId, message);
      }
      break;
    }

    case "Stop":
      upsert(taskId, projectName, cwd, payload.session_id);
      State.updateTask(taskId, "finished");
      if (payload.last_assistant_message ?? payload.message) State.appendStep(taskId, (payload.last_assistant_message ?? payload.message ?? "").slice(0, 60));
      Sound.play("finish");
      if (focused) surface("finished", true);
      else State.setPillBadge(taskId, "finished");
      completionTimers.set(taskId, window.setTimeout(() => {
        completionTimers.delete(taskId);
        State.updateTask(taskId, "idle");
        State.setPillBadge(taskId, null);
      }, 5200));
      break;

    case "StopFailure":
      State.updateTask(taskId, "error");
      Sound.play("error");
      if (focused) surface("error", true);
      else State.setPillBadge(taskId, "error");
      break;

    case "SessionEnd":
      State.updateTask(taskId, "idle");
      clearSession(taskId);
      break;

    case "Interrupt":
      State.updateTask(taskId, "idle");
      State.appendStep(taskId, "• interrupted");
      State.setPillBadge(taskId, null);
      break;

    case "SubagentStart":
      State.appendStep(taskId, "+ subagent");
      break;

    case "SubagentStop":
      State.appendStep(taskId, "• subagent done");
      break;

    case "PermissionRequest": {
      const requestId = payload.request_id ?? "";
      if (!requestId) break;
      // One card, one request. A second one must never quietly replace the first
      // — that would leave a human staring at request B while request A waits for
      // a decision nobody can give. Hand it straight back to the terminal.
      if (State.pendingApproval && State.pendingApproval.requestId !== requestId) {
        if (requestId) void Bridge.approvalDecline(requestId);
        break;
      }
      upsert(taskId, projectName, cwd, payload.session_id);
      if (pendingTimeout != null) window.clearTimeout(pendingTimeout);
      const tool = payload.tool_name ?? "Tool";
      const input = payload.tool_input ?? {};
      State.pendingApproval = {
        taskId,
        requestId,
        sessionId: payload.session_id ?? "",
        tool,
        command: approvalTarget(tool, input),
      };
      // The relay's short ack window closes in 800 ms; everything below this
      // line is synchronous, so the card really is up by the time it lands.
      State.updateTask(taskId, "approval");
      State.isPinned = true;
      Sound.play("approval");
      if (focused) {
        island.alert("approval");
      } else {
        // Another agent holds the view, so the card would yank it away. The badge
        // is the signal instead — but it has to be on screen for that to mean
        // anything, hence the reveal. We just told the relay a human can act.
        State.setPillBadge(taskId, "approval");
        island.reveal();
      }
      void Bridge.approvalAck(requestId);
      // Coucou answers within 108 s or not at all; after that the terminal has
      // taken over and the card would be lying.
      pendingTimeout = window.setTimeout(() => {
        pendingTimeout = null;
        if (State.pendingApproval?.requestId !== requestId) return;
        State.pendingApproval = null;
        State.isPinned = false;
        island.dropPin();
        State.updateTask(taskId, "working");
        State.setPillBadge(taskId, null);
        if (State.view === "approval") island.setView(State.defaultView());
        State.notify();
      }, 110_000);
      break;
    }

    default:
      break;
  }
  State.notify();
}
