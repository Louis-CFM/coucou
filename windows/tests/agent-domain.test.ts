import assert from "node:assert/strict";
import test from "node:test";
import {
  reduceAgentSession,
  type AgentEvent,
  type AgentSession,
} from "../src/core/ai/domain.ts";
import { translateClaudeHook } from "../src/agents/claude-code/hook-translator.ts";

const session = (): AgentSession => ({
  id: "codex:session-1",
  runtime: "codex",
  provider: "openai",
  nativeSessionId: "session-1",
  state: "idle",
  startedAt: "2026-09-30T10:00:00.000Z",
  updatedAt: "2026-09-30T10:00:00.000Z",
  metadata: {},
});

const event = (
  kind: AgentEvent["kind"],
  overrides: Partial<AgentEvent> = {},
): AgentEvent => ({
  id: "event-1",
  runtime: "codex",
  provider: "openai",
  sessionId: "session-1",
  timestamp: "2026-09-30T10:01:00.000Z",
  kind,
  metadata: {},
  ...overrides,
});

test("approval lifecycle is isolated to its session", () => {
  const waiting = reduceAgentSession(session(), event("approval-requested", {
    approval: {
      id: "approval-1",
      title: "Run command",
      choices: ["allow", "deny"],
    },
  }));
  assert.equal(waiting.state, "waiting-for-approval");
  assert.equal(waiting.pendingApproval?.id, "approval-1");

  const resumed = reduceAgentSession(waiting, event("approval-resolved"));
  assert.equal(resumed.state, "working");
  assert.equal(resumed.pendingApproval, undefined);
});

test("event from another runtime does not change the session", () => {
  const original = session();
  const result = reduceAgentSession(
    original,
    event("error", { runtime: "claude-code", sessionId: "session-2" }),
  );
  assert.equal(result, original);
});

test("delayed activity cannot reopen a completed session", () => {
  const completed = reduceAgentSession(session(), event("completed"));
  const delayed = reduceAgentSession(completed, event("tool-started", {
    sequence: 1,
    timestamp: "2026-09-30T10:00:30.000Z",
  }));

  assert.equal(delayed.state, "completed");
});

test("tool activity cannot hide a pending approval", () => {
  const waiting = reduceAgentSession(session(), event("approval-requested", {
    approval: {
      id: "approval-1",
      title: "Run command",
      choices: ["allow", "deny"],
    },
  }));
  const activity = reduceAgentSession(waiting, event("tool-completed"));

  assert.equal(activity.state, "waiting-for-approval");
  assert.equal(activity.pendingApproval?.id, "approval-1");
});

test("Claude tool hook translates to a normalized event", () => {
  const translation = translateClaudeHook(
    "PreToolUse",
    {
      session_id: "claude-1",
      cwd: "C:\\work\\notch-buddy",
      tool_name: "Read",
      tool_input: { file_path: "C:\\work\\notch-buddy\\README.md" },
    },
    "2026-09-30T10:00:00.000Z",
    "event-1",
  );

  assert.equal(translation?.event.runtime, "claude-code");
  assert.equal(translation?.event.provider, "anthropic");
  assert.equal(translation?.event.kind, "tool-started");
  assert.equal(translation?.event.title, "Lit · README.md");
  assert.equal(translation?.projectName, "Notch Buddy");
});

test("Claude approval keeps its identifying target", () => {
  const translation = translateClaudeHook(
    "PermissionRequest",
    {
      request_id: "approval-1",
      session_id: "claude-1",
      tool_name: "Write",
      tool_input: { file_path: "C:\\work\\project\\.env" },
    },
    "2026-09-30T10:00:00.000Z",
    "event-1",
  );

  assert.equal(translation?.event.kind, "approval-requested");
  assert.equal(
    translation?.event.approval?.detail,
    "Write · C:\\work\\project\\.env",
  );
});
