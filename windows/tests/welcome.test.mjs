// Unit tests for Mochi Contextual Companion Welcome-Back & Identity Engine
// Tests state vector evaluation, 4-tier identity resolution priority,
// preferred name override & reset, neutral greeting fallbacks,
// hydration triggers, circadian phase mapping, and auto-dismiss.

import { test } from "node:test";
import assert from "node:assert/strict";
import { WelcomeMessageManager } from "../src/core/welcome.ts";

test("WelcomeMessageManager computes circadian phases correctly across 24h", () => {
  const mgr = WelcomeMessageManager.shared;

  // Dawn (6 AM)
  const dawn = mgr.computeStateVector(15, new Date(2026, 10, 14, 6, 0).getTime());
  assert.equal(dawn.timeOfDay, "dawn");

  // Morning Peak (10 AM)
  const morning = mgr.computeStateVector(15, new Date(2026, 10, 14, 10, 0).getTime());
  assert.equal(morning.timeOfDay, "morning_peak");

  // Midday Lunch (12:30 PM)
  const lunch = mgr.computeStateVector(15, new Date(2026, 10, 14, 12, 30).getTime());
  assert.equal(lunch.timeOfDay, "midday_lunch");

  // Afternoon Slump (3 PM)
  const slump = mgr.computeStateVector(15, new Date(2026, 10, 14, 15, 0).getTime());
  assert.equal(slump.timeOfDay, "afternoon_slump");

  // Golden Hour (6 PM)
  const golden = mgr.computeStateVector(15, new Date(2026, 10, 14, 18, 0).getTime());
  assert.equal(golden.timeOfDay, "golden_hour");

  // Evening Wrap-up (8:30 PM)
  const evening = mgr.computeStateVector(15, new Date(2026, 10, 14, 20, 30).getTime());
  assert.equal(evening.timeOfDay, "evening_wrapup");

  // Deep Night (1 AM)
  const night = mgr.computeStateVector(15, new Date(2026, 10, 14, 1, 0).getTime());
  assert.equal(night.timeOfDay, "deep_night");
});

test("4-tier identity resolution priority works correctly", () => {
  const mgr = WelcomeMessageManager.shared;

  // Reset to clean slate
  mgr.preferredName = "";
  mgr.detectedGreetingName = "";
  assert.equal(mgr.resolvedGreetingName, "", "Clean slate must yield neutral empty name");

  // Priority 2: Detected Windows identity
  mgr.detectedGreetingName = "Alex";
  assert.equal(mgr.resolvedGreetingName, "Alex", "Must use detected Windows identity when preferred name is unset");

  // Priority 1: Explicit user preferred name overrides detected identity
  mgr.preferredName = "Lex";
  assert.equal(mgr.resolvedGreetingName, "Lex", "Preferred name must take precedence over detected identity");

  // Clearing preferred name immediately restores detected identity
  mgr.preferredName = "";
  assert.equal(mgr.resolvedGreetingName, "Alex", "Clearing preferred name must restore detected identity immediately");

  // Cleaning detected name falls back to neutral
  mgr.detectedGreetingName = "";
  assert.equal(mgr.resolvedGreetingName, "", "When both are empty, must fall back to neutral");
});

test("Personalization interpolates arbitrary names across different Windows users", () => {
  const mgr = WelcomeMessageManager.shared;

  for (const name of ["Alex", "Sarah", "José", "Anne-Marie", "Wei"]) {
    mgr.detectedGreetingName = name;
    mgr.preferredName = "";
    assert.equal(mgr.resolvedGreetingName, name);

    const msg = mgr.selectBestMessage({
      awayMinutes: 15,
      timeOfDay: "morning_peak",
      hour: 10,
      dayOfWeek: 2,
      sessionWorkHours: 1,
      minutesSinceWater: 20,
      userName: mgr.resolvedGreetingName,
      wardrobe: "none",
    });

    const text = msg.template(mgr.resolvedGreetingName);
    assert.ok(text.includes(name), `Expected greeting to include ${name}: ${text}`);
    assert.doesNotMatch(text, /undefined|null/i);
  }
});

test("Neutral fallback generates natural greetings when no name is available", () => {
  const mgr = WelcomeMessageManager.shared;
  mgr.preferredName = "";
  mgr.detectedGreetingName = "";

  const vector = {
    awayMinutes: 15,
    timeOfDay: "morning_peak",
    hour: 10,
    dayOfWeek: 1,
    sessionWorkHours: 1,
    minutesSinceWater: 20,
    userName: mgr.resolvedGreetingName, // ""
    wardrobe: "none",
  };

  const msg = mgr.selectBestMessage(vector);
  const text = msg.template(mgr.resolvedGreetingName);

  // Must not have placeholder, undefined, null, or empty comma artifacts like "Hey , you're back!"
  assert.doesNotMatch(text, /undefined|null|\bHey ,/i);
  assert.ok(text.length > 5, "Neutral greeting must be a complete, natural sentence");
});

test("Hydration & Health nudge takes priority when water gap is high and screen time > 1.5h", () => {
  const mgr = WelcomeMessageManager.shared;
  mgr.detectedGreetingName = "Alex";

  const msg = mgr.selectBestMessage({
    awayMinutes: 15,
    timeOfDay: "afternoon_slump",
    hour: 14,
    dayOfWeek: 3,
    sessionWorkHours: 3.5, // 3.5 hours on screen
    minutesSinceWater: 80,  // No water in 80 mins
    userName: mgr.resolvedGreetingName,
    wardrobe: "none",
  });

  assert.equal(msg.category, "hydration");
  const text = msg.template(mgr.resolvedGreetingName);
  assert.match(text, /water/i);
  assert.ok(text.includes("Alex"));
});

test("Deep night care messages dominate between 23:00 and 05:00", () => {
  const mgr = WelcomeMessageManager.shared;
  mgr.detectedGreetingName = "Sarah";

  const msg = mgr.selectBestMessage({
    awayMinutes: 12,
    timeOfDay: "deep_night",
    hour: 2, // 2 AM
    dayOfWeek: 4,
    sessionWorkHours: 2,
    minutesSinceWater: 30,
    userName: mgr.resolvedGreetingName,
    wardrobe: "none",
  });

  assert.equal(msg.phase, "deep_night");
});

test("Recency penalty avoids repeating the same message consecutively", () => {
  const mgr = WelcomeMessageManager.shared;
  mgr.detectedGreetingName = "Alex";

  const vector = {
    awayMinutes: 15,
    timeOfDay: "morning_peak",
    hour: 10,
    dayOfWeek: 1,
    sessionWorkHours: 1,
    minutesSinceWater: 20,
    userName: mgr.resolvedGreetingName,
    wardrobe: "none",
  };

  const first = mgr.selectBestMessage(vector);
  mgr["recentHistory"].push(first.id);

  const second = mgr.selectBestMessage(vector);
  assert.notEqual(first.id, second.id, "Second message should not be identical to first");
});

test("Dismiss clears active message", () => {
  const mgr = WelcomeMessageManager.shared;
  mgr.detectedGreetingName = "Alex";
  mgr.onUserReturned(15, "Alex");
  assert.ok(mgr.active());
  mgr.dismiss();
  assert.equal(mgr.active(), null);
});

test("Launch greeting formats correctly and produces valid closedContent structure", async () => {
  const mgr = WelcomeMessageManager.shared;
  mgr.detectedGreetingName = "Madhan";
  mgr["hasGreetedOnLaunch"] = false;
  mgr.onAppLaunch();
  const active = mgr.active();
  assert.ok(active, "Active greeting message must exist on launch");
  assert.equal(active.bot, true, "Greeting must request bot avatar");
  assert.match(active.text, /Madhan/);

  // Test closedContent produces isWelcome = true
  const { closedContent } = await import("../src/core/closed.ts");
  const content = closedContent("mochi", {
    now: new Date(),
    locale: "en",
    planUsage: null,
    music: null,
    welcome: { text: active.text, bot: active.bot },
  });

  assert.ok(content);
  assert.equal(content.isWelcome, true);
  assert.equal(content.bot, true);
  assert.equal(content.text, active.text);
  mgr.dismiss();
});
