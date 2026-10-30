// The model chip through a subscription (src/core/subscriptions.ts).

import { test } from "node:test";
import assert from "node:assert/strict";
import { chipLabel, setSubscriptions, subscribedProviders } from "../src/core/subscriptions.ts";
import { DEFAULT_SETTINGS } from "../src/core/state.ts";

const row = (provider, tool, on) => ({
  provider, tool, on, installed: true, signIn: "x", installUrl: "https://x", subscriptionOnly: false,
});

test("the chip names the tool that answers", () => {
  setSubscriptions([row("anthropic", "Claude Code", true), row("google", "Antigravity CLI", true), row("openai", "Codex CLI", false)]);
  assert.equal(chipLabel({ ...DEFAULT_SETTINGS, chatProvider: "anthropic" }, "claude-opus-5"), "claude-opus-5 · Claude Code");
  assert.equal(chipLabel({ ...DEFAULT_SETTINGS, chatProvider: "google" }, "gemini-2.0-flash"), "Antigravity CLI");
  // Off: the API model, as before.
  assert.equal(chipLabel({ ...DEFAULT_SETTINGS, chatProvider: "openai" }, "gpt-4o"), "gpt-4o");
  assert.deepEqual([...subscribedProviders()], ["anthropic", "google"]);
});
