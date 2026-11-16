import test from "node:test";
import assert from "node:assert/strict";

import { ContextIntelligence } from "../src/companion/context.ts";
import { PromptBuilder } from "../src/companion/prompt.ts";
import { CompanionOrchestrator } from "../src/companion/orchestrator.ts";

test("PromptBuilder provides distinct guidelines for all 4 personality modes", () => {
  const modes = ["warm_playful", "witty_sarcastic", "zen_mindful", "focus_coach"];
  const instructions = modes.map(m => PromptBuilder.getPersonalityInstruction(m));

  assert.equal(instructions.length, 4);
  // Verify each mode has unique keywords
  assert.ok(instructions[0].includes("Cheerful") || instructions[0].includes("Warm"));
  assert.ok(instructions[1].includes("Witty") || instructions[1].includes("sarcastic"));
  assert.ok(instructions[2].includes("Calming") || instructions[2].includes("breathing"));
  assert.ok(instructions[3].includes("encouraging") || instructions[3].includes("milestones"));
});

test("PromptBuilder builds hardened payload and isolates context in JSON", () => {
  const snapshot = ContextIntelligence.capture("greeting_return", 300);
  const exclusions = ["Msg 1", "Msg 2", "Msg 3", "Msg 4", "Msg 5", "Msg 6"];

  const payload = PromptBuilder.buildPayload(
    snapshot,
    "warm_playful",
    exclusions,
    "ollama",
    "llama3.2",
    "http://127.0.0.1:11434",
    2500,
  );

  assert.ok(payload.systemPrompt.includes("You are Mochi"));
  assert.ok(payload.systemPrompt.includes("CRITICAL FORMAT RULES"));
  assert.equal(payload.recentExclusions.length, 5, "Exclusions must be capped at 5");

  // Validate JSON serialization
  const parsed = JSON.parse(payload.userContextJson);
  assert.equal(parsed.category, "greeting_return");
  assert.equal(parsed.away_minutes, 5);
  assert.equal(parsed.circadian_phase, snapshot.circadianPhase);
});

test("CompanionOrchestrator enforces routing modes and consent boundaries", async () => {
  const snapshot = ContextIntelligence.capture("greeting_return", 300);

  const defaultConsent = {
    version: 2,
    consentedProviders: { anthropic: false, openai: false },
    consentedCategories: { userGreetingName: true, sessionMetrics: true },
    grantedAtTimestamp: null,
    consentRevoked: false,
  };

  // 1. Classic mode returns null (bypasses AI)
  const classicSettings = {
    enabled: true,
    routingMode: "classic",
    preferredName: "",
    personality: "warm_playful",
    absenceIntervalSeconds: 180,
    quietHoursEnabled: false,
    quietHoursStart: "22:00",
    quietHoursEnd: "08:00",
  };
  const res1 = await CompanionOrchestrator.generate(snapshot, classicSettings, defaultConsent);
  assert.equal(res1, null);

  // 2. Disabled setting returns null
  const disabledSettings = { ...classicSettings, enabled: false, routingMode: "auto" };
  const res2 = await CompanionOrchestrator.generate(snapshot, disabledSettings, defaultConsent);
  assert.equal(res2, null);

  // 3. Cloud mode without consent returns null
  const cloudSettings = { ...classicSettings, routingMode: "cloud_only" };
  const res3 = await CompanionOrchestrator.generate(snapshot, cloudSettings, defaultConsent);
  assert.equal(res3, null);

  // 4. Cloud mode with revoked consent returns null
  const revokedConsent = {
    ...defaultConsent,
    consentedProviders: { anthropic: true, openai: true },
    consentRevoked: true,
  };
  const res4 = await CompanionOrchestrator.generate(snapshot, cloudSettings, revokedConsent);
  assert.equal(res4, null);
});
