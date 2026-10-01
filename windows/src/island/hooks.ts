// Multi-CLI hook events → island state.
// Port of HookServer.processEvent / processPermissionRequest from the macOS app,
// extended: Claude Code + Gemini CLI + opencode (+ generic CLI) side by side.
// Difference from macOS: no terminal filter. On Windows the hook fires from any
// terminal (Windows Terminal, VS Code, PowerShell…) and all of them are handled.
//
// Routing:
// - source == "claudeCode" (or missing, legacy) → integration_claude pill.
// - source == "geminiCli" → ephemeral cli_gemini_<session> task.
// - source == "opencode"   → ephemeral cli_opencode_<session> task.
// - anything else          → ephemeral cli_<session> task.
// Only Claude PermissionRequest blocks for a decision; Gemini/opencode events
// are fire-and-forget (their CLIs have no compatible blocking approval).

import { Bridge, onEvent } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, type AgentSource } from "../core/state";
import type { Island } from "./island";

const CLAUDE_ID = "integration_claude";

/** Clears the approval card if no decision was made before the hook gave up. */
let pendingTimeout: number | null = null;

interface HookPayload {
  hook_event_name?: string;
  request_id?: string;
  session_id?: string;
  source?: string;
  cwd?: string;
  message?: string;
  /** UserPromptSubmit carries `prompt`; `message` belongs to Notification/Stop. */
  prompt?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
  /** Optional agent tag: lowercase, digits and hyphens, ≤ 24 chars. */
  coucou_agent?: string;
}

/** Same rule as HookServer.validateAgent on macOS. "claude" is reserved. */
function validateAgent(raw: string | undefined): string | null {
  if (!raw || raw.length > 24 || raw === "claude") return null;
  if (!/^[a-z0-9-]+$/.test(raw)) return null;
  return raw;
}

const FALLBACK_COLORS = ["#22C55E", "#EAB308", "#60A5FA", "#E879F9"];

function agentColor(name: string): string {
  let h = 0;
  for (let i = 0; i < name.length; i++) {
    h = (Math.imul(31, h) + name.charCodeAt(i)) | 0;
  }
  return FALLBACK_COLORS[Math.abs(h) % FALLBACK_COLORS.length];
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

/** frenchStep() — same labels as the macOS app, plus Gemini CLI tool names. */
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
  // Gemini CLI
  write_file: "Écrit",
  read_file: "Lit",
  replace: "Modifie",
  run_shell_command: "Exécute",
  web_search: "Recherche web",
  web_fetch: "Récupère",
  glob: "Cherche",
  grep: "Recherche",
  list_directory: "Liste",
  // Antigravity CLI (`agy`, Go binary)
  run_command: "Exécute",
  view_file: "Lit",
  write_file_content: "Écrit",
  edit_file: "Modifie",
  list_files: "Liste",
  search_files: "Recherche",
  // opencode
  "task": "Agent",
  "bash": "Exécute",
};

function stepLabel(tool: string, input: Record<string, unknown>): string {
  const label = TOOL_LABELS[tool] ?? TOOL_LABELS[tool.toLowerCase()] ?? tool;
  const str = (k: string) => (typeof input[k] === "string" ? (input[k] as string) : null);
  const cmd = str("command");
  if (cmd) return `${label} · ${cmd.slice(0, 40)}`;
  const path = str("path") ?? str("absolute_path") ?? str("file") ?? str("filename");
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
  "command", // Bash, PowerShell, run_shell_command
  "file_path", // Write, Edit, MultiEdit, NotebookEdit
  "absolute_path", // Gemini write_file/replace
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

function normalizeSource(raw: string | undefined): AgentSource {
  switch ((raw ?? "").toLowerCase()) {
    case "geminicli":
    case "gemini":
    case "gemini-cli":
      return "geminiCli";
    case "agy":
    case "antigravity":
    case "antigravity-cli":
      return "antigravity";
    case "opencode":
    case "open-code":
      return "opencode";
    case "genericcli":
    case "generic":
    case "cli":
      return "genericCli";
    case "claudecode":
    case "claude":
    case "":
      return "claudeCode";
    default:
      return "genericCli";
  }
}

const SOURCE_META: Record<AgentSource, { prefix: string; color: string; label: string }> = {
  claudeCode: { prefix: "integration_claude", color: "#F5F6F8", label: "Claude" },
  geminiCli: { prefix: "cli_gemini_", color: "#38BDF8", label: "Gemini" },
  antigravity: { prefix: "cli_agy_", color: "#F472B6", label: "agy" },
  opencode: { prefix: "cli_opencode_", color: "#A78BFA", label: "opencode" },
  genericCli: { prefix: "cli_", color: "#22C55E", label: "CLI" },
  media: { prefix: "integration_", color: "#1DB954", label: "Media" },
  n8n: { prefix: "integration_", color: "#F29B38", label: "n8n" },
  // Upstream third-party agents carry their own per-name color (agentColor);
  // this entry only satisfies the Record — resolveTaskId never uses it.
  agent: { prefix: "agent_", color: "#EAB308", label: "Agent" },
};

function shortId(sessionId: string | undefined, cwd: string): string {
  if (sessionId && sessionId !== "unknown") return sessionId.slice(0, 8).replace(/[^a-zA-Z0-9]/g, "");
  // Stable fallback from cwd so a CLI without session_id still gets one task.
  let h = 0;
  for (let i = 0; i < cwd.length; i++) h = (h * 31 + cwd.charCodeAt(i)) >>> 0;
  return h.toString(36).slice(0, 8) || "local";
}

/** Resolve (or create) the task id for this event. Claude stays on the legacy pill. */
function resolveTaskId(source: AgentSource, payload: HookPayload, projectName: string, cwd: string): string {
  if (source === "claudeCode") {
    upsertClaude(projectName, cwd);
    return CLAUDE_ID;
  }
  const meta = SOURCE_META[source];
  const id = `${meta.prefix}${shortId(payload.session_id, cwd)}`;
  const display = `${meta.label} · ${projectName}`;
  State.ensureCliTask(id, display, meta.color, source);
  const t = State.tasks.find((x) => x.id === id);
  if (t && cwd) t.sessionCwd = cwd;
  // Steer focus to the most recently active CLI so Gemini + opencode side by
  // side don't fight silently — last event wins, like the Mac focus rule.
  if (State.focusId !== id && (t?.state === "idle" || State.focusTask?.state === "idle")) {
    State.focusId = id;
  }
  return id;
}

function upsertClaude(projectName: string, cwd: string) {
  const t = State.tasks.find((x) => x.id === CLAUDE_ID);
  if (!t) return;
  t.name = projectName;
  if (cwd) t.sessionCwd = cwd;
}

function clearSession() {
  const t = State.tasks.find((x) => x.id === CLAUDE_ID);
  if (!t) return;
  t.steps = [];
  t.stepIndex = 0;
  t.name = "VS Code";
  t.pillBadge = null;
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
  const source = normalizeSource(payload.source);
  const cwd = payload.cwd ?? "";
  const raw = lastPathComponent(cwd);
  const projectName = aliasProjectName(raw || "Session");

  // Two routing mechanisms, one pill per session:
  // 1. Valid coucou_agent (upstream) → dynamic "agent_<name>" pill.
  // 2. Otherwise our source tag → integration_claude or cli_<source>_<session>.
  // "claude" is reserved; absent/invalid agent + Claude source → Claude pill.
  const validAgent = validateAgent(payload.coucou_agent);
  const isExternalAgent = validAgent !== null;
  const taskId = isExternalAgent
    ? upsertAgentTask(validAgent)
    : resolveTaskId(source, payload, projectName, cwd);
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

  /** Creates the upstream agent_ pill on first event; no-op if present. */
function upsertAgentTask(name: string): string {
  const id = `agent_${name}`;
  State.upsertExternalAgent(id, name, agentColor(name));
  return id;
}

  switch (name) {
    case "SessionStart":
      surface("overview", false);
      Sound.play("work");
      break;

    case "UserPromptSubmit": {
      State.updateTask(taskId, "thinking");
      // The field is `prompt`; reading `message` meant this step was always blank.
      const asked = payload.prompt ?? payload.message;
      if (asked) State.appendStep(taskId, `[${SOURCE_META[source].label}] ${asked.slice(0, 50)}`);
      else State.appendStep(taskId, `[${SOURCE_META[source].label}] prompt`);
      surface("overview", false);
      break;
    }

    case "PreToolUse": {
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
      State.updateTask(taskId, "finished");
      if (payload.message) State.appendStep(taskId, payload.message.slice(0, 60));
      Sound.play("finish");
      if (focused) surface("finished", true);
      else State.setPillBadge(taskId, "finished");
      window.setTimeout(() => {
        if (taskId === CLAUDE_ID) {
          State.updateTask(taskId, "idle");
          State.setPillBadge(taskId, null);
        } else if (isExternalAgent) {
          State.removeTask(taskId);
        } else {
          // Ephemeral CLI tasks disappear after the finished toast, like Mac Stop.
          State.removeCliTask(taskId);
        }
      }, 5200);
      break;

    case "StopFailure":
      State.updateTask(taskId, "error");
      Sound.play("error");
      if (focused) surface("error", true);
      else State.setPillBadge(taskId, "error");
      break;

    case "SessionEnd":
      if (taskId === CLAUDE_ID) {
        State.updateTask(taskId, "idle");
        clearSession();
      } else if (isExternalAgent) {
        State.removeTask(taskId);
      } else {
        State.removeCliTask(taskId);
      }
      break;

    case "SubagentStart":
      State.appendStep(taskId, "+ subagent");
      break;

    case "SubagentStop":
      State.appendStep(taskId, "• subagent done");
      break;

    case "PermissionRequest": {
      // External agent_ pills never get an approval card — it would look like
      // a Claude Code request. Decline immediately so the agent re-asks in
      // its terminal. Other non-Claude sources show activity instead.
      if (isExternalAgent) {
        if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
        break;
      }
      if (source !== "claudeCode") {
        State.updateTask(taskId, "working");
        const tool = payload.tool_name ?? "Tool";
        State.appendStep(taskId, stepLabel(tool, payload.tool_input ?? {}));
        surface("overview", false);
        break;
      }
      const requestId = payload.request_id ?? "";
      // One card, one request. A second one must never quietly replace the first
      // — that would leave a human staring at request B while request A waits for
      // a decision nobody can give. Hand it straight back to the terminal.
      if (State.pendingApproval && State.pendingApproval.requestId !== requestId) {
        if (requestId) void Bridge.approvalDecline(requestId);
        break;
      }
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
