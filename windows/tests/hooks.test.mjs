// Claude Code hook events → island state (src/island/hooks.ts), driven through
// the real bridge: events come in the way Rust emits them, and what the island
// answers is read from the commands it invokes.

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { calls, emit, sent } from "./tauri.mjs";
import { registerHookHandlers } from "../src/island/hooks.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

const CLAUDE = "integration_claude";

/** What the handler asked the island to do, in order. */
let asked;
const island = {
  alert: (view) => asked.push(`alert:${view}`),
  setView: (view) => asked.push(`setView:${view}`),
  reveal: () => asked.push("reveal"),
  dropPin: () => asked.push("dropPin"),
};
registerHookHandlers(island);

const hook = (payload) => emit("hook", payload);
const task = (id = CLAUDE) => State.tasks.find((t) => t.id === id);
const seconds = (n) => mock.timers.tick(n * 1000);

beforeEach(() => {
  mock.timers.enable({ apis: ["setTimeout"] });
  asked = [];
  calls.length = 0;
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.view = "overview";
  State.paused = false;
  State.isPinned = false;
  State.pendingApproval = null;
  State.settings = { ...DEFAULT_SETTINGS };
  State.loadIntegrationTasks();
});

// hooks.ts keeps timer handles between events: the 110 s approval timeout, and
// one 5.2 s return to idle per pill that has stopped. Letting every timer fire
// before the reset clears them all; otherwise the next test would cancel a timer
// that belongs to a mock clock that no longer exists.
afterEach(() => {
  mock.timers.runAll();
  mock.timers.reset();
});

// ── Paused ────────────────────────────────────────────────────────────────────

test("a paused island hands a permission request straight back to the terminal", () => {
  State.paused = true;
  hook({ hook_event_name: "PermissionRequest", request_id: "r1", tool_name: "Bash" });
  assert.deepEqual(sent("approval_decline"), [{ requestId: "r1" }]);
  assert.deepEqual(sent("approval_ack"), []);
  assert.equal(State.pendingApproval, null);
  assert.equal(task().state, "idle");
});

test("a paused island ignores every other event", () => {
  State.paused = true;
  hook({ hook_event_name: "SessionStart", cwd: "C:\\Users\\me\\proj" });
  assert.equal(task().name, "VS Code");
  assert.deepEqual(asked, []);
  assert.deepEqual(calls, []);
});

// ── Session and work events ───────────────────────────────────────────────────

test("a session names the pill after its folder and reveals the island", () => {
  hook({ hook_event_name: "SessionStart", cwd: "C:\\Users\\me\\proj\\" });
  assert.equal(task().name, "proj");
  assert.equal(task().sessionCwd, "C:\\Users\\me\\proj\\");
  assert.deepEqual(asked, ["reveal"]);
});

test("known project folders get their display name, and no folder is a Session", () => {
  hook({ hook_event_name: "SessionStart", cwd: "/home/me/notch-buddy" });
  assert.equal(task().name, "Notch Buddy");
  hook({ hook_event_name: "SessionStart" });
  assert.equal(task().name, "Session");
});

test("a work event leaves an island that is already showing where it is", () => {
  State.mode = "compact";
  hook({ hook_event_name: "SessionStart", cwd: "/p" });
  assert.deepEqual(asked, []);
});

test("a submitted prompt shows as thinking, with the prompt as the step", () => {
  hook({ hook_event_name: "UserPromptSubmit", cwd: "/p", prompt: "x".repeat(80) });
  assert.equal(task().state, "thinking");
  assert.deepEqual(task().steps, ["x".repeat(60)]);
  hook({ hook_event_name: "UserPromptSubmit", cwd: "/p", message: "older field" });
  assert.equal(task().steps.at(-1), "older field");
});

test("a tool call shows as working, labelled with what it acts on", () => {
  const step = (tool_name, tool_input) => {
    hook({ hook_event_name: "PreToolUse", cwd: "/p", tool_name, tool_input });
    return task().steps.at(-1);
  };
  assert.equal(step("Bash", { command: "npm run build" }), "Runs · npm run build");
  assert.equal(task().state, "working");
  assert.equal(step("Bash", { command: "c".repeat(50) }), `Runs · ${"c".repeat(40)}`);
  assert.equal(step("Read", { file_path: "C:\\Users\\me\\proj\\.env" }), "Reads · .env");
  assert.equal(step("Grep", { pattern: "x", path: "src/island/" }), "Searches · island");
  assert.equal(step("WebSearch", { query: "tauri" }), "Searches the web · tauri");
  assert.equal(step("Foo", {}), "Foo");
  assert.equal(step(undefined, undefined), "Tool");
});

test("only the last 20 steps are kept", () => {
  for (let i = 0; i < 25; i++) {
    hook({ hook_event_name: "PreToolUse", cwd: "/p", tool_name: "Bash", tool_input: { command: `c${i}` } });
  }
  assert.equal(task().steps.length, 20);
  assert.equal(task().steps.at(-1), "Runs · c24");
  assert.equal(task().stepIndex, 19);
});

test("a failed tool call and subagents leave their own steps", () => {
  hook({ hook_event_name: "PostToolUseFailure" });
  hook({ hook_event_name: "SubagentStart" });
  hook({ hook_event_name: "SubagentStop" });
  assert.deepEqual(task().steps, ["⚠ failed", "+ subagent", "• subagent done"]);
  assert.equal(task().state, "working");
});

test("a notification is a rate limit, a question, or nothing", () => {
  hook({ hook_event_name: "Notification", message: "Just so you know." });
  assert.equal(task().state, "idle");
  hook({ hook_event_name: "Notification", message: "Shall I continue?" });
  assert.equal(task().state, "question");
  assert.deepEqual(task().steps, ["Shall I continue?"]);
  hook({ hook_event_name: "Notification", message: "Usage Rate Limit reached" });
  assert.equal(task().state, "ratelimit");
  hook({ hook_event_name: "Notification", message: "Limite d'utilisation atteinte" });
  assert.equal(task().state, "ratelimit");
});

test("an unknown event changes nothing", () => {
  hook({ hook_event_name: "SomethingNew", cwd: "/p" });
  assert.equal(task().state, "idle");
  assert.equal(task().name, "VS Code");
  assert.deepEqual(asked, []);
});

// ── Stop ──────────────────────────────────────────────────────────────────────

test("a finished session opens the finished view, then goes idle after 5.2 s", () => {
  hook({ hook_event_name: "Stop", message: "done" });
  assert.equal(task().state, "finished");
  assert.deepEqual(task().steps, ["done"]);
  assert.deepEqual(asked, ["alert:finished"]);
  seconds(5.1);
  assert.equal(task().state, "finished");
  seconds(0.1);
  assert.equal(task().state, "idle");
});

test("an alert on an island that is already open only switches its view", () => {
  State.mode = "expanded";
  hook({ hook_event_name: "Stop" });
  assert.deepEqual(asked, ["setView:finished"]);
});

test("a session finishing behind another pill only badges its own, for 5.2 s", () => {
  State.setFocus("integration_n8n");
  hook({ hook_event_name: "Stop" });
  assert.deepEqual(asked, []);
  assert.equal(task().pillBadge, "finished");
  seconds(5.2);
  assert.equal(task().pillBadge, null);
});

test("a failed stop shows the error view, or the error badge behind another pill", () => {
  hook({ hook_event_name: "StopFailure" });
  assert.equal(task().state, "error");
  assert.deepEqual(asked, ["alert:error"]);
  State.setFocus("integration_n8n");
  hook({ hook_event_name: "StopFailure" });
  assert.equal(task().pillBadge, "error");
});

test("the end of a session puts the pill back as it was", () => {
  hook({ hook_event_name: "PreToolUse", cwd: "/p/proj", tool_name: "Bash", tool_input: { command: "ls" } });
  hook({ hook_event_name: "SessionEnd", cwd: "/p/proj" });
  assert.equal(task().state, "idle");
  assert.equal(task().name, "VS Code");
  assert.deepEqual(task().steps, []);
});

// Stop arms a 5.2 s timer that puts the pill back to idle. It used to be armed
// and forgotten, so a prompt submitted inside that window showed as thinking and
// was then put back to idle mid-work when the old timer fired.
test("a new turn within 5.2 s of a stop is not put back to idle", () => {
  hook({ hook_event_name: "Stop" });
  seconds(1);
  hook({ hook_event_name: "UserPromptSubmit", prompt: "next" });
  seconds(5);
  assert.equal(task().state, "thinking");
});

// ── Other agents ──────────────────────────────────────────────────────────────

test("a tagged agent gets its own pill next to Claude Code's", () => {
  hook({ hook_event_name: "PreToolUse", cwd: "/p/proj", coucou_agent: "gemini", tool_name: "Bash", tool_input: { command: "ls" } });
  assert.equal(State.tasks[0].id, CLAUDE);
  assert.equal(State.tasks[1].id, "agent_gemini");
  const agent = task("agent_gemini");
  assert.equal(agent.name, "Gemini CLI");
  assert.equal(agent.source, "agent");
  assert.equal(agent.state, "working");
  assert.deepEqual(agent.steps, ["Runs · ls"]);
  assert.match(agent.color, /^#[0-9A-F]{6}$/);
  // Claude Code's own pill is not the one that moved.
  assert.equal(task().name, "VS Code");
  assert.equal(task().state, "idle");
});

test("an invalid or reserved agent tag falls back to the Claude Code pill", () => {
  for (const tag of ["claude", "Gemini", "has space", "a".repeat(25), ""]) {
    hook({ hook_event_name: "SessionStart", cwd: "/p/proj", coucou_agent: tag });
  }
  assert.equal(State.tasks.some((t) => t.id.startsWith("agent_")), false);
  assert.equal(task().name, "proj");
});

test("an agent's pill goes away when its session ends, or 5.2 s after it stops", () => {
  hook({ hook_event_name: "SessionStart", coucou_agent: "gemini" });
  hook({ hook_event_name: "SessionEnd", coucou_agent: "gemini" });
  assert.equal(task("agent_gemini"), undefined);

  hook({ hook_event_name: "SessionStart", coucou_agent: "codex" });
  hook({ hook_event_name: "Stop", coucou_agent: "codex" });
  assert.equal(task("agent_codex").state, "finished");
  seconds(5.2);
  assert.equal(task("agent_codex"), undefined);
});

test("an agent's permission request is declined, never shown as Claude Code's", () => {
  for (const agent of ["gemini", "antigravity", "cursor", "opencode", "amp", "hermes", "my-tool"]) {
    calls.length = 0;
    hook({ hook_event_name: "PermissionRequest", request_id: "r1", coucou_agent: agent, tool_name: "Bash" });
    assert.deepEqual(sent("approval_decline"), [{ requestId: "r1" }], agent);
    assert.deepEqual(sent("approval_ack"), [], agent);
    assert.equal(State.pendingApproval, null, agent);
  }
});

test("Codex, Copilot CLI and Muse Code get the card on their own pill", () => {
  for (const agent of ["codex", "copilot", "muse"]) {
    State.pendingApproval = null;
    State.focusId = CLAUDE;
    calls.length = 0;
    asked = [];
    hook({
      hook_event_name: "PermissionRequest", request_id: `r-${agent}`, session_id: "s1",
      coucou_agent: agent, tool_name: "Bash", tool_input: { command: "npm publish" },
    });
    const id = `agent_${agent}`;
    assert.deepEqual(State.pendingApproval, {
      requestId: `r-${agent}`, sessionId: "s1", pillId: id, tool: "Bash", command: "Bash · npm publish",
    });
    assert.deepEqual(sent("approval_ack"), [{ requestId: `r-${agent}` }]);
    assert.deepEqual(sent("approval_decline"), []);
    // The same card as Claude Code's: it comes up and its pill comes to the
    // front, even from behind Claude Code's pill (unified with Mac #120).
    assert.equal(task(id).state, "approval");
    assert.equal(State.focusId, id);
    assert.deepEqual(asked, ["alert:approval"]);
    // Claude Code's pill is untouched, and comes back once the card goes.
    assert.equal(task().state, "idle");
    assert.equal(task().pillBadge ?? null, null);
    State.endApproval();
    assert.equal(State.focusId, CLAUDE);
  }
});

test("an agent's turn ending takes its card down and gives the front back", () => {
  State.setFocus("integration_n8n");
  hook({ hook_event_name: "PermissionRequest", request_id: "r1", session_id: "s1", coucou_agent: "codex", tool_name: "Bash" });
  assert.equal(State.focusId, "agent_codex");
  asked = [];
  hook({ hook_event_name: "Stop", session_id: "s1", coucou_agent: "codex" });
  assert.equal(State.pendingApproval, null);
  assert.equal(State.focusId, "integration_n8n");
  // The stop no longer has the front: its pill is badged, the view is not taken.
  assert.equal(task("agent_codex").pillBadge, "finished");
  assert.ok(!asked.includes("alert:finished"));
});

test("an agent's card comes up at once when its pill has the focus", () => {
  hook({ hook_event_name: "SessionStart", session_id: "s1", coucou_agent: "codex" });
  State.setFocus("agent_codex");
  asked = [];
  hook({ hook_event_name: "PermissionRequest", request_id: "r1", session_id: "s1", coucou_agent: "codex", tool_name: "Bash" });
  assert.deepEqual(asked, ["alert:approval"]);
});

test("only Claude Code's questions become a question card", () => {
  hook({
    hook_event_name: "PermissionRequest", request_id: "r1", session_id: "s1", coucou_agent: "codex",
    tool_name: "AskUserQuestion",
    tool_input: { questions: [{ question: "Which?", options: [{ label: "A" }, { label: "B" }] }] },
  });
  assert.equal(State.pendingApproval.questions, undefined);
  assert.equal(task("agent_codex").state, "approval");
});

test("the end of the turn takes a waiting card down and releases the relay", () => {
  for (const end of ["Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt"]) {
    State.pendingApproval = null;
    calls.length = 0;
    hook({ hook_event_name: "PermissionRequest", request_id: "r1", session_id: "s1", coucou_agent: "codex", tool_name: "Bash" });
    // Another session's turn ending changes nothing.
    hook({ hook_event_name: end, session_id: "other", coucou_agent: "codex" });
    assert.equal(State.pendingApproval?.requestId, "r1", end);
    hook({ hook_event_name: end, session_id: "s1", coucou_agent: "codex" });
    assert.equal(State.pendingApproval, null, end);
    assert.deepEqual(sent("approval_decline"), [{ requestId: "r1" }], end);
    mock.timers.runAll();
  }
});

test("Codex's Interrupt puts its pill back to idle", () => {
  hook({ hook_event_name: "UserPromptSubmit", session_id: "s1", coucou_agent: "codex", prompt: "go" });
  assert.equal(task("agent_codex").state, "thinking");
  hook({ hook_event_name: "Interrupt", session_id: "s1", coucou_agent: "codex" });
  assert.equal(task("agent_codex").state, "idle");
});

test("Hermes says where a gateway session comes from", () => {
  hook({ hook_event_name: "SessionStart", coucou_agent: "hermes", platform: "telegram" });
  assert.deepEqual(task("agent_hermes").steps, ["Telegram"]);
  hook({ hook_event_name: "SessionEnd", coucou_agent: "hermes" });
  hook({ hook_event_name: "SessionStart", coucou_agent: "hermes", platform: "cli" });
  assert.deepEqual(task("agent_hermes").steps, []);
});

test("an agent's last words show when it stops", () => {
  hook({ hook_event_name: "SessionStart", coucou_agent: "hermes" });
  hook({ hook_event_name: "Stop", coucou_agent: "hermes", last_assistant_message: "All done, tests pass." });
  assert.deepEqual(task("agent_hermes").steps, ["All done, tests pass."]);
});

test("a Claude Desktop session gets the Claude Desktop pill and can answer approvals (Issue #328)", () => {
  hook({ hook_event_name: "SessionStart", cwd: "C:\\p\\proj", session_id: "d1", coucou_agent: "claude-desktop" });
  const desktop = task("agent_claude-desktop");
  assert.equal(desktop.color, "#D97757");
  assert.equal(desktop.sessionId, "d1");
  assert.equal(task().state, "idle");
  // Permission requests are acknowledged and shown on its pill
  hook({ hook_event_name: "PermissionRequest", request_id: "r1", coucou_agent: "claude-desktop", tool_name: "Bash", tool_input: { command: "npm test" } });
  assert.deepEqual(sent("approval_ack"), [{ requestId: "r1" }]);
  assert.equal(task("agent_claude-desktop").state, "approval");
});

// ── Main tool and Cursor ──────────────────────────────────────────────────────

test("Claude Code in Cursor's terminal works on the Cursor pill, made for the session", () => {
  hook({ hook_event_name: "SessionStart", cwd: "/p/proj", session_id: "s9", term_editor: "cursor" });
  hook({ hook_event_name: "PreToolUse", cwd: "/p/proj", term_editor: "cursor", tool_name: "Bash", tool_input: { command: "ls" } });
  assert.equal(task("agent_cursor").state, "working");
  assert.equal(task("agent_cursor").sessionId, "s9");
  assert.equal(task().state, "idle");
  hook({ hook_event_name: "SessionEnd", term_editor: "cursor" });
  assert.equal(task("agent_cursor"), undefined);
});

test("with another main tool, Claude Code's pill comes for the session and goes after", () => {
  State.settings.mainPill = "agent_codex";
  State.loadIntegrationTasks();
  assert.equal(task(), undefined);
  hook({ hook_event_name: "SessionStart", cwd: "/p/proj" });
  assert.equal(task().name, "proj");
  assert.equal(State.tasks[0].id, "agent_codex");
  hook({ hook_event_name: "SessionEnd" });
  assert.equal(task(), undefined);
});

test("the main tool's agent sessions put it back as it was, never take it away", () => {
  State.settings.mainPill = "agent_codex";
  State.loadIntegrationTasks();
  hook({ hook_event_name: "SessionStart", coucou_agent: "codex" });
  hook({ hook_event_name: "Stop", coucou_agent: "codex" });
  seconds(5.2);
  assert.equal(task("agent_codex").state, "idle");
  assert.equal(task("agent_codex").name, "Codex");
});

// ── Permission requests ───────────────────────────────────────────────────────

const ask = (request_id, extra = {}) =>
  hook({
    hook_event_name: "PermissionRequest",
    request_id,
    session_id: "s1",
    cwd: "C:\\Users\\me\\proj",
    tool_name: "Write",
    tool_input: { file_path: " C:\\Users\\me\\proj\\.env ", content: "SECRET=1" },
    ...extra,
  });

test("a permission request puts the card up, says exactly what it authorises, and acknowledges", () => {
  ask("r1");
  assert.deepEqual(State.pendingApproval, {
    requestId: "r1",
    sessionId: "s1",
    pillId: CLAUDE,
    tool: "Write",
    command: "Write · C:\\Users\\me\\proj\\.env",
  });
  assert.deepEqual(sent("approval_ack"), [{ requestId: "r1" }]);
  assert.deepEqual(sent("approval_decline"), []);
  assert.equal(task().state, "approval");
  assert.equal(task().name, "proj");
  assert.equal(State.isPinned, true);
  assert.deepEqual(asked, ["alert:approval"]);
});

test("the card names the most specific thing the tool carries", () => {
  const target = (tool_name, tool_input) => {
    State.pendingApproval = null;
    ask("r1", { tool_name, tool_input });
    return State.pendingApproval.command;
  };
  assert.equal(target("Bash", { command: "rm -rf build", file_path: "x" }), "Bash · rm -rf build");
  assert.equal(target("WebFetch", { url: "https://example.com" }), "WebFetch · https://example.com");
  assert.equal(target("Task", { prompt: "do it" }), "Task · do it");
  assert.equal(target("Odd", { command: "   ", count: 3 }), "Odd");
  assert.equal(target(undefined, undefined), "Tool");
});

test("a request behind another pill comes to the front, and that pill comes back after (Mac #120)", () => {
  State.setFocus("integration_n8n");
  ask("r1");
  assert.deepEqual(asked, ["alert:approval"]);
  assert.equal(State.focusId, CLAUDE);
  assert.deepEqual(sent("approval_ack"), [{ requestId: "r1" }]);
  State.endApproval();
  assert.equal(State.focusId, "integration_n8n");
  assert.equal(State.isPinned, false);
  assert.equal(task().state, "working");
});

test("the pill you were on comes back after a withdrawn card too", () => {
  State.setFocus("integration_n8n");
  ask("r1");
  seconds(110);
  assert.equal(State.pendingApproval, null);
  assert.equal(State.focusId, "integration_n8n");
});

test("a pill picked while the card was up keeps the front after the answer", () => {
  State.setFocus("integration_n8n");
  ask("r1");
  State.setFocus("integration_github");
  State.endApproval();
  assert.equal(State.focusId, "integration_github");
});

test("the card shows when the island is already open, and is what it reopens on", () => {
  State.mode = "expanded";
  ask("r1");
  assert.deepEqual(asked, ["alert:approval"]);
  assert.equal(State.defaultView(), "approval");
  State.endApproval();
  assert.equal(State.defaultView(), "overview");
});

test("a question is what the island reopens on while it waits", () => {
  ask("r1", {
    tool_name: "AskUserQuestion",
    tool_input: { questions: [{ question: "Which?", options: [{ label: "A" }, { label: "B" }] }] },
  });
  assert.equal(State.defaultView(), "question");
});

test("a finished or failed session behind a waiting card only badges its pill", () => {
  State.settings.activeIntegrations = ["agent_gemini"];
  State.loadIntegrationTasks();
  hook({ hook_event_name: "SessionStart", coucou_agent: "gemini" });
  ask("r1");
  asked = [];
  State.focusId = "agent_gemini";
  hook({ hook_event_name: "Stop", coucou_agent: "gemini" });
  hook({ hook_event_name: "StopFailure", coucou_agent: "gemini" });
  assert.deepEqual(asked, []);
  assert.equal(task("agent_gemini").pillBadge, "error");
});

test("a request from Claude Code in Cursor's terminal goes on the Cursor pill", () => {
  ask("r1", { term_editor: "cursor" });
  assert.equal(State.pendingApproval.pillId, "agent_cursor");
  assert.equal(task("agent_cursor").state, "approval");
  assert.equal(task("agent_cursor").name, "proj");
  assert.equal(State.focusId, "agent_cursor");
  assert.equal(task().state, "idle");
});

test("a second request never replaces the card: it goes back to the terminal", () => {
  ask("r1");
  ask("r2", { tool_name: "Bash", tool_input: { command: "ls" } });
  assert.equal(State.pendingApproval.requestId, "r1");
  assert.equal(State.pendingApproval.tool, "Write");
  assert.deepEqual(sent("approval_decline"), [{ requestId: "r2" }]);
  assert.deepEqual(sent("approval_ack"), [{ requestId: "r1" }]);
});

test("the same request arriving twice is acknowledged again, not declined", () => {
  ask("r1");
  ask("r1");
  assert.deepEqual(sent("approval_decline"), []);
  assert.deepEqual(sent("approval_ack"), [{ requestId: "r1" }, { requestId: "r1" }]);
});

test("an unanswered card is withdrawn after 110 s", () => {
  ask("r1");
  State.view = "approval";
  asked = [];
  seconds(109);
  assert.notEqual(State.pendingApproval, null);
  seconds(1);
  assert.equal(State.pendingApproval, null);
  assert.equal(State.isPinned, false);
  assert.equal(task().state, "working");
  assert.equal(task().pillBadge, null);
  assert.deepEqual(asked, ["dropPin", "setView:overview"]);
});

test("a card answered in time leaves nothing for the 110 s timer to undo", () => {
  ask("r1");
  // What the Allow button does to the state before the timer fires.
  State.pendingApproval = null;
  State.updateTask(CLAUDE, "working");
  asked = [];
  seconds(110);
  assert.deepEqual(asked, []);
  assert.equal(task().state, "working");
});

// ── What takes over from a stop ───────────────────────────────────────────────
// Stop arms a 5.2 s return to idle. A handler that writes a newer state cancels
// it; one that writes none leaves it alone, or the pill would stay finished.

/** A stop, then `event` one second later, then enough time for the timer. */
const afterStop = (event, extra = {}) => {
  hook({ hook_event_name: "Stop", ...extra });
  seconds(1);
  if (typeof event === "function") event();
  else hook({ ...event, ...extra });
  seconds(5);
};

test("a tool call within 5.2 s of a stop is not put back to idle", () => {
  afterStop({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: "ls" } });
  assert.equal(task().state, "working");
});

test("a tool result within 5.2 s of a stop is not put back to idle", () => {
  afterStop({ hook_event_name: "PostToolUse" });
  assert.equal(task().state, "working");
});

test("a failed tool call within 5.2 s of a stop keeps working, and its step", () => {
  afterStop({ hook_event_name: "PostToolUseFailure" });
  assert.equal(task().state, "working");
  assert.equal(task().steps.at(-1), "⚠ failed");
});

test("a permission request within 5.2 s of a stop keeps its card", () => {
  afterStop(() => ask("r1"));
  assert.equal(task().state, "approval");
  assert.equal(State.pendingApproval.requestId, "r1");
});

test("a permission request behind another pill keeps the front past the stop timer", () => {
  State.setFocus("integration_n8n");
  afterStop(() => ask("r1"));
  assert.equal(task().state, "approval");
  assert.equal(State.focusId, CLAUDE);
  assert.equal(State.pendingApproval.requestId, "r1");
});

test("a rate limit within 5.2 s of a stop stays a rate limit", () => {
  afterStop({ hook_event_name: "Notification", message: "Usage rate limit reached" });
  assert.equal(task().state, "ratelimit");
});

test("a question within 5.2 s of a stop stays a question", () => {
  afterStop({ hook_event_name: "Notification", message: "Shall I continue?" });
  assert.equal(task().state, "question");
});

test("a failed stop within 5.2 s of a stop stays an error, badge included", () => {
  afterStop({ hook_event_name: "StopFailure" });
  assert.equal(task().state, "error");
  State.setFocus("integration_n8n");
  afterStop({ hook_event_name: "StopFailure" });
  assert.equal(task().state, "error");
  assert.equal(task().pillBadge, "error");
});

test("a new turn behind another pill drops the finished badge straight away", () => {
  State.setFocus("integration_n8n");
  hook({ hook_event_name: "Stop" });
  assert.equal(task().pillBadge, "finished");
  hook({ hook_event_name: "UserPromptSubmit", prompt: "next" });
  assert.equal(task().pillBadge, null);
});

test("an agent that goes back to work within 5.2 s of its stop keeps its pill", () => {
  afterStop(
    { hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: "ls" } },
    { coucou_agent: "gemini" },
  );
  assert.equal(task("agent_gemini").state, "working");
});

test("an agent's session ending takes its stop timer with it", () => {
  hook({ hook_event_name: "Stop", coucou_agent: "gemini" });
  hook({ hook_event_name: "SessionEnd", coucou_agent: "gemini" });
  hook({ hook_event_name: "SessionStart", coucou_agent: "gemini" });
  seconds(5.2);
  assert.notEqual(task("agent_gemini"), undefined);
});

test("a second stop restarts the 5.2 s: the first stop's timer no longer counts", () => {
  hook({ hook_event_name: "Stop" });
  seconds(3);
  hook({ hook_event_name: "Stop" });
  // 5.2 s after the first stop.
  seconds(2.2);
  assert.equal(task().state, "finished");
  // 5.1 s, then 5.2 s, after the second.
  seconds(2.9);
  assert.equal(task().state, "finished");
  seconds(0.1);
  assert.equal(task().state, "idle");
});

test("the end of a Claude Code session leaves no stop timer behind", () => {
  State.setFocus("integration_n8n");
  hook({ hook_event_name: "Stop", cwd: "/p/proj" });
  hook({ hook_event_name: "SessionEnd", cwd: "/p/proj" });
  assert.equal(task().state, "idle");
  assert.equal(task().pillBadge, null);
  // Whatever the pill shows next is not the stop's to undo. Set directly, the
  // way the Allow button does, because a hook event would cancel the timer itself.
  State.updateTask(CLAUDE, "working");
  State.setPillBadge(CLAUDE, "error");
  seconds(5.2);
  assert.equal(task().state, "working");
  assert.equal(task().pillBadge, "error");
});

test("one pill going back to work leaves another pill's stop timer running", () => {
  hook({ hook_event_name: "Stop", coucou_agent: "gemini" });
  afterStop({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: "ls" } });
  assert.equal(task().state, "working");
  assert.equal(task("agent_gemini"), undefined);
});

for (const [what, event] of [
  ["a session start", { hook_event_name: "SessionStart", cwd: "/p" }],
  ["a subagent starting", { hook_event_name: "SubagentStart" }],
  ["a subagent finishing", { hook_event_name: "SubagentStop" }],
  ["a notification that is neither a limit nor a question", { hook_event_name: "Notification", message: "Just so you know." }],
  ["an unknown event", { hook_event_name: "SomethingNew" }],
]) {
  test(`${what} within 5.2 s of a stop still lets the pill go idle`, () => {
    hook({ hook_event_name: "Stop" });
    seconds(1);
    hook(event);
    seconds(4.1);
    assert.equal(task().state, "finished");
    seconds(0.1);
    assert.equal(task().state, "idle");
  });
}

test("a declined permission request leaves the stop timer running", () => {
  // An agent's request is declined without a card.
  afterStop(
    { hook_event_name: "PermissionRequest", request_id: "r1", tool_name: "Bash" },
    { coucou_agent: "gemini" },
  );
  assert.equal(task("agent_gemini"), undefined);
  // So is a second request while a card is already up.
  ask("r1");
  afterStop(() => ask("r2"));
  assert.deepEqual(sent("approval_decline"), [{ requestId: "r1" }, { requestId: "r2" }]);
  assert.equal(task().state, "idle");
});
