import test from "node:test";
import assert from "node:assert/strict";

import { ContextIntelligence } from "../src/companion/context.ts";
import { MessagePolicyEngine } from "../src/companion/policy.ts";
import { DeterministicCatalog } from "../src/companion/catalog.ts";

test("DeterministicCatalog resolves valid static fallback candidate in <1ms", () => {
  const snapshot = ContextIntelligence.capture("greeting_return", 300);
  const start = performance.now();
  const fallback = DeterministicCatalog.resolveFallback(snapshot);
  const duration = performance.now() - start;

  assert.ok(duration < 15, `Fallback resolution took ${duration}ms, expected < 15ms`);
  assert.equal(fallback.provider, "static");
  assert.equal(fallback.category, "greeting_return");
  assert.ok(fallback.text && fallback.text.length > 0);
  assert.equal(fallback.identityVersion, snapshot.identityVersion);
});

test("isQuietHours handles overnight and same-day quiet ranges", () => {
  // Overnight range 22:00 -> 08:00
  assert.equal(MessagePolicyEngine.isQuietHours("23:30", true, "22:00", "08:00"), true);
  assert.equal(MessagePolicyEngine.isQuietHours("03:15", true, "22:00", "08:00"), true);
  assert.equal(MessagePolicyEngine.isQuietHours("07:59", true, "22:00", "08:00"), true);
  assert.equal(MessagePolicyEngine.isQuietHours("08:00", true, "22:00", "08:00"), false);
  assert.equal(MessagePolicyEngine.isQuietHours("14:30", true, "22:00", "08:00"), false);

  // When quiet hours are disabled, always returns false
  assert.equal(MessagePolicyEngine.isQuietHours("23:30", false, "22:00", "08:00"), false);

  // Same-day range 13:00 -> 15:00
  assert.equal(MessagePolicyEngine.isQuietHours("14:00", true, "13:00", "15:00"), true);
  assert.equal(MessagePolicyEngine.isQuietHours("16:00", true, "13:00", "15:00"), false);
});

test("canTriggerReturnGreeting enforces 2.5-minute return cooldown", () => {
  MessagePolicyEngine.resetTimers();
  const now = Date.now();

  assert.equal(MessagePolicyEngine.canTriggerReturnGreeting(now), true);

  MessagePolicyEngine.recordDelivered("greeting_return", now);
  assert.equal(MessagePolicyEngine.canTriggerReturnGreeting(now + 1000), false);
  assert.equal(MessagePolicyEngine.canTriggerReturnGreeting(now + 60000), false);

  // After 2.5 minutes (150,000ms)
  assert.equal(MessagePolicyEngine.canTriggerReturnGreeting(now + 150001), true);
});

test("determineCategory prioritizes deep night and absence return", () => {
  const d = new Date();
  d.setHours(2, 0, 0, 0);
  const nightSnap = ContextIntelligence.capture("greeting_return", 0, d);
  assert.equal(MessagePolicyEngine.determineCategory(nightSnap), "late_night_care");

  d.setHours(14, 0, 0, 0);
  const returnSnap = ContextIntelligence.capture("greeting_return", 300, d);
  assert.equal(MessagePolicyEngine.determineCategory(returnSnap), "greeting_return");
});

test("validateCandidate executes 7-point validity evaluation on return", () => {
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

  const validCandidate = {
    id: "cand_1",
    text: "Welcome back! Let's get to work ✨",
    category: "greeting_return",
    provider: "ollama",
    model: "llama3.2",
    contextVersion: snapshot.version,
    identityVersion: snapshot.identityVersion,
    circadianPhase: snapshot.circadianPhase,
    generatedAt: now - 30000, // 30s ago
    ttlMilliseconds: 600000,
    expectedDurationMaxSeconds: 3600,
  };

  // 1. Valid candidate passes
  const res1 = MessagePolicyEngine.validateCandidate(validCandidate, snapshot, defaultSettings, now);
  assert.equal(res1.valid, true);

  // 2. Empty candidate fails
  const res2 = MessagePolicyEngine.validateCandidate(null, snapshot, defaultSettings, now);
  assert.equal(res2.valid, false);
  assert.equal(res2.reason, "CANDIDATE_EMPTY");

  // 3. TTL expired (> 10m)
  const expiredCandidate = { ...validCandidate, generatedAt: now - 650000 };
  const res3 = MessagePolicyEngine.validateCandidate(expiredCandidate, snapshot, defaultSettings, now);
  assert.equal(res3.valid, false);
  assert.equal(res3.reason, "TTL_EXPIRED");

  // 4. Identity changed
  const idChangedCandidate = { ...validCandidate, identityVersion: "different_hash" };
  const res4 = MessagePolicyEngine.validateCandidate(idChangedCandidate, snapshot, defaultSettings, now);
  assert.equal(res4.valid, false);
  assert.equal(res4.reason, "IDENTITY_CHANGED");

  // 5. Circadian transition
  const circCandidate = { ...validCandidate, circadianPhase: "deep_night" };
  const res5 = MessagePolicyEngine.validateCandidate(circCandidate, { ...snapshot, circadianPhase: "morning" }, defaultSettings, now);
  assert.equal(res5.valid, false);
  assert.equal(res5.reason, "CIRCADIAN_TRANSITION");

  // 6. Feature disabled
  const res6 = MessagePolicyEngine.validateCandidate(validCandidate, snapshot, { ...defaultSettings, enabled: false }, now);
  assert.equal(res6.valid, false);
  assert.equal(res6.reason, "FEATURE_DISABLED");
});
