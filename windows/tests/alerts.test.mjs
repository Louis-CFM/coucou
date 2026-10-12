// Which alerts open the island (src/core/alerts.ts), and the agent and
// integration handlers that ask it (src/island/hooks.ts, integrations.ts).

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { emit } from "./tauri.mjs";
import { AGENT_ERROR, AGENT_FINISHED, opensOnAlert } from "../src/core/alerts.ts";
import { registerHookHandlers } from "../src/island/hooks.ts";
import { registerIntegrationHandlers } from "../src/island/integrations.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

const VERCEL = "integration_vercel";

let asked;
const island = {
  alert: (view) => asked.push(`alert:${view}`),
  setView: (view) => asked.push(`setView:${view}`),
  reveal: () => asked.push("reveal"),
  dropPin: () => asked.push("dropPin"),
};
registerHookHandlers(island);
registerIntegrationHandlers(island);

const expandOn = (...keys) => { State.settings = { ...DEFAULT_SETTINGS, expandOnAlert: keys }; };

beforeEach(() => {
  mock.timers.enable({ apis: ["setTimeout"] });
  asked = [];
  State.settings = { ...DEFAULT_SETTINGS };
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.paused = false;
  State.pendingApproval = null;
  State.loadIntegrationTasks();
});

afterEach(() => {
  mock.timers.runAll();
  mock.timers.reset();
});

test("no alert opens the island until Settings asks for it", () => {
  assert.deepEqual(DEFAULT_SETTINGS.expandOnAlert, []);
  assert.equal(opensOnAlert(AGENT_FINISHED), false);
  expandOn(AGENT_FINISHED);
  assert.equal(opensOnAlert(AGENT_FINISHED), true);
  assert.equal(opensOnAlert(AGENT_ERROR), false);
});

test("a paused, open or waiting island is never opened by an alert", () => {
  expandOn(AGENT_FINISHED);
  State.paused = true;
  assert.equal(opensOnAlert(AGENT_FINISHED), false);
  State.paused = false;
  State.mode = "expanded";
  assert.equal(opensOnAlert(AGENT_FINISHED), false);
  State.mode = "compact";
  assert.equal(opensOnAlert(AGENT_FINISHED), true);
  State.pendingApproval = { requestId: "r", sessionId: "s", pillId: VERCEL, tool: "Bash", command: "ls" };
  assert.equal(opensOnAlert(AGENT_FINISHED), false);
});

test("a session finishing behind another pill opens its finished card when asked", () => {
  State.setFocus("integration_n8n");
  emit("hook", { hook_event_name: "Stop" });
  assert.deepEqual(asked, []);

  expandOn(AGENT_FINISHED);
  emit("hook", { hook_event_name: "Stop" });
  assert.deepEqual(asked, ["alert:finished"]);
  assert.equal(State.focusId, "integration_claude");
  assert.equal(State.focusTask.pillBadge, null);
});

test("an agent error behind another pill opens its error card when asked", () => {
  expandOn(AGENT_ERROR);
  State.setFocus("integration_n8n");
  emit("hook", { hook_event_name: "StopFailure" });
  assert.deepEqual(asked, ["alert:error"]);
  assert.equal(State.focusId, "integration_claude");
});

test("an integration alert peeks, or opens its pill's card when asked", () => {
  const deploy = { id: VERCEL, data: {}, error: null, event: { success: true, label: "site" } };
  emit("integration", deploy);
  assert.deepEqual(asked, ["reveal"]);

  asked = [];
  expandOn(VERCEL);
  emit("integration", deploy);
  assert.deepEqual(asked, ["alert:overview"]);
  assert.equal(State.focusId, VERCEL);
});

test("a new song while music plays opens the Spotify card when asked, an ad never does", async () => {
  const { applySpotify } = await import("../src/island/spotify.ts");
  const { Spotify } = await import("../src/core/spotify.ts");
  const host = { ...island, revealSilently: () => asked.push("revealSilently") };
  const play = (id) => ({ ...Spotify.state, running: true, playing: true, track: { id, title: id, artist: "", album: "", duration: 200, artUrl: null } });
  const withSpotify = () => {
    State.os = "linux";
    State.settings.activeIntegrations = [...State.settings.activeIntegrations, "integration_spotify"];
    State.loadIntegrationTasks();
  };
  withSpotify();
  State.mode = "compact";
  applySpotify(host, play("spotify:track:a"));
  asked = [];
  applySpotify(host, play("spotify:track:b"));
  assert.deepEqual(asked, []);

  expandOn("integration_spotify");
  withSpotify();
  applySpotify(host, play("spotify:track:c"));
  assert.deepEqual(asked, ["alert:overview"]);
  asked = [];
  State.mode = "compact";
  applySpotify(host, play("spotify:track:c"));
  applySpotify(host, play("spotify:ad:x"));
  assert.deepEqual(asked, []);
});
