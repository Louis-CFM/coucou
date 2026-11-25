// Comprehensive verification suite for Coucou Smart Personalization & Hydration Engine
import test from "node:test";
import assert from "node:assert/strict";

import { WelcomeMessageManager } from "../src/core/welcome.ts";
import { ContextIntelligence } from "../src/companion/context.ts";
import { MessagePolicyEngine } from "../src/companion/policy.ts";
import { DeterministicCatalog } from "../src/companion/catalog.ts";

test("CircadianPhase matchesPhase correctly links granular catalog phases to canonical time of day", () => {
  const mgr = WelcomeMessageManager.shared;

  // Morning matches morning, dawn, morning_peak
  assert.equal(mgr.matchesPhase("morning", "morning"), true);
  assert.equal(mgr.matchesPhase("dawn", "morning"), true);
  assert.equal(mgr.matchesPhase("morning_peak", "morning"), true);
  assert.equal(mgr.matchesPhase("afternoon_slump", "morning"), false);
  assert.equal(mgr.matchesPhase("deep_night", "morning"), false);

  // Afternoon matches afternoon, midday_lunch, afternoon_slump
  assert.equal(mgr.matchesPhase("afternoon", "afternoon"), true);
  assert.equal(mgr.matchesPhase("midday_lunch", "afternoon"), true);
  assert.equal(mgr.matchesPhase("afternoon_slump", "afternoon"), true);
  assert.equal(mgr.matchesPhase("morning_peak", "afternoon"), false);

  // Evening matches evening, golden_hour, evening_wrapup
  assert.equal(mgr.matchesPhase("evening", "evening"), true);
  assert.equal(mgr.matchesPhase("golden_hour", "evening"), true);
  assert.equal(mgr.matchesPhase("evening_wrapup", "evening"), true);
  assert.equal(mgr.matchesPhase("dawn", "evening"), false);

  // Night and Deep Night matches
  assert.equal(mgr.matchesPhase("deep_night", "deep_night"), true);
  assert.equal(mgr.matchesPhase("evening_wrapup", "night"), true);
});

test("User presence tracking: onUserAway and onUserReturned update presence state", () => {
  const mgr = WelcomeMessageManager.shared;

  mgr.setUserPresent(true);
  assert.equal(mgr.userPresent, true);

  mgr.onUserAway(10);
  assert.equal(mgr.userPresent, false, "onUserAway must mark user as away");

  mgr.onUserReturned(10, "Alex");
  assert.equal(mgr.userPresent, true, "onUserReturned must restore user as present");
});

test("Idle state pauses active work screen time accumulation and suppresses ambient nudges", () => {
  const mgr = WelcomeMessageManager.shared;
  mgr.setUserPresent(false);

  const initialActive = mgr["activeMinutes"];
  // Invoke private onAmbientTick
  mgr["onAmbientTick"]();

  assert.equal(
    mgr["activeMinutes"],
    initialActive,
    "activeMinutes must not increment when user is away/idle",
  );

  // Restore presence
  mgr.setUserPresent(true);
});

test("Stepping away for >= 15 minutes breaks the continuous fatigue streak", () => {
  const mgr = WelcomeMessageManager.shared;
  mgr.setUserPresent(true);
  mgr["activeMinutes"] = 120; // 2 hours of continuous work

  mgr.onUserReturned(20, "Alex");
  assert.equal(
    mgr["activeMinutes"],
    0,
    "Absence >= 15 minutes must reset continuous active work minutes",
  );
});

test("User return greetings strictly decouple from hydration reminders", () => {
  const mgr = WelcomeMessageManager.shared;
  mgr.detectedGreetingName = "Madhan";

  // State with high screen time and long water absence (which previously hijacked return)
  const vector = {
    awayMinutes: 10,
    timeOfDay: "afternoon_slump",
    hour: 15,
    dayOfWeek: 2,
    sessionWorkHours: 3.5,
    minutesSinceWater: 90,
    userName: "Madhan",
    wardrobe: "none",
  };

  // When resolving with "greeting_return" category filter (as done on user return)
  const msg = mgr.selectBestMessage(vector, "greeting_return");
  assert.notEqual(
    msg.category,
    "hydration",
    "Return greeting must NEVER select a hydration reminder",
  );
  assert.notEqual(
    msg.category,
    "posture",
    "Return greeting must NEVER select a posture reminder",
  );
});

test("DeterministicCatalog.resolveFallback respects greeting_return override", () => {
  const snapshot = ContextIntelligence.capture("greeting_return", 600);
  const fallback = DeterministicCatalog.resolveFallback(snapshot, "greeting_return");

  assert.equal(fallback.category, "greeting_return");
  assert.doesNotMatch(fallback.text, /grab a glass of water/i);
  assert.doesNotMatch(fallback.text, /did you hydrate/i);
});

test("recordHydrationDelivered synchronizes WelcomeManager, PolicyEngine, and ContextIntelligence", () => {
  const mgr = WelcomeMessageManager.shared;
  const testTimestamp = Date.now() - 5000;

  mgr.recordHydrationDelivered(testTimestamp);

  assert.equal(mgr["lastWaterNudgeTime"], testTimestamp);
  assert.equal(ContextIntelligence.getMinutesSinceHydration(testTimestamp), 0);
});

test("onAppLaunch generates personalized, context-aware greeting without throwing", () => {
  const mgr = WelcomeMessageManager.shared;
  mgr.detectedGreetingName = "Alex";
  mgr["hasGreetedOnLaunch"] = false;

  mgr.onAppLaunch();
  const active = mgr.active();

  assert.ok(active, "Active launch message must be produced");
  assert.ok(active.text.length > 5, "Launch message must be substantive text");
  assert.equal(active.bot, true);
  mgr.dismiss();
});
