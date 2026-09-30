// Claude Code hook events → island state.
// Port of HookServer.processEvent / processPermissionRequest from the macOS app.
// Difference from macOS: no terminal filter. On Windows the hook fires from any
// terminal (Windows Terminal, VS Code, PowerShell…) and all of them are handled.

import { Bridge, onEvent } from "../core/bridge";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import type { Island } from "./island";

const CLAUDE_ID = "integration_claude";
const CODEX_ID = "integration_codex";

/** Clears the approval card if no decision was made before the hook gave up. */
let pendingTimeout: number | null = null;

interface HookPayload {
  hook_event_name?: string;
  request_id?: string;
  session_id?: string;
  cwd?: string;
  message?: string;
  /** UserPromptSubmit carries `prompt`; `message` belongs to Notification/Stop. */
  prompt?: string;
  /** Codex sends the turn's last message under this name. */
  last_assistant_message?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
  /** Written by the relay: "claude" (or absent) / "codex". */
  coucou_agent?: string;
  /** Codex sends `source` on SessionStart; "compact" arrives mid-turn. */
  source?: string;
  /** Claude and Codex both report the subagent type. */
  agent_type?: string;
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

/** Collapses newlines so a multi-line command stays one ticker row. */
function oneLine(text: string, limit = 60): string {
  const collapsed = text.split(/\s+/).filter(Boolean).join(" ");
  return collapsed.length > limit ? collapsed.slice(0, limit) + "…" : collapsed;
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
  // Codex's own tools, where Claude has Task / TodoWrite.
  apply_patch: "Modifie",
  update_plan: "Tâches",
  spawn_agent: "Agent",
};

/**
 * Verb for a shell command. Codex reads, searches and tests through the shell
 * instead of using Claude's Read/Grep tools, so the verb comes from the command —
 * on Windows those commands are the cmd/PowerShell ones.
 */
function bashVerb(command: string): string {
  const first = command.trim().split(/\s+/)[0] ?? "";
  const readers = ["cat", "bat", "head", "tail", "less", "more", "nl", "type", "Get-Content"];
  if (readers.includes(first)) return "Lit";
  const searchers = ["rg", "grep", "find", "fd", "ls", "tree", "wc", "dir",
                     "findstr", "where", "Select-String", "Get-ChildItem"];
  if (searchers.includes(first)) return "Cherche";
  const runners = ["unittest", "pytest", "vitest", "jest", "npm test", "npm run test",
                   "cargo test", "go test", "dotnet test", "ctest"];
  if (runners.some((r) => command.includes(r))) return "Teste";
  return "Exécute";
}

function stepLabel(tool: string, input: Record<string, unknown>): string {
  let label = TOOL_LABELS[tool] ?? tool;
  // Codex MCP tools arrive as mcp__server__tool — show "server · tool".
  if (tool.startsWith("mcp__")) {
    const parts = tool.slice(5).split("__");
    label = parts.length >= 2 ? `${parts[0]} · ${parts.slice(1).join("__")}` : tool.slice(5);
  }
  const str = (k: string) => (typeof input[k] === "string" ? (input[k] as string) : null);
  const cmd = str("command");
  if (cmd) {
    // Codex sends the whole patch for apply_patch: show the first file it touches.
    if (tool === "apply_patch") {
      for (const line of cmd.split("\n")) {
        for (const prefix of ["*** Update File: ", "*** Add File: ", "*** Delete File: "]) {
          if (line.startsWith(prefix)) {
            return `${label} · ${lastPathComponent(line.slice(prefix.length))}`;
          }
        }
      }
      return label;
    }
    // Codex reads, searches and tests through the shell: take the verb from the command.
    const verb = tool === "Bash" || tool === "PowerShell" ? bashVerb(cmd) : label;
    return `${verb} · ${oneLine(cmd, 120)}`;
  }
  const path = str("path");
  if (path) return `${label} · ${lastPathComponent(path)}`;
  const file = str("file_path");
  if (file) return `${label} · ${lastPathComponent(file)}`;
  const query = str("query");
  if (query) return `${label} · ${oneLine(query, 120)}`;
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

function upsert(id: string, projectName: string, cwd: string) {
  const t = State.tasks.find((x) => x.id === id);
  if (!t) return;
  t.name = projectName;
  if (cwd) t.sessionCwd = cwd;
}

function clearSession(id: string, isCodex: boolean) {
  const t = State.tasks.find((x) => x.id === id);
  if (!t) return;
  t.steps = [];
  t.stepIndex = 0;
  t.name = isCodex ? "Codex" : "VS Code";
  t.pillBadge = null;
}

function taskState(id: string) {
  return State.tasks.find((x) => x.id === id)?.state;
}

/** "+ subagent (reviewer)" when the payload says which subagent it is. */
function subagentSuffix(payload: HookPayload): string {
  return payload.agent_type ? ` (${oneLine(payload.agent_type, 20)})` : "";
}

export function registerHookHandlers(island: Island) {
  void onEvent<HookPayload>("hook", (payload) => handleHook(island, payload));
}

function handleHook(island: Island, payload: HookPayload) {
  if (State.paused) {
    // Silence here used to cost Claude Code nearly two minutes: the relay waited
    // for a decision from an island that had already decided not to look. Say so,
    // and the terminal takes the question immediately.
    if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
    return;
  }

  const name = payload.hook_event_name ?? "";
  // The relay tags every payload with coucou_agent; absent means Claude Code.
  const isCodex = (payload.coucou_agent ?? "claude") === "codex";
  const taskId = isCodex ? CODEX_ID : CLAUDE_ID;
  const cwd = payload.cwd ?? "";
  const raw = lastPathComponent(cwd);
  const projectName = aliasProjectName(raw || "Session");
  const focused = State.focusId === taskId;

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
      upsert(taskId, projectName, cwd);
      // A real session start clears a pill left behind by a session that died
      // without Stop. Codex also fires SessionStart mid-turn when it compacts,
      // and that one must not interrupt a running turn.
      if (payload.source !== "compact") State.updateTask(taskId, "idle");
      surface("overview", false);
      Sound.play("work");
      break;

    case "UserPromptSubmit": {
      upsert(taskId, projectName, cwd);
      State.updateTask(taskId, "thinking");
      // The field is `prompt`; reading `message` meant this step was always blank.
      const asked = payload.prompt ?? payload.message;
      if (asked) State.appendStep(taskId, oneLine(asked, 120));
      surface("overview", false);
      break;
    }

    case "PreToolUse": {
      upsert(taskId, projectName, cwd);
      State.updateTask(taskId, "working");
      const tool = payload.tool_name ?? "Tool";
      State.appendStep(taskId, stepLabel(tool, payload.tool_input ?? {}));
      surface("overview", false);
      break;
    }

    case "PostToolUse":
      // Codex can deliver a PostToolUse after the turn ended (it arrives when a
      // polled command finishes). A late event must not resurrect a finished pill.
      if (taskState(taskId) === "finished" || taskState(taskId) === "idle") break;
      State.updateTask(taskId, "working");
      break;

    case "PostToolUseFailure":
      if (taskState(taskId) === "finished" || taskState(taskId) === "idle") break;
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
        State.appendStep(taskId, oneLine(message));
      }
      break;
    }

    case "Stop":
      State.updateTask(taskId, "finished");
      // Claude Code sends `message`; Codex sends `last_assistant_message`.
      const said = payload.message ?? payload.last_assistant_message;
      if (said) State.appendStep(taskId, oneLine(said));
      Sound.play("finish");
      if (focused) surface("finished", true);
      else State.setPillBadge(taskId, "finished");
      window.setTimeout(() => {
        State.updateTask(taskId, "idle");
        State.setPillBadge(taskId, null);
      }, 5200);
      break;

    case "StopFailure":
      State.updateTask(taskId, "error");
      Sound.play("error");
      if (focused) surface("error", true);
      else State.setPillBadge(taskId, "error");
      break;

    case "Interrupt":
      // Codex only: the user stopped the turn.
      State.updateTask(taskId, "idle");
      State.appendStep(taskId, "Interrompu");
      break;

    case "SessionEnd":
      State.updateTask(taskId, "idle");
      clearSession(taskId, isCodex);
      break;

    case "SubagentStart":
      State.appendStep(taskId, `+ subagent${subagentSuffix(payload)}`);
      break;

    case "SubagentStop":
      State.appendStep(taskId, `• subagent done${subagentSuffix(payload)}`);
      break;

    case "PermissionRequest": {
      const requestId = payload.request_id ?? "";
      // One card, one request. A second one must never quietly replace the first
      // — that would leave a human staring at request B while request A waits for
      // a decision nobody can give. Hand it straight back to the terminal.
      if (State.pendingApproval && State.pendingApproval.requestId !== requestId) {
        if (requestId) void Bridge.approvalDecline(requestId);
        break;
      }
      upsert(taskId, projectName, cwd);
      if (pendingTimeout != null) window.clearTimeout(pendingTimeout);
      const tool = payload.tool_name ?? "Tool";
      const input = payload.tool_input ?? {};
      State.pendingApproval = {
        requestId,
        sessionId: payload.session_id ?? "",
        tool,
        command: approvalTarget(tool, input),
      };
      // The relay's short ack window closes in 800 ms; everything below this
      // line is synchronous, so the card really is up by the time it lands.
      if (requestId) void Bridge.approvalAck(requestId);
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
      // Coucou answers within 108 s or not at all; after that the terminal has
      // taken over and the card would be lying.
      pendingTimeout = window.setTimeout(() => {
        pendingTimeout = null;
        if (!State.pendingApproval) return;
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
