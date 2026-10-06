import assert from "node:assert/strict";
import test from "node:test";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

// Bundle the actual event handler, replacing only OS/UI side effects. No webview,
// running Coucou, live configuration, or third-party test framework is needed.
const result = await build({
  stdin: {
    contents: `export { createHookHandlers } from "./island/hooks";
      export { State, DEFAULT_SETTINGS, isCodingAgent, agentLabel } from "./core/state";
      export { calls } from "./core/bridge";`,
    resolveDir: fileURLToPath(new URL("../src", import.meta.url)), loader: "ts",
  },
  bundle: true, write: false, platform: "node", format: "esm",
  plugins: [{ name: "hook-side-effects", setup(build) {
    build.onResolve({ filter: /(?:\.\.\/|\.\/)core\/(bridge|sound)$/ }, args =>
      ({ path: args.path.endsWith("bridge") ? "bridge" : "sound", namespace: "mock" }));
    build.onLoad({ filter: /.*/, namespace: "mock" }, args => ({ contents:
      args.path === "sound" ? `export const Sound = { play() {} };` : `
        export const calls = [];
        export const Bridge = {
          approvalAck(id) { calls.push(["ack", id]); },
          approvalDecline(id) { calls.push(["decline", id]); },
        };
        export function onEvent() {}`,
    }));
    // Resolve this small TS graph directly; esbuild otherwise scans ancestor
    // directories for configuration, which a sandboxed Windows runner may deny.
    build.onResolve({ filter: /^\./ }, args => ({
      path: resolve(args.namespace === "source" ? dirname(args.importer)
        : fileURLToPath(new URL("../src", import.meta.url)), `${args.path}.ts`),
      namespace: "source",
    }));
    build.onLoad({ filter: /.*/, namespace: "source" }, async args => ({
      contents: await readFile(args.path, "utf8"), loader: "ts",
    }));
  } }],
});
const { createHookHandlers, State, DEFAULT_SETTINGS, isCodingAgent, agentLabel, calls } = await import(
  `data:text/javascript;base64,${Buffer.from(result.outputFiles[0].text).toString("base64")}`
);

function setup() {
  let timerId = 0;
  const timers = new Map();
  globalThis.window = {
    setTimeout(fn, delay) { timers.set(++timerId, { fn, delay }); return timerId; },
    clearTimeout(id) { timers.delete(id); },
  };
  State.tasks = [];
  State.focusId = "integration_claude";
  State.settings = { ...DEFAULT_SETTINGS };
  State.pendingApproval = null;
  State.paused = false;
  State.isPinned = false;
  State.mode = "expanded";
  State.view = "overview";
  State.loadIntegrationTasks();
  calls.length = 0;
  const island = {
    alert(view) { State.view = view; },
    setView(view) { State.view = view; },
    reveal() {}, dropPin() {},
  };
  const handlers = createHookHandlers(island);
  return {
    ...handlers,
    send(event, options = {}) {
      handlers.handle({ hook_event_name: event, coucou_agent: "codex", session_id: "c1", cwd: "C:\\work\\one", ...options });
    },
    task(agent = "codex") { return State.tasks.find(t => t.id === `integration_${agent}`); },
    timer(delay) { return [...timers.values()].find(t => t.delay === delay)?.fn; },
  };
}
const request = (request_id = "r1", extra = {}) => ({
  request_id, tool_name: "shell", tool_input: { command: "echo hello" },
  coucou_tool_input_json: '{"command":"echo hello"}', ...extra,
});

test("legacy and explicit Claude events stay separate from Codex", () => {
  const h = setup();
  h.send("PreToolUse", { coucou_agent: undefined, tool_name: "Read", tool_input: { path: "C:\\app\\legacy.txt" } });
  h.send("PreToolUse", { tool_name: "shell" });
  assert.equal(h.task("claude").steps.at(-1), "Lit · legacy.txt");
  assert.equal(h.task().steps.at(-1), "shell");
  h.send("UserPromptSubmit", { coucou_agent: "claude", prompt: "Claude task" });
  assert.equal(h.task("claude").state, "thinking");
  assert.equal(h.task().state, "working");
});

test("Codex activity never shows prompts or raw commands even from an older relay", () => {
  const h = setup();
  h.send("UserPromptSubmit", { prompt: "secret prompt" });
  h.send("PreToolUse", { tool_name: "shell", tool_input: { command: "secret command" } });
  h.send("Stop", { message: "secret answer" });
  assert.deepEqual(h.task().steps, ["Working on your request", "shell"]);
});

test("late post-tool events after Stop/Interrupt/SessionEnd cannot revive work", () => {
  for (const event of ["Stop", "Interrupt", "SessionEnd"]) {
    const h = setup();
    h.send("PreToolUse", { turn_id: "t1" });
    h.send(event, { turn_id: "t1" });
    const expected = event === "Stop" ? "finished" : "idle";
    h.send("PostToolUse", { turn_id: "t1" });
    h.send("PostToolUseFailure", { turn_id: "t1" });
    assert.equal(h.task().state, expected, event);
  }
});

test("SessionEnd still clears a stopped turn", () => {
  const h = setup();
  h.send("PreToolUse", { turn_id: "t1" });
  h.send("Stop", { turn_id: "t1" });
  h.send("SessionEnd", { turn_id: "t1" });
  assert.equal(h.task().name, "Codex");
  assert.equal(h.task().sessionCwd, null);
  assert.deepEqual(h.task().steps, []);
});

test("finishing one session cannot stop another session or erase its badge", () => {
  const h = setup();
  h.send("PreToolUse");
  h.send("Stop");
  const finishTimer = h.timer(5200);
  h.send("PreToolUse", { session_id: "c2", cwd: "C:\\work\\two", tool_name: "apply_patch" });
  h.send("SessionEnd");
  finishTimer();
  assert.equal(h.task().sessionId, "c2");
  assert.equal(h.task().name, "two");
  assert.equal(h.task().state, "working");
  assert.equal(h.task().pillBadge, null);
});

test("late events and old completion timer cannot overwrite a newer turn", () => {
  const h = setup();
  h.send("PreToolUse", { turn_id: "t1" });
  h.send("Stop", { turn_id: "t1" });
  const finishTimer = h.timer(5200);
  h.send("UserPromptSubmit", { turn_id: "t2" });
  h.send("PreToolUse", { turn_id: "t2", tool_name: "apply_patch" });
  for (const event of ["PostToolUse", "Stop", "PreToolUse"]) h.send(event, { turn_id: "t1" });
  finishTimer();
  assert.equal(h.task().state, "working");
  assert.equal(h.task().steps.at(-1), "apply_patch");
});

test("permission carries exact raw JSON and identifies its owning provider/session", () => {
  const h = setup();
  const exact = '{"id":9007199254740993123,"command":"echo hello","description":"reason"}';
  h.send("PermissionRequest", request("r1", { coucou_tool_input_json: exact, permission_mode: "default" }));
  assert.equal(State.pendingApproval.taskId, "integration_codex");
  assert.equal(State.pendingApproval.sessionId, "c1");
  assert.equal(State.pendingApproval.command, `shell\nWorking directory: C:\\work\\one\nSession: c1\nPermission mode: default\n${exact}`);
  assert.deepEqual(calls, [["ack", "r1"]]);
  h.send("PermissionRequest", request("r2", { coucou_agent: "claude", session_id: "a1" }));
  assert.deepEqual(calls.at(-1), ["decline", "r2"]);
  assert.equal(State.pendingApproval.requestId, "r1");
  assert.equal(h.task("claude").state, "idle");
});

test("a permission after successive synthetic activity turns opens the approval view", () => {
  const h = setup();
  State.focusId = "integration_codex";
  for (const turn_id of ["preview-1", "preview-2"]) {
    h.send("UserPromptSubmit", { turn_id });
    h.send("PreToolUse", { turn_id, tool_name: "Bash" });
  }
  h.send("PermissionRequest", request("preview-request-2", { turn_id: "preview-2" }));
  assert.equal(State.view, "approval");
  assert.equal(State.pendingApproval.requestId, "preview-request-2");
  assert.equal(h.task().state, "approval");
});

test("array/scalar MCP arguments remain exact and missing arguments decline", () => {
  for (const raw of ['[1,"two",null]', '"literal argument"', 'null', 'true']) {
    const h = setup();
    h.send("PermissionRequest", request("r1", { coucou_tool_input_json: raw }));
    assert.equal(State.pendingApproval.command, `shell\nWorking directory: C:\\work\\one\nSession: c1\n${raw}`);
  }
  const h = setup();
  h.send("PermissionRequest", request("r1", { coucou_tool_input_json: undefined }));
  assert.equal(State.pendingApproval, null);
  assert.deepEqual(calls, [["decline", "r1"]]);
});

test("background activity cannot steal a pending session's pill or approval", () => {
  const h = setup();
  State.focusId = "integration_codex";
  h.send("PermissionRequest", request());
  h.send("PreToolUse", { session_id: "c2", tool_name: "background" });
  h.send("Stop", { coucou_agent: "claude", session_id: "a1" });
  h.send("SessionEnd", { session_id: "c2" });
  assert.equal(h.task().sessionId, "c1");
  assert.equal(h.task().state, "approval");
  assert.equal(State.view, "approval");
  assert.equal(State.pendingApproval.requestId, "r1");
});

test("approval-ended and captured timeout affect only their exact request", () => {
  const h = setup();
  h.send("PermissionRequest", request("old"));
  const staleTimeout = h.timer(110000);
  h.approvalEnded("old");
  h.send("PermissionRequest", request("new", { session_id: "c2" }));
  h.approvalEnded("old");
  staleTimeout();
  assert.equal(State.pendingApproval.requestId, "new");
  assert.equal(h.task().state, "approval");
  assert.equal(State.isPinned, true);
  h.approvalEnded("new");
  assert.equal(State.pendingApproval, null);
  assert.equal(h.task().state, "working");
  assert.equal(State.isPinned, false);
});

test("ending/interruption of another session leaves pending approval intact", () => {
  const h = setup();
  h.send("PermissionRequest", request());
  h.send("Interrupt", { session_id: "c2" });
  assert.equal(State.pendingApproval.requestId, "r1");
  h.send("Interrupt");
  assert.equal(State.pendingApproval, null);
  assert.deepEqual(calls.at(-1), ["decline", "r1"]);
  assert.equal(h.task().state, "idle");
});

test("paused, unidentified Codex and generic permissions fall back without acknowledgment", () => {
  const h = setup();
  State.paused = true;
  h.send("PermissionRequest", request("paused"));
  State.paused = false;
  h.send("PermissionRequest", request("unknown", { coucou_agent: "other" }));
  h.send("PermissionRequest", request("missing", { session_id: undefined }));
  assert.deepEqual(calls, [["decline", "paused"], ["decline", "unknown"], ["decline", "missing"]]);
  assert.equal(State.pendingApproval, null);
});

test("valid external agents get distinct dynamic pills and keep their names", () => {
  const h = setup();
  for (const coucou_agent of ["gemini", "my-tool", "a".repeat(24)]) {
    h.send("UserPromptSubmit", { coucou_agent, prompt: "Plan the change" });
    h.send("PreToolUse", { coucou_agent, tool_name: "Read", tool_input: { path: "C:\\demo\\notes.md" } });
    const task = State.tasks.find(t => t.id === `agent_${coucou_agent}`);
    assert.equal(task.source, "agent");
    assert.equal(task.isIntegration, false);
    assert.equal(task.name, coucou_agent);
    assert.equal(agentLabel(task), coucou_agent);
    assert.equal(isCodingAgent(task), true);
    assert.deepEqual(task.steps, ["Plan the change", "Lit · notes.md"]);
    assert.equal(task.state, "working");
  }
  State.loadIntegrationTasks();
  assert.equal(State.tasks[0].id, "integration_claude");
  assert.ok(State.tasks.slice(1, 4).every(t => t.source === "agent"));
  assert.equal(State.tasks[4].id, "integration_codex");
  assert.equal(h.task().state, "idle");
  assert.equal(h.task("claude").state, "idle");
});

test("absent, invalid and reserved Claude tags preserve the upstream Claude fallback", () => {
  for (const coucou_agent of [undefined, "", "claude", "Bad-Name", "with space", "../name", "a".repeat(25)]) {
    const h = setup();
    h.send("PreToolUse", { coucou_agent, tool_name: "Read", tool_input: { path: "fallback.txt" } });
    assert.equal(h.task("claude").state, "working", String(coucou_agent));
    assert.equal(h.task("claude").steps.at(-1), "Lit · fallback.txt");
    assert.equal(h.task().state, "idle");
    assert.equal(State.tasks.some(t => t.source === "agent"), false);
  }
});

test("generic permissions decline without a card or a dynamic task", () => {
  const h = setup();
  h.send("PermissionRequest", request("generic", { coucou_agent: "gemini" }));
  assert.deepEqual(calls, [["decline", "generic"]]);
  assert.equal(State.pendingApproval, null);
  assert.equal(State.tasks.some(t => t.id === "agent_gemini"), false);
  h.send("PermissionRequest", request("native"));
  assert.equal(State.pendingApproval.taskId, "integration_codex");
  h.send("PermissionRequest", request("generic-2", { coucou_agent: "other-agent" }));
  assert.equal(State.pendingApproval.requestId, "native");
  assert.deepEqual(calls.at(-1), ["decline", "generic-2"]);
});

test("generic Stop removes its pill after 5.2 seconds and SessionEnd removes it immediately", () => {
  const h = setup();
  h.send("PreToolUse", { coucou_agent: "gemini" });
  h.send("Stop", { coucou_agent: "gemini", message: "Done" });
  assert.equal(State.tasks.find(t => t.id === "agent_gemini").state, "finished");
  h.timer(5200)();
  assert.equal(State.tasks.some(t => t.id === "agent_gemini"), false);
  h.send("PostToolUse", { coucou_agent: "gemini" });
  assert.equal(State.tasks.some(t => t.id === "agent_gemini"), false);
  h.send("SessionStart", { coucou_agent: "gemini" });
  State.setFocus("agent_gemini");
  h.send("SessionEnd", { coucou_agent: "gemini" });
  assert.equal(State.tasks.some(t => t.id === "agent_gemini"), false);
  assert.equal(State.focusId, "integration_claude");
  assert.ok(h.task());
});

test("a generic completion timer and old SessionEnd cannot remove newer activity", () => {
  const h = setup();
  h.send("PreToolUse", { coucou_agent: "gemini", session_id: "g1", turn_id: "t1" });
  h.send("Stop", { coucou_agent: "gemini", session_id: "g1", turn_id: "t1" });
  const oldTimer = h.timer(5200);
  h.send("PreToolUse", { coucou_agent: "gemini", session_id: "g2", turn_id: "t2" });
  oldTimer();
  h.send("SessionEnd", { coucou_agent: "gemini", session_id: "g1", turn_id: "t1" });
  const task = State.tasks.find(t => t.id === "agent_gemini");
  assert.equal(task.state, "working");
  assert.equal(task.sessionId, "g2");
});
