import { createConnection } from 'node:net';
import { homedir } from 'node:os';
import { join } from 'node:path';
import type { ExtensionAPI, ExtensionContext } from '@earendil-works/pi-coding-agent';

// Monitoring only: never return a tool decision or forward prompts, arguments,
// results, or approval requests. Coucou dynamically creates the agent_pi pill.
export default function coucou(pi: ExtensionAPI) {
  // agent_settled only carries `aborted`; the richer outcome arrives earlier on the
  // settle boundary. Reset per attempt so one turn's failure never marks the next.
  let settledOutcome: 'completed' | 'aborted' | 'error' | undefined;

  function emit(name: string, ctx: ExtensionContext, toolName?: string): Promise<void> {
    const payload = {
      hook_event_name: name,
      coucou_agent: 'pi',
      session_id: ctx.sessionManager.getSessionId(),
      cwd: ctx.cwd,
      ...(toolName === undefined ? {} : { tool_name: toolName }),
    };
    const path = process.env.COUCOU_SOCKET_PATH ||
      join(homedir(), 'Library', 'Application Support', 'NotchBuddy', 'nb.sock');

    return new Promise((resolve) => {
      // Absolute deadline includes connecting, sending and waiting for EOF.
      // No persistent socket, retries, logs, or resources at factory invocation.
      const socket = createConnection(path);
      const finish = () => {
        clearTimeout(timer);
        socket.destroy();
        resolve();
      };
      const timer = setTimeout(finish, 150);
      socket.on('error', finish);
      socket.on('close', finish);
      socket.on('data', finish);
      socket.on('connect', () => socket.end(`${JSON.stringify(payload)}\n`));
    });
  }

  pi.on('session_start', (_event, ctx) => emit('SessionStart', ctx));
  pi.on('before_agent_start', (_event, ctx) => emit('UserPromptSubmit', ctx));
  pi.on('agent_start', () => { settledOutcome = undefined; });
  pi.on('agent_before_settle', (event) => { settledOutcome = event.outcome; });
  pi.on('tool_call', (event, ctx) => emit('PreToolUse', ctx, event.toolName));
  pi.on('tool_result', (event, ctx) =>
    emit(event.isError ? 'PostToolUseFailure' : 'PostToolUse', ctx, event.toolName));
  // agent_end/turn_end are intermediate: recovery or queued work can follow.
  pi.on('agent_settled', (event, ctx) => {
    if (event.aborted || settledOutcome === 'aborted') return emit('Interrupt', ctx);
    return emit(settledOutcome === 'error' ? 'StopFailure' : 'Stop', ctx);
  });
  pi.on('session_shutdown', (_event, ctx) => emit('SessionEnd', ctx));
}
