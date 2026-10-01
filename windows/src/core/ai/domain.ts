export type ProviderId = "anthropic" | "openai" | "google";

export type AgentRuntimeId =
  | "claude-code"
  | "codex"
  | "gemini-cli"
  | "antigravity";

export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

export interface ReasoningOption {
  id: string;
  displayName: string;
  providerValue: string;
}

export interface ModelCapabilities {
  text: boolean;
  vision: boolean;
  attachments: boolean;
  toolCalling: boolean;
  webSearch: boolean;
  reasoning: boolean;
  streaming: boolean;
}

export interface ModelDescriptor {
  id: string;
  provider: ProviderId;
  displayName: string;
  capabilities: ModelCapabilities;
  reasoningOptions: ReasoningOption[];
  contextWindow?: number;
  maxOutputTokens?: number;
  isDeprecated: boolean;
  metadata: Record<string, string>;
}

export interface ProviderCapabilities {
  dynamicModelCatalog: boolean;
  apiKeyAuthentication: boolean;
  accountAuthentication: boolean;
  streaming: boolean;
  toolCalling: boolean;
  webSearch: boolean;
  attachments: boolean;
}

export interface AgentRuntimeCapabilities {
  observeSessions: boolean;
  startSession: boolean;
  resumeSession: boolean;
  interrupt: boolean;
  approvals: boolean;
  userInputRequests: boolean;
  toolEvents: boolean;
  fileChanges: boolean;
  commandEvents: boolean;
  subagents: boolean;
  runtimeModelSelection: boolean;
  runtimeReasoningSelection: boolean;
}

export type AgentSessionState =
  | "starting"
  | "idle"
  | "working"
  | "waiting-for-approval"
  | "waiting-for-user"
  | "completed"
  | "failed"
  | "cancelled"
  | "disconnected";

export type AgentEventKind =
  | "session-started"
  | "session-resumed"
  | "session-ended"
  | "user-prompt"
  | "activity-started"
  | "activity-updated"
  | "activity-completed"
  | "tool-started"
  | "tool-completed"
  | "tool-failed"
  | "command-started"
  | "command-completed"
  | "command-failed"
  | "file-changed"
  | "approval-requested"
  | "approval-resolved"
  | "user-input-requested"
  | "subagent-started"
  | "subagent-completed"
  | "rate-limited"
  | "warning"
  | "error"
  | "cancelled"
  | "completed"
  | `provider-specific:${string}`;

export interface AgentToolInfo {
  name: string;
  summary?: string;
  input: Record<string, JsonValue>;
}

export type ApprovalDecision = "allow" | "allow-for-session" | "deny";

export interface AgentApprovalRequest {
  id: string;
  title: string;
  detail?: string;
  tool?: AgentToolInfo;
  choices: ApprovalDecision[];
}

export interface AgentEvent {
  id: string;
  sequence?: number;
  runtime: AgentRuntimeId;
  provider?: ProviderId;
  sessionId: string;
  timestamp: string;
  kind: AgentEventKind;
  title?: string;
  detail?: string;
  tool?: AgentToolInfo;
  approval?: AgentApprovalRequest;
  metadata: Record<string, JsonValue>;
}

export interface ModelSelection {
  modelId: string;
  reasoningOptionId?: string;
}

export interface AgentActivity {
  id: string;
  title: string;
  detail?: string;
  startedAt: string;
  completedAt?: string;
}

export interface AgentSession {
  id: string;
  runtime: AgentRuntimeId;
  provider?: ProviderId;
  nativeSessionId: string;
  workspace?: string;
  state: AgentSessionState;
  model?: ModelSelection;
  latestActivity?: AgentActivity;
  pendingApproval?: AgentApprovalRequest;
  startedAt: string;
  updatedAt: string;
  metadata: Record<string, JsonValue>;
}

export function reduceAgentSession(
  session: AgentSession,
  event: AgentEvent,
): AgentSession {
  if (
    event.runtime !== session.runtime
    || event.sessionId !== session.nativeSessionId
  ) {
    return session;
  }

  if (
    ["completed", "failed", "cancelled", "disconnected"].includes(session.state)
    && event.kind !== "session-started"
    && event.kind !== "session-resumed"
  ) {
    return session;
  }

  let state = session.state;
  let pendingApproval = session.pendingApproval;

  switch (event.kind) {
    case "session-started":
    case "session-resumed":
      state = "working";
      pendingApproval = undefined;
      break;
    case "user-prompt":
    case "activity-started":
    case "activity-updated":
    case "tool-started":
    case "tool-completed":
    case "command-started":
    case "command-completed":
    case "file-changed":
    case "subagent-started":
    case "subagent-completed":
      if (state !== "waiting-for-approval" && state !== "waiting-for-user") {
        state = "working";
      }
      break;
    case "activity-completed":
      if (state !== "waiting-for-approval" && state !== "waiting-for-user") {
        state = "idle";
      }
      break;
    case "approval-requested":
      if (pendingApproval?.id === event.approval?.id) break;
      state = "waiting-for-approval";
      pendingApproval = event.approval;
      break;
    case "approval-resolved":
      if (
        typeof event.metadata.requestID === "string"
        && pendingApproval
        && event.metadata.requestID !== pendingApproval.id
      ) break;
      state = "working";
      pendingApproval = undefined;
      break;
    case "user-input-requested":
      state = "waiting-for-user";
      break;
    case "tool-failed":
    case "command-failed":
    case "error":
      state = "failed";
      pendingApproval = undefined;
      break;
    case "cancelled":
      state = "cancelled";
      pendingApproval = undefined;
      break;
    case "completed":
      state = "completed";
      pendingApproval = undefined;
      break;
    case "session-ended":
      state = "disconnected";
      pendingApproval = undefined;
      break;
    case "rate-limited":
    case "warning":
    default:
      break;
  }

  return {
    ...session,
    state,
    pendingApproval,
    updatedAt:
      event.timestamp > session.updatedAt ? event.timestamp : session.updatedAt,
    latestActivity: event.title
      ? {
          id: event.id,
          title: event.title,
          detail: event.detail,
          startedAt: event.timestamp,
          completedAt:
            event.kind === "activity-completed" ? event.timestamp : undefined,
        }
      : session.latestActivity,
  };
}
