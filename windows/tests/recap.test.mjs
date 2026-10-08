// Weekly recap aggregation (src/recap/summary.ts) — the numbers the card and
// the shared image show. Mirrors the fake week of scripts/test-weekly-recap.swift.
// Dates are built with local constructors, so the tests hold in any time zone.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  addDays, dayKey, formatCount, formatDuration, mergedSeconds, mondayOf,
  previousWeekStart, sampleHistory, shouldAutoShow, summarize, weekRangeLabel,
} from "../src/recap/summary.ts";

const secs = (d) => Math.floor(d.getTime() / 1000);
const turn = (start, end, extra = {}) => ({
  agent: "integration_claude", project: "coucou",
  start: secs(start), end: secs(end),
  filesChanged: 0, linesAdded: 0, linesRemoved: 0, commandsRun: 0, questions: 0,
  ...extra,
});
const history = (turns, decisions = []) => ({
  turns, decisions, prefs: { enabled: true, hideProjects: false, lastShownWeek: "" },
});

// Monday 28 September 2026 → Sunday 4 October; "now" is Monday 5 October.
const LAST_MONDAY = new Date(2026, 8, 28);
const NOW = new Date(2026, 9, 5, 9, 15);

// ── Week boundaries ───────────────────────────────────────────────────────────

test("the last completed week runs from the previous Monday to Sunday, local time", () => {
  assert.equal(dayKey(previousWeekStart(NOW)), "2026-09-28");
  // Any moment of the current week points at the same previous week.
  assert.equal(dayKey(previousWeekStart(new Date(2026, 9, 5, 0, 0, 1))), "2026-09-28");
  assert.equal(dayKey(previousWeekStart(new Date(2026, 9, 11, 23, 59))), "2026-09-28");
  // Sunday still belongs to the week that began six days earlier.
  assert.equal(dayKey(mondayOf(new Date(2026, 9, 4, 22))), "2026-09-28");
  // Across a month and a year.
  assert.equal(dayKey(mondayOf(new Date(2027, 0, 1))), "2026-12-28");
  assert.equal(previousWeekStart(NOW).getHours(), 0);
});

test("only turns that start inside the week count", () => {
  const s = summarize(history([
    turn(new Date(2026, 8, 27, 23, 0), new Date(2026, 8, 27, 23, 59)), // Sunday before
    turn(new Date(2026, 8, 28, 0, 0), new Date(2026, 8, 28, 0, 30)), // Monday 00:00
    turn(new Date(2026, 9, 4, 23, 50), new Date(2026, 9, 5, 0, 40)), // Sunday night, ends Monday
    turn(new Date(2026, 9, 5, 0, 0), new Date(2026, 9, 5, 1, 0)), // this Monday
  ]), LAST_MONDAY);
  assert.equal(s.sessionCount, 2);
  assert.equal(s.totalMinutes, 30 + 50);
  assert.equal(dayKey(s.weekStart), "2026-09-28");
  assert.equal(dayKey(s.weekEnd), "2026-10-04");
  assert.equal(weekRangeLabel(s), "Sep 28 – Oct 4");
});

test("a week with nothing in it has no summary", () => {
  assert.equal(summarize(history([]), LAST_MONDAY), null);
  const lastMonth = turn(new Date(2026, 8, 1, 9), new Date(2026, 8, 1, 10));
  assert.equal(summarize(history([lastMonth]), LAST_MONDAY), null);
});

// ── The Mac's fake week ───────────────────────────────────────────────────────

test("the sample week adds up like the Mac's", () => {
  const s = summarize(sampleHistory(LAST_MONDAY), LAST_MONDAY);
  assert.equal(s.totalMinutes, 150 + 105 + 60 + 150 + 60 + 300);
  assert.equal(formatDuration(s.totalMinutes), "13h 45m");
  assert.equal(s.sessionCount, 6);
  assert.equal(s.filesChanged, 31);
  assert.equal(s.linesAdded, 1217);
  assert.equal(s.linesRemoved, 312);
  assert.equal(s.commandsRun, 54);
  assert.equal(s.questions, 11);
  assert.equal(s.permissionsAllowed, 4);
  assert.equal(s.permissionsDenied, 1);
  assert.equal(s.topAgent, "Claude Code");
  assert.equal(s.topProject, "coucou");
  assert.equal(s.busiestDay, "Monday");
  assert.equal(s.longestSessionMinutes, 300);
});

// ── Details ───────────────────────────────────────────────────────────────────

test("parallel sessions are not counted twice in the time spent", () => {
  const d = (h, m = 0) => new Date(2026, 8, 29, h, m);
  const turns = [
    turn(d(9), d(10)),
    turn(d(9, 30), d(11)), // overlaps the first
    turn(d(10, 15), d(10, 45)), // inside both
    turn(d(14), d(14, 20)),
  ];
  assert.equal(mergedSeconds(turns), (120 + 20) * 60);
  const s = summarize(history(turns), LAST_MONDAY);
  assert.equal(s.totalMinutes, 140);
  assert.equal(s.longestSessionMinutes, 90);
  assert.equal(s.sessionCount, 4);
});

test("top agent and top project go by number of sessions", () => {
  const d = (day, h) => new Date(2026, 8, 28 + day, h);
  const s = summarize(history([
    turn(d(0, 9), d(0, 15), { agent: "integration_claude", project: "big-but-once" }),
    turn(d(1, 9), d(1, 10), { agent: "agent_gemini", project: "korus" }),
    turn(d(1, 11), d(1, 12), { agent: "agent_gemini", project: "korus" }),
    turn(d(2, 9), d(2, 10), { agent: "agent_my-tool", project: "" }),
    turn(d(2, 11), d(2, 12), { agent: "agent_my-tool", project: "" }),
    turn(d(2, 13), d(2, 14), { agent: "agent_my-tool", project: "" }),
  ]), LAST_MONDAY);
  assert.equal(s.topAgent, "My-tool");
  // Sessions without a folder never make a top project.
  assert.equal(s.topProject, "korus");
  assert.equal(s.busiestDay, "Wednesday");
  assert.equal(s.longestSessionMinutes, 360);
});

test("ties are settled the same way every time", () => {
  const d = (day, h) => new Date(2026, 8, 28 + day, h);
  const s = summarize(history([
    turn(d(6, 9), d(6, 10), { agent: "agent_codex", project: "zeta" }), // Sunday
    turn(d(3, 9), d(3, 10), { agent: "integration_claude", project: "alpha" }), // Thursday
  ]), LAST_MONDAY);
  assert.equal(s.topAgent, "Codex"); // agent_codex < integration_claude
  assert.equal(s.topProject, "alpha");
  assert.equal(s.busiestDay, "Thursday"); // earlier in the week than Sunday
});

test("decisions outside the week do not count", () => {
  const inWeek = secs(new Date(2026, 8, 30, 10));
  const s = summarize(history(
    [turn(new Date(2026, 8, 30, 9), new Date(2026, 8, 30, 11))],
    [
      { agent: "integration_claude", date: inWeek, decision: "allow" },
      { agent: "integration_claude", date: inWeek, decision: "deny" },
      { agent: "integration_claude", date: secs(new Date(2026, 9, 5, 10)), decision: "allow" },
      { agent: "integration_claude", date: secs(new Date(2026, 8, 20, 10)), decision: "deny" },
    ],
  ), LAST_MONDAY);
  assert.equal(s.permissionsAllowed, 1);
  assert.equal(s.permissionsDenied, 1);
});

test("a history older than the window shows nothing for last week", () => {
  // Rust prunes past 12 weeks; whatever it keeps from earlier weeks stays out.
  const twelveWeeksAgo = addDays(LAST_MONDAY, -7 * 12);
  const s = summarize(history([turn(twelveWeeksAgo, addDays(twelveWeeksAgo, 0.01))]), LAST_MONDAY);
  assert.equal(s, null);
  const old = summarize(history([turn(addDays(twelveWeeksAgo, 1), new Date(addDays(twelveWeeksAgo, 1).getTime() + 3600_000))]), twelveWeeksAgo);
  assert.equal(old.sessionCount, 1);
});

// ── When it opens on its own ──────────────────────────────────────────────────

test("the recap opens on Monday from 8 am, once a week", () => {
  assert.equal(shouldAutoShow(new Date(2026, 9, 5, 7, 59), ""), false);
  assert.equal(shouldAutoShow(new Date(2026, 9, 5, 8, 0), ""), true);
  assert.equal(shouldAutoShow(new Date(2026, 9, 5, 18, 0), "2026-09-28"), true);
  assert.equal(shouldAutoShow(new Date(2026, 9, 5, 18, 0), "2026-10-05"), false);
  assert.equal(shouldAutoShow(new Date(2026, 9, 6, 9, 0), ""), false); // Tuesday
  assert.equal(shouldAutoShow(new Date(2026, 9, 4, 9, 0), ""), false); // Sunday
});

test("numbers stay short enough for a stat chip", () => {
  assert.equal(formatDuration(0), "0m");
  assert.equal(formatDuration(59), "59m");
  assert.equal(formatDuration(120), "2h");
  assert.equal(formatCount(1217), "1,217");
  assert.equal(formatCount(12_345), "12.3k");
  assert.equal(formatCount(123_456), "123k");
});
