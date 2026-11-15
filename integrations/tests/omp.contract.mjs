import assert from "node:assert/strict";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { fixture } from "./helpers.mjs";

test("OMP 18.12 loads the extension and dispatches through its own runner", async t => {
  const f = await fixture(t);
  process.env.PI_CODING_AGENT_DIR = f.dir;
  const { loadExtensions, ExtensionRunner } = await import("@oh-my-pi/pi-coding-agent/extensibility/extensions");
  const { SessionManager } = await import("@oh-my-pi/pi-coding-agent/session/session-manager");
  const path = fileURLToPath(new URL("../oh-my-pi/coucou.ts", import.meta.url));
  const loaded = await loadExtensions([path], f.dir);
  assert.deepEqual(loaded.errors, []);
  assert.equal(loaded.extensions.length, 1);
  const session = SessionManager.inMemory(f.dir);
  const runner = new ExtensionRunner(loaded.extensions, loaded.runtime, f.dir, session, {});
  const errors = [];
  runner.onError(error => errors.push(error));
  assert.equal(runner.hasHandlers("tool_call"), false);
  assert.equal(runner.hasHandlers("tool_result"), false);
  await runner.emit({ type: "session_start" });
  assert.equal(await runner.emitBeforeAgentStart("SECRET", undefined, ["SECRET"]), undefined);
  await runner.emit({ type: "agent_start" });
  await runner.emit({ type: "tool_execution_start", toolName: "read", toolCallId: "t", args: { path: "SECRET" } });
  await runner.emit({ type: "tool_execution_end", toolName: "read", toolCallId: "t", isError: false, result: "SECRET" });
  await runner.emit({ type: "agent_end", messages: [], willContinue: true });
  await runner.emit({ type: "agent_end", messages: [], awaitingAsyncWork: true });
  await runner.emit({ type: "message_end", message: { role: "assistant", stopReason: "aborted" } });
  await runner.emit({ type: "agent_end", messages: [{ role: "assistant", stopReason: "aborted" }] });
  await runner.emit({ type: "session_shutdown" });
  assert.deepEqual(errors, []);
  const records = await f.records();
  assert.deepEqual(records.map(r => r.payload.hook_event_name), [
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Interrupt", "SessionEnd",
  ]);
  assert.ok(records.every(r => r.payload.session_id === `oh-my-pi:${session.getSessionId()}`));
  assert.equal(JSON.stringify(records).includes("SECRET"), false);
});

test("OMP notifications may overtake: recovery, subagent failures, aborts and late starts", async t => {
  const { writeFile } = await import("node:fs/promises");
  const { join } = await import("node:path");
  const f = await fixture(t);
  process.env.PI_CODING_AGENT_DIR = f.dir;
  const { loadExtensions, ExtensionRunner } = await import("@oh-my-pi/pi-coding-agent/extensibility/extensions");
  const { SessionManager } = await import("@oh-my-pi/pi-coding-agent/session/session-manager");
  const key = Symbol.for("coucou.contract.notification-gates");
  const deferred = () => Promise.withResolvers();
  globalThis[key] = { message: deferred(), start: deferred() };
  t.after(() => { delete globalThis[key]; });
  const blocker = join(f.dir, "preceding-extension.ts");
  await writeFile(blocker, `export default function (api) {
    const gates = globalThis[Symbol.for("coucou.contract.notification-gates")];
    api.on("message_end", async () => { await gates.message.promise; });
    api.on("agent_start", async () => { await gates.start.promise; });
  }`);
  const path = fileURLToPath(new URL("../oh-my-pi/coucou.ts", import.meta.url));
  const loaded = await loadExtensions([blocker, path], f.dir);
  assert.deepEqual(loaded.errors, []);
  const session = SessionManager.inMemory(f.dir);
  const runner = new ExtensionRunner(loaded.extensions, loaded.runtime, f.dir, session, {});
  let idle = false;
  runner.initialize({}, {
    getModel: () => undefined, isIdle: () => idle, abort() {}, hasPendingMessages: () => false,
    shutdown() {}, getContextUsage: () => undefined, compact: async () => {}, getSystemPrompt: () => [],
  });
  const errors = [];
  runner.onError(error => errors.push(error));
  const assistant = (timestamp, stopReason) => ({
    role: "assistant", timestamp, stopReason, content: [{ type: "text", text: "SECRET" }],
    api: "openai-completions", provider: "openai", model: "fixture",
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
  });
  await runner.emit({ type: "session_start" });
  await runner.emitBeforeAgentStart("SECRET", undefined, ["SECRET"]);
  const lateStart = runner.emit({ type: "agent_start" });
  const length = assistant(1, "length");
  await runner.emitAssistantMessage(length);
  const lateMessage = runner.emit({ type: "message_end", message: length });
  // Main-session recovery promotes the same message to a pruned terminal error.
  const recoveredError = { ...length, stopReason: "error" };
  await runner.emitSessionStop({ messages: [], turn_id: 0, session_id: session.getSessionId(),
    last_assistant_message: recoveredError, stop_hook_active: false, signal: new AbortController().signal });
  await runner.emit({ type: "agent_end", messages: [] });
  globalThis[key].start.resolve();
  globalThis[key].message.resolve();
  await Promise.all([lateStart, lateMessage]);
  // Child sessions do not receive session_stop. Their awaited finalization snapshot
  // must survive history pruning without depending on message_end notification order.
  await runner.emitBeforeAgentStart("SECRET", undefined, ["SECRET"]);
  const childError = assistant(2, "error");
  await runner.emitAssistantMessage(childError);
  await runner.emit({ type: "agent_end", messages: [], willContinue: true });
  await runner.emit({ type: "agent_end", messages: [], awaitingAsyncWork: true });
  await runner.emit({ type: "agent_end", messages: [] });
  // A child can exhaust length recovery and prune its incomplete assistant;
  // terminal truncation must not become success just because session_stop is absent.
  await runner.emitBeforeAgentStart("SECRET", undefined, ["SECRET"]);
  await runner.emitAssistantMessage(assistant(2.5, "length"));
  await runner.emit({ type: "agent_end", messages: [] });
  // A cut-off stream can abort before the assistant_message control hook fires.
  await runner.emitBeforeAgentStart("SECRET", undefined, ["SECRET"]);
  await runner.emit({ type: "agent_end", messages: [assistant(3, "aborted")] });
  await runner.emitBeforeAgentStart("SECRET", undefined, ["SECRET"]);
  await runner.emitAssistantMessage(assistant(4, "error"));
  await runner.emit({ type: "agent_end", messages: [], willContinue: true });
  const success = assistant(5, "stop");
  await runner.emitAssistantMessage(success);
  await runner.emit({ type: "agent_end", messages: [success] });
  // A synthetic model continuation has an awaited context boundary even when
  // it has no user before_agent_start notification.
  assert.deepEqual(await runner.emitContext([]), []);
  const synthetic = assistant(6, "stop");
  await runner.emitAssistantMessage(synthetic);
  await runner.emit({ type: "agent_end", messages: [synthetic] });
  idle = true;
  // Idle side queries also pass through context hooks, but have no agent_end.
  assert.deepEqual(await runner.emitContext([]), []);
  await runner.emitAssistantMessage(assistant(7, "stop"));
  await runner.emit({ type: "session_shutdown" });
  assert.deepEqual(errors, []);
  const records = await f.records();
  assert.deepEqual(records.map(r => r.payload.hook_event_name), [
    "SessionStart", "UserPromptSubmit", "StopFailure", "UserPromptSubmit", "StopFailure",
    "UserPromptSubmit", "StopFailure", "UserPromptSubmit", "Interrupt", "UserPromptSubmit", "Stop", "UserPromptSubmit", "Stop", "SessionEnd",
  ]);
  assert.equal(JSON.stringify(records).includes("SECRET"), false);
});

test("OMP delayed terminal notifications cannot settle a newer same-session run", async t => {
  const { writeFile } = await import("node:fs/promises");
  const { join } = await import("node:path");
  for (const pruned of [false, true]) {
    const f = await fixture(t);
    process.env.PI_CODING_AGENT_DIR = f.dir;
    const { loadExtensions, ExtensionRunner } = await import("@oh-my-pi/pi-coding-agent/extensibility/extensions");
    const { SessionManager } = await import("@oh-my-pi/pi-coding-agent/session/session-manager");
    const key = Symbol.for("coucou.contract.terminal-gate");
    const gate = Promise.withResolvers();
    const entered = Promise.withResolvers();
    globalThis[key] = { gate, entered };
    const blocker = join(f.dir, "preceding-terminal-extension.ts");
    await writeFile(blocker, `export default function (api) {
      let first = true;
      api.on("agent_end", async () => {
        if (!first) return;
        first = false;
        const { gate, entered } = globalThis[Symbol.for("coucou.contract.terminal-gate")];
        entered.resolve();
        await gate.promise;
      });
    }`);
    const path = fileURLToPath(new URL("../oh-my-pi/coucou.ts", import.meta.url));
    const loaded = await loadExtensions([blocker, path], f.dir);
    assert.deepEqual(loaded.errors, []);
    const session = SessionManager.inMemory(f.dir);
    const runner = new ExtensionRunner(loaded.extensions, loaded.runtime, f.dir, session, {});
    const errors = [];
    runner.onError(error => errors.push(error));
    const assistant = (timestamp, stopReason) => ({
      role: "assistant", timestamp, stopReason, content: [], api: "openai-completions",
      provider: "openai", model: "fixture", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
        totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    });
    await runner.emit({ type: "session_start" });
    await runner.emitBeforeAgentStart("A", undefined, []);
    const a = assistant(10, "stop");
    await runner.emitAssistantMessage(a);
    session.appendMessage(a);
    const late = runner.emit({ type: "agent_end", messages: pruned ? [] : [a] });
    await entered.promise;
    await runner.emitBeforeAgentStart("B", undefined, []);
    const tool = assistant(11, "toolUse");
    await runner.emitAssistantMessage(tool);
    gate.resolve();
    await late;
    await runner.emit({ type: "tool_execution_start", toolName: "read", toolCallId: "b", args: {} });
    const b = assistant(12, "stop");
    await runner.emitAssistantMessage(b);
    await runner.emit({ type: "agent_end", messages: [a, tool, b] });
    await runner.emit({ type: "session_shutdown" });
    delete globalThis[key];
    assert.deepEqual(errors, []);
    assert.deepEqual((await f.records()).map(r => r.payload.hook_event_name), [
      "SessionStart", "UserPromptSubmit", "UserPromptSubmit", "PreToolUse", "Stop", "SessionEnd",
    ], `pruned prior terminal = ${pruned}`);
  }
});
