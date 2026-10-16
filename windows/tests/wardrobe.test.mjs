// Mochi's wardrobe: season → outfit, stored preference → outfit (src/mochi/wardrobe.ts).
// Mirrors tests/MochiWardrobeTests.swift so both platforms dress Mochi alike.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  MAIN_MOCHI, OUTFIT_SELECTIONS, OUTFIT_LABELS, SeasonCache, easterDate, lookOf, mochiKey,
  parseOutfit, parseWardrobeMode, resolveOutfit, seasonalOutfit, setLook, wardrobeHeader,
} from "../src/mochi/wardrobe.ts";
import { DEFAULT_SETTINGS } from "../src/core/state.ts";

/** A local calendar day, at noon so no time zone can push it into the next one. */
const day = (y, m, d) => new Date(y, m - 1, d, 12);
const season = (y, m, d) => seasonalOutfit(day(y, m, d));

test("witch hat from October 1 to November 1", () => {
  assert.equal(season(2026, 9, 30), "none");
  assert.equal(season(2026, 10, 1), "witchHat");
  assert.equal(season(2026, 10, 31), "witchHat");
  assert.equal(season(2026, 11, 1), "witchHat");
  assert.equal(season(2026, 11, 2), "none");
});

test("Santa hat from December 1 to 26", () => {
  assert.equal(season(2026, 11, 30), "none");
  assert.equal(season(2026, 12, 1), "santaHat");
  assert.equal(season(2026, 12, 26), "santaHat");
  assert.equal(season(2026, 12, 27), "none");
});

test("party hat from December 31 to January 2", () => {
  assert.equal(season(2026, 12, 30), "none");
  assert.equal(season(2026, 12, 31), "partyHat");
  assert.equal(season(2027, 1, 1), "partyHat");
  assert.equal(season(2027, 1, 2), "partyHat");
  assert.equal(season(2027, 1, 3), "none");
});

test("nothing around Valentine's day (the hearts headband is gone)", () => {
  for (const d of [12, 13, 15, 16]) assert.equal(season(2026, 2, d), "none");
});

test("Easter falls where the calendar says", () => {
  assert.deepEqual(easterDate(2026), [4, 5]);
  assert.deepEqual(easterDate(2027), [3, 28]);
  assert.deepEqual(easterDate(2028), [4, 16]);
  assert.deepEqual(easterDate(2019), [4, 21]);
});

test("bunny ears from two days before Easter to the day after", () => {
  // Easter 2026 = April 5
  assert.equal(season(2026, 4, 2), "none");
  for (const d of [3, 4, 5, 6]) assert.equal(season(2026, 4, d), "bunnyEars", `April ${d}`);
  assert.equal(season(2026, 4, 7), "none");
  // Easter 2027 = March 28
  assert.equal(season(2027, 3, 26), "bunnyEars");
  assert.equal(season(2027, 3, 29), "bunnyEars");
  assert.equal(season(2027, 3, 30), "none");
  // Easter 2028 = April 16
  assert.equal(season(2028, 4, 14), "bunnyEars");
  assert.equal(season(2028, 4, 17), "bunnyEars");
  assert.equal(season(2028, 4, 18), "none");
});

test("a daylight-saving change just before Easter doesn't shift the count", () => {
  // Europe moves its clocks on March 29 2026, a week before Easter: midnight
  // and late-evening dates must count the same days as noon.
  assert.equal(seasonalOutfit(new Date(2026, 3, 3, 0, 0)), "bunnyEars");
  assert.equal(seasonalOutfit(new Date(2026, 3, 6, 23, 59)), "bunnyEars");
  assert.equal(seasonalOutfit(new Date(2026, 3, 7, 0, 0)), "none");
});

test("sunglasses from June 21 to August 31", () => {
  assert.equal(season(2026, 6, 20), "none");
  assert.equal(season(2026, 6, 21), "sunglasses");
  assert.equal(season(2026, 8, 31), "sunglasses");
  assert.equal(season(2026, 9, 1), "none");
});

test("auto dresses for the season, any other choice is worn as is", () => {
  const d = day(2026, 10, 15);
  assert.equal(resolveOutfit("auto", d), "witchHat");
  assert.equal(resolveOutfit("none", d), "none");
  assert.equal(resolveOutfit("beanie", d), "beanie");
});

test("the stored values are the Mac's, in the wardrobe's order, with the skins and SVG hats", () => {
  assert.deepEqual([...OUTFIT_SELECTIONS], [
    "auto", "none", "partyHat", "beanie", "crown", "sunglasses", "roundGlasses",
    "bow", "scarf", "witchHat", "pumpkin", "frog", "bee", "strawberry", "robot", "ladybug", "panda", "ghost",
    "santaHat", "bunnyEars",
    "catEars", "chefHat", "cowboyHat", "gradCap", "sprout", "strawHat", "topHat",
  ]);
  for (const sel of OUTFIT_SELECTIONS) assert.ok(OUTFIT_LABELS[sel], `${sel} has a label`);
});

test("a stored preference is read back as it was saved", () => {
  for (const sel of OUTFIT_SELECTIONS) assert.equal(parseOutfit(sel), sel);
});

test("removed, unknown or missing preferences mean auto", () => {
  // ("topHat" and "strawHat", gone from the Mac, are SVG hats here.)
  for (const raw of ["cap", "heartsHeadband", "tophat", "totallyUnknown", "", "Beanie"]) {
    assert.equal(parseOutfit(raw), "auto", JSON.stringify(raw));
  }
  for (const raw of [undefined, null, 42, true, {}, ["beanie"]]) {
    assert.equal(parseOutfit(raw), "auto", String(raw));
  }
});

test("preferences from before the wardrobe start on auto", () => {
  assert.equal(DEFAULT_SETTINGS.mochiOutfit, "auto");
  // What main.ts does with a settings.json that has no mochiOutfit key.
  const old = { soundEnabled: false, model: "x" };
  const merged = { ...DEFAULT_SETTINGS, ...old };
  assert.equal(parseOutfit(merged.mochiOutfit), "auto");
});

test("the wardrobe header names the hovered outfit, else the current choice", () => {
  const d = day(2026, 10, 15);
  assert.equal(wardrobeHeader(null, "auto", d), "Auto · Witch hat");
  assert.equal(wardrobeHeader(null, "crown", d), "Crown");
  assert.equal(wardrobeHeader("auto", "crown", d), "Auto · follows the seasons (now: Witch hat)");
  assert.equal(wardrobeHeader("scarf", "auto", d), "Scarf");
  assert.equal(wardrobeHeader(null, "auto", day(2026, 5, 1)), "Auto · None");
});

test("the per-frame season lookup follows the calendar day", () => {
  const cache = new SeasonCache();
  assert.equal(cache.get("auto", day(2026, 9, 30)), "none");
  assert.equal(cache.get("auto", new Date(2026, 9, 1, 0, 0, 1)), "witchHat");
  assert.equal(cache.get("bow", day(2026, 10, 1)), "bow");
  assert.equal(cache.get("auto", day(2026, 12, 2)), "santaHat");
});

// ── Each Mochi's own look ─────────────────────────────────────────────────────

const looks = (mode) => ({
  ...DEFAULT_SETTINGS,
  wardrobeMode: mode,
  mochiOutfit: "crown",
  mochiLooks: {
    [MAIN_MOCHI]: { outfit: "beanie" },
    integration_github: { outfit: "witchHat" },
  },
});

test("each Mochi wears its own outfit, or all wear the shared one", () => {
  assert.equal(DEFAULT_SETTINGS.wardrobeMode, "perMochi");
  for (const raw of [undefined, "", "perMochi", "nope"]) assert.equal(parseWardrobeMode(raw), "perMochi");
  assert.equal(parseWardrobeMode("all"), "all");

  const own = looks("perMochi");
  assert.deepEqual(lookOf(own, MAIN_MOCHI), { outfit: "beanie" });
  assert.deepEqual(lookOf(own, "integration_github"), { outfit: "witchHat" });
  // A Mochi never dressed dresses for the seasons.
  assert.deepEqual(lookOf(own, "integration_n8n"), { outfit: "auto" });
  assert.deepEqual(lookOf({ ...own, mochiLooks: undefined }, MAIN_MOCHI), { outfit: "auto" });

  const shared = looks("all");
  for (const key of [MAIN_MOCHI, "integration_github", "integration_n8n"]) {
    assert.deepEqual(lookOf(shared, key), { outfit: "crown" });
  }
});

test("a pill shows its own coloured Mochi; the main pill and sessions show the main one", () => {
  const main = "integration_claude";
  assert.equal(mochiKey({ id: "integration_github", isIntegration: true }, main), "integration_github");
  assert.equal(mochiKey({ id: main, isIntegration: true }, main), MAIN_MOCHI);
  assert.equal(mochiKey({ id: "gemini-session-1", isIntegration: false }, main), MAIN_MOCHI);
  assert.equal(mochiKey(null, main), MAIN_MOCHI);
});

test("switching modes back and forth keeps both sets of looks", () => {
  const s = looks("perMochi");
  setLook(s, "integration_github", { outfit: "bow" });
  setLook(s, "integration_n8n", { outfit: "scarf" });
  const own = structuredClone(s.mochiLooks);
  assert.deepEqual(own.integration_github, { outfit: "bow" });
  assert.deepEqual(own.integration_n8n, { outfit: "scarf" });
  assert.equal(s.mochiOutfit, "crown"); // the shared outfit is not touched

  s.wardrobeMode = "all";
  setLook(s, "integration_github", { outfit: "pumpkin" });
  assert.deepEqual(lookOf(s, MAIN_MOCHI), { outfit: "pumpkin" });
  assert.deepEqual(s.mochiLooks, own); // each Mochi's own look waits

  s.wardrobeMode = "perMochi";
  assert.deepEqual(lookOf(s, "integration_github"), { outfit: "bow" });
  assert.deepEqual(lookOf(s, MAIN_MOCHI), { outfit: "beanie" });
  s.wardrobeMode = "all";
  assert.deepEqual(lookOf(s, "integration_n8n"), { outfit: "pumpkin" });
});
