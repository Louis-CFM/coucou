// Settings → Android phone → chat: how the list of models the phone may use is built.

import { test } from "node:test";
import assert from "node:assert/strict";
import { MAX_ALLOWED, modelId, modelsOf, providerOf, toggleModel, usableProviders } from "../src/core/phone-chat.ts";
import { DEFAULT_SETTINGS } from "../src/core/state.ts";

test("an id is provider/model and the provider must be one the app knows", () => {
  assert.equal(modelId("openai", "gpt-4o"), "openai/gpt-4o");
  assert.equal(providerOf("openai/gpt-4o"), "openai");
  assert.equal(providerOf("openrouter/openrouter/auto"), "openrouter");
  for (const bad of ["", "openai", "openai/", "nope/x", "/x"]) assert.equal(providerOf(bad), null, bad);
});

test("ticking adds once, unticking removes, the order is kept", () => {
  let list = [];
  list = toggleModel(list, "openai/a", true);
  list = toggleModel(list, "google/b", true);
  list = toggleModel(list, "openai/a", true);
  assert.deepEqual(list, ["google/b", "openai/a"]);
  list = toggleModel(list, "google/b", false);
  assert.deepEqual(list, ["openai/a"]);
  assert.deepEqual(toggleModel(list, "nothing/there", false), ["openai/a"]);
});

test("the list stops at the cap", () => {
  let list = [];
  for (let i = 0; i < MAX_ALLOWED + 10; i++) list = toggleModel(list, `openai/m${i}`, true);
  assert.equal(list.length, MAX_ALLOWED);
});

test("only providers with a key, or a connected server, are offered", () => {
  const none = usableProviders(DEFAULT_SETTINGS, {});
  assert.deepEqual(none, []);
  const some = usableProviders({ ...DEFAULT_SETTINGS, ollamaUrl: "http://127.0.0.1:11434" }, { anthropic: true, openai: false });
  assert.deepEqual(some.map((p) => p.id), ["anthropic", "ollama"]);
});

test("the models of one provider are told apart from the others'", () => {
  const list = ["openai/a", "openai/b", "google/a", "openrouter/openrouter/auto"];
  assert.deepEqual(modelsOf(list, "openai"), ["a", "b"]);
  assert.deepEqual(modelsOf(list, "openrouter"), ["openrouter/auto"]);
  assert.deepEqual(modelsOf(list, "ollama"), []);
});
