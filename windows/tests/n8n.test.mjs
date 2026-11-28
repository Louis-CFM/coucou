// n8n integration card, poller updates, and idleStatus transitions (Issue #1093).

import { mock, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { State } from "../src/core/state.ts";

installFakeDom();

const { idleStatus, hasIntegrationData, renderIntegrationCard } = await import("../src/views/integrations.ts");
const { handleIntegrationUpdate } = await import("../src/island/integrations.ts");

function makeN8nTask(overrides = {}) {
  return {
    id: "integration_n8n",
    name: "n8n",
    color: "#F29B38",
    state: "idle",
    stepIndex: 0,
    steps: [],
    source: "n8n",
    isIntegration: true,
    ...overrides,
  };
}

test("idleStatus: transitions from loading to Connected once loaded is true", () => {
  assert.equal(idleStatus("integration_n8n", { configured: false, error: null, loaded: false }, "claude-opus-5").label, "Key not configured");
  assert.equal(idleStatus("integration_n8n", { configured: true, error: null, loaded: false }, "claude-opus-5").label, "Connected · loading…");
  assert.equal(idleStatus("integration_n8n", { configured: true, error: null, loaded: true }, "claude-opus-5").label, "Connected");
});

test("n8n card: shows workflow from initial seed and after 60s auto-clear", () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  const prevTasks = State.tasks;
  const prevIntegrations = State.integrations;
  const prevFocus = State.focusId;
  State.integrations = { integration_n8n: { configured: false, loaded: false, error: null, data: {} } };
  const task = makeN8nTask();
  State.tasks = [task];
  State.focusId = "integration_claude";

  let revealed = 0;
  const island = { reveal() { revealed += 1; } };
  const hooks = { detailOpen: false, openDetail() {}, closeDetail() {}, openSettings() {} };

  try {
    // 1. Initial seed at launch (event: null) populates the card without triggering reveal/badge.
    handleIntegrationUpdate(island, {
      id: "integration_n8n",
      data: { id: "41", workflow: "Nightly sync", status: "success", detail: "→ HTTP · 1 item" },
      error: null,
      event: null,
    });
    assert.equal(State.integrations.integration_n8n.configured, true);
    assert.equal(State.integrations.integration_n8n.loaded, true);
    assert.equal(hasIntegrationData("integration_n8n"), true);
    assert.equal(revealed, 0);
    assert.equal(task.pillBadge, undefined);

    const seededCard = renderIntegrationCard(task, hooks);
    assert.ok(seededCard.textContent.includes("Nightly sync"));
    assert.ok(!seededCard.textContent.includes("Connected · loading…"));

    const seededDetail = renderIntegrationCard(task, { ...hooks, detailOpen: true });
    assert.ok(seededDetail.textContent.includes("Nightly sync"));
    assert.ok(seededDetail.textContent.includes("→ HTTP · 1 item"));
    assert.ok(seededDetail.textContent.includes("Success"));

    // 2. Empty zone/workspace with 0 executions transitions idleStatus cleanly to "Connected".
    handleIntegrationUpdate(island, {
      id: "integration_n8n",
      data: {},
      error: null,
      event: null,
    });
    assert.equal(hasIntegrationData("integration_n8n"), false);
    const connectedIdle = renderIntegrationCard(task, hooks);
    assert.ok(connectedIdle.textContent.includes("Connected"));
    assert.ok(!connectedIdle.textContent.includes("loading"));

    // 3. New failed execution emits event -> sets badge/steps/state, calls reveal, and keeps card after 60s clear.
    handleIntegrationUpdate(island, {
      id: "integration_n8n",
      data: { id: "42", workflow: "Deploy webhook", status: "error", detail: "HTTP Request\nECONNREFUSED" },
      error: null,
      event: { success: false, label: "Deploy webhook", detail: "HTTP Request\nECONNREFUSED" },
    });
    assert.equal(revealed, 1);
    assert.equal(task.state, "error");
    assert.equal(task.pillBadge, "error");
    assert.deepEqual(task.steps, ["Deploy webhook", "HTTP Request\nECONNREFUSED"]);

    // After 60s, task resets to idle/empty steps, yet the card keeps showing the last execution.
    mock.timers.tick(60_000);
    assert.equal(task.state, "idle");
    assert.deepEqual(task.steps, []);
    assert.equal(task.pillBadge, null);

    const postClearCard = renderIntegrationCard(task, hooks);
    assert.ok(postClearCard.textContent.includes("Deploy webhook"));
    const postClearDetail = renderIntegrationCard(task, { ...hooks, detailOpen: true });
    assert.ok(postClearDetail.textContent.includes("Deploy webhook"));
    assert.ok(postClearDetail.textContent.includes("ECONNREFUSED"));
    assert.ok(postClearDetail.textContent.includes("Failed"));
  } finally {
    mock.timers.reset();
    State.tasks = prevTasks;
    State.integrations = prevIntegrations;
    State.focusId = prevFocus;
  }
});

