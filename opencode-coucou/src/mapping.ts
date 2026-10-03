// Mapping from OpenCode events to Coucou's canonical hook event shape.
// Stub for Task 1 — the real mapping table lands in Task 2.
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

export function mapEvent(_evt: unknown): CanonicalEvent | null {
  return null;
}
