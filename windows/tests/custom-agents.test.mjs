// Issue #592: Persistent custom agents and third-party agent hooks.

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { calls, emit } from "./tauri.mjs";
import { registerHookHandlers } from "../src/island/hooks.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";
import {
  MAX_DECLARED, availablePills, fromPillId, resolvePill, sanitizeDeclared, toPillId, toggleDeclared,
} from "../src/core/pills.ts";
import { validateAgent } from "../src/island/agents.ts";

let asked = [];
const island = {
  alert: (view) => asked.push(`alert:${view}`),
  setView: (view) => asked.push(`setView:${view}`),
  reveal: () => asked.push("reveal"),
  dropPin: () => asked.push("dropPin"),
};
registerHookHandlers(island);

const hook = (payload) => emit("hook", payload);
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
  State.settings = {
    ...DEFAULT_SETTINGS,
    activeIntegrations: [],
    customAgents: [],
  };
  State.loadIntegrationTasks();
});

afterEach(() => {
  mock.timers.runAll();
  mock.timers.reset();
});

// ── Validation & Helpers ──────────────────────────────────────────────────────

test("validateAgent allows underscores, hyphens, and alphanumeric up to 24 chars", () => {
  assert.equal(validateAgent("my_agent"), "my_agent");
  assert.equal(validateAgent("dev-bot_01"), "dev-bot_01");
  assert.equal(validateAgent("claude"), null);
  assert.equal(validateAgent("bad@agent"), null);
  assert.equal(validateAgent("A".repeat(25)), null);
});

test("toPillId and fromPillId convert symmetrically", () => {
  assert.equal(toPillId("my_bot"), "agent_my_bot");
  assert.equal(toPillId("agent_my_bot"), "agent_my_bot");
  assert.equal(fromPillId("agent_my_bot"), "my_bot");
  assert.equal(fromPillId("my_bot"), "my_bot");
});

// ── Pure Functions in pills.ts ────────────────────────────────────────────────

test("resolvePill resolves built-in catalog pills first", () => {
  const def = resolvePill("agent_cursor");
  assert.ok(def);
  assert.equal(def.name, "Cursor");
});

test("resolvePill synthesizes a definition for registered custom agents", () => {
  const customAgents = [{ id: "local_llm", name: "Local LLM" }];
  const def = resolvePill("agent_local_llm", customAgents);
  assert.ok(def);
  assert.equal(def.id, "agent_local_llm");
  assert.equal(def.name, "Local LLM");
  assert.equal(def.category, "agent");
  assert.equal(def.connect.kind, "hooks");
});

test("resolvePill falls back to id when display name is missing or empty", () => {
  const customAgents = [{ id: "raw_bot" }];
  const def = resolvePill("agent_raw_bot", customAgents);
  assert.ok(def);
  assert.equal(def.name, "raw_bot");
});

test("resolvePill prioritizes catalog over custom agents with colliding IDs", () => {
  const customAgents = [{ id: "cursor", name: "Fake Cursor" }];
  const def = resolvePill("agent_cursor", customAgents);
  assert.ok(def);
  assert.equal(def.name, "Cursor"); // Built-in catalog wins!
});

test("sanitizeDeclared preserves registered custom agents and strips unknown agents", () => {
  const customAgents = [{ id: "bot_a", name: "Bot A" }];
  const declared = {
    mainPill: "integration_claude",
    activeIntegrations: ["agent_bot_a", "agent_unknown_bot", "agent_cursor"],
    customAgents,
  };
  const sanitized = sanitizeDeclared(declared);
  assert.deepEqual(sanitized.activeIntegrations, ["agent_bot_a", "agent_cursor"]);
});

test("toggleDeclared declares and undeclares registered custom agents within slot limits", () => {
  const customAgents = [{ id: "bot_1" }, { id: "bot_2" }, { id: "bot_3" }, { id: "bot_4" }, { id: "bot_5" }];
  let d = {
    mainPill: "integration_claude",
    activeIntegrations: [],
    customAgents,
  };

  const next1 = toggleDeclared(d, "agent_bot_1");
  assert.deepEqual(next1, ["agent_bot_1"]);
  d.activeIntegrations = next1;

  // Toggle off
  const nextOff = toggleDeclared(d, "agent_bot_1");
  assert.deepEqual(nextOff, []);

  // Fill up to MAX_DECLARED (4)
  d.activeIntegrations = ["agent_bot_1", "agent_bot_2", "agent_bot_3", "agent_bot_4"];
  const full = toggleDeclared(d, "agent_bot_5");
  assert.equal(full, null); // 5th pill refused!
});

// ── Cold Boot Rehydration & State ─────────────────────────────────────────────

test("State.loadIntegrationTasks hydrates pinned custom agents as idle pills", () => {
  State.settings.customAgents = [{ id: "auto_pilot", name: "Auto Pilot" }];
  State.settings.activeIntegrations = ["agent_auto_pilot"];
  State.settings.pillColors = { agent_auto_pilot: "#34D399" };

  State.loadIntegrationTasks();

  const task = State.tasks.find((t) => t.id === "agent_auto_pilot");
  assert.ok(task, "custom agent task should be loaded into State.tasks");
  assert.equal(task.name, "Auto Pilot");
  assert.equal(task.state, "idle");
  assert.equal(task.color, "#34D399");
  assert.equal(State.isKept("agent_auto_pilot"), true);
});

// ── Hook Events & Lifecycle ───────────────────────────────────────────────────

test("an incoming hook for a registered custom agent displays its custom name and color", () => {
  State.settings.customAgents = [{ id: "my_worker", name: "Custom Worker" }];
  State.settings.pillColors = { agent_my_worker: "#F472B6" };
  State.loadIntegrationTasks();

  hook({
    hook_event_name: "SessionStart",
    coucou_agent: "my_worker",
    cwd: "C:\\Projects\\repo",
  });

  const task = State.tasks.find((t) => t.id === "agent_my_worker");
  assert.ok(task);
  assert.equal(task.name, "Custom Worker");
  assert.equal(task.color, "#F472B6");
});

test("pinned custom agents return to idle after Stop 5.2s timer without removal", () => {
  State.settings.customAgents = [{ id: "pinned_bot", name: "Pinned Bot" }];
  State.settings.activeIntegrations = ["agent_pinned_bot"];
  State.loadIntegrationTasks();

  hook({
    hook_event_name: "SessionStart",
    coucou_agent: "pinned_bot",
    session_id: "s1",
  });

  hook({
    hook_event_name: "Stop",
    coucou_agent: "pinned_bot",
    session_id: "s1",
    message: "Finished task successfully",
  });

  const busyTask = State.tasks.find((t) => t.id === "agent_pinned_bot");
  assert.equal(busyTask.state, "finished");

  seconds(5.2);

  const idleTask = State.tasks.find((t) => t.id === "agent_pinned_bot");
  assert.ok(idleTask, "pinned custom agent must remain in State.tasks");
  assert.equal(idleTask.state, "idle");
  assert.equal(idleTask.name, "Pinned Bot");

  hook({
    hook_event_name: "SessionEnd",
    coucou_agent: "pinned_bot",
    session_id: "s1",
  });
  assert.equal(idleTask.steps.length, 0);
});

test("unpinned external agent teardown is deferred while card is actively inspected", () => {
  hook({
    hook_event_name: "SessionStart",
    coucou_agent: "temp_bot",
    session_id: "s1",
  });

  assert.ok(State.tasks.some((t) => t.id === "agent_temp_bot"));

  // User expands island and focuses on the card:
  State.mode = "expanded";
  State.view = "overview";
  State.setFocus("agent_temp_bot");

  hook({
    hook_event_name: "Stop",
    coucou_agent: "temp_bot",
    session_id: "s1",
  });

  // 5.2 seconds elapse while user is still viewing the card:
  seconds(5.2);

  assert.ok(
    State.tasks.some((t) => t.id === "agent_temp_bot"),
    "task must NOT be removed while user actively inspects it in expanded island",
  );

  // User collapses the island:
  State.mode = "hidden";
  State.notify();

  assert.ok(
    !State.tasks.some((t) => t.id === "agent_temp_bot"),
    "task must be removed once island is folded",
  );
});

test("concurrent sessions for the same custom agent are preserved until all sessions end", () => {
  hook({
    hook_event_name: "SessionStart",
    coucou_agent: "multi_bot",
    session_id: "sess_A",
  });

  hook({
    hook_event_name: "SessionStart",
    coucou_agent: "multi_bot",
    session_id: "sess_B",
  });

  // First session ends:
  hook({
    hook_event_name: "SessionEnd",
    coucou_agent: "multi_bot",
    session_id: "sess_A",
  });

  assert.ok(
    State.tasks.some((t) => t.id === "agent_multi_bot"),
    "agent task must remain active because sess_B is still running",
  );

  // Second session ends:
  hook({
    hook_event_name: "SessionEnd",
    coucou_agent: "multi_bot",
    session_id: "sess_B",
  });

  assert.ok(
    !State.tasks.some((t) => t.id === "agent_multi_bot"),
    "agent task is removed once all concurrent sessions have ended",
  );
});
