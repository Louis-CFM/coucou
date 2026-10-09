import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";
import { Bridge } from "../src/core/bridge.ts";
import { calls, emit, sent } from "./tauri.mjs";
import { registerHookHandlers } from "../src/island/hooks.ts";

const island = { alert() {}, setView() {}, reveal() {}, dropPin() {}, collapse() {}, hide() {},
  canAutoPopup: () => !State.pendingApproval && !State.isPinned };

test("Auto-launch defaults OFF and saving it preserves Windows startup and other preferences", async () => {
  assert.equal(DEFAULT_SETTINGS.autoLaunchWithAgents, false);
  calls.length = 0;
  for (const autostart of [false, true]) {
    for (const autoLaunchWithAgents of [true, false]) {
      const settings = { ...DEFAULT_SETTINGS, autostart, autoLaunchWithAgents,
        islandAppearance: "windowsDarkFrosted", clickThroughShortcut: "ctrlAltD",
        shortcuts: { wardrobeToggle: { keys: "Ctrl+Alt+W", enabled: true } } };
      await Bridge.saveSettings(settings);
      assert.deepEqual(sent("save_settings").at(-1).settings, settings);
    }
  }
});

test("a running Coucou monitors Codex and keeps permissions working with Auto-launch ON or OFF", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  t.after(() => { t.mock.timers.runAll(); t.mock.timers.reset(); });
  calls.length = 0;
  await registerHookHandlers(island);
  await Bridge.hooksReady();
  for (const autoLaunchWithAgents of [false, true]) {
    State.tasks = [];
    State.pendingApproval = null;
    State.paused = false;
    State.isPinned = false;
    State.focusId = null;
    State.settings = { ...DEFAULT_SETTINGS, autoLaunchWithAgents };
    State.loadIntegrationTasks();
    emit("hook", { hook_event_name: "UserPromptSubmit", coucou_agent: "codex",
      session_id: "s", turn_id: "t", prompt: "Check the project", cwd: "C:\\project" });
    assert.equal(State.tasks.find((task) => task.id === "agent_codex").state, "thinking");
    const requestId = `r-${autoLaunchWithAgents}`;
    emit("hook", { hook_event_name: "PermissionRequest", coucou_agent: "codex",
      session_id: "s", request_id: requestId, tool_name: "Bash", tool_input: { command: "dir" } });
    assert.equal(State.pendingApproval.requestId, requestId);
    assert.deepEqual(sent("approval_ack").at(-1), { requestId });
    t.mock.timers.runAll();
  }
});

test("Hermes and Codex monitoring coexist with either toggle value and preserve agent answers", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  t.after(() => { t.mock.timers.runAll(); t.mock.timers.reset(); });
  await registerHookHandlers(island);
  for (const autoLaunchWithAgents of [false, true]) {
    State.tasks = [];
    State.pendingApproval = null;
    State.finishedPopup = null;
    State.paused = false;
    State.isPinned = false;
    State.focusId = null;
    State.settings = { ...DEFAULT_SETTINGS, autoLaunchWithAgents };
    State.loadIntegrationTasks();
    emit("hook", { hook_event_name: "SessionStart", coucou_agent: "hermes", session_id: "h", platform: "cli" });
    emit("hook", { hook_event_name: "UserPromptSubmit", coucou_agent: "codex", session_id: "c", turn_id: "t", prompt: "Private Codex prompt" });
    emit("hook", { hook_event_name: "PreToolUse", coucou_agent: "hermes", session_id: "h", tool_name: "Bash", tool_input: { command: "dir" } });
    const codex = State.tasks.find((task) => task.id === "agent_codex");
    const hermes = State.tasks.find((task) => task.id === "agent_hermes");
    assert.equal(codex.state, "thinking");
    assert.equal(hermes.state, "working");
    assert.equal(codex.sessionId, "c");
    assert.equal(hermes.sessionId, "h");
    assert.ok(!codex.steps.some((step) => step.includes("Private Codex prompt")));
    emit("hook", { hook_event_name: "Stop", coucou_agent: "hermes", session_id: "h", last_assistant_message: "Hermes answer" });
    emit("hook", { hook_event_name: "Stop", coucou_agent: "codex", session_id: "c", last_assistant_message: "Codex answer" });
    assert.equal(hermes.finalLine, "Hermes answer");
    assert.equal(codex.finalLine, "Codex answer");
    const requestId = `mixed-${autoLaunchWithAgents}`;
    emit("hook", { hook_event_name: "PermissionRequest", coucou_agent: "codex", session_id: "c", request_id: requestId, tool_name: "Bash", tool_input: { command: "dir" } });
    emit("hook", { hook_event_name: "SessionEnd", coucou_agent: "hermes", session_id: "h" });
    assert.equal(State.pendingApproval.requestId, requestId);
    assert.ok(!State.tasks.some((task) => task.id === "agent_hermes"));
    assert.ok(State.tasks.some((task) => task.id === "agent_codex"));
    assert.deepEqual(sent("quit_app"), []);
    t.mock.timers.runAll();
  }
});

test("a resumed Hermes turn works without SessionStart and never shows the user's prompt", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  t.after(() => { t.mock.timers.runAll(); t.mock.timers.reset(); });
  await registerHookHandlers(island);
  State.tasks = [];
  State.pendingApproval = null;
  State.finishedPopup = null;
  State.paused = false;
  State.isPinned = false;
  State.focusId = null;
  State.settings = { ...DEFAULT_SETTINGS, autoLaunchWithAgents: true };
  State.loadIntegrationTasks();
  emit("hook", { hook_event_name: "UserPromptSubmit", coucou_agent: "hermes",
    session_id: "resumed", turn_id: "resumed:turn", prompt: "Private Hermes prompt" });
  const hermes = State.tasks.find((task) => task.id === "agent_hermes");
  assert.equal(hermes.state, "thinking");
  assert.ok(!hermes.steps.some((step) => step.includes("Private Hermes prompt")));
  emit("hook", { hook_event_name: "Stop", coucou_agent: "hermes",
    session_id: "resumed", last_assistant_message: "Hermes answer" });
  assert.equal(hermes.finalLine, "Hermes answer");
  assert.deepEqual(sent("quit_app"), []);
  t.mock.timers.runAll();
});

test("OpenCode and Claude Code monitoring, answers, and Main Tool survive either Auto-launch value", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  t.after(() => { t.mock.timers.runAll(); t.mock.timers.reset(); });
  await registerHookHandlers(island);
  for (const autoLaunchWithAgents of [false, true]) {
    State.tasks = [];
    State.pendingApproval = null;
    State.finishedPopup = null;
    State.paused = false;
    State.isPinned = false;
    State.focusId = "agent_codex";
    State.settings = { ...DEFAULT_SETTINGS, mainPill: "agent_codex", autoLaunchWithAgents, autoCloseInterval: 1 };
    State.loadIntegrationTasks();
    emit("hook", { hook_event_name: "UserPromptSubmit", coucou_agent: "opencode",
      session_id: "open-resume", turn_id: "msg-1", prompt: "Private OpenCode prompt" });
    const open = State.tasks.find((task) => task.id === "agent_opencode");
    assert.equal(open.state, "thinking");
    assert.ok(!open.steps.some((step) => step.includes("Private OpenCode prompt")));
    emit("hook", { hook_event_name: "Stop", coucou_agent: "opencode", session_id: "open-resume",
      last_assistant_message: "OpenCode answer" });
    assert.equal(State.finishedPopup.id, "agent_opencode");
    assert.equal(State.finishedPopup.finalLine, "OpenCode answer");
    emit("hook", { hook_event_name: "SessionStart", session_id: "claude-resume", source: "resume" });
    emit("hook", { hook_event_name: "UserPromptSubmit", session_id: "claude-resume",
      prompt: "Private Claude prompt" });
    const claude = State.tasks.find((task) => task.id === "integration_claude");
    assert.equal(claude.state, "thinking");
    assert.ok(!claude.steps.some((step) => step.includes("Private Claude prompt")));
    emit("hook", { hook_event_name: "Stop", session_id: "claude-resume",
      last_assistant_message: "Claude answer" });
    assert.equal(State.finishedPopup.id, "agent_opencode");
    t.mock.timers.tick(1000);
    assert.equal(State.finishedPopup.id, "integration_claude");
    assert.equal(State.finishedPopup.finalLine, "Claude answer");
    assert.equal(State.mainPillId, "agent_codex");
    assert.deepEqual(sent("quit_app"), []);
    t.mock.timers.runAll();
  }
});

test("both Antigravity runtimes monitor through one pill with Auto-launch ON or OFF", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  t.after(() => { t.mock.timers.runAll(); t.mock.timers.reset(); });
  await registerHookHandlers(island);
  for (const autoLaunchWithAgents of [false, true]) {
    State.tasks = [];
    State.pendingApproval = null;
    State.finishedPopup = null;
    State.paused = false;
    State.isPinned = false;
    State.focusId = "agent_codex";
    State.settings = { ...DEFAULT_SETTINGS, mainPill: "agent_codex", autoLaunchWithAgents };
    State.loadIntegrationTasks();
    for (const session_id of [
      "ec33ebf9-0cba-4100-8142-c61503f6c587",
      "7c619818-5c45-4e67-910e-f1dd3cffcb83",
    ]) {
      emit("hook", { hook_event_name: "UserPromptSubmit", coucou_agent: "antigravity",
        session_id, prompt: "Private Antigravity input" });
      const task = State.tasks.find((item) => item.id === "agent_antigravity");
      assert.equal(task.sessionId, session_id);
      assert.equal(task.state, "thinking");
      assert.ok(!task.steps.some((step) => step.includes("Private Antigravity input")));
    }
    const session_id = "7c619818-5c45-4e67-910e-f1dd3cffcb83";
    emit("hook", { hook_event_name: "Stop", coucou_agent: "antigravity", session_id });
    assert.equal(State.finishedPopup.id, "agent_antigravity");
    assert.equal(State.finishedPopup.sessionId, session_id);
    assert.equal(State.finishedPopup.color, "#E879F9");
    assert.equal(State.finishedPopup.finalLine, null);
    assert.equal(State.tasks.filter((item) => item.id === "agent_antigravity").length, 1);
    assert.equal(State.focusId, "agent_codex");
    assert.equal(State.mainPillId, "agent_codex");
    assert.deepEqual(sent("quit_app"), []);
    t.mock.timers.runAll();
  }
});
