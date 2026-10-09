// Claude Code hook events → island state (src/island/hooks.ts), driven through
// the real bridge: events come in the way Rust emits them, and what the island
// answers is read from the commands it invokes.

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { calls, emit, sent } from "./tauri.mjs";
import { registerHookHandlers } from "../src/island/hooks.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";
import { Sound } from "../src/core/sound.ts";
import { KNOWN_AGENTS } from "../src/island/agents.ts";
import { Island } from "../src/island/island.ts";
import { BotEngine, hexToRGB } from "../src/mochi/engine.ts";
import { Ticker } from "../src/views/ticker.ts";
import { buildFinished } from "../src/views/views.ts";
import { installFakeDom } from "./fakedom.mjs";

const CLAUDE = "integration_claude";

/** What the handler asked the island to do, in order. */
let asked;
let autoPopupAllowed;
const island = {
  alert: (view) => asked.push(`alert:${view}`),
  setView: (view) => { asked.push(`setView:${view}`); State.view = view; },
  reveal: () => asked.push("reveal"),
  dropPin: () => asked.push("dropPin"),
  collapse: () => asked.push("collapse"),
  hide: () => asked.push("hide"),
  canAutoPopup: () => autoPopupAllowed && !State.pendingApproval && !State.isPinned &&
    !State.fileDragOver && (State.mode !== "expanded" || State.view === "overview" ||
      (State.view === "finished" && State.finishedPopup !== null)),
};
registerHookHandlers(island);

const hook = (payload) => emit("hook", payload);
const task = (id = CLAUDE) => State.tasks.find((t) => t.id === id);
const seconds = (n) => mock.timers.tick(n * 1000);

beforeEach(() => {
  mock.timers.enable({ apis: ["setTimeout"] });
  asked = [];
  autoPopupAllowed = true;
  calls.length = 0;
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.view = "overview";
  State.paused = false;
  State.isPinned = false;
  State.pendingApproval = null;
  State.finishedPopup = null;
  State.chatHistory = [];
  State.stateOverride = null;
  State.settings = { ...DEFAULT_SETTINGS };
  State.loadIntegrationTasks();
});

// hooks.ts keeps timer handles between events: the 110 s approval timeout, and
// one 5.2 s return to idle per pill that has stopped. Letting every timer fire
// before the reset clears them all; otherwise the next test would cancel a timer
// that belongs to a mock clock that no longer exists.
afterEach(() => {
  // Tick through chained answer popups as well as their 5.2 s cleanup timers.
  mock.timers.tick(200_000);
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

test("a submitted prompt shows as thinking without putting user input in monitoring steps", () => {
  hook({ hook_event_name: "UserPromptSubmit", cwd: "/p", prompt: "x".repeat(80) });
  assert.equal(task().state, "thinking");
  assert.deepEqual(task().steps, ["…"]);
  hook({ hook_event_name: "UserPromptSubmit", cwd: "/p", message: "older field" });
  assert.deepEqual(task().steps, ["…", "…"]);
});

test("a Codex prompt replaces the focused finished card with current monitoring", () => {
  hook({ hook_event_name: "SessionStart", coucou_agent: "codex", session_id: "s" });
  State.setFocus("agent_codex");
  State.mode = "expanded";
  hook({ hook_event_name: "Stop", coucou_agent: "codex", last_assistant_message: "Previous answer." });
  State.view = "finished";
  assert.equal(task("agent_codex").finalLine, "Previous answer.");
  asked = [];
  const payload = Object.freeze({ hook_event_name: "UserPromptSubmit", coucou_agent: "codex",
    session_id: "s", turn_id: "new-turn", cwd: "C:\\project", prompt: "Private user input" });
  hook(payload);
  const agent = task("agent_codex");
  assert.equal(agent.state, "thinking");
  assert.equal(agent.finalLine, null);
  assert.equal(agent.pillBadge ?? null, null);
  assert.equal(agent.steps.at(-1), "…");
  assert.equal(agent.sessionId, "s");
  assert.equal(agent.sessionCwd, "C:\\project");
  assert.deepEqual(asked, ["setView:overview"]);
  // The display handler never strips fields needed earlier by relay/Auto-Launch.
  assert.equal(payload.hook_event_name, "UserPromptSubmit");
  assert.equal(payload.turn_id, "new-turn");
  assert.equal(payload.prompt, "Private user input");
  seconds(6);
  assert.equal(task("agent_codex").state, "thinking");
});

test("two rapid Codex prompts never enter ticker frames and the latest answer still displays", () => {
  installFakeDom();
  hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "codex", session_id: "s", turn_id: "t0", prompt: "First private prompt" });
  State.setFocus("agent_codex");
  hook({ hook_event_name: "Stop", coucou_agent: "codex", last_assistant_message: "Previous answer." });
  const ticker = new Ticker();
  ticker.sync(task("agent_codex"));
  assert.ok(ticker.el.textContent.includes("Previous answer."));
  for (const [turn_id, prompt] of [["t1", "Private prompt one"], ["t2", "Private prompt two"]]) {
    hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "codex", session_id: "s", turn_id, prompt });
    ticker.sync(task("agent_codex"));
  }
  for (let frame = 0; frame <= 1000; frame += 20) {
    ticker.tick(frame);
    assert.ok(!ticker.el.textContent.includes("Private prompt"));
    assert.ok(!ticker.el.textContent.includes("First private prompt"));
  }
  assert.equal(task("agent_codex").state, "thinking");
  assert.equal(task("agent_codex").finalLine, null);
  seconds(6);
  assert.equal(task("agent_codex").state, "thinking");
  hook({ hook_event_name: "Stop", coucou_agent: "codex", last_assistant_message: "Latest **agent answer**." });
  ticker.sync(task("agent_codex"));
  for (let frame = 1100; frame <= 1600; frame += 20) ticker.tick(frame);
  assert.equal(task("agent_codex").state, "finished");
  assert.equal(task("agent_codex").finalLine, "Latest agent answer.");
  assert.ok(ticker.el.textContent.includes("Latest agent answer."));
  assert.ok(!ticker.el.textContent.includes("Private prompt"));
});

test("a new prompt updates its pill without replacing another pill's finished card", () => {
  State.mode = "expanded";
  hook({ hook_event_name: "Stop", last_assistant_message: "Claude's answer." });
  State.view = "finished";
  asked = [];
  hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "codex", prompt: "Private prompt" });
  assert.deepEqual(asked, []);
  assert.equal(task().state, "finished");
  assert.equal(task().finalLine, "Claude's answer.");
  assert.equal(task("agent_codex").state, "thinking");
});

test("a prompt on a folded finished island updates monitoring without reopening the card", () => {
  hook({ hook_event_name: "SessionStart", coucou_agent: "codex" });
  State.setFocus("agent_codex");
  hook({ hook_event_name: "Stop", coucou_agent: "codex", last_assistant_message: "Previous answer." });
  State.mode = "compact";
  State.view = "finished";
  asked = [];
  hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "codex", prompt: "Private input" });
  assert.equal(task("agent_codex").state, "thinking");
  assert.equal(task("agent_codex").finalLine, null);
  assert.equal(State.mode, "compact");
  assert.deepEqual(asked, []);
});

test("monitoring prompts preserve the active island Chat, its history and state override", () => {
  hook({ hook_event_name: "SessionStart", coucou_agent: "codex" });
  State.setFocus("agent_codex");
  State.mode = "expanded";
  State.view = "prompt";
  State.stateOverride = "thinking";
  const history = [{ id: 1, role: "user", content: "Island chat input" },
    { id: 2, role: "assistant", content: "Island chat reply" }];
  State.chatHistory = structuredClone(history);
  asked = [];
  hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "codex", prompt: "Codex CLI private input" });
  assert.equal(State.view, "prompt");
  assert.equal(State.stateOverride, "thinking");
  assert.deepEqual(State.chatHistory, history);
  assert.deepEqual(asked, []);
  assert.deepEqual(task("agent_codex").steps, ["…"]);
});

test("all agents sharing the handler keep user input out and still display their answers", () => {
  for (const coucou_agent of [undefined, ...Object.keys(KNOWN_AGENTS), "my-tool"]) {
    const id = coucou_agent ? `agent_${coucou_agent}` : CLAUDE;
    hook({ hook_event_name: "UserPromptSubmit", coucou_agent, prompt: "Private input", message: "Private legacy input" });
    assert.equal(task(id).state, "thinking", id);
    assert.deepEqual(task(id).steps, ["…"], id);
    hook({ hook_event_name: "Stop", coucou_agent, message: "Agent answer." });
    assert.equal(task(id).finalLine, "Agent answer.", id);
    assert.equal(task(id).state, "finished", id);
    hook({ hook_event_name: "UserPromptSubmit", coucou_agent, message: "Next private legacy input" });
    assert.equal(task(id).finalLine, null, id);
    assert.equal(task(id).state, "thinking", id);
    assert.equal(task(id).pillBadge ?? null, null, id);
    assert.deepEqual(task(id).steps, ["…", "Agent answer.", "…"], id);
  }
});

test("Antigravity transcript metadata cannot substitute an unverified answer", () => {
  for (const app of ["antigravity", "antigravity-ide"]) {
    const session_id = `conversation-${app}`;
    hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "antigravity", session_id });
    hook({ hook_event_name: "Stop", coucou_agent: "antigravity", session_id,
      transcriptPath: `C:/Users/test/.gemini/${app}/brain/${session_id}/.system_generated/logs/transcript.jsonl`,
      executionNum: 2, terminationReason: "model_stop", fullyIdle: true,
      prompt: "Private user input", tool_output: "Not an assistant answer" });
    assert.equal(State.finishedPopup.finalLine, null);
    assert.equal(State.finishedPopup.sessionId, session_id);
    assert.equal(State.finishedPopup.id, "agent_antigravity");
    assert.doesNotMatch(task("agent_antigravity").steps.join(" "), /Private|Not an assistant/);
    seconds(20);
  }
});

test("Antigravity and Antigravity IDE share a pill without mixing active conversations", () => {
  State.settings.mainPill = "agent_codex";
  State.loadIntegrationTasks();
  const first = "ec33ebf9-0cba-4100-8142-c61503f6c587";
  const second = "7c619818-5c45-4e67-910e-f1dd3cffcb83";
  hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "antigravity", session_id: first, prompt: "Private A" });
  hook({ hook_event_name: "PreToolUse", coucou_agent: "antigravity", session_id: first, tool_name: "run_command" });
  hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "antigravity", session_id: second, prompt: "Private B" });
  assert.equal(task("agent_antigravity").sessionId, second);
  assert.deepEqual(task("agent_antigravity").steps, ["\u2026"]);
  hook({ hook_event_name: "PostToolUse", coucou_agent: "antigravity", session_id: first, tool_name: "run_command" });
  hook({ hook_event_name: "Stop", coucou_agent: "antigravity", session_id: first, message: "Old response" });
  assert.equal(task("agent_antigravity").state, "thinking");
  assert.equal(State.finishedPopup, null);
  hook({ hook_event_name: "Stop", coucou_agent: "antigravity", session_id: second, message: "Current response" });
  assert.equal(State.finishedPopup.sessionId, second);
  assert.equal(State.finishedPopup.finalLine, "Current response");
  assert.equal(State.tasks.filter((t) => t.id === "agent_antigravity").length, 1);
  assert.equal(State.mainPillId, "agent_codex");
  assert.equal(State.focusId, "agent_codex");
  assert.doesNotMatch(task("agent_antigravity").steps.join(" "), /Private|Old response/);
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

test("a session finishing behind another pill opens its own answer without changing focus", () => {
  State.setFocus("integration_n8n");
  hook({ hook_event_name: "Stop", message: "Claude's answer" });
  assert.deepEqual(asked, ["alert:finished"]);
  assert.equal(State.focusId, "integration_n8n");
  assert.equal(State.finishedPopup.id, CLAUDE);
  assert.equal(State.finishedPopup.finalLine, "Claude's answer");
  seconds(5.2);
  assert.equal(task().pillBadge, null);
});

test("Main Tool Codex shows Hermes's answer, not Codex's or the user's prompt", () => {
  installFakeDom();
  State.settings.mainPill = "agent_codex";
  State.loadIntegrationTasks();
  State.setFocus("agent_codex");
  hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "codex", session_id: "c1", prompt: "Private Codex prompt" });
  hook({ hook_event_name: "Stop", coucou_agent: "codex", session_id: "c1", last_assistant_message: "Codex's old answer" });
  hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "hermes", session_id: "h1", prompt: "Private Hermes prompt" });
  hook({ hook_event_name: "Stop", coucou_agent: "hermes", session_id: "h1", last_assistant_message: "Hermes's answer" });
  assert.equal(State.mainPillId, "agent_codex");
  assert.equal(State.focusId, "agent_codex");
  // The first response retains its normal display interval; Hermes waits its turn.
  seconds(15);
  assert.equal(State.finishedPopup.id, "agent_hermes");
  const view = buildFinished({ openTerminal() {}, collapse() {} });
  view.sync();
  assert.match(view.el.textContent, /Hermes/);
  assert.match(view.el.textContent, /Hermes's answer/);
  assert.doesNotMatch(view.el.textContent, /Codex's old answer|Private/);
  assert.equal(State.mainPillId, "agent_codex");
  assert.equal(State.focusId, "agent_codex");
});

test("Codex's answer displays when Hermes is focused without changing the Main Tool", () => {
  State.settings.mainPill = "agent_codex";
  State.loadIntegrationTasks();
  hook({ hook_event_name: "SessionStart", coucou_agent: "hermes", session_id: "h1" });
  State.setFocus("agent_hermes");
  hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "codex", session_id: "c1", prompt: "Private" });
  hook({ hook_event_name: "Stop", coucou_agent: "codex", session_id: "c1", last_assistant_message: "Codex response" });
  assert.deepEqual(asked.filter((a) => a === "alert:finished"), ["alert:finished"]);
  assert.equal(State.finishedPopup.id, "agent_codex");
  assert.equal(State.finishedPopup.sessionId, "c1");
  assert.equal(State.mainPillId, "agent_codex");
  assert.equal(State.focusId, "agent_hermes");
});

test("two near-simultaneous answers are shown in order even after the second pill expires", () => {
  State.settings.autoCloseInterval = 6;
  hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "codex", session_id: "c1", prompt: "Private C" });
  hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "hermes", session_id: "h1", prompt: "Private H" });
  hook({ hook_event_name: "Stop", coucou_agent: "codex", session_id: "c1", last_assistant_message: "Codex response" });
  hook({ hook_event_name: "Stop", coucou_agent: "hermes", session_id: "h1", last_assistant_message: "Hermes response" });
  assert.equal(State.finishedPopup.id, "agent_codex");
  assert.equal(task("agent_hermes").pillBadge, "finished");
  seconds(5.2);
  assert.equal(task("agent_hermes"), undefined);
  seconds(0.8);
  assert.equal(State.finishedPopup.id, "agent_hermes");
  assert.equal(State.finishedPopup.sessionId, "h1");
  assert.equal(State.finishedPopup.finalLine, "Hermes response");
  assert.deepEqual(asked.filter((a) => a === "alert:finished"), ["alert:finished", "alert:finished"]);
});

test("queued answer cards paint each sender's mascot without changing focus or Main Tool", () => {
  const outfitEngine = new BotEngine();
  outfitEngine.setOutfit("witch", false);
  outfitEngine.setOutfit("none");
  assert.equal(outfitEngine.outfit, "witch");
  outfitEngine.setOutfit("none", false);
  assert.equal(outfitEngine.outfit, "none");
  assert.equal(outfitEngine.outfitPresence, 0);

  installFakeDom();
  State.settings.mainPill = "agent_codex";
  State.settings.autoCloseInterval = 1;
  State.loadIntegrationTasks();
  hook({ hook_event_name: "SessionStart", coucou_agent: "hermes", session_id: "h1" });
  State.setFocus("agent_hermes");
  State.mode = "expanded";
  State.view = "overview";

  const frames = [];
  const engine = {
    bodyColor: null, morph: 0,
    setOutfit(outfit, animated) { this.outfit = outfit; this.animated = animated; },
    update() {},
    draw() { frames.push({ color: this.bodyColor, outfit: this.outfit, animated: this.animated }); },
  };
  const renderer = Object.create(Island.prototype);
  Object.assign(renderer, {
    canvasPx: 0, botCx: { value: 40 }, botCy: { value: 30 }, botSize: { value: 64 }, engine,
    botCanvas: { style: {}, getContext: () => ({ setTransform() {}, clearRect() {} }) },
    seasons: { get: () => "witch" }, lookX: () => 0, lookY: () => 0,
  });
  const view = buildFinished({ openTerminal() {}, collapse() {} });
  const answers = [
    ["agent_codex", "codex", "Codex", "Codex answer", "#2DD4BF"],
    ["agent_hermes", "hermes", "Hermes", "Hermes answer", "#C084FC"],
    ["integration_claude", null, "Claude Code", "Claude answer", "#F5F6F8"],
    ["agent_opencode", "opencode", "OpenCode", "OpenCode answer", "#4ADE80"],
    ["agent_antigravity", "antigravity", "Antigravity", "Antigravity answer", "#E879F9"],
  ];
  for (const [id, agent, , answer] of answers) {
    hook({ hook_event_name: "Stop", ...(agent ? { coucou_agent: agent } : {}),
      session_id: agent === "hermes" ? "h1" : id, last_assistant_message: answer });
  }
  for (const [index, [id, , name, answer, color]] of answers.entries()) {
    if (index) seconds(1);
    assert.equal(State.finishedPopup.id, id);
    assert.equal(State.displayTask.id, id);
    State.stateOverride = "thinking";
    assert.equal(renderer.botState, "finished");
    State.stateOverride = null;
    view.sync();
    assert.match(view.el.textContent, new RegExp(name));
    assert.match(view.el.textContent, new RegExp(answer));
    renderer.drawBot(0.016);
    assert.deepEqual(frames.at(-1).color, hexToRGB(color));
    assert.equal(frames.at(-1).outfit, index === 0 ? "witch" : "none");
    assert.equal(frames.at(-1).animated, false);
    if (index === 1) {
      State.mode = "compact";
      renderer.drawBot(0.016);
      assert.equal(frames.at(-1).outfit, "none");
      State.mode = "expanded";
    }
    assert.equal(State.focusId, "agent_hermes");
    assert.equal(State.mainPillId, "agent_codex");
  }
  seconds(1);
  assert.equal(State.finishedPopup, null);
  assert.equal(State.view, "overview");
  assert.equal(State.focusId, "agent_hermes");
});

test("a duplicate Stop does not replay the popup or append its answer twice", () => {
  const done = { hook_event_name: "Stop", coucou_agent: "hermes", session_id: "h1", last_assistant_message: "One answer" };
  hook({ hook_event_name: "SessionStart", coucou_agent: "hermes", session_id: "h1" });
  asked = [];
  const played = [];
  const originalPlay = Sound.play;
  Sound.play = (name) => played.push(name);
  try {
    hook(done);
    hook(done);
  } finally {
    Sound.play = originalPlay;
  }
  assert.deepEqual(asked, ["alert:finished"]);
  assert.deepEqual(task("agent_hermes").steps, ["One answer"]);
  assert.deepEqual(played, ["finish"]);
  assert.equal(task("agent_hermes").state, "finished");
  seconds(15);
  assert.deepEqual(asked.filter((a) => a === "alert:finished"), ["alert:finished"]);
});

test("the same answer in a new session is not mistaken for a duplicate", () => {
  hook({ hook_event_name: "SessionStart", coucou_agent: "hermes", session_id: "h1" });
  hook({ hook_event_name: "Stop", coucou_agent: "hermes", session_id: "h1", last_assistant_message: "Done" });
  hook({ hook_event_name: "SessionStart", coucou_agent: "hermes", session_id: "h2" });
  asked = [];
  hook({ hook_event_name: "Stop", coucou_agent: "hermes", session_id: "h2", last_assistant_message: "Done" });
  assert.deepEqual(asked, ["alert:finished"]);
  assert.equal(State.finishedPopup.sessionId, "h2");
});

test("a stale session Stop cannot replace the current agent response", () => {
  hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "hermes", session_id: "h2", prompt: "Private new prompt" });
  asked = [];
  hook({ hook_event_name: "Stop", coucou_agent: "hermes", session_id: "h1", last_assistant_message: "Old answer" });
  assert.deepEqual(asked, []);
  assert.equal(task("agent_hermes").state, "thinking");
  hook({ hook_event_name: "Stop", coucou_agent: "hermes", session_id: "h2", last_assistant_message: "New answer" });
  assert.equal(State.finishedPopup.sessionId, "h2");
  assert.equal(State.finishedPopup.finalLine, "New answer");
});

test("manual navigation cancels an old popup timer before the next agent finishes", () => {
  hook({ hook_event_name: "Stop", coucou_agent: "hermes", last_assistant_message: "Hermes answer" });
  State.setFocus("agent_hermes"); // User picked a pill; the old popup is dismissed.
  asked = [];
  hook({ hook_event_name: "Stop", coucou_agent: "codex", last_assistant_message: "Codex answer" });
  assert.deepEqual(asked, ["alert:finished"]);
  assert.equal(State.finishedPopup.id, "agent_codex");
});

test("a Stop without an answer never uses the submitted prompt as popup text", () => {
  installFakeDom();
  hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "opencode", session_id: "o1", prompt: "Sensitive user prompt" });
  hook({ hook_event_name: "Stop", coucou_agent: "opencode", session_id: "o1" });
  const view = buildFinished({ openTerminal() {}, collapse() {} });
  view.sync();
  assert.match(view.el.textContent, /OpenCode/);
  assert.match(view.el.textContent, /Session finished/);
  assert.doesNotMatch(view.el.textContent, /Sensitive user prompt/);
});

test("OpenCode's popup uses OpenCode's own answer behind Codex", () => {
  installFakeDom();
  State.settings.mainPill = "agent_codex";
  State.loadIntegrationTasks();
  State.setFocus("agent_codex");
  hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "opencode", session_id: "o1", prompt: "Private" });
  hook({ hook_event_name: "Stop", coucou_agent: "opencode", session_id: "o1", last_assistant_message: "OpenCode result" });
  const view = buildFinished({ openTerminal() {}, collapse() {} });
  view.sync();
  assert.equal(State.finishedPopup.id, "agent_opencode");
  assert.match(view.el.textContent, /OpenCode result/);
  assert.doesNotMatch(view.el.textContent, /Codex result|Private/);
  assert.equal(State.mainPillId, "agent_codex");
});

test("an idle hidden island returns to hidden after the normal popup duration", () => {
  State.settings.autoCloseInterval = 1;
  hook({ hook_event_name: "Stop", message: "Done" });
  State.mode = "expanded"; // The mock alert records the call; real Island changes mode.
  State.view = "finished";
  seconds(1);
  assert.ok(asked.includes("hide"));
  assert.equal(State.finishedPopup, null);
});

test("opening a hidden island does not lose the agent answer during the home transition", () => {
  const answer = { id: "agent_hermes", name: "Hermes", finalLine: "Hermes response" };
  State.finishedPopup = answer;
  const host = {
    fsm: { pinned: false, forceHome() { State.finishedPopup = null; } },
    expand(view) { asked.push(`expand:${view}`); },
  };
  Island.prototype.alert.call(host, "finished");
  assert.equal(State.finishedPopup, answer);
  assert.deepEqual(asked, ["expand:finished"]);
});

test("the real island blocks auto-popup while hovered or showing an interactive view", () => {
  const host = { wasInIsland: false, desktop: { carrying: false } };
  assert.equal(Island.prototype.canAutoPopup.call(host), true);
  host.wasInIsland = true;
  assert.equal(Island.prototype.canAutoPopup.call(host), false);
  host.wasInIsland = false;
  State.mode = "expanded";
  State.view = "prompt";
  assert.equal(Island.prototype.canAutoPopup.call(host), false);
  State.view = "overview";
  assert.equal(Island.prototype.canAutoPopup.call(host), true);
  State.fileDragOver = true;
  assert.equal(Island.prototype.canAutoPopup.call(host), false);
  State.fileDragOver = false;
});

test("Chat, Settings, drag and permission requests keep the current view", () => {
  for (const view of ["prompt", "settings", "upload"]) {
    State.mode = "expanded";
    State.view = view;
    asked = [];
    hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "hermes", session_id: `h-${view}`, prompt: "Private" });
    hook({ hook_event_name: "Stop", coucou_agent: "hermes", session_id: `h-${view}`, last_assistant_message: "Answer" });
    assert.deepEqual(asked, [], view);
    assert.equal(task("agent_hermes").pillBadge, "finished", view);
  }
  State.mode = "hidden";
  State.view = "overview";
  State.fileDragOver = true;
  asked = [];
  hook({ hook_event_name: "Stop", coucou_agent: "codex", last_assistant_message: "Codex answer" });
  assert.deepEqual(asked, []);
  State.fileDragOver = false;
  hook({ hook_event_name: "UserPromptSubmit", coucou_agent: "hermes", session_id: "h-other", prompt: "Private" });
  hook({ hook_event_name: "PermissionRequest", coucou_agent: "codex", request_id: "r1", session_id: "c2", tool_name: "Bash" });
  asked = [];
  hook({ hook_event_name: "Stop", coucou_agent: "hermes", session_id: "h-other", last_assistant_message: "Other answer" });
  assert.deepEqual(asked, []);
  assert.equal(State.pendingApproval.requestId, "r1");
  assert.equal(task("agent_hermes").pillBadge, "finished");
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
  // The permission card is gone; the answer can surface without moving focus.
  assert.equal(State.finishedPopup.id, "agent_codex");
  assert.ok(asked.includes("alert:finished"));
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

test("a Claude Desktop session gets the Claude Desktop pill, in its colour (Mac #191)", () => {
  hook({ hook_event_name: "SessionStart", cwd: "C:\\p\\proj", session_id: "d1", coucou_agent: "claude-desktop" });
  const desktop = task("agent_claude-desktop");
  assert.equal(desktop.color, "#D97757");
  assert.equal(desktop.sessionId, "d1");
  assert.equal(task().state, "idle");
  // Its permission requests are answered in the app, as on macOS.
  hook({ hook_event_name: "PermissionRequest", request_id: "r1", coucou_agent: "claude-desktop", tool_name: "Bash" });
  assert.deepEqual(sent("approval_decline"), [{ requestId: "r1" }]);
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

test("a new turn behind another pill dismisses the finished popup straight away", () => {
  State.setFocus("integration_n8n");
  hook({ hook_event_name: "Stop" });
  assert.equal(State.finishedPopup.id, CLAUDE);
  hook({ hook_event_name: "UserPromptSubmit", prompt: "next" });
  assert.equal(State.finishedPopup, null);
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
