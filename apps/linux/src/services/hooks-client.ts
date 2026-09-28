import type { AppState } from "../core/state.js";
import type { IslandView } from "../core/types.js";
import { logger } from "../core/logger.js";

export interface HookEvent {
  hook_event_name: string;
  session_id?: string;
  cwd?: string;
  term_program?: string;
  bundle_id?: string;
  message?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
}

export interface HookEffects {
  playSound?: string;
  reveal?: boolean;
  expandTo?: IslandView;
  /** Reset integration_claude to idle after delay (ms). */
  scheduleIdleResetMs?: number;
}

const PROJECT_ALIASES: Record<string, string> = {
  "notch-buddy": "Notch Buddy",
  notchbuddy: "Notch Buddy",
  notch_buddy: "Notch Buddy",
};

const TOOL_LABELS: Record<string, string> = {
  Bash: "Runs",
  Read: "Reads",
  Write: "Writes",
  Edit: "Edits",
  Glob: "Finds",
  Grep: "Searches",
  WebSearch: "Web search",
  WebFetch: "Fetches",
  TodoWrite: "Todos",
  Task: "Agent",
  LS: "Lists",
  MultiEdit: "Edits",
  NotebookEdit: "Notebook",
};

const CLAUDE_TASK_ID = "integration_claude";

let activeSessionId: string | null = null;
const idleResetTimers = new Map<string, number>();

function basename(path: string): string {
  const parts = path.replace(/\\/g, "/").split("/");
  return parts[parts.length - 1] || path;
}

function aliasProjectName(name: string): string {
  return PROJECT_ALIASES[name.toLowerCase()] ?? name;
}

function projectNameFromCwd(cwd: string): string {
  const raw = basename(cwd);
  return aliasProjectName(raw || "Session");
}

/** VS Code / Cursor on Linux (Swift macOS build only checks vscode). */
export function isEditorHookSource(termProgram: string, bundleId: string): boolean {
  const term = termProgram.toLowerCase();
  const bundle = bundleId.toLowerCase();
  return (
    term.includes("vscode") ||
    term.includes("cursor") ||
    bundle.includes("vscode") ||
    bundle.includes("cursor")
  );
}

function toolStep(tool: string, input: Record<string, unknown>): string {
  const label = TOOL_LABELS[tool] ?? tool;
  const cmd = input.command;
  if (typeof cmd === "string") {
    return `${label} · ${cmd.slice(0, 40)}`;
  }
  const path = input.path ?? input.file_path;
  if (typeof path === "string") {
    return `${label} · ${basename(path)}`;
  }
  const query = input.query;
  if (typeof query === "string") {
    return `${label} · ${query.slice(0, 40)}`;
  }
  return label;
}

function upsertClaudeTask(state: AppState, projectName: string, cwd: string): void {
  const idx = state.tasks.findIndex((t) => t.id === CLAUDE_TASK_ID);
  if (idx < 0) return;
  const patch: { name: string; sessionCwd?: string } = { name: projectName };
  if (cwd) patch.sessionCwd = cwd;
  state.patchTask(CLAUDE_TASK_ID, patch);
}

function appendStep(state: AppState, id: string, step: string): void {
  const task = state.tasks.find((t) => t.id === id);
  if (!task) return;
  let steps = [...task.steps, step];
  if (steps.length > 20) steps = steps.slice(steps.length - 20);
  state.patchTask(id, {
    steps,
    stepIndex: steps.length - 1,
  });
}

function clearSession(state: AppState): void {
  state.patchTask(CLAUDE_TASK_ID, {
    steps: [],
    stepIndex: 0,
    name: "VS Code",
    pillBadge: undefined,
  });
}

function isAlertView(view: IslandView): boolean {
  return (
    view === "approval" ||
    view === "finished" ||
    view === "error" ||
    view === "confused"
  );
}

function expandIfNeeded(
  state: AppState,
  view: IslandView,
  focused: boolean,
): Pick<HookEffects, "reveal" | "expandTo"> {
  const alert = isAlertView(view);
  if (state.mode === "expanded") {
    if (alert) {
      state.setView(view);
    }
    return {};
  }
  if (alert) {
    return { expandTo: view };
  }
  if (state.mode === "hidden") {
    return { reveal: true };
  }
  if (!focused) {
    return {};
  }
  return {};
}

function scheduleIdleReset(
  state: AppState,
  ms: number,
  effects: HookEffects,
): void {
  const prev = idleResetTimers.get(CLAUDE_TASK_ID);
  if (prev !== undefined) window.clearTimeout(prev);
  const id = window.setTimeout(() => {
    idleResetTimers.delete(CLAUDE_TASK_ID);
    state.updateTask(CLAUDE_TASK_ID, "idle");
    state.setPillBadge(CLAUDE_TASK_ID, undefined);
  }, ms);
  idleResetTimers.set(CLAUDE_TASK_ID, id);
  effects.scheduleIdleResetMs = ms;
}

export function applyHookEvent(state: AppState, event: HookEvent): HookEffects {
  const name = event.hook_event_name;
  const effects: HookEffects = {};

  if (name === "PermissionRequest") {
    const termProgram = event.term_program ?? "";
    const bundleId = event.bundle_id ?? "";
    if (!isEditorHookSource(termProgram, bundleId)) {
      logger.hook(
        `Ignored PermissionRequest from ${termProgram || bundleId}`,
      );
      return effects;
    }

    const sessionId = event.session_id ?? "unknown";
    const cwd = event.cwd ?? "";
    const projectName = projectNameFromCwd(cwd);
    const tool = event.tool_name ?? "Tool";
    let command = tool;
    const input = event.tool_input ?? {};
    if (typeof input.command === "string") {
      command = input.command;
    }

    activeSessionId = sessionId;
    upsertClaudeTask(state, projectName, cwd);
    state.updateTask(CLAUDE_TASK_ID, "approval");
    state.pendingApproval = { sessionId, tool, command };
    state.isPinned = true;
    effects.playSound = "approval";

    const focused = state.focusId === CLAUDE_TASK_ID;
    if (focused) {
      Object.assign(effects, expandIfNeeded(state, "approval", focused));
    } else {
      state.setPillBadge(CLAUDE_TASK_ID, "approval");
    }
    return effects;
  }

  const termProgram = event.term_program ?? "";
  const bundleId = event.bundle_id ?? "";
  if (!isEditorHookSource(termProgram, bundleId)) {
    const cwd = event.cwd ?? "";
    const projectName = projectNameFromCwd(cwd);
    logger.hook(
      `Ignored ${name} from ${termProgram || bundleId} (${projectName})`,
    );
    return effects;
  }

  const sessionId = event.session_id ?? "unknown";
  const cwd = event.cwd ?? "";
  const projectName = projectNameFromCwd(cwd);
  const focused = state.focusId === CLAUDE_TASK_ID;

  switch (name) {
    case "SessionStart":
      activeSessionId = sessionId;
      upsertClaudeTask(state, projectName, cwd);
      logger.hook(`SessionStart ${projectName} (${sessionId.slice(0, 8)})`);
      if (state.isPresent) {
        Object.assign(effects, expandIfNeeded(state, "overview", focused));
      }
      effects.playSound = "work";
      break;

    case "UserPromptSubmit":
      activeSessionId = sessionId;
      upsertClaudeTask(state, projectName, cwd);
      state.updateTask(CLAUDE_TASK_ID, "thinking");
      if (event.message) {
        appendStep(state, CLAUDE_TASK_ID, event.message.slice(0, 60));
      }
      if (state.isPresent) {
        Object.assign(effects, expandIfNeeded(state, "overview", focused));
      }
      break;

    case "PreToolUse":
      activeSessionId = sessionId;
      upsertClaudeTask(state, projectName, cwd);
      state.updateTask(CLAUDE_TASK_ID, "working");
      appendStep(
        state,
        CLAUDE_TASK_ID,
        toolStep(event.tool_name ?? "Tool", event.tool_input ?? {}),
      );
      break;

    case "PostToolUse":
      state.updateTask(CLAUDE_TASK_ID, "working");
      break;

    case "PostToolUseFailure":
      state.updateTask(CLAUDE_TASK_ID, "working");
      appendStep(state, CLAUDE_TASK_ID, "⚠ failed");
      break;

    case "Notification": {
      const message = event.message ?? "";
      const lower = message.toLowerCase();
      if (lower.includes("rate limit") || lower.includes("limite d")) {
        state.updateTask(CLAUDE_TASK_ID, "ratelimit");
        effects.playSound = "rate";
      } else if (message.endsWith("?")) {
        state.updateTask(CLAUDE_TASK_ID, "question");
        appendStep(state, CLAUDE_TASK_ID, message);
      }
      break;
    }

    case "Stop":
      state.updateTask(CLAUDE_TASK_ID, "finished");
      if (event.message) {
        appendStep(state, CLAUDE_TASK_ID, event.message.slice(0, 60));
      }
      effects.playSound = "finish";
      if (focused) {
        Object.assign(effects, expandIfNeeded(state, "finished", focused));
      } else {
        state.setPillBadge(CLAUDE_TASK_ID, "finished");
      }
      scheduleIdleReset(state, 5200, effects);
      break;

    case "StopFailure":
      state.updateTask(CLAUDE_TASK_ID, "error");
      effects.playSound = "error";
      if (focused) {
        Object.assign(effects, expandIfNeeded(state, "error", focused));
      } else {
        state.setPillBadge(CLAUDE_TASK_ID, "error");
      }
      break;

    case "SessionEnd":
      activeSessionId = null;
      state.updateTask(CLAUDE_TASK_ID, "idle");
      clearSession(state);
      break;

    case "SubagentStart":
      appendStep(state, CLAUDE_TASK_ID, "+ subagent");
      break;

    case "SubagentStop":
      appendStep(state, CLAUDE_TASK_ID, "• subagent done");
      break;

    default:
      break;
  }

  return effects;
}

export function getActiveHookSessionId(): string | null {
  return activeSessionId;
}

export function clearHookIdleResetTimer(): void {
  const id = idleResetTimers.get(CLAUDE_TASK_ID);
  if (id !== undefined) {
    window.clearTimeout(id);
    idleResetTimers.delete(CLAUDE_TASK_ID);
  }
}
