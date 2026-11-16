// The closed island (src/core/closed.ts): what stays at the top of the screen
// once the island is folded, where a Mac has its notch.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  CLOSED_BALANCED_W, CLOSED_ISLANDS, CLOSED_MAX_W, CLOSED_MIN_W, CLOSED_PAD, closedContent, closedIsland, closedTime, closedWidth,
} from "../src/core/closed.ts";

const NOW = new Date(2026, 10, 2, 20, 28);
const input = (over = {}) => ({ now: NOW, locale: "en-GB", planUsage: null, music: null, ...over });

test("an unknown or missing choice reads as Mochi, the Mac's own look", () => {
  assert.equal(closedIsland(undefined), "mochi");
  assert.equal(closedIsland("sparkles"), "mochi");
  for (const style of CLOSED_ISLANDS) assert.equal(closedIsland(style), style);
});

test("Mochi, the empty island and no island show no line", () => {
  for (const style of ["mochi", "empty", "hidden"]) assert.equal(closedContent(style, input()), null);
});

test("the time, and the date with it", () => {
  assert.deepEqual(closedContent("time", input()), { text: "20:28", dot: null, note: false });
  const both = closedContent("datetime", input());
  assert.match(both.text, /2 Nov/);
  assert.match(both.text, /20:28$/);
});

test("Claude's usage with its colour, the time while there are no numbers yet", () => {
  assert.equal(closedContent("claude", input()).text, "20:28");
  const planUsage = {
    fiveHour: { usedPct: 48, resetsAt: NOW.getTime() + 3_600_000 },
    sevenDay: { usedPct: 20, resetsAt: NOW.getTime() + 86_400_000 },
    updatedAt: NOW.getTime(),
  };
  const shown = closedContent("claude", input({ planUsage }));
  assert.equal(shown.text, "Claude 48%");
  assert.equal(shown.dot, "#22C55E");
});

test("what plays, with its note; the time when nothing plays", () => {
  assert.equal(closedContent("music", input()).text, "20:28");
  const shown = closedContent("music", input({ music: { title: "Midnight City", artist: "M83" } }));
  assert.deepEqual(shown, { text: "Midnight City · M83", dot: null, note: true });
  assert.equal(closedContent("music", input({ music: { title: "Intro", artist: "" } })).text, "Intro");
});

test("Coucoudoro timer shows the countdown with phase dot", () => {
  const shown = closedContent("coucoudoro", input());
  assert.ok(shown.text);
});

test("active notification takes top priority in the small notch", () => {
  const notif = { text: "WhatsApp · 1 msg", dot: "#25D366" };
  for (const style of ["time", "datetime", "claude", "music", "coucoudoro", "mochi", "empty"]) {
    const shown = closedContent(style, input({ notification: notif }));
    assert.deepEqual(shown, {
      text: "WhatsApp · 1 msg",
      dot: "#25D366",
      note: false,
      isNotification: true,
    });
  }
});

test("welcome message with Mochi on left takes top priority in the small notch", () => {
  const welcome = { text: "Hey Alex, you're back! ✨", bot: true };
  for (const style of ["time", "datetime", "claude", "music", "coucoudoro", "mochi", "empty"]) {
    const shown = closedContent(style, input({ welcome }));
    assert.deepEqual(shown, {
      text: "Hey Alex, you're back! ✨",
      dot: null,
      note: false,
      bot: true,
      isWelcome: true,
    });
  }
});

test("the island is as wide as its line, within bounds", () => {
  assert.equal(closedWidth(0), CLOSED_MIN_W);
  assert.equal(closedWidth(Number.NaN), CLOSED_MIN_W);
  assert.equal(closedWidth(100), 100 + CLOSED_PAD * 2);
  assert.equal(closedWidth(100, 12), 112 + CLOSED_PAD * 2);
  assert.equal(closedWidth(5000), CLOSED_MAX_W);
});

test("balanced dynamic island resting constants and formatting", () => {
  assert.equal(CLOSED_BALANCED_W, 160);
  assert.equal(closedTime(NOW, "en-GB"), "20:28");
});
