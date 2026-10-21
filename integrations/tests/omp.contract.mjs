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
    "SessionStart", "UserPromptSubmit", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Interrupt", "SessionEnd",
  ]);
  assert.ok(records.every(r => r.payload.session_id === `oh-my-pi:${session.getSessionId()}`));
  assert.equal(JSON.stringify(records).includes("SECRET"), false);
});
