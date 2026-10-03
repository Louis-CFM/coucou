// test/permission.test.mjs — pure permission-relay tests, no framework.
// Run: node test/permission.test.mjs
// Contract: .superpowers/sdd/2026-10-02-coucou-opencode-support/opencode-event-shapes.md
// ("Coucou-side PermissionRequest payload contract" + "Decision mapping").
import assert from "node:assert/strict";
import { buildPermissionPayload, decisionToReply } from "../src/permission.ts";

// --- Decision mapping: Coucou button → ctx.permission.reply value ---
assert.equal(decisionToReply("allow"), "once");
assert.equal(decisionToReply("always"), "always");
assert.equal(decisionToReply("deny"), "reject");
// "ask" (timeout/displacement) → no reply; let OpenCode re-ask in its terminal
assert.equal(decisionToReply("ask"), null);
// Garbage decision → no reply, never throws
assert.equal(decisionToReply("bogus"), null);
assert.equal(decisionToReply(undefined), null);

// --- Payload builder: permission.asked properties → Coucou payload ---
const props = {
  id: "req_1",
  sessionID: "ses_abc",
  permission: "bash",
  patterns: ["rm -rf *"],
  metadata: { command: "ls -la" },
  always: ["bash"],
  tool: { messageID: "msg_1", callID: "prt_1" },
};
assert.deepEqual(buildPermissionPayload(props, "/work"), {
  hook_event_name: "PermissionRequest",
  coucou_agent: "opencode",
  session_id: "ses_abc",
  cwd: "/work",
  tool_name: "bash",
  tool_input: { command: "ls -la" },
});

// No metadata → synthesize { patterns } so the card still has context
assert.deepEqual(buildPermissionPayload({ ...props, metadata: undefined }, "/work").tool_input, {
  patterns: ["rm -rf *"],
});
// metadata that isn't an object falls back to patterns
assert.deepEqual(buildPermissionPayload({ ...props, metadata: "not-an-object" }, "/work").tool_input, {
  patterns: ["rm -rf *"],
});
// No metadata, no patterns → empty tool_input is acceptable (Coucou falls back to tool_name)
assert.deepEqual(buildPermissionPayload({ ...props, metadata: undefined, patterns: undefined }, "/work").tool_input, {});
// cwd omitted when not a string
assert.equal(buildPermissionPayload(props, undefined).cwd, undefined);

// Malformed properties → null (caller drops), never throws
for (const bad of [null, undefined, 42, "props", {}, { sessionID: "s1" }, { permission: "bash" }, { sessionID: 42, permission: "bash" }]) {
  assert.equal(buildPermissionPayload(bad, "/work"), null, `expected null for ${JSON.stringify(bad)}`);
}

console.log("permission.test.mjs PASS");
