// Unit tests for Mochi Contextual Companion Welcome-Back Engine (#1055)
// Tests state vector evaluation, hydration triggers, circadian phase mapping,
// user name personalization, recency penalties, and auto-dismiss.

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

test("Personalization interpolates user name correctly", () => {
  const mgr = WelcomeMessageManager.shared;
  mgr.userName = "Madhan";

  const msg = mgr.selectBestMessage({
    awayMinutes: 15,
    timeOfDay: "morning_peak",
    hour: 10,
    dayOfWeek: 2,
    sessionWorkHours: 1,
    minutesSinceWater: 20,
    userName: "Madhan",
    wardrobe: "none",
  });

  const text = msg.template("Madhan");
  assert.ok(text.includes("Madhan"), `Expected message to include Madhan: ${text}`);
});

test("Hydration & Health nudge takes priority when water gap is high and screen time > 1.5h", () => {
  const mgr = WelcomeMessageManager.shared;

  const msg = mgr.selectBestMessage({
    awayMinutes: 15,
    timeOfDay: "afternoon_slump",
    hour: 14,
    dayOfWeek: 3,
    sessionWorkHours: 3.5, // 3.5 hours on screen
    minutesSinceWater: 80,  // No water in 80 mins
    userName: "Madhan",
    wardrobe: "none",
  });

  assert.equal(msg.category, "hydration");
  const text = msg.template("Madhan");
  assert.match(text, /water/i);
});

test("Deep night care messages dominate between 23:00 and 05:00", () => {
  const mgr = WelcomeMessageManager.shared;

  const msg = mgr.selectBestMessage({
    awayMinutes: 12,
    timeOfDay: "deep_night",
    hour: 2, // 2 AM
    dayOfWeek: 4,
    sessionWorkHours: 2,
    minutesSinceWater: 30,
    userName: "Madhan",
    wardrobe: "none",
  });

  assert.equal(msg.phase, "deep_night");
});

test("Recency penalty avoids repeating the same message consecutively", () => {
  const mgr = WelcomeMessageManager.shared;
  mgr.userName = "Madhan";

  const vector = {
    awayMinutes: 15,
    timeOfDay: "morning_peak",
    hour: 10,
    dayOfWeek: 1,
    sessionWorkHours: 1,
    minutesSinceWater: 20,
    userName: "Madhan",
    wardrobe: "none",
  };

  const first = mgr.selectBestMessage(vector);
  // Simulate it being shown
  mgr["recentHistory"].push(first.id);

  const second = mgr.selectBestMessage(vector);
  assert.notEqual(first.id, second.id, "Second message should not be identical to first");
});

test("Dismiss clears active message", () => {
  const mgr = WelcomeMessageManager.shared;
  mgr.onUserReturned(15, "Madhan");
  assert.ok(mgr.active());
  mgr.dismiss();
  assert.equal(mgr.active(), null);
});
