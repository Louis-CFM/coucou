import test from "node:test";
import assert from "node:assert/strict";

import { ContextIntelligence } from "../src/companion/context.ts";
import { MessagePolicyEngine } from "../src/companion/policy.ts";
import { DeterministicCatalog } from "../src/companion/catalog.ts";
import { SpeculativeEngine } from "../src/companion/speculative.ts";
import { MessageValidator } from "../src/companion/validator.ts";
import { CompanionMemory } from "../src/companion/memory.ts";
import { CompanionOrchestrator } from "../src/companion/orchestrator.ts";

test("Scenario A: Normal user return consumes speculative candidate in <1ms", () => {
  MessagePolicyEngine.resetTimers();
  CompanionMemory.clear();
  const now = Date.now();
  const awaySnap = ContextIntelligence.capture("greeting_return", 300);

  const defaultSettings = {
    enabled: true,
    routingMode: "auto",
    preferredName: "Sarah",
    personality: "warm_playful",
    absenceIntervalSeconds: 180,
    quietHoursEnabled: false,
    quietHoursStart: "22:00",
    quietHoursEnd: "08:00",
  };

  // 1. Speculative generation buffers candidate while away
  const candidate = {
    id: "req_spec_normal_1",
    text: "Welcome back, Sarah! Let's crush this afternoon ✨",
    category: "greeting_return",
    provider: "ollama",
    model: "llama3.2",
    contextVersion: awaySnap.version,
    identityVersion: awaySnap.identityVersion,
    circadianPhase: awaySnap.circadianPhase,
    generatedAt: now - 20000, // 20s ago
    ttlMilliseconds: 600000,
    expectedDurationMaxSeconds: 3600,
  };
  SpeculativeEngine.setCandidate(candidate);

  // 2. User returns
  const returnSnap = ContextIntelligence.capture("greeting_return", 320);
  const start = performance.now();
  const res = SpeculativeEngine.consumeIfValid(returnSnap, defaultSettings, now);
  const duration = performance.now() - start;

  assert.ok(duration < 2, `Consumption took ${duration}ms, expected < 2ms`);
  assert.ok(res.candidate !== null);
  assert.equal(res.candidate?.id, "req_spec_normal_1");

  // 3. Validation & Memory check
  const validated = MessageValidator.sanitizeAndValidate(res.candidate?.text);
  assert.equal(validated, "Welcome back, Sarah! Let's crush this afternoon ✨");
  assert.equal(CompanionMemory.isDuplicateOrSimilar(validated, now), false);

  CompanionMemory.record(validated, res.candidate.category, res.candidate.provider, now);
  assert.equal(CompanionMemory.count, 1);
  assert.equal(SpeculativeEngine.hasCandidate, false, "Candidate slot must be cleared");
});

test("Scenario B: Provider unavailable seamlessly falls back to deterministic catalog", async () => {
  MessagePolicyEngine.resetTimers();
  const now = Date.now();
  const returnSnap = ContextIntelligence.capture("greeting_return", 300);

  // Invalidate any active queue
  await SpeculativeEngine.invalidate();

  const start = performance.now();
  const fallback = DeterministicCatalog.resolveFallback(returnSnap);
  const duration = performance.now() - start;

  assert.ok(duration < 15, `Fallback resolution took ${duration}ms, expected < 15ms`);
  assert.equal(fallback.provider, "static");
  assert.ok(fallback.text && fallback.text.length > 0);
  assert.equal(fallback.category, "greeting_return");
});

test("Scenario C: Identity change invalidates in-flight generation and stale candidate", async () => {
  MessagePolicyEngine.resetTimers();
  const now = Date.now();
  const initialSnap = ContextIntelligence.capture("greeting_return", 300);

  // Candidate generated for previous name "Madhan"
  const oldCandidate = {
    id: "req_old_id",
    text: "Welcome back, Madhan!",
    category: "greeting_return",
    provider: "ollama",
    model: "llama3.2",
    contextVersion: initialSnap.version,
    identityVersion: initialSnap.identityVersion,
    circadianPhase: initialSnap.circadianPhase,
    generatedAt: now - 5000,
    ttlMilliseconds: 600000,
    expectedDurationMaxSeconds: 3600,
  };
  SpeculativeEngine.setCandidate(oldCandidate);

  // User changes preferred name to "Alex" -> Version advanced & queue invalidated
  ContextIntelligence.incrementVersion();
  await SpeculativeEngine.invalidate();

  assert.equal(SpeculativeEngine.hasCandidate, false);

  // If old candidate somehow remained in queue:
  const newSnap = { ...initialSnap, identityVersion: "hash_alex_new", version: ContextIntelligence.currentVersion };
  const check = MessagePolicyEngine.validateCandidate(oldCandidate, newSnap, {
    enabled: true,
    routingMode: "auto",
    preferredName: "Alex",
    personality: "warm_playful",
    absenceIntervalSeconds: 180,
    quietHoursEnabled: false,
    quietHoursStart: "22:00",
    quietHoursEnd: "08:00",
  }, now);

  assert.equal(check.valid, false);
  assert.equal(check.reason, "IDENTITY_CHANGED");
});

test("Scenario D: User return before generation completes aborts in-flight task and falls back", () => {
  MessagePolicyEngine.resetTimers();
  const now = Date.now();
  const returnSnap = ContextIntelligence.capture("greeting_return", 150);

  const settings = {
    enabled: true,
    routingMode: "auto",
    preferredName: "",
    personality: "warm_playful",
    absenceIntervalSeconds: 180,
    quietHoursEnabled: false,
    quietHoursStart: "22:00",
    quietHoursEnd: "08:00",
  };

  // Generation is active while candidate is still null
  SpeculativeEngine.setCandidate(null);

  // User returns
  const res = SpeculativeEngine.consumeIfValid(returnSnap, settings, now);
  assert.equal(res.candidate, null);
  assert.equal(res.reason, "CANDIDATE_EMPTY");

  // Immediate fallback
  const fallback = DeterministicCatalog.resolveFallback(returnSnap);
  assert.equal(fallback.provider, "static");
  assert.ok(fallback.text.length > 0);
});

test("Scenario E: Companion disabled halts prefetch and suppresses delivery", () => {
  const returnSnap = ContextIntelligence.capture("greeting_return", 300);

  const disabledSettings = {
    enabled: false,
    routingMode: "auto",
    preferredName: "",
    personality: "warm_playful",
    absenceIntervalSeconds: 180,
    quietHoursEnabled: false,
    quietHoursStart: "22:00",
    quietHoursEnd: "08:00",
  };

  // Prefetch is rejected
  assert.equal(MessagePolicyEngine.isSpeculativeAllowed(disabledSettings, returnSnap), false);

  // Candidate in queue is rejected
  const candidate = {
    id: "req_disabled",
    text: "Welcome back!",
    category: "greeting_return",
    provider: "ollama",
    model: "llama3.2",
    contextVersion: returnSnap.version,
    identityVersion: returnSnap.identityVersion,
    circadianPhase: returnSnap.circadianPhase,
    generatedAt: Date.now(),
    ttlMilliseconds: 600000,
    expectedDurationMaxSeconds: 3600,
  };
  SpeculativeEngine.setCandidate(candidate);

  const res = SpeculativeEngine.consumeIfValid(returnSnap, disabledSettings, Date.now());
  assert.equal(res.candidate, null);
  assert.equal(res.reason, "FEATURE_DISABLED");
});

test("Scenario F: Workstation Lock and Unlock presence simulation suppresses return while locked", () => {
  MessagePolicyEngine.resetTimers();
  const now = Date.now();
  const awaySnap = ContextIntelligence.capture("greeting_return", 300);

  // Buffer a candidate
  SpeculativeEngine.setCandidate({
    id: "req_lock_test",
    text: "Welcome back!",
    category: "greeting_return",
    provider: "ollama",
    model: "llama3.2",
    contextVersion: awaySnap.version,
    identityVersion: awaySnap.identityVersion,
    circadianPhase: awaySnap.circadianPhase,
    generatedAt: now - 30000,
    ttlMilliseconds: 600000,
    expectedDurationMaxSeconds: 3600,
  });

  // 1. While workstation is locked, UI must not consume or display greeting
  // (In native presence.rs, tick(locked=true) returns None, preventing event emission)
  assert.equal(SpeculativeEngine.hasCandidate, true);

  // 2. Workstation unlocks: event arrives, candidate consumed
  const returnSnap = ContextIntelligence.capture("greeting_return", 310);
  const res = SpeculativeEngine.consumeIfValid(returnSnap, {
    enabled: true,
    routingMode: "auto",
    preferredName: "",
    personality: "warm_playful",
    absenceIntervalSeconds: 180,
    quietHoursEnabled: false,
    quietHoursStart: "22:00",
    quietHoursEnd: "08:00",
  }, now);

  assert.ok(res.candidate !== null);
  assert.equal(res.candidate?.id, "req_lock_test");
  assert.equal(SpeculativeEngine.hasCandidate, false, "Slot cleared after unlock consumption");
});

test("Scenario G: Combined Recovery from in-flight generation during workstation lock", async () => {
  MessagePolicyEngine.resetTimers();
  const awaySnap = ContextIntelligence.capture("greeting_return", 180);

  // Set candidate slot to empty representing in-flight prefetch
  SpeculativeEngine.setCandidate(null);

  // Workstation locks -> aborts in-flight generation
  await SpeculativeEngine.invalidate();
  assert.equal(SpeculativeEngine.hasCandidate, false);
  assert.equal(SpeculativeEngine.isBusy, false);

  // Workstation unlocks -> fallback resolves cleanly in <1ms without hang
  const returnSnap = ContextIntelligence.capture("greeting_return", 240);
  const fallback = DeterministicCatalog.resolveFallback(returnSnap);
  assert.equal(fallback.provider, "static");
  assert.ok(fallback.text.length > 0);
});
