import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:net';
import { join } from 'node:path';
import { test } from 'node:test';
import coucou from '../integrations/pi/coucou.ts';

type Handler = (event: any, context: any) => unknown;

function register() {
  const handlers = new Map<string, Handler>();
  coucou({ on: (name: string, handler: Handler) => handlers.set(name, handler) } as any);
  return handlers;
}

const context = (id: string) => ({
  cwd: '/project/example',
  sessionManager: { getSessionId: () => id },
});

// A single-slot socket server that records every newline-delimited hook.
function fakeCoucou(dir: string) {
  const received: any[] = [];
  const sockets = new Set<import('node:net').Socket>();
  let notify: () => void = () => {};
  const server = createServer((socket) => {
    sockets.add(socket);
    socket.on('error', () => {});
    socket.on('close', () => sockets.delete(socket));
    let buffer = '';
    socket.on('data', (chunk) => {
      buffer += chunk.toString();
      if (!buffer.endsWith('\n')) return;
      received.push(JSON.parse(buffer));
      socket.end('{"ok":true}\n');
      notify();
    });
  });
  return {
    received,
    path: join(dir, 'nb.sock'),
    listen: () => new Promise<void>((resolve, reject) => {
      // Never allow a test to reach the real Coucou socket.
      assert.ok(join(dir, 'nb.sock').includes('.pi-hook-test-'), 'tests must use an isolated socket');
      server.once('error', reject);
      server.listen(join(dir, 'nb.sock'), resolve);
    }),
    close: async () => {
      for (const socket of sockets) socket.destroy();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
    // Resolves once any event is delivery-confirmed. The socket data handler replaces
    // notify before the hook call resumes, so a delivered event cannot be missed.
    waitFor: (target: number) => received.length >= target
      ? Promise.resolve()
      : new Promise<void>((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error('missing hook event')), 1000);
          notify = () => { clearTimeout(timer); resolve(); };
        }),
  };
}

// All sockets and data stay inside the repository; real Pi config is never touched.
test('Pi lifecycle emits Coucou JSON lines with stable session identity', async () => {
  const dir = await mkdtemp(join(process.cwd(), '.pi-hook-test-'));
  const previous = process.env.COUCOU_SOCKET_PATH;
  const coucouSocket = fakeCoucou(dir);
  try {
    process.env.COUCOU_SOCKET_PATH = coucouSocket.path;
    assert.ok(coucouSocket.path.includes('.pi-hook-test-'), 'tests must never use the real socket');
    await coucouSocket.listen();
    const handlers = register();
    assert.equal(handlers.has('agent_end'), false, 'low-level loop end is not completion');
    assert.equal(handlers.has('turn_end'), false, 'tool turns are not completion');
    const events = [
      ['session_start', { reason: 'startup' }, 'SessionStart', {}],
      ['before_agent_start', { messageType: 'user', prompt: 'private prompt' }, 'UserPromptSubmit', {}],
      ['before_agent_start', { messageType: 'custom', message: { content: 'private continuation' } }, 'UserPromptSubmit', {}],
      ['tool_call', { toolName: 'bash', input: { command: 'private command' } }, 'PreToolUse', { tool_name: 'bash' }],
      ['tool_result', { toolName: 'bash', isError: false }, 'PostToolUse', { tool_name: 'bash' }],
      ['tool_result', { toolName: 'bash', isError: true }, 'PostToolUseFailure', { tool_name: 'bash' }],
      ['agent_settled', { aborted: false }, 'Stop', {}],
      ['agent_settled', { aborted: true }, 'Interrupt', {}],
      ['session_shutdown', { reason: 'new' }, 'SessionEnd', {}],
      ['session_start', { reason: 'new' }, 'SessionStart', {}],
      ['session_shutdown', { reason: 'quit' }, 'SessionEnd', {}],
    ] as const;
    for (const [index, [name, event, expected, extra]] of events.entries()) {
      const sessionId = index < 9 ? 'stable-session' : 'new-session';
      await handlers.get(name)!(event, context(sessionId));
      await coucouSocket.waitFor(index + 1);
      // Payloads carry identity only: no prompt, tool input, or result text.
      assert.deepEqual(coucouSocket.received[index], {
        hook_event_name: expected,
        coucou_agent: 'pi',
        session_id: sessionId,
        cwd: '/project/example',
        ...extra,
      });
    }
    assert.equal(coucouSocket.received.length, events.length);
  } finally {
    if (previous === undefined) delete process.env.COUCOU_SOCKET_PATH;
    else process.env.COUCOU_SOCKET_PATH = previous;
    await coucouSocket.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test('closed Coucou and unresponsive sockets never block or reject Pi events', async () => {
  const dir = await mkdtemp(join(process.cwd(), '.pi-hook-test-'));
  const previous = process.env.COUCOU_SOCKET_PATH;
  // allowHalfOpen keeps the accepted peer open after Pi half-closes, so only the
  // extension's own deadline can resolve the hook.
  const sockets = new Set<import('node:net').Socket>();
  const stalled = createServer({ allowHalfOpen: true }, (socket) => {
    sockets.add(socket);
    socket.on('error', () => {});
    socket.on('close', () => sockets.delete(socket));
  });
  try {
    process.env.COUCOU_SOCKET_PATH = join(dir, 'missing.sock');
    const handlers = register();
    await assert.doesNotReject(async () => handlers.get('session_start')!({}, context('offline')));
    process.env.COUCOU_SOCKET_PATH = join(dir, 'stalled.sock');
    await new Promise<void>((resolve) => stalled.listen(join(dir, 'stalled.sock'), resolve));
    const started = Date.now();
    await assert.doesNotReject(async () => handlers.get('session_start')!({}, context('stalled')));
    const elapsed = Date.now() - started;
    assert.ok(elapsed >= 100, `a stalled Coucou must still apply the deadline, waited ${elapsed}ms`);
    assert.ok(elapsed < 1000, `a stalled Coucou must not hold Pi for a second, waited ${elapsed}ms`);
    assert.equal(handlers.has('tool_execution_start'), false, 'no duplicate tool hooks');
  } finally {
    if (previous === undefined) delete process.env.COUCOU_SOCKET_PATH;
    else process.env.COUCOU_SOCKET_PATH = previous;
    for (const socket of sockets) socket.destroy();
    await new Promise<void>((resolve) => stalled.close(() => resolve()));
    await rm(dir, { recursive: true, force: true });
  }
});

test('the settled outcome decides error, finished and idle', async () => {
  const dir = await mkdtemp(join(process.cwd(), '.pi-hook-test-'));
  const previous = process.env.COUCOU_SOCKET_PATH;
  const coucouSocket = fakeCoucou(dir);
  const handlers = register();
  const deliver = async (name: string, event: any, expected: number) => {
    const target = coucouSocket.received.length + expected;
    await handlers.get(name)!(event, context('settle-session'));
    await coucouSocket.waitFor(target);
    assert.equal(coucouSocket.received.length, target, `${name} emitted the wrong event count`);
  };
  try {
    process.env.COUCOU_SOCKET_PATH = coucouSocket.path;
    await coucouSocket.listen();
    // agent_settled carries only `aborted`; the richer outcome is an agent_before_settle signal.
    assert.equal(handlers.has('agent_before_settle'), true, 'the settled outcome must be observed');
    assert.equal(handlers.has('agent_start'), true, 'a new attempt must reset the outcome');

    await deliver('agent_start', {}, 0);
    await deliver('agent_before_settle', { outcome: 'error' }, 0);
    await deliver('agent_settled', { aborted: false }, 1);

    // A later successful attempt must not inherit the previous error.
    await deliver('agent_start', {}, 0);
    await deliver('agent_before_settle', { outcome: 'completed' }, 0);
    await deliver('agent_settled', { aborted: false }, 1);

    await deliver('agent_start', {}, 0);
    await deliver('agent_before_settle', { outcome: 'aborted' }, 0);
    await deliver('agent_settled', { aborted: true }, 1);

    // Without a recorded outcome, `aborted` alone still avoids a false failure.
    await deliver('agent_start', {}, 0);
    await deliver('agent_settled', { aborted: true }, 1);
    await deliver('agent_start', {}, 0);
    await deliver('agent_settled', { aborted: false }, 1);

    assert.deepEqual(coucouSocket.received.map((e) => e.hook_event_name), [
      'StopFailure', 'Stop', 'Interrupt', 'Interrupt', 'Stop',
    ]);
    assert.ok(coucouSocket.received.every((e) => e.coucou_agent === 'pi' && e.session_id === 'settle-session'));
  } finally {
    if (previous === undefined) delete process.env.COUCOU_SOCKET_PATH;
    else process.env.COUCOU_SOCKET_PATH = previous;
    await coucouSocket.close();
    await rm(dir, { recursive: true, force: true });
  }
});
