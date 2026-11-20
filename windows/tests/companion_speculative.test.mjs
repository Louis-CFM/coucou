import test from "node:test";
import assert from "node:assert/strict";

import { ContextIntelligence } from "../src/companion/context.ts";
import { MessagePolicyEngine } from "../src/companion/policy.ts";
import { SpeculativeEngine } from "../src/companion/speculative.ts";

test("SpeculativeEngine buffers and consumes valid candidate upon user return", () => {
  MessagePolicyEngine.resetTimers();
  const now = Date.now();
  const snapshot = ContextIntelligence.capture("greeting_return", 300);

  const defaultSettings = {
    enabled: true,
    routingMode: "auto",
    preferredName: "",
    personality: "warm_playful",
    absenceIntervalSeconds: 180,
    quietHoursEnabled: false,
    quietHoursStart: "22:00",
    quietHoursEnd: "08:00",
  };

  const candidate = {
    id: "cand_spec_1",
    text: "Welcome back, ready to continue? ✨",
    category: "greeting_return",
    provider: "ollama",
    model: "llama3.2",
    contextVersion: snapshot.version,
    identityVersion: snapshot.identityVersion,
    circadianPhase: snapshot.circadianPhase,
    generatedAt: now - 15000, // 15 seconds ago
    ttlMilliseconds: 600000,
    expectedDurationMaxSeconds: 3600,
  };

  SpeculativeEngine.setCandidate(candidate);
  assert.equal(SpeculativeEngine.hasCandidate, true);
  assert.equal(SpeculativeEngine.peekCandidate()?.id, "cand_spec_1");

  // Consume valid candidate on user return
  const result = SpeculativeEngine.consumeIfValid(snapshot, defaultSettings, now);
  assert.equal(result.candidate?.id, "cand_spec_1");
  assert.equal(result.candidate?.text, "Welcome back, ready to continue? ✨");

  // Verify candidate was cleared from queue upon consumption
  assert.equal(SpeculativeEngine.hasCandidate, false);
});

test("SpeculativeEngine discards stale candidates on user return", () => {
  MessagePolicyEngine.resetTimers();
  const now = Date.now();
  const snapshot = ContextIntelligence.capture("greeting_return", 300);

  const defaultSettings = {
    enabled: true,
    routingMode: "auto",
    preferredName: "",
    personality: "warm_playful",
    absenceIntervalSeconds: 180,
    quietHoursEnabled: false,
    quietHoursStart: "22:00",
    quietHoursEnd: "08:00",
  };

  // Stale candidate (15 minutes old, exceeds 10m TTL)
  const staleCandidate = {
    id: "cand_stale",
    text: "Still here?",
    category: "greeting_return",
    provider: "ollama",
    model: "llama3.2",
    contextVersion: snapshot.version,
    identityVersion: snapshot.identityVersion,
    circadianPhase: snapshot.circadianPhase,
    generatedAt: now - 900000, // 15 min ago
    ttlMilliseconds: 600000,
    expectedDurationMaxSeconds: 3600,
  };

  SpeculativeEngine.setCandidate(staleCandidate);
  const result = SpeculativeEngine.consumeIfValid(snapshot, defaultSettings, now);

  assert.equal(result.candidate, null);
  assert.equal(result.reason, "TTL_EXPIRED");
  assert.equal(SpeculativeEngine.hasCandidate, false);
});

test("SpeculativeEngine invalidate immediately clears candidate slot", async () => {
  const snapshot = ContextIntelligence.capture("greeting_return", 300);
  SpeculativeEngine.setCandidate({
    id: "cand_temp",
    text: "Temporary",
    category: "greeting_return",
    provider: "ollama",
    model: "llama3.2",
    contextVersion: snapshot.version,
    identityVersion: snapshot.identityVersion,
    circadianPhase: snapshot.circadianPhase,
    generatedAt: Date.now(),
    ttlMilliseconds: 600000,
    expectedDurationMaxSeconds: 3600,
  });

  assert.equal(SpeculativeEngine.hasCandidate, true);
  await SpeculativeEngine.invalidate();
  assert.equal(SpeculativeEngine.hasCandidate, false);
  assert.equal(SpeculativeEngine.isBusy, false);
});
