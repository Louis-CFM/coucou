// Prayer times worked out on the PC (src/core/prayer.ts), against published timetables.

import { test } from "node:test";
import assert from "node:assert/strict";
import { arcPosition, dayHours, findCities, nextPrayer, prayerTimes, untilParts } from "../src/core/prayer.ts";

const hm = (h) => {
  const m = Math.round(h * 60);
  return `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
};
const near = (got, want, label, slack = 3) => {
  const [gh, gm] = got.split(":").map(Number);
  const [wh, wm] = want.split(":").map(Number);
  assert.ok(Math.abs(gh * 60 + gm - (wh * 60 + wm)) <= slack, `${label}: ${got}, expected about ${want}`);
};

test("Karachi (Karachi method, Hanafi Asr) on 7 November 2026", () => {
  const t = dayHours({ y: 2026, m: 11, d: 7 }, 24.8607, 67.0011, 5, "karachi", "hanafi");
  // Solar noon in Karachi is 12:15 that day; maghrib is sunset.
  near(hm(t.dhuhr), "12:16", "dhuhr");
  near(hm(t.sunrise), "06:43", "sunrise");
  near(hm(t.maghrib), "17:48", "maghrib");
  assert.ok(t.fajr < t.sunrise && t.sunrise < t.dhuhr && t.dhuhr < t.asr && t.asr < t.maghrib && t.maghrib < t.isha);
});

test("Hanafi Asr comes later than the standard one; Makkah's Isha is 90 min after Maghrib", () => {
  const std = dayHours({ y: 2026, m: 11, d: 7 }, 31.5204, 74.3587, 5, "karachi", "standard");
  const han = dayHours({ y: 2026, m: 11, d: 7 }, 31.5204, 74.3587, 5, "karachi", "hanafi");
  assert.ok(han.asr - std.asr > 0.5, "about 40 min later in November");
  const mk = dayHours({ y: 2026, m: 11, d: 7 }, 21.3891, 39.8579, 3, "makkah", "standard");
  assert.equal(Math.round((mk.isha - mk.maghrib) * 60), 90);
});

test("Jakarta (Kemenag) matches the ministry's timetable within a few minutes", () => {
  const t = dayHours({ y: 2026, m: 11, d: 7 }, -6.2088, 106.8456, 7, "kemenag", "standard");
  near(hm(t.fajr), "04:04", "subuh");
  near(hm(t.dhuhr), "11:36", "dzuhur");
  near(hm(t.maghrib), "17:47", "maghrib");
  near(hm(t.isha), "19:00", "isya");
});

test("far north in summer, Isha still has a time (the night-portion rule)", () => {
  const t = dayHours({ y: 2026, m: 6, d: 21 }, 59.9139, 10.7522, 2, "mwl", "standard");
  assert.ok(Number.isFinite(t.fajr) && Number.isFinite(t.isha));
});

test("the next prayer, and tomorrow's Fajr after Isha", () => {
  const lat = 24.8607;
  const lng = 67.0011;
  const day = new Date(2026, 10, 7, 12, 0).getTime();
  const times = prayerTimes(day, lat, lng, "karachi", "hanafi");
  const afterDhuhr = nextPrayer(times.dhuhr + 60_000, lat, lng, "karachi", "hanafi");
  assert.equal(afterDhuhr.name, "asr");
  assert.equal(afterDhuhr.prev.name, "dhuhr");
  const night = nextPrayer(times.isha + 60_000, lat, lng, "karachi", "hanafi");
  assert.equal(night.name, "fajr");
  assert.ok(night.at > times.isha && night.at - times.isha < 12 * 3_600_000);
  const dawn = nextPrayer(new Date(2026, 10, 7, 1, 0).getTime(), lat, lng, "karachi", "hanafi");
  assert.equal(dawn.name, "fajr");
  assert.equal(dawn.prev.name, "isha");
});

test("time left reads in hours and minutes, rounded up", () => {
  assert.deepEqual(untilParts(68 * 60_000), [1, 8]);
  assert.deepEqual(untilParts(30_000), [0, 1]);
  assert.deepEqual(untilParts(-5), [0, 0]);
});

test("the sun's place on the arc: 0 at sunrise, 1 at sunset", () => {
  const times = prayerTimes(new Date(2026, 10, 7, 12).getTime(), 24.8607, 67.0011, "karachi", "hanafi");
  assert.equal(arcPosition(times.sunrise, times), 0);
  assert.equal(arcPosition(times.maghrib, times), 1);
  const noon = arcPosition(times.dhuhr, times);
  assert.ok(noon > 0.45 && noon < 0.55);
});

test("cities are found by any word of their name or country", () => {
  assert.equal(findCities("lah")[0].name, "Lahore");
  assert.ok(findCities("pakistan").every((c) => c.country === "Pakistan"));
  assert.equal(findCities("abu")[0].name, "Abu Dhabi");
  assert.equal(findCities("").length, 8, "the first ones when nothing is typed");
});
