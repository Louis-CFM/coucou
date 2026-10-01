import type {
  AgentEvent,
  AgentEventKind,
  AgentToolInfo,
  JsonValue,
} from "../../core/ai/domain.ts";

export interface ClaudeHookPayload {
  hook_event_name?: string;
  request_id?: string;
  session_id?: string;
  cwd?: string;
  message?: string;
  prompt?: string;
  tool_name?: string;
  tool_input?: Record<string, unknown>;
  /** Optional third-party agent tag: lowercase, digits and hyphens, ≤ 24 chars. */
  coucou_agent?: string;
}

export interface ClaudeHookTranslation {
  event: AgentEvent;
  projectName: string;
  cwd: string;
}

const PROJECT_ALIASES: Record<string, string> = {
  "notch-buddy": "Notch Buddy",
  notchbuddy: "Notch Buddy",
  notch_buddy: "Notch Buddy",
};

const TOOL_LABELS: Record<string, string> = {
  Bash: "Exécute", Read: "Lit", Write: "Écrit", Edit: "Modifie",
  Glob: "Cherche", Grep: "Recherche", WebSearch: "Recherche web",
  WebFetch: "Récupère", TodoWrite: "Tâches", Task: "Agent",
  LS: "Liste", MultiEdit: "Modifie", NotebookEdit: "Notebook",
  PowerShell: "Exécute",
};

const APPROVAL_FIELDS = [
  "command", "file_path", "path", "url", "query", "pattern", "prompt",
] as const;

function lastPathComponent(path: string): string {
  const cleaned = path.replace(/[\\/]+$/, "");
  const index = Math.max(cleaned.lastIndexOf("\\"), cleaned.lastIndexOf("/"));
  return index >= 0 ? cleaned.slice(index + 1) : cleaned;
}

function aliasProjectName(name: string): string {
  return PROJECT_ALIASES[name.toLowerCase()] ?? name;
}

function stringField(input: Record<string, unknown>, key: string): string | undefined {
  const value = input[key];
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function stepLabel(tool: string, input: Record<string, unknown>): string {
  const label = TOOL_LABELS[tool] ?? tool;
  const command = stringField(input, "command");
  if (command) return `${label} · ${command.slice(0, 40)}`;
  const path = stringField(input, "path");
  if (path) return `${label} · ${lastPathComponent(path)}`;
  const file = stringField(input, "file_path");
  if (file) return `${label} · ${lastPathComponent(file)}`;
  const query = stringField(input, "query");
  if (query) return `${label} · ${query.slice(0, 40)}`;
  return label;
}

function approvalTarget(tool: string, input: Record<string, unknown>): string {
  for (const field of APPROVAL_FIELDS) {
    const value = stringField(input, field);
    if (value) return `${tool} · ${value.trim()}`;
  }
  return tool;
}

function asJsonRecord(input: Record<string, unknown>): Record<string, JsonValue> {
  const result: Record<string, JsonValue> = {};
  for (const [key, value] of Object.entries(input)) {
    const converted = asJsonValue(value);
    if (converted !== undefined) result[key] = converted;
  }
  return result;
}

function asJsonValue(value: unknown): JsonValue | undefined {
  if (
    value === null
    || typeof value === "string"
    || typeof value === "number"
    || typeof value === "boolean"
  ) return value;
  if (Array.isArray(value)) {
    return value
      .map(asJsonValue)
      .filter((item): item is JsonValue => item !== undefined);
  }
  if (typeof value === "object") {
    return asJsonRecord(value as Record<string, unknown>);
  }
  return undefined;
}

export function translateClaudeHook(
  name: string,
  payload: ClaudeHookPayload,
  timestamp = new Date().toISOString(),
  id = crypto.randomUUID(),
): ClaudeHookTranslation | null {
  const cwd = payload.cwd ?? "";
  const rawProjectName = lastPathComponent(cwd);
  const projectName = aliasProjectName(rawProjectName || "Session");
  const toolName = payload.tool_name;
  const toolInput = payload.tool_input ?? {};
  const tool: AgentToolInfo | undefined = toolName
    ? { name: toolName, summary: stepLabel(toolName, toolInput), input: asJsonRecord(toolInput) }
    : undefined;

  let kind: AgentEventKind;
  let title: string | undefined;
  let detail: string | undefined;
  let approval: AgentEvent["approval"];

  switch (name) {
    case "SessionStart": kind = "session-started"; title = projectName; break;
    case "UserPromptSubmit":
      kind = "user-prompt";
      title = (payload.prompt ?? payload.message)?.slice(0, 60);
      break;
    case "PreToolUse": kind = "tool-started"; title = tool?.summary; break;
    case "PostToolUse": kind = "tool-completed"; title = tool?.summary; break;
    case "PostToolUseFailure": kind = "tool-failed"; title = "⚠ failed"; break;
    case "Notification": {
      const message = payload.message ?? "";
      const lower = message.toLowerCase();
      kind = lower.includes("rate limit") || lower.includes("limite d")
        ? "rate-limited"
        : message.endsWith("?")
          ? "user-input-requested"
          : "provider-specific:notification";
      title = message || undefined;
      break;
    }
    case "Stop": kind = "completed"; title = payload.message?.slice(0, 60); break;
    case "StopFailure": kind = "error"; title = payload.message?.slice(0, 60); break;
    case "SessionEnd": kind = "session-ended"; break;
    case "SubagentStart": kind = "subagent-started"; title = "+ subagent"; break;
    case "SubagentStop": kind = "subagent-completed"; title = "• subagent done"; break;
    case "PermissionRequest": {
      const name = toolName ?? "Tool";
      detail = approvalTarget(name, toolInput);
      kind = "approval-requested";
      title = name;
      approval = {
        id: payload.request_id || id,
        title: name,
        detail,
        tool,
        choices: ["allow", "allow-for-session", "deny"],
      };
      break;
    }
    default: return null;
  }

  return {
    event: {
      id,
      runtime: "claude-code",
      provider: "anthropic",
      sessionId: payload.session_id ?? "unknown",
      timestamp,
      kind,
      title,
      detail,
      tool,
      approval,
      metadata: { projectName, cwd, nativeEventName: name },
    },
    projectName,
    cwd,
  };
}
