import assert from "node:assert/strict";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { fixture } from "./helpers.mjs";

test("Pi 1.3 loads the extension and dispatches through its official runner", async t => {
  const f = await fixture(t);
  process.env.PI_CODING_AGENT_DIR = f.dir;
  const { discoverAndLoadExtensions, ExtensionRunner, SessionManager } = await import("@earendil-works/pi-coding-agent");
  const path = fileURLToPath(new URL("../pi/coucou.ts", import.meta.url));
  const loaded = await discoverAndLoadExtensions([path], f.dir, f.dir);
  assert.deepEqual(loaded.errors, []);
  assert.equal(loaded.extensions.length, 1);
  const session = SessionManager.inMemory(f.dir);
  const runner = new ExtensionRunner(loaded.extensions, loaded.runtime, f.dir, session, {});
  const errors = [];
  runner.onError(error => errors.push(error));
  assert.equal(runner.hasHandlers("tool_call"), false);
  assert.equal(runner.hasHandlers("tool_result"), false);
  await runner.emit({ type: "session_start", reason: "startup" });
  const options = { cwd: f.dir, customPrompt: "SECRET" };
  const prepared = await runner.emitBeforeAgentStart({ messageType: "user", prompt: "SECRET" }, options);
  assert.deepEqual(prepared.messages, []);
  assert.equal(prepared.systemPromptOptions.customPrompt, "SECRET");
  await runner.emitBeforeAgentStart({ messageType: "custom", message: { content: "SECRET" } }, options);
  await runner.emit({ type: "agent_start" });
  await runner.emit({ type: "tool_execution_start", toolName: "bash", toolCallId: "t", args: { command: "SECRET" } });
  await runner.emit({ type: "tool_execution_end", toolName: "bash", toolCallId: "t", isError: true, result: "SECRET" });
  const boundary = await runner.emitBoundary({ type: "agent_before_settle", outcome: "error" }, () => ({
    contextEntries: [], contextMessages: [], llmMessages: [], pendingMessages: [], canContinue: true,
  }));
  assert.deepEqual(boundary.entries, []);
  assert.equal(boundary.continue, false);
  await runner.emit({ type: "agent_settled", aborted: false });
  await runner.emit({ type: "session_shutdown", reason: "quit" });
  assert.deepEqual(errors, []);
  const records = await f.records();
  assert.deepEqual(records.map(r => r.payload.hook_event_name), [
    "SessionStart", "UserPromptSubmit", "UserPromptSubmit", "PreToolUse", "PostToolUseFailure", "StopFailure", "SessionEnd",
  ]);
  assert.ok(records.every(r => r.payload.session_id === `pi:${session.getSessionId()}`));
  assert.equal(JSON.stringify(records).includes("SECRET"), false);
});
