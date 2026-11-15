import { createRelay, type Agent, type HookEvent, type Session } from "./relay.ts";

/** The small, read-only part of both upstream contexts that Coucou consumes. */
type Context = { cwd: string; sessionManager: { getSessionId(): string } };

export function createReporter(agent: Agent) {
  const relay = createRelay(agent);
  let current: Session | undefined;

  function start(ctx: Context): Session {
    const session = { session_id: `${agent}:${ctx.sessionManager.getSessionId()}`, cwd: ctx.cwd };
    if (current?.session_id !== session.session_id) {
      if (current) relay.send(current, { hook_event_name: "SessionEnd" });
      relay.send(session, { hook_event_name: "SessionStart" });
    }
    current = session;
    return session;
  }

  return {
    start,
    send(ctx: Context, event: HookEvent): void { relay.send(start(ctx), event); },
    async close(): Promise<void> {
      if (current) relay.send(current, { hook_event_name: "SessionEnd" });
      current = undefined;
      await relay.close();
    },
  };
}
