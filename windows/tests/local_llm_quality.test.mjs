// CouCou Local LLM Reasoning Control & Personalized Message Quality Tests
// Verifies reasoning suppression, response length compliance, activity grounding,
// actionable suggestions, and disconnect/timeout resilience.

import test from "node:test";
import assert from "node:assert/strict";

import { ContextIntelligence } from "../src/companion/context.ts";
import { PromptBuilder } from "../src/companion/prompt.ts";
import { MessageValidator } from "../src/companion/validator.ts";
import { CompanionOrchestrator } from "../src/companion/orchestrator.ts";
import { DeterministicCatalog } from "../src/companion/catalog.ts";
import { MessagePolicyEngine } from "../src/companion/policy.ts";

test("1. Reasoning suppression: strips thought blocks, rejects unclosed think tags & deliberation headers", () => {
  // Case A: Closed <think> block stripped cleanly
  const withClosedThink = "<think>The user has been coding for 3 hours. They need a rest.</think>You've been in VS Code for 3 hours; take a quick eye break.";
  const cleanedA = MessageValidator.sanitizeAndValidate(withClosedThink);
  assert.equal(cleanedA, "You've been in VS Code for 3 hours; take a quick eye break.");
  assert.ok(!cleanedA.includes("<think>"));
  assert.ok(!cleanedA.includes("</think>"));

  // Case B: Unclosed <think> tag indicates cutoff deliberation - must be rejected
  const unclosedThink = "<think>I should tell the user to stretch their neck and sip water because they've been at the desk";
  const cleanedB = MessageValidator.sanitizeAndValidate(unclosedThink);
  assert.equal(cleanedB, null, "Unclosed think tags must be strictly rejected");

  // Case C: Leaked deliberation headers must be rejected
  const withHeader = "Thinking Process:\n1. User has 15 app switches.\nOutput: Try closing extra tabs.";
  const cleanedC = MessageValidator.sanitizeAndValidate(withHeader);
  assert.equal(cleanedC, null, "Reasoning headers must be rejected");

  // Case D: Pure thinking response with no content must return null
  const onlyThink = "<think>Just internal deliberation with no final message</think>";
  const cleanedD = MessageValidator.sanitizeAndValidate(onlyThink);
  assert.equal(cleanedD, null, "Empty content after stripping thinking must return null");
});

test("2. Response length compliance: enforces maximum 2 sentences and Dynamic Island fit", () => {
  // Case A: 1 short sentence passes unchanged
  const oneSentence = "Continuous coding flow for 2 hours. Take a quick stretch.";
  const cleanedA = MessageValidator.sanitizeAndValidate(oneSentence);
  assert.equal(cleanedA, oneSentence);

  // Case B: 3 sentences truncated to maximum 2 sentences
  const threeSentences = "You've coded for 180 minutes. Save your progress now. Don't forget to hydrate.";
  const cleanedB = MessageValidator.sanitizeAndValidate(threeSentences);
  assert.equal(cleanedB, "You've coded for 180 minutes. Save your progress now.");

  // Case C: Long run-on sentence clamped gracefully with ellipsis at word boundary
  const longSentence = "You have been diligently programming in Visual Studio Code for a very extensive period of time without taking any physical breaks whatsoever.";
  const cleanedC = MessageValidator.sanitizeAndValidate(longSentence);
  assert.ok(cleanedC !== null);
  assert.ok(cleanedC.endsWith("…"), "Clamped text must end with ellipsis");
  assert.ok(cleanedC.length <= MessageValidator.MAX_GRAPHEMES + 5, "Clamped text must fit within bounds");
});

test("3. Grounding verification across 5 distinct activity contexts", () => {
  // Context 1: 3 hours coding in VS Code with frequent browser switching
  ContextIntelligence.setActivityContextOverride({
    currentApp: "Visual Studio Code",
    appSwitchCount: 16,
    continuousAppMinutes: 180,
    recentApps: ["Visual Studio Code", "Google Chrome"],
  });
  const snap1 = ContextIntelligence.capture("work_streak", 0);
  assert.equal(snap1.currentApp, "Visual Studio Code");
  assert.equal(snap1.continuousAppMinutes, 180);
  assert.equal(snap1.appSwitchCount, 16);
  assert.ok(snap1.activitySummary.includes("Visual Studio Code"));
  assert.ok(snap1.activitySummary.includes("Frequent switching"));

  const payload1 = PromptBuilder.buildPayload(snap1, "warm_playful", [], "ollama", "qwen3.5:4b");
  const parsed1 = JSON.parse(payload1.userContextJson);
  assert.equal(parsed1.active_application, "Visual Studio Code");
  assert.equal(parsed1.continuous_app_minutes, 180);
  assert.equal(parsed1.recent_app_switches, 16);

  // Context 2: Long continuous coding session with zero switching
  ContextIntelligence.setActivityContextOverride({
    currentApp: "Visual Studio Code",
    appSwitchCount: 0,
    continuousAppMinutes: 120,
    recentApps: ["Visual Studio Code"],
  });
  const snap2 = ContextIntelligence.capture("work_streak", 0);
  assert.equal(snap2.continuousAppMinutes, 120);
  assert.equal(snap2.appSwitchCount, 0);
  assert.ok(snap2.activitySummary.includes("Long continuous session"));

  // Context 3: Frequent application switching over short period (multitasking)
  ContextIntelligence.setActivityContextOverride({
    currentApp: "Slack",
    appSwitchCount: 22,
    continuousAppMinutes: 3,
    recentApps: ["Slack", "Google Chrome", "Visual Studio Code", "Spotify"],
  });
  const snap3 = ContextIntelligence.capture("work_streak", 0);
  assert.equal(snap3.appSwitchCount, 22);
  assert.ok(snap3.activitySummary.includes("Frequent switching"));

  // Context 4: Research / documentation browsing
  ContextIntelligence.setActivityContextOverride({
    currentApp: "Google Chrome",
    appSwitchCount: 2,
    continuousAppMinutes: 45,
    recentApps: ["Google Chrome"],
  });
  const snap4 = ContextIntelligence.capture("work_streak", 0);
  assert.equal(snap4.currentApp, "Google Chrome");
  assert.ok(snap4.activitySummary.includes("Google Chrome"));

  // Context 5: Return after an away period
  ContextIntelligence.setActivityContextOverride({
    currentApp: "Visual Studio Code",
    appSwitchCount: 1,
    continuousAppMinutes: 2,
    recentApps: ["Visual Studio Code"],
  });
  const snap5 = ContextIntelligence.capture("greeting_return", 1800); // 30 minutes away
  assert.equal(snap5.awayDurationSeconds, 1800);
  const payload5 = PromptBuilder.buildPayload(snap5, "warm_playful", [], "ollama", "qwen3.5:4b");
  const parsed5 = JSON.parse(payload5.userContextJson);
  assert.equal(parsed5.away_minutes, 30);

  // Clean up test override
  ContextIntelligence.setActivityContextOverride(null);
});

test("4. Generic motivational filler rejection", () => {
  // Pure ungrounded slogans must be rejected
  assert.equal(MessageValidator.sanitizeAndValidate("You got this!"), null);
  assert.equal(MessageValidator.sanitizeAndValidate("Believe in yourself!"), null);
  assert.equal(MessageValidator.sanitizeAndValidate("Keep pushing!"), null);
  assert.equal(MessageValidator.sanitizeAndValidate("You got this! Keep pushing!"), null);
  assert.equal(MessageValidator.sanitizeAndValidate("Stay positive!"), null);

  // Grounded suggestions with actual context must pass
  const groundedMsg = "You've coded for 180 minutes; save your work now to lock in progress.";
  assert.equal(MessageValidator.sanitizeAndValidate(groundedMsg), groundedMsg);

  const hydrationMsg = "Quick water break to stay energized during your coding stretch.";
  assert.equal(MessageValidator.sanitizeAndValidate(hydrationMsg), hydrationMsg);
});

test("5. Disconnect / timeout resilience and deterministic catalog fallback", async () => {
  MessagePolicyEngine.resetTimers();
  const snap = ContextIntelligence.capture("greeting_return", 300);

  // When Ollama is unreachable or times out, DeterministicCatalog provides instant fallback
  const start = performance.now();
  const fallback = DeterministicCatalog.resolveFallback(snap);
  const duration = performance.now() - start;

  assert.ok(duration < 15, `Fallback resolution took ${duration}ms, expected < 15ms`);
  assert.equal(fallback.provider, "static");
  assert.ok(fallback.text && fallback.text.length > 0);
  assert.equal(fallback.category, "greeting_return");

  // Validate fallback passes MessageValidator
  const validatedFallback = MessageValidator.sanitizeAndValidate(fallback.text);
  assert.ok(validatedFallback !== null, "Fallback text must pass validation");
  assert.ok(validatedFallback.length > 5);
});
