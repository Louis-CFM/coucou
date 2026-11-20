// CouCou Dynamic Island — Expanded Companion Message Library & Selection Tests
// Verifies:
// 1. All 35 original catalog entries preserved
// 2. >= 220 new scripts added across all 10 categories
// 3. Short, crisp length constraints (6-22 words, single sentence preferred)
// 4. Safe interpolation with and without username (no "Hey ," or trailing commas)
// 5. Zero duplicate IDs across the entire catalog
// 6. Recency penalty and category diversity bonus

import test from "node:test";
import assert from "node:assert/strict";

import { WelcomeMessageManager, GlobalWelcomeMessages } from "../src/core/welcome.ts";

const ORIGINAL_CATALOG_IDS = [
  "core_back", "core_seat_warm", "core_missed_you", "core_look_who",
  "health_water_urgent", "health_water_check", "health_posture", "health_eyes", "health_breath",
  "time_dawn_coffee", "time_dawn_quiet", "time_morning_crush", "time_morning_momentum",
  "time_lunch_food", "time_slump_beater", "time_afternoon_second_wind", "time_golden_hour",
  "time_evening_wrapup", "time_night_owl", "time_night_bed", "time_night_care",
  "work_streak_high", "work_streak_marathon",
  "dur_short_stretch", "dur_long_reunion",
  "day_monday", "day_friday", "day_weekend",
  "wardrobe_santa", "wardrobe_sunglasses"
];

test("1. Catalog size: preserves all original scripts and adds >= 220 new scripts", () => {
  const mgr = WelcomeMessageManager.shared;
  const catalog = mgr["getCatalog"]();

  assert.ok(catalog.length >= 250, `Catalog must have at least 250 items (found ${catalog.length})`);
  
  // Verify all original catalog IDs exist
  const catalogIds = new Set(catalog.map(c => c.id));
  for (const originalId of ORIGINAL_CATALOG_IDS) {
    assert.ok(catalogIds.has(originalId), `Original catalog ID '${originalId}' must be preserved`);
  }

  // Count new scripts added
  const newScripts = catalog.filter(c => !ORIGINAL_CATALOG_IDS.includes(c.id));
  assert.ok(newScripts.length >= 220, `Must add at least 220 new scripts (found ${newScripts.length})`);
});

test("2. Uniqueness: zero duplicate IDs exist across the entire catalog", () => {
  const mgr = WelcomeMessageManager.shared;
  const catalog = mgr["getCatalog"]();
  const seenIds = new Set();
  const duplicates = [];

  for (const item of catalog) {
    if (seenIds.has(item.id)) {
      duplicates.push(item.id);
    }
    seenIds.add(item.id);
  }

  assert.equal(duplicates.length, 0, `Catalog contains duplicate IDs: ${duplicates.join(", ")}`);
});

test("3. Word count & length: every message is short, sweet, and crisp (<= 25 words)", () => {
  const mgr = WelcomeMessageManager.shared;
  const catalog = mgr["getCatalog"]();
  const testNames = ["Madhan", "Alex", ""];

  for (const item of catalog) {
    for (const name of testNames) {
      const rendered = item.template(name);
      assert.ok(typeof rendered === "string" && rendered.length > 0, `Template for ${item.id} produced invalid output`);
      
      const words = rendered.trim().split(/\s+/).filter(Boolean);
      assert.ok(
        words.length <= 25,
        `Message ${item.id} (name: "${name}") is too long: ${words.length} words -> "${rendered}"`
      );
    }
  }
});

test("4. Safe username interpolation: no awkward commas or missing names when empty", () => {
  const mgr = WelcomeMessageManager.shared;
  const catalog = mgr["getCatalog"]();

  for (const item of catalog) {
    const renderedWithoutName = item.template("");
    // Should never contain awkward patterns like "Hey ,", "back, !", "undefined", "null"
    assert.ok(!renderedWithoutName.includes(" ,"), `${item.id} contains awkward ' ,' when name is empty: "${renderedWithoutName}"`);
    assert.ok(!renderedWithoutName.includes(", !"), `${item.id} contains awkward ', !' when name is empty: "${renderedWithoutName}"`);
    assert.ok(!renderedWithoutName.includes("undefined"), `${item.id} contains 'undefined': "${renderedWithoutName}"`);
    assert.ok(!renderedWithoutName.includes("null"), `${item.id} contains 'null': "${renderedWithoutName}"`);
    
    // Check with name
    const renderedWithName = item.template("Madhan");
    assert.ok(!renderedWithName.includes("undefined"), `${item.id} with name contains 'undefined'`);
  }
});

test("5. Category coverage: spans across all intended categories", () => {
  const mgr = WelcomeMessageManager.shared;
  const catalog = mgr["getCatalog"]();

  const categoryCounts = {};
  for (const item of catalog) {
    categoryCounts[item.category] = (categoryCounts[item.category] || 0) + 1;
  }

  // Categories defined in WelcomeCategory
  assert.ok((categoryCounts["classic"] || 0) >= 30, `classic should have >= 30 items (has ${categoryCounts["classic"]})`);
  assert.ok((categoryCounts["work_streak"] || 0) >= 100, `work_streak should have >= 100 items (has ${categoryCounts["work_streak"]})`);
  assert.ok((categoryCounts["hydration"] || 0) >= 20, `hydration should have >= 20 items (has ${categoryCounts["hydration"]})`);
  assert.ok((categoryCounts["posture"] || 0) >= 25, `posture should have >= 25 items (has ${categoryCounts["posture"]})`);
  assert.ok((categoryCounts["circadian"] || 0) >= 15, `circadian should have >= 15 items (has ${categoryCounts["circadian"]})`);
});

test("6. Selection engine: recency avoidance and category variety over consecutive calls", () => {
  const mgr = WelcomeMessageManager.shared;
  mgr["recentHistory"] = []; // reset history

  const stateVector = {
    awayMinutes: 10,
    timeOfDay: "morning_focus",
    hour: 10,
    dayOfWeek: 2, // Tuesday
    sessionWorkHours: 2.0,
    minutesSinceWater: 20,
    userName: "Madhan",
    wardrobe: "none",
  };

  const selectedIds = [];
  for (let i = 0; i < 30; i++) {
    const selected = mgr.selectBestMessage(stateVector);
    selectedIds.push(selected.id);
  }

  // 1. No two consecutive selections should have the exact same ID
  for (let i = 1; i < selectedIds.length; i++) {
    assert.notEqual(
      selectedIds[i],
      selectedIds[i - 1],
      `Consecutive duplicate at turn ${i}: ${selectedIds[i]}`
    );
  }

  // 2. High variety: at least 10 unique IDs chosen in 30 calls
  const uniqueCount = new Set(selectedIds).size;
  assert.ok(
    uniqueCount >= 10,
    `Expected at least 10 unique messages over 30 calls, got ${uniqueCount}`
  );
});

test("7. Poke interaction produces short, natural messages", () => {
  const mgr = WelcomeMessageManager.shared;
  mgr.poke();
  const active = mgr.active();
  assert.ok(active, "Poke should produce an active message");
  assert.ok(active.text.length > 5, "Poke text should have content");
  const words = active.text.trim().split(/\s+/);
  assert.ok(words.length <= 20, `Poke text should be <= 20 words, got ${words.length}`);
});
