import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";

// Bundle the real state/handler, replacing only the native bridge and sound I/O.
const calls = [];
const timers = new Map();
let timerId = 0;
globalThis.__hookCalls = calls;
globalThis.window = {
  setTimeout(fn, delay) { const id = ++timerId; timers.set(id, { fn, delay }); return id; },
  clearTimeout(id) { timers.delete(id); },
};
const bundle = await build({
  stdin: {
    contents: 'export {handleHook} from "./src/island/hooks.ts"; export {State, DEFAULT_SETTINGS} from "./src/core/state.ts";',
    resolveDir: fileURLToPath(new URL("../", import.meta.url)), loader: "ts",
  },
  bundle: true, write: false, format: "esm", platform: "node",
  plugins: [{ name: "native-fixtures", setup(builder) {
    builder.onResolve({ filter: /core\/(bridge|sound)$/ }, (args) => ({ path: args.path, namespace: "fixture" }));
    builder.onLoad({ filter: /.*/, namespace: "fixture" }, (args) => ({ contents: args.path.endsWith("sound")
      ? 'export const Sound = {play: (...args) => globalThis.__hookCalls.push(["sound", ...args])};'
      : `export const Bridge = Object.fromEntries(["approvalDecline","approvalAck"].map(k => [k, (...a) => globalThis.__hookCalls.push([k,...a])])); export async function onEvent() { return () => {}; }`, loader: "js" }));
  } }],
});
const { handleHook, State, DEFAULT_SETTINGS } = await import(`data:text/javascript;base64,${Buffer.from(bundle.outputFiles[0].text).toString("base64")}`);
const island = {
  reveal() { calls.push(["reveal"]); },
  alert(view) { State.view = view; State.mode = "expanded"; calls.push(["alert", view]); },
  setView(view) { State.view = view; calls.push(["setView", view]); },
  dropPin() { calls.push(["dropPin"]); },
};
const emit = (event, payload = {}, provider = "codex") => handleHook(island, {
  agent_provider: provider, hook_event_name: event, session_id: "session-A", cwd: "C:\\work\\project", ...payload,
});
const task = (id = "integration_codex") => State.tasks.find((t) => t.id === id);

beforeEach(() => {
  calls.length = 0; timers.clear();
  State.tasks = []; State.settings = { ...DEFAULT_SETTINGS, activeIntegrations: [...DEFAULT_SETTINGS.activeIntegrations] };
  State.pendingApproval = null; State.isPinned = false; State.paused = false;
  State.focusId = "integration_claude"; State.mode = "hidden"; State.view = "overview";
  State.loadIntegrationTasks();
});

test("default pills are unchanged; Codex is opt-in and is not a service integration", () => {
  assert.equal(task(), undefined);
  assert.equal(State.tasks.length, 5);
  State.settings.codexHooksInstalled = true; State.loadIntegrationTasks();
  assert.equal(task().source, "codex");
  State.toggleIntegration("integration_codex");
  assert.equal(task().source, "codex");
  assert.equal(State.settings.activeIntegrations.length, 4);
});

test("Codex lifecycle targets Codex only and retains Unicode tool labels", () => {
  emit("SessionStart"); emit("UserPromptSubmit", { prompt: "Run the tests" });
  assert.equal(task().state, "thinking"); assert.equal(task().steps[0], "Run the tests");
  emit("PreToolUse", { tool_name: "apply_patch", tool_input: { command: "*** Begin Patch" } });
  assert.equal(task().state, "working"); assert.equal(task().steps[1], "Modifie · *** Begin Patch");
  assert.equal(task("integration_claude").state, "idle");
  emit("Stop", { last_assistant_message: "All tests pass" });
  assert.equal(task().state, "finished"); assert.equal(task().steps.at(-1), "All tests pass");
  assert.equal(task().pillBadge, "finished");
  emit("SessionEnd"); assert.equal(task().state, "idle"); assert.equal(task().name, "Codex");
  assert.equal(task().sessionCwd, null);
});

test("legacy untagged Claude events preserve routing and naming", () => {
  handleHook(island, { hook_event_name: "PreToolUse", tool_name: "Read", tool_input: { file_path: "file.ts" }, session_id: "legacy" });
  assert.equal(task("integration_claude").state, "working");
  assert.equal(task("integration_claude").steps.at(-1), "Lit · file.ts");
  assert.equal(task(), undefined);
});

test("a new turn cancels the old finish reset; providers finish independently", () => {
  emit("Stop"); const completion = [...timers.entries()].find(([, t]) => t.delay === 5200)[0];
  emit("PreToolUse", { tool_name: "Bash", tool_input: { command: "npm test" } });
  assert.equal(timers.has(completion), false); assert.equal(task().state, "working");
  emit("Stop", {}, "claude");
  assert.equal(task().state, "working"); assert.equal(task("integration_claude").state, "finished");
});

test("a stale session end cannot clear the latest session", () => {
  emit("SessionStart"); emit("PreToolUse", { session_id: "session-B", tool_name: "Bash" });
  emit("SessionEnd", { session_id: "session-A" });
  assert.equal(task().sessionId, "session-B"); assert.equal(task().state, "working");
});

test("approval is explicit, bound to its provider and acknowledged after presentation", () => {
  State.focusId = "integration_codex";
  emit("PermissionRequest", { request_id: "request-A", tool_name: "Bash", tool_input: { command: "npm test" } });
  assert.equal(State.pendingApproval.taskId, "integration_codex");
  assert.equal(State.pendingApproval.command, "Bash · npm test");
  assert.equal(task().state, "approval"); assert.equal(State.isPinned, true);
  assert.ok(calls.findIndex((c) => c[0] === "alert") < calls.findIndex((c) => c[0] === "approvalAck"));
  assert.equal(calls.some((c) => c[0] === "approvalDecision"), false);
});

test("a competing approval is declined without changing the reviewed request/session", () => {
  emit("PermissionRequest", { request_id: "request-A", tool_name: "Bash" });
  emit("PermissionRequest", { request_id: "request-B", session_id: "session-B", tool_name: "apply_patch" });
  assert.equal(State.pendingApproval.requestId, "request-A"); assert.equal(task().sessionId, "session-A");
  assert.ok(calls.some((c) => c[0] === "approvalDecline" && c[1] === "request-B"));
});

test("paused/unknown providers and requests without an ID do not create an approval", () => {
  State.paused = true; emit("PermissionRequest", { request_id: "request-A" });
  assert.equal(State.pendingApproval, null); assert.equal(task(), undefined);
  assert.ok(calls.some((c) => c[0] === "approvalDecline"));
  State.paused = false; emit("PermissionRequest"); assert.equal(State.pendingApproval, null);
  emit("PreToolUse", {}, "unknown"); assert.equal(task("integration_claude").state, "idle");
});

test("approval expiration releases the card without a permission decision", () => {
  emit("PermissionRequest", { request_id: "request-A" });
  [...timers.values()].find((t) => t.delay === 110_000).fn();
  assert.equal(State.pendingApproval, null); assert.equal(State.isPinned, false);
  assert.equal(task().state, "working");
  assert.equal(calls.some((c) => c[0] === "approvalDecision"), false);
});

test("Interrupt is idle, not success or an approval", () => {
  emit("PreToolUse", { tool_name: "Bash" }); emit("Interrupt");
  assert.equal(task().state, "idle"); assert.equal(task().steps.at(-1), "• interrupted");
  assert.equal(task().pillBadge, null);
});

test("malformed IPC payloads have no state or approval side effects", () => {
  for (const value of [null, [], "text", 42, { hook_event_name: 7 },
    { hook_event_name: "PreToolUse", tool_input: [] },
    { hook_event_name: "PermissionRequest", request_id: {} }]) handleHook(island, value);
  assert.equal(State.tasks.length, 5); assert.equal(State.pendingApproval, null);
  assert.equal(calls.length, 0);
});

test("session cancellation releases its approval and cancels the old card timer", () => {
  emit("PermissionRequest", { request_id: "request-A" });
  const timer = [...timers.entries()].find(([, t]) => t.delay === 110_000)[0];
  emit("Interrupt");
  assert.equal(State.pendingApproval, null); assert.equal(State.isPinned, false);
  assert.equal(timers.has(timer), false); assert.equal(task().state, "idle");
  assert.ok(calls.some((c) => c[0] === "approvalDecline" && c[1] === "request-A"));
});

test("a new session releases the previous approval without authorizing either request", () => {
  emit("PermissionRequest", { request_id: "request-A" });
  emit("SessionStart", { session_id: "session-B" });
  assert.equal(State.pendingApproval, null); assert.equal(task().sessionId, "session-B");
  assert.ok(calls.some((c) => c[0] === "approvalDecline" && c[1] === "request-A"));
  assert.equal(calls.some((c) => c[0] === "approvalDecision"), false);
});
