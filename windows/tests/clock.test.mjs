// The island's clock text (src/core/clock.ts): what goes before the time, and 12 or 24 hours.

import { test } from "node:test";
import assert from "node:assert/strict";
import { clockDate, clockHours, clockText, timeText } from "../src/core/clock.ts";
import { closedContent } from "../src/core/closed.ts";

const NOW = new Date(2026, 10, 15, 14, 6);

test("an unknown or missing choice reads as today's clock", () => {
  assert.equal(clockDate(undefined), "date");
  assert.equal(clockDate("year"), "date");
  assert.equal(clockHours(undefined), "auto");
  assert.equal(clockHours("13"), "auto");
});

test("24 hours is the 24-hour clock whatever the language", () => {
  assert.equal(timeText(NOW, "24", "en-US"), "14:06");
  assert.equal(timeText(new Date(2026, 10, 15, 0, 5), "24", "en-US"), "00:05");
});

test("12 hours carries the day period, without a leading zero", () => {
  assert.match(timeText(NOW, "12", "en-GB"), /^2:06\s?pm$/i);
});

test("automatic follows the language", () => {
  assert.equal(timeText(NOW, "auto", "en-GB"), "14:06");
  assert.match(timeText(NOW, "auto", "en-US"), /^02:06\s?PM$/);
});

test("the time alone, with the weekday, or with the date", () => {
  assert.equal(clockText(NOW, "none", "24", "en-GB"), "14:06");
  assert.equal(clockText(NOW, "weekday", "24", "en-GB"), "Sun  14:06");
  assert.equal(clockText(NOW, "date", "24", "en-GB"), "Sun 15 Nov  14:06");
});

test("the closed island's time follows the hours", () => {
  const input = { now: NOW, locale: "en-US", planUsage: null, music: null };
  assert.equal(closedContent("time", { ...input, hours: "24" }).text, "14:06");
  assert.match(closedContent("time", input).text, /PM$/);
});
