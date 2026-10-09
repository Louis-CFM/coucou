// Cross-process compact-island preference defaults.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DEFAULT_SETTINGS } from "../src/core/state.ts";

test("the compact island remains visible by default", () => {
  assert.equal(DEFAULT_SETTINGS.showCompactIsland, true);
});

test("live settings apply compact visibility to the island state machine", () => {
  const source = readFileSync(new URL("../src/island/island.ts", import.meta.url), "utf8");
  assert.match(source, /this\.fsm\.showCompactIsland = State\.settings\.showCompactIsland;/);
});

test("boot applies persisted settings before handlers and the first greeting", () => {
  const source = readFileSync(new URL("../src/main.ts", import.meta.url), "utf8");
  const loaded = source.indexOf("State.settings = { ...State.settings, ...boot.settings };");
  const applied = source.indexOf("island.applySettings();");
  const handlers = source.indexOf("registerHookHandlers(island);");
  const greeting = source.indexOf("island.launch();");
  assert.ok(loaded >= 0 && loaded < applied);
  assert.ok(applied < handlers);
  assert.ok(handlers < greeting);
});

test("Rust persists the camel-case preference and defaults old files to visible", () => {
  const source = readFileSync(new URL("../src-tauri/src/settings.rs", import.meta.url), "utf8");
  assert.match(source, /pub show_compact_island: bool,/);
  assert.match(source, /show_compact_island: true,/);
  assert.match(source, /"showCompactIsland": false,/);
  assert.match(source, /"showCompactIsland",/);
});

test("General settings exposes the compact-island preference", () => {
  const source = readFileSync(new URL("../src/settings/main.ts", import.meta.url), "utf8");
  assert.match(source, /t\("Show compact island"\)/);
  assert.match(source, /settings\.showCompactIsland = v; void save\(\);/);
});
