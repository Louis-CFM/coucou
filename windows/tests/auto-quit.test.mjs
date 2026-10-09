import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { State, DEFAULT_SETTINGS } from "../src/core/state.ts";
import { Bridge } from "../src/core/bridge.ts";
import { Island } from "../src/island/island.ts";
import { calls, sent } from "./tauri.mjs";

let host, inputs;
beforeEach(() => {
  calls.length = 0;
  Object.assign(State, { mode: "compact", view: "overview", fileDragOver: false,
    droppedFile: null, promptContext: null, pendingApproval: null, finishedPopup: null,
    isPinned: false, stateOverride: null, chatHistory: [], lastActivity: performance.now() - 31_000 });
  inputs = [];
  host = { wasInIsland: false, desktop: { carrying: false }, uploadActive: false,
    autoQuitBlocker: Island.prototype.autoQuitBlocker,
    root: { querySelectorAll: () => inputs } };
});
const allowed = () => Island.prototype.canAutoQuit.call(host);

test("Auto-Quit defaults OFF and persists independently of launch and Windows startup", async () => {
  assert.equal(DEFAULT_SETTINGS.autoQuitWhenAgentsFinish, false);
  assert.equal(DEFAULT_SETTINGS.autoQuitDelayMinutes, 10);
  for (const autoQuitDelayMinutes of [5, 10, 15, 30, 60]) {
    for (const autoQuitWhenAgentsFinish of [true, false]) {
      for (const autoLaunchWithAgents of [true, false]) {
        for (const autostart of [true, false]) {
          const settings = { ...DEFAULT_SETTINGS, autoQuitDelayMinutes, autoQuitWhenAgentsFinish, autoLaunchWithAgents, autostart };
          await Bridge.saveSettings(settings);
          assert.deepEqual(sent("save_settings").at(-1).settings, settings);
        }
      }
    }
  }
});

test("an unattended collapsed island permits the backend check without issuing manual Quit", async () => {
  assert.equal(allowed(), true);
  await Bridge.autoQuitConfirm(17, !allowed());
  assert.deepEqual(sent("auto_quit_confirm"), [{ ticket: 17, busy: false }]);
  assert.deepEqual(sent("quit_app"), []);
});

for (const view of ["prompt", "settings", "approval", "finished", "overview", "wardrobe"]) {
  test(`an expanded ${view} view postpones Auto-Quit`, () => {
    State.mode = "expanded";
    State.view = view;
    assert.equal(allowed(), false);
  });
}

for (const [key, value] of Object.entries({
  pendingApproval: { requestId: "r" }, finishedPopup: { id: "agent_hermes" },
  fileDragOver: true, droppedFile: { name: "file.txt" }, promptContext: { kind: "file" },
  isPinned: true, stateOverride: "thinking", chatHistory: [{ role: "user", content: "Keep my chat" }],
})) {
  test(`${key} protects user data and interaction even when collapsed`, () => {
    State[key] = value;
    assert.equal(allowed(), false);
    assert.notEqual(host.autoQuitBlocker(), null);
    assert.deepEqual(State[key], value);
  });
}

test("hover, mascot dragging, uploading, and recent interaction postpone closure", () => {
  host.wasInIsland = true;
  assert.equal(allowed(), false);
  host.wasInIsland = false;
  host.desktop.carrying = true;
  assert.equal(allowed(), false);
  host.desktop.carrying = false;
  host.uploadActive = true;
  assert.equal(allowed(), false);
  host.uploadActive = false;
  State.lastActivity = performance.now();
  assert.equal(allowed(), false);
});

test("a hidden unsent draft is preserved", () => {
  inputs.push({ value: "Unsent message" });
  assert.equal(allowed(), false);
  assert.equal(host.autoQuitBlocker(), "chat_draft");
  assert.equal(inputs[0].value, "Unsent message");
});

test("Auto-Quit reports safe blocker categories without chat content", () => {
  State.chatHistory = [{ role: "user", content: "private message" }];
  assert.equal(host.autoQuitBlocker(), "chat_history");
  State.chatHistory = [];
  State.finishedPopup = { id: "agent_codex" };
  assert.equal(host.autoQuitBlocker(), "popup");
  State.finishedPopup = null;
  State.pendingApproval = { requestId: "secret" };
  assert.equal(host.autoQuitBlocker(), "permission");
});
