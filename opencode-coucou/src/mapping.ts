// Mapping from OpenCode events to Coucou's canonical hook event shape.
// Event names/fields are the confirmed V2 shapes — see
// .superpowers/sdd/2026-10-02-coucou-opencode-support/opencode-event-shapes.md.
// mapEvent is pure (no ctx): unknown or malformed events return null; the
// caller drops them. `cwd` is not in the event — index.ts fills it from
// ctx.location.
export type CanonicalEvent = {
  hook_event_name: string;
  session_id: string;
  coucou_agent: "opencode";
  prompt?: string;
  tool_name?: string;
  tool_input?: object;
  message?: string;
  cwd?: string;
};

// Confirmed V2 table: event.type → canonical hook_event_name.
const HOOK_NAMES: Record<string, string> = {
  "session.created": "SessionStart",
  "session.next.prompted": "UserPromptSubmit",
  "session.next.tool.called": "PreToolUse",
  "session.next.tool.success": "PostToolUse",
  "session.next.tool.failed": "PostToolUseFailure",
  "session.idle": "Stop",
  "session.deleted": "SessionEnd",
  "session.error": "StopFailure",
};

export function mapEvent(evt: unknown): CanonicalEvent | null {
  if (typeof evt !== "object" || evt === null) return null;
  const e = evt as { type?: unknown; properties?: unknown; data?: unknown };
  const type = typeof e.type === "string" ? e.type : null;
  const hookName = type ? HOOK_NAMES[type] : undefined;
  if (!hookName) return null;

  // V2 events carry fields under `properties`; newer SDK builds nest them
  // under `data` — read whichever is present.
  const p =
    (typeof e.properties === "object" && e.properties) ||
    (typeof e.data === "object" && e.data) ||
    null;
  const session_id = p && typeof p.sessionID === "string" ? p.sessionID : null;
  if (!session_id) return null;

  const out: CanonicalEvent = {
    hook_event_name: hookName,
    session_id,
    coucou_agent: "opencode",
  };

  // Optional fields are omitted (not dropped) when mis-shaped — fail soft.
  if (hookName === "UserPromptSubmit") {
    const text = (p.prompt as { text?: unknown } | undefined)?.text;
    if (typeof text === "string") out.prompt = text;
  } else if (hookName === "PreToolUse") {
    if (typeof p.tool === "string") out.tool_name = p.tool;
    if (p.input && typeof p.input === "object") out.tool_input = p.input;
  } else if (hookName === "StopFailure") {
    // ponytail: error shape unpinned (string | { error: { message } });
    // if a live shape slips past both, message is omitted, not thrown.
    const err = p.error;
    const message =
      typeof err === "string"
        ? err
        : err && typeof err === "object"
          ? (err as { error?: { message?: unknown } }).error?.message
          : undefined;
    if (typeof message === "string") out.message = message;
  }

  return out;
}
