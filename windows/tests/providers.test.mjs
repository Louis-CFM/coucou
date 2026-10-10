// The island's provider table (src/core/providers.ts): which model the chat
// uses, which chips the picker shows, and what a server address exposes.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  PROVIDERS, activeModel, isLoopbackHost, keyAddress, pickModel, providerDef, urlExposure, visibleProviders, withModel,
} from "../src/core/providers.ts";
import { DEFAULT_SETTINGS } from "../src/core/state.ts";

const settings = (over = {}) => ({ ...DEFAULT_SETTINGS, ...over });

test("the ids and key names match the Rust side and the Mac", () => {
  assert.deepEqual(PROVIDERS.map((p) => p.id), ["anthropic", "google", "openai", "openrouter", "ollama", "lmstudio", "custom"]);
  assert.equal(providerDef("google").key, "google-api-key");
  assert.equal(providerDef("openai").key, "openai-api-key");
  assert.equal(providerDef("openrouter").key, "openrouter-api-key");
  assert.equal(providerDef("ollama").key, null);
  // An unknown id (an older or newer settings.json) falls back to Claude.
  assert.equal(providerDef("nope").id, "anthropic");
});

test("Claude's model is the existing setting; the others are kept per provider", () => {
  assert.equal(activeModel(settings()), "claude-opus-5");
  assert.equal(activeModel(settings({ chatProvider: "google" })), "gemini-2.0-flash");
  assert.equal(activeModel(settings({ chatProvider: "ollama" })), "");
  let s = withModel(settings({ chatProvider: "openai" }), "openai", "gpt-5-mini");
  assert.equal(activeModel(s), "gpt-5-mini");
  assert.equal(s.model, "claude-opus-5");
  s = withModel(s, "anthropic", "claude-haiku-4-5");
  assert.equal(s.model, "claude-haiku-4-5");
  assert.equal(s.chatModels.openai, "gpt-5-mini");
  // withModel never changes the object it was given.
  assert.deepEqual(DEFAULT_SETTINGS.chatModels, {});
});

test("model servers show in the picker once connected, or while in use", () => {
  const ids = (s) => visibleProviders(s).map((p) => p.id);
  assert.deepEqual(ids(settings()), ["anthropic", "google", "openai", "openrouter"]);
  assert.deepEqual(ids(settings({ ollamaUrl: "http://127.0.0.1:11434" })), ["anthropic", "google", "openai", "openrouter", "ollama"]);
  assert.deepEqual(ids(settings({ chatProvider: "custom" })), ["anthropic", "google", "openai", "openrouter", "custom"]);
});

test("the saved model is kept when offered, else a sensible one is picked", () => {
  const google = providerDef("google");
  assert.equal(pickModel(google, ["gemini-2.5-pro", "gemini-2.0-flash"], "gemini-2.5-pro"), "gemini-2.5-pro");
  assert.equal(pickModel(google, ["gemini-2.5-pro", "gemini-2.5-flash"], "gone"), "gemini-2.5-flash");
  assert.equal(pickModel(providerDef("openai"), ["gpt-4o", "gpt-5-mini"], "gone"), "gpt-5-mini");
  assert.equal(pickModel(providerDef("ollama"), ["llama3.2", "qwen"], ""), "llama3.2");
  assert.equal(pickModel(providerDef("openrouter"), ["a/b", "openrouter/auto"], "gone"), "openrouter/auto");
  assert.equal(pickModel(google, [], "x"), null);
});

test("loopback hosts match net.rs", () => {
  for (const host of ["localhost", "app.localhost", "127.0.0.1", "127.9.9.9", "[::1]", "::1", "0.0.0.0", "[::]"]) {
    assert.ok(isLoopbackHost(host), host);
  }
  for (const host of ["example.com", "192.168.1.2", "localhost.example.com", "128.0.0.1", "[2001:db8::1]"]) {
    assert.ok(!isLoopbackHost(host), host);
  }
  // An IPv4 loopback written as IPv6, as the URL parser normalises it (net.rs accepts it too).
  for (const host of ["[::ffff:7f00:1]", "[::ffff:7f00:2]", "[::ffff:7f01:203]", "::ffff:127.0.0.2"]) {
    assert.ok(isLoopbackHost(host), host);
  }
  for (const host of ["[::ffff:c0a8:102]", "[::ffff:8000:1]", "[::ffff:0:0]"]) {
    assert.ok(!isLoopbackHost(host), host);
  }
  assert.equal(new URL("http://[::ffff:127.0.0.2]:5678").hostname, "[::ffff:7f00:2]");
  assert.equal(keyAddress("http://[::ffff:127.0.0.2]:5678"), "ok");
});

test("an address says whether what you type leaves this computer", () => {
  assert.equal(urlExposure(""), "local");
  assert.equal(urlExposure("http://localhost:11434"), "local");
  assert.equal(urlExposure("127.0.0.1:1234/v1"), "local");
  assert.equal(urlExposure("http://[::1]:8000"), "local");
  assert.equal(urlExposure("https://llm.example.com"), "remote");
  assert.equal(urlExposure("http://gpu-box.lan:8000"), "remote-http");
  assert.equal(urlExposure("192.168.1.20:8000"), "remote-http");
  assert.equal(urlExposure("ftp://example.com"), "invalid");
  assert.equal(urlExposure("http://user:pw@example.com"), "invalid");
  assert.equal(urlExposure("http://"), "invalid");
});

test("a key address is https, or plain http to this computer only (n8n_base in integrations.rs)", () => {
  for (const ok of [
    "https://n8n.example.com", " https://n8n.example.com/ ", "https://me:pw@n8n.example.com",
    "http://localhost:5678", "http://127.0.0.1:5678", "http://[::1]:5678", "http://n8n.localhost",
  ]) {
    assert.equal(keyAddress(ok), "ok", ok);
  }
  for (const remote of ["http://n8n.example.com", "http://192.168.1.20:5678", "http://localhost.example.com"]) {
    assert.equal(keyAddress(remote), "remote-http", remote);
  }
  // No scheme added for you, unlike urlExposure: the Rust side refuses these.
  for (const bad of ["", "n8n.example.com", "localhost:5678", "ftp://n8n.example.com", "ws://localhost:5678", "https://"]) {
    assert.equal(keyAddress(bad), "invalid", bad);
  }
});
