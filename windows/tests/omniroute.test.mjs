// OmniRoute's island side (src/core/omniroute.ts): where its card says it
// stands, which model the features keep, and when the chat's picker shows it.

import { test } from "node:test";
import assert from "node:assert/strict";
import { chatAfterOff, featuresModel, omnirouteConfig, stage } from "../src/core/omniroute.ts";
import { visibleProviders } from "../src/core/providers.ts";
import { DEFAULT_SETTINGS } from "../src/core/state.ts";

const on = { enabled: true, url: "", features: false, featuresModel: "" };
const status = (over = {}) => ({
  url: "http://127.0.0.1:20128", local: true, installed: true, running: true,
  key: "ok", models: ["cc/claude-sonnet-4-5", "my-combo"], error: null, ...over,
});

test("the card says the one thing that is missing, worst first", () => {
  assert.equal(stage({ ...on, enabled: false }, status()), "off");
  assert.equal(stage(on, null), "unreachable");
  assert.equal(stage(on, status({ running: false, installed: false })), "not-installed");
  assert.equal(stage(on, status({ running: false })), "stopped");
  // Elsewhere, Coucou can neither find nor start it.
  assert.equal(stage(on, status({ running: false, local: false, installed: false })), "unreachable");
  assert.equal(stage(on, status({ key: "missing", models: [] })), "key");
  assert.equal(stage(on, status({ key: "refused", models: [] })), "refused");
  assert.equal(stage(on, status({ models: [] })), "empty");
  assert.equal(stage(on, status({ error: "OmniRoute 500" })), "unreachable");
  assert.equal(stage(on, status()), "ready");
});

test("the features keep their model while it is offered, else take the first", () => {
  assert.equal(featuresModel("my-combo", ["a", "my-combo"]), "my-combo");
  assert.equal(featuresModel("gone", ["a", "b"]), "a");
  assert.equal(featuresModel("", []), "");
});

test("an older settings.json without it reads as turned off", () => {
  const { omniroute: _, ...older } = DEFAULT_SETTINGS;
  assert.deepEqual(omnirouteConfig(older), { enabled: false, url: "", features: false, featuresModel: "" });
  assert.equal(omnirouteConfig({ ...DEFAULT_SETTINGS, omniroute: { enabled: true } }).enabled, true);
});

test("the chat's picker shows it while it is on, or while the chat still goes to it", () => {
  const ids = (s) => visibleProviders({ ...DEFAULT_SETTINGS, ...s }).map((p) => p.id);
  assert.ok(!ids({}).includes("omniroute"));
  assert.ok(ids({ omniroute: on }).includes("omniroute"));
  assert.ok(ids({ chatProvider: "omniroute" }).includes("omniroute"));
  // An older settings.json has no omniroute at all.
  const { omniroute: _, ...older } = DEFAULT_SETTINGS;
  assert.ok(!visibleProviders(older).map((p) => p.id).includes("omniroute"));
});

test("turned off, the chat goes back to the provider it had before", () => {
  assert.equal(chatAfterOff("omniroute", { ...on, chatBefore: "openrouter" }), "openrouter");
  // Never taken by the card (picked in the island): Claude, as before.
  assert.equal(chatAfterOff("omniroute", on), "anthropic");
  // Moved elsewhere meanwhile: left there.
  assert.equal(chatAfterOff("ollama", { ...on, chatBefore: "openrouter" }), "ollama");
});
