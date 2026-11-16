import test from "node:test";
import assert from "node:assert/strict";

import { ContextIntelligence } from "../src/companion/context.ts";

test("evaluateCircadianPhase accurately categorizes 24-hour cycles", () => {
  const d = new Date();
  
  d.setHours(7, 30, 0, 0);
  assert.equal(ContextIntelligence.evaluateCircadianPhase(d), "morning");

  d.setHours(13, 15, 0, 0);
  assert.equal(ContextIntelligence.evaluateCircadianPhase(d), "afternoon");

  d.setHours(19, 45, 0, 0);
  assert.equal(ContextIntelligence.evaluateCircadianPhase(d), "evening");

  d.setHours(22, 10, 0, 0);
  assert.equal(ContextIntelligence.evaluateCircadianPhase(d), "night");

  d.setHours(2, 20, 0, 0);
  assert.equal(ContextIntelligence.evaluateCircadianPhase(d), "deep_night");
});

test("formatLocalTime pads hours and minutes to 2 digits", () => {
  const d = new Date();
  d.setHours(8, 5, 0, 0);
  assert.equal(ContextIntelligence.formatLocalTime(d), "08:05");

  d.setHours(15, 30, 0, 0);
  assert.equal(ContextIntelligence.formatLocalTime(d), "15:30");
});

test("hashIdentity produces stable, case-insensitive 8-character hex fingerprints", () => {
  const h1 = ContextIntelligence.hashIdentity("Sarah");
  const h2 = ContextIntelligence.hashIdentity("  sarah  ");
  const h3 = ContextIntelligence.hashIdentity("Alex");

  assert.equal(h1, h2, "Hashes should match regardless of casing or whitespace");
  assert.notEqual(h1, h3, "Different names should yield different fingerprints");
  assert.equal(h1.length, 8, "Hash should be 8-character hex string");
});

test("capture generates valid 8-dimensional ContextSnapshot", () => {
  const initialVersion = ContextIntelligence.currentVersion;
  const snapshot = ContextIntelligence.capture("greeting_return", 360);

  assert.equal(snapshot.version, initialVersion);
  assert.equal(snapshot.category, "greeting_return");
  assert.equal(snapshot.awayDurationSeconds, 360);
  assert.ok(["morning", "afternoon", "evening", "night", "deep_night"].includes(snapshot.circadianPhase));
  assert.match(snapshot.localTimeStr, /^\d{2}:\d{2}$/);
  assert.ok(typeof snapshot.dayOfWeek === "string" && snapshot.dayOfWeek.length > 0);
  assert.ok(typeof snapshot.sessionDurationMinutes === "number");
  assert.ok(typeof snapshot.minutesSinceHydration === "number");
  assert.ok(typeof snapshot.identityVersion === "string");
  assert.ok(typeof snapshot.mochiWardrobe === "string");
});

test("incrementVersion strictly monotonically advances the sequence version", () => {
  const v1 = ContextIntelligence.currentVersion;
  const v2 = ContextIntelligence.incrementVersion();
  const v3 = ContextIntelligence.incrementVersion();

  assert.equal(v2, v1 + 1);
  assert.equal(v3, v2 + 1);
});
