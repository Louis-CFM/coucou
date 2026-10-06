// Local coding-agent hook events → independent sessions and approval ownership.
import { Bridge, onEvent, type HookAgent } from "../core/bridge";
import type { BotStateName } from "../core/layout";
import { Sound } from "../core/sound";
import { State, type ApprovalInfo } from "../core/state";
import type { Island } from "./island";

export interface HookPayload {
  coucou_agent?: string;
  hook_event_name?: string;
  request_id?: string;
  session_id?: string;
  turn_id?: string;
  cwd?: string;
  message?: string;
  prompt?: string;
  tool_name?: string;
  tool_input?: unknown;
  /** Original argument JSON preserves large numbers and every displayed byte. */
  coucou_tool_input_json?: string;
  permission_mode?: string;
}

const TASK_IDS = { claude: "integration_claude", codex: "integration_codex" } as const;
const NAMES = { claude: "VS Code", codex: "Codex" } as const;
/** Preserve the upstream tag contract; Codex has its own first-class provider. */
function validateAgent(raw: string | undefined): string {
  return typeof raw === "string" && /^[a-z0-9-]{1,24}$/.test(raw) ? raw : "claude";
}
function isExternalAgent(agent: string): boolean {
  return agent !== "claude" && agent !== "codex";
}
function taskIdFor(agent: string): string {
  return agent === "claude" || agent === "codex" ? TASK_IDS[agent] : `agent_${agent}`;
}
function nameFor(agent: string): string {
  return agent === "claude" || agent === "codex" ? NAMES[agent] : agent;
}
const FALLBACK_COLORS = ["#22C55E", "#EAB308", "#60A5FA", "#E879F9"];
function agentColor(name: string): string {
  let hash = 0;
  for (let i = 0; i < name.length; i++) hash = (Math.imul(31, hash) + name.charCodeAt(i)) | 0;
  return FALLBACK_COLORS[Math.abs(hash) % FALLBACK_COLORS.length];
}
const PROJECT_ALIASES: Record<string, string> = {
  "notch-buddy": "Notch Buddy", notchbuddy: "Notch Buddy", notch_buddy: "Notch Buddy",
};
function lastPathComponent(path: string): string {
  return path.replace(/[\\/]+$/, "").split(/[\\/]/).at(-1) ?? "";
}
const TOOL_LABELS: Record<string, string> = {
  Bash: "Exécute", Read: "Lit", Write: "Écrit", Edit: "Modifie", Glob: "Cherche",
  Grep: "Recherche", WebSearch: "Recherche web", WebFetch: "Récupère", TodoWrite: "Tâches",
  Task: "Agent", LS: "Liste", MultiEdit: "Modifie", NotebookEdit: "Notebook", PowerShell: "Exécute",
};
function inputRecord(input: unknown): Record<string, unknown> {
  return input && typeof input === "object" && !Array.isArray(input)
    ? input as Record<string, unknown> : {};
}
function stepLabel(tool: string, input: unknown): string {
  const label = TOOL_LABELS[tool] ?? tool;
  const record = inputRecord(input);
  const str = (k: string) => typeof record[k] === "string" ? record[k] as string : null;
  const cmd = str("command");
  if (cmd) return `${label} · ${cmd.slice(0, 40)}`;
  const path = str("path") ?? str("file_path");
  if (path) return `${label} · ${lastPathComponent(path)}`;
  const query = str("query");
  return query ? `${label} · ${query.slice(0, 40)}` : label;
}
function approvalTarget(agent: HookAgent, payload: HookPayload): string {
  const tool = payload.tool_name ?? "Tool";
  if (agent === "codex") {
    // Keep exact MCP scalar/array/object arguments; the card scrolls, not truncates.
    const cwd = payload.cwd ? `\nWorking directory: ${payload.cwd}` : "";
    const session = payload.session_id ? `\nSession: ${payload.session_id}` : "";
    const mode = payload.permission_mode ? `\nPermission mode: ${payload.permission_mode}` : "";
    return `${tool}${cwd}${session}${mode}\n${payload.coucou_tool_input_json}`;
  }
  const input = inputRecord(payload.tool_input);
  for (const field of ["command", "file_path", "path", "url", "query", "pattern", "prompt"]) {
    const value = input[field];
    if (typeof value === "string" && value.trim()) return `${tool} · ${value.trim()}`;
  }
  return tool;
}
interface Session {
  agent: string;
  id: string;
  name: string;
  cwd: string | null;
  state: BotStateName;
  steps: string[];
  phase: "active" | "stopped" | "ended";
  generation: number;
  turnId?: string;
  closedTurns: Set<string>;
}
type HookIsland = Pick<Island, "alert" | "setView" | "reveal" | "dropPin">;

/** Timers/session ownership belong to this island, rather than global hook state. */
export function createHookHandlers(island: HookIsland) {
  const sessions = new Map<string, Session>();
  const selected = new Map<string, Session>();
  let pendingTimeout: number | null = null;
  let activeApproval: ApprovalInfo | null = null;
  const append = (session: Session, text: string) => {
    session.steps.push(text);
    if (session.steps.length > 20) session.steps.shift();
  };
  const paint = (session: Session) => {
    if (selected.get(session.agent) !== session) return;
    const task = State.tasks.find((t) => t.id === taskIdFor(session.agent));
    if (!task) return;
    task.name = session.name;
    task.sessionId = session.id;
    task.sessionCwd = session.cwd;
    task.state = session.state;
    task.steps = [...session.steps];
    task.stepIndex = Math.max(0, task.steps.length - 1);
  };
  const clearApproval = (requestId: string, decline = false) => {
    const pending = activeApproval;
    if (!pending || pending.requestId !== requestId) return;
    activeApproval = null;
    if (decline) void Bridge.approvalDecline(requestId);
    if (pendingTimeout != null) window.clearTimeout(pendingTimeout);
    pendingTimeout = null;
    State.pendingApproval = null;
    State.isPinned = false;
    island.dropPin();
    const session = [...sessions.values()].find((s) =>
      taskIdFor(s.agent) === pending.taskId && s.id === pending.sessionId);
    if (session?.state === "approval") {
      session.state = session.phase === "active" ? "working" : "idle";
      paint(session);
    }
    State.setPillBadge(pending.taskId, null);
    if (State.view === "approval") island.setView(State.defaultView());
    State.notify();
  };
  const surface = (agent: string, view: Parameters<Island["alert"]>[0], alert: boolean) => {
    if (alert && State.focusId !== taskIdFor(agent)) return;
    if (State.pendingApproval && view !== "approval") return;
    if (State.mode === "expanded") {
      if (alert) island.setView(view);
    } else if (alert) island.alert(view);
    else if (State.mode === "hidden") island.reveal();
  };
  const handle = (payload: HookPayload) => {
    // A local click clears the shared card before the backend completion event.
    if (activeApproval && !State.pendingApproval) clearApproval(activeApproval.requestId);
    const agent = validateAgent(payload.coucou_agent);
    const external = isExternalAgent(agent);
    if (State.paused || (agent === "codex" && !payload.session_id)) {
      if (payload.request_id) void Bridge.approvalDecline(payload.request_id);
      return;
    }
    const event = payload.hook_event_name ?? "";
    const taskId = taskIdFor(agent);
    const sessionId = payload.session_id ?? "legacy";
    const key = `${agent}:${sessionId}`;
    const requestId = payload.request_id ?? "";
    const isPermission = event === "PermissionRequest";
    if (isPermission) {
      // Generic tags retain activity-only support; their terminal owns approval.
      if (external || !requestId || (agent === "codex" && !payload.coucou_tool_input_json)
        || (State.pendingApproval && State.pendingApproval.requestId !== requestId)) {
        if (requestId) void Bridge.approvalDecline(requestId);
        return;
      }
      // A retry must not extend the lifetime or change the displayed arguments.
      if (State.pendingApproval?.requestId === requestId) return;
    }
    let session = sessions.get(key);
    const startsTurn = event === "SessionStart" || event === "UserPromptSubmit";
    if (session && !startsTurn) {
      const post = event === "PostToolUse" || event === "PostToolUseFailure";
      const lateTurn = payload.turn_id && payload.turn_id === session.turnId;
      const terminal = event === "SessionEnd" || event === "Interrupt" || event === "StopFailure";
      const closedTurn = payload.turn_id && session.closedTurns.has(payload.turn_id);
      const otherTurn = payload.turn_id && session.turnId && payload.turn_id !== session.turnId
        && !["PreToolUse", "PermissionRequest", "SessionEnd"].includes(event);
      if (session.phase === "ended" || (closedTurn && event !== "SessionEnd") || otherTurn
        || (session.phase === "stopped" && (post || (lateTurn && !terminal)))) {
        if (isPermission && requestId) void Bridge.approvalDecline(requestId);
        return;
      }
    }
    if (!session) {
      session = { agent, id: sessionId, name: nameFor(agent), cwd: null,
        state: "idle", steps: [], phase: "active", generation: 0, closedTurns: new Set() };
      sessions.set(key, session);
      if (sessions.size > 256) {
        const old = [...sessions.entries()].find(([, s]) => selected.get(s.agent) !== s);
        if (old) sessions.delete(old[0]);
      }
    }
    if (payload.cwd) {
      session.cwd = payload.cwd;
      const raw = lastPathComponent(payload.cwd);
      if (!external) session.name = (PROJECT_ALIASES[raw.toLowerCase()] ?? raw) || nameFor(agent);
    }
    const pending = State.pendingApproval;
    const ownsApproval = pending?.taskId === taskId && pending.sessionId === sessionId;
    const blockedByApproval = pending?.taskId === taskId && !ownsApproval;
    const foreground = startsTurn || event === "PreToolUse" || isPermission;
    if (external && foreground) State.upsertExternalAgent(taskId, agent, agentColor(agent));
    if ((!selected.has(agent) || foreground) && !blockedByApproval) {
      selected.set(agent, session);
      if (!ownsApproval) State.setPillBadge(taskId, null);
    }
    if (payload.turn_id && session.turnId && payload.turn_id !== session.turnId) {
      session.closedTurns.add(session.turnId);
      if (session.closedTurns.size > 32) session.closedTurns.delete(session.closedTurns.values().next().value!);
    }
    if (startsTurn || event === "PreToolUse") {
      session.phase = "active";
      session.generation++;
      session.turnId = payload.turn_id;
    } else if (payload.turn_id && session.phase === "active") session.turnId = payload.turn_id;

    switch (event) {
      case "SessionStart":
        if (!ownsApproval) session.state = "idle";
        surface(agent, "overview", false);
        Sound.play("work");
        break;
      case "UserPromptSubmit":
        if (!ownsApproval) session.state = "thinking";
        if (agent === "codex") append(session, "Working on your request");
        else if (payload.prompt ?? payload.message) append(session, (payload.prompt ?? payload.message)!.slice(0, 60));
        surface(agent, "overview", false);
        break;
      case "PreToolUse":
        if (!ownsApproval) session.state = "working";
        append(session, agent === "codex" ? payload.tool_name ?? "Tool" : stepLabel(payload.tool_name ?? "Tool", payload.tool_input));
        surface(agent, "overview", false);
        break;
      case "PostToolUse":
      case "PostToolUseFailure":
        if (!ownsApproval) session.state = "working";
        if (event === "PostToolUseFailure") append(session, "⚠ failed");
        break;
      case "Notification": {
        const message = payload.message ?? "";
        if (/rate limit|limite d/i.test(message)) {
          if (!ownsApproval) session.state = "ratelimit";
          Sound.play("rate");
        } else if (message.endsWith("?")) {
          if (!ownsApproval) session.state = "question";
          append(session, agent === "codex" ? "Answer in Codex" : message);
        }
        break;
      }
      case "Stop": {
        if (ownsApproval) clearApproval(pending.requestId, true);
        session.phase = "stopped";
        session.state = "finished";
        const generation = ++session.generation;
        if (agent !== "codex" && payload.message) append(session, payload.message.slice(0, 60));
        if (selected.get(agent) === session) {
          Sound.play("finish");
          if (State.focusId === taskId) surface(agent, "finished", true);
          else State.setPillBadge(taskId, "finished");
        }
        const stopped = session;
        window.setTimeout(() => {
          if (stopped.generation !== generation || stopped.state !== "finished") return;
          stopped.state = "idle";
          if (selected.get(agent) === stopped) {
            if (external) {
              State.removeTask(taskId);
              selected.delete(agent);
              return;
            }
            State.setPillBadge(taskId, null);
            paint(stopped);
            State.notify();
          }
        }, 5200);
        break;
      }
      case "StopFailure":
      case "Interrupt":
      case "SessionEnd":
        if (ownsApproval) clearApproval(pending.requestId, true);
        session.generation++;
        session.phase = event === "SessionEnd" ? "ended" : "stopped";
        session.state = event === "StopFailure" ? "error" : "idle";
        if (event === "Interrupt") append(session, "Interrupted");
        if (event === "SessionEnd") {
          session.name = nameFor(agent);
          session.cwd = null;
          session.steps = [];
        }
        if (selected.get(agent) === session) {
          if (event === "SessionEnd" && external) {
            State.removeTask(taskId);
            selected.delete(agent);
            break;
          }
          State.setPillBadge(taskId, event === "StopFailure" ? "error" : null);
          if (event === "StopFailure") {
            Sound.play("error");
            surface(agent, "error", true);
          }
        }
        break;
      case "SubagentStart": append(session, "+ subagent"); break;
      case "SubagentStop": append(session, "• subagent done"); break;
      case "PermissionRequest":
        // The generic-provider path returned above; narrowing preserves this invariant.
        if (agent !== "claude" && agent !== "codex") return;
        session.state = "approval";
        State.pendingApproval = { requestId, taskId, sessionId,
          tool: payload.tool_name ?? "Tool", command: approvalTarget(agent, payload) };
        activeApproval = State.pendingApproval;
        State.isPinned = true;
        paint(session);
        Sound.play("approval");
        if (State.focusId === taskId) island.alert("approval");
        else {
          State.setPillBadge(taskId, "approval");
          island.reveal();
        }
        void Bridge.approvalAck(requestId);
        pendingTimeout = window.setTimeout(() => clearApproval(requestId, true), 110_000);
        break;
      default: return;
    }
    paint(session);
    State.notify();
  };
  return { handle, approvalEnded: (requestId: string) => clearApproval(requestId) };
}

export function registerHookHandlers(island: Island) {
  const handlers = createHookHandlers(island);
  void onEvent<HookPayload>("hook", handlers.handle);
  void onEvent<{ request_id: string }>("approval-ended", (payload) => handlers.approvalEnded(payload.request_id));
}
