// Permission relay: OpenCode `permission.asked` event → Coucou
// `PermissionRequest` payload, and Coucou decision → ctx.permission.reply
// value. Contract:
// .superpowers/sdd/2026-10-02-coucou-opencode-support/opencode-event-shapes.md
// Both functions are pure (no ctx, no I/O) so they unit-test without a socket.
import type { PermissionDecision } from "./socket.ts";

// Payload Coucou's HookServer.swift processPermissionRequest expects.
export type CoucouPermissionPayload = {
  hook_event_name: "PermissionRequest";
  coucou_agent: "opencode";
  session_id: string;
  cwd?: string;
  tool_name: string;
  tool_input: object;
};

/**
 * Build the Coucou payload from a `permission.asked` event's `properties`
 * (a PermissionRequest: { id, sessionID, permission, patterns, metadata, ... }).
 * Returns null (caller drops) for malformed properties — never throws.
 */
export function buildPermissionPayload(
  properties: unknown,
  cwd?: string,
): CoucouPermissionPayload | null {
  if (typeof properties !== "object" || properties === null) return null;
  const p = properties as {
    sessionID?: unknown;
    permission?: unknown;
    metadata?: unknown;
    patterns?: unknown;
  };
  if (typeof p.sessionID !== "string" || typeof p.permission !== "string")
    return null;

  // Best-effort card context: prefer metadata if it looks like the tool's
  // input, else the patterns list, else nothing (Coucou falls back to
  // tool_name).
  let tool_input: object = {};
  if (p.metadata && typeof p.metadata === "object") {
    tool_input = p.metadata;
  } else if (Array.isArray(p.patterns)) {
    tool_input = { patterns: p.patterns };
  }

  const out: CoucouPermissionPayload = {
    hook_event_name: "PermissionRequest",
    coucou_agent: "opencode",
    session_id: p.sessionID,
    tool_name: p.permission,
    tool_input,
  };
  if (typeof cwd === "string") out.cwd = cwd;
  return out;
}

/**
 * Map Coucou's decision to the ctx.permission.reply value.
 * "ask" (timeout/displacement) → null: do NOT reply; OpenCode re-asks in its
 * own terminal.
 */
export function decisionToReply(
  decision: PermissionDecision | unknown,
): "once" | "always" | "reject" | null {
  if (decision === "allow") return "once";
  if (decision === "always") return "always";
  if (decision === "deny") return "reject";
  return null;
}
