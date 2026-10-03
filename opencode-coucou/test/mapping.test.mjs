// test/mapping.test.mjs — pure mapEvent tests, no framework. Run: node test/mapping.test.mjs
// Table is the confirmed V2 event spec:
// .superpowers/sdd/2026-10-02-coucou-opencode-support/opencode-event-shapes.md
import assert from "node:assert/strict";
import { mapEvent } from "../src/mapping.ts";

const evt = (type, properties) => ({
  id: "evt_test",
  type,
  properties: properties ?? {},
});

// session.created → SessionStart
assert.deepEqual(mapEvent(evt("session.created", { sessionID: "s1" })), {
  hook_event_name: "SessionStart",
  session_id: "s1",
  coucou_agent: "opencode",
});

// session.next.prompted → UserPromptSubmit; prompt.text → prompt
assert.deepEqual(mapEvent(evt("session.next.prompted", { sessionID: "s1", prompt: { text: "hi", files: ["a.txt"] } })), {
  hook_event_name: "UserPromptSubmit",
  session_id: "s1",
  coucou_agent: "opencode",
  prompt: "hi",
});

// session.next.tool.called → PreToolUse; tool → tool_name, input → tool_input
assert.deepEqual(mapEvent(evt("session.next.tool.called", { sessionID: "s1", callID: "c1", tool: "bash", input: { command: "ls" } })), {
  hook_event_name: "PreToolUse",
  session_id: "s1",
  coucou_agent: "opencode",
  tool_name: "bash",
  tool_input: { command: "ls" },
});

// session.next.tool.success → PostToolUse (no extra fields extracted)
assert.deepEqual(mapEvent(evt("session.next.tool.success", { sessionID: "s1", callID: "c1", content: [], structured: {} })), {
  hook_event_name: "PostToolUse",
  session_id: "s1",
  coucou_agent: "opencode",
});

// session.next.tool.failed → PostToolUseFailure
assert.deepEqual(mapEvent(evt("session.next.tool.failed", { sessionID: "s1", callID: "c1", error: "boom" })), {
  hook_event_name: "PostToolUseFailure",
  session_id: "s1",
  coucou_agent: "opencode",
});

// session.idle → Stop
assert.deepEqual(mapEvent(evt("session.idle", { sessionID: "s1" })), {
  hook_event_name: "Stop",
  session_id: "s1",
  coucou_agent: "opencode",
});

// session.deleted → SessionEnd
assert.deepEqual(mapEvent(evt("session.deleted", { sessionID: "s1", info: { id: "s1" } })), {
  hook_event_name: "SessionEnd",
  session_id: "s1",
  coucou_agent: "opencode",
});

// session.error → StopFailure; error → message (string or nested message)
assert.deepEqual(mapEvent(evt("session.error", { sessionID: "s1", error: "kaboom" })), {
  hook_event_name: "StopFailure",
  session_id: "s1",
  coucou_agent: "opencode",
  message: "kaboom",
});
assert.deepEqual(mapEvent(evt("session.error", { sessionID: "s1", error: { error: { message: "structured boom" } } })), {
  hook_event_name: "StopFailure",
  session_id: "s1",
  coucou_agent: "opencode",
  message: "structured boom",
});

// Everything else is noise → null
for (const type of [
  "session.next.text.delta",
  "session.next.reasoning.delta",
  "session.next.part.updated",
  "permission.asked",
  "permission.replied",
  "tui.prompt.append",
  "mcp.status.changed",
  "unknown.type",
  "",
]) {
  assert.equal(mapEvent(evt(type, { sessionID: "s1" })), null, `expected null for ${type}`);
}

// Garbage input never throws — a bad event is dropped, not raised
for (const bad of [null, undefined, 42, "event", {}, { type: "session.idle" }, { type: "session.next.prompted", properties: { prompt: null } }]) {
  assert.equal(mapEvent(bad), null, `expected null for ${JSON.stringify(bad)}`);
}

console.log("mapping.test.mjs PASS");
