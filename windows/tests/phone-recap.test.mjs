// The weekly recap as the phone gets it (src/recap/phone.ts): the numbers of the last completed week, the busiest agent's name, and nothing
// that names a file or a command.

import { test } from "node:test";
import assert from "node:assert/strict";
import { recapForPhone, recapWeekKey } from "../src/recap/phone.ts";
import { addDays, dayKey, mondayOf, previousWeekStart, sampleHistory, summarize } from "../src/recap/summary.ts";

const MONDAY = new Date(2026, 9, 5); // Monday 5 October 2026, local time
const NEXT_WEEK = new Date(2026, 9, 12, 10, 30); // the Monday after, 10:30

test("the recap is last completed week's numbers", () => {
  const history = sampleHistory(MONDAY);
  const r = recapForPhone(history, NEXT_WEEK);
  const week = summarize(history, MONDAY);
  assert.equal(r.week, "2026-10-05");
  assert.equal(r.minutes, week.totalMinutes);
  assert.equal(r.sessions, week.sessionCount);
  assert.equal(r.files, week.filesChanged);
  assert.equal(r.linesAdded, week.linesAdded);
  assert.equal(r.linesRemoved, week.linesRemoved);
  assert.equal(r.commands, week.commandsRun);
  assert.equal(r.allowed, 4);
  assert.equal(r.denied, 1);
  assert.equal(r.topAgent, "Claude Code");
  assert.equal(r.topProject, "coucou");
});

test("the recap is the same all week long and changes on Monday", () => {
  const wednesday = addDays(NEXT_WEEK, 2);
  assert.equal(recapWeekKey(NEXT_WEEK), recapWeekKey(wednesday));
  assert.equal(recapWeekKey(NEXT_WEEK), "2026-10-05");
  assert.notEqual(recapWeekKey(NEXT_WEEK), recapWeekKey(addDays(NEXT_WEEK, 7)));
  assert.equal(recapWeekKey(new Date(2026, 9, 11, 23, 59)), "2026-09-28", "Sunday night is still the week before");
  assert.equal(dayKey(previousWeekStart(NEXT_WEEK)), recapWeekKey(NEXT_WEEK));
});

test("a week with no session has no recap", () => {
  assert.equal(recapForPhone(sampleHistory(MONDAY), addDays(NEXT_WEEK, 14)), null);
  assert.equal(recapForPhone({ turns: [], decisions: [], prefs: { enabled: true, hideProjects: false, lastShownWeek: "" } }, NEXT_WEEK), null);
  assert.equal(recapForPhone(null, NEXT_WEEK), null);
  assert.equal(recapForPhone(undefined, NEXT_WEEK), null);
});

test("hiding project names in the recap keeps the project out of what the phone gets", () => {
  const history = sampleHistory(MONDAY);
  history.prefs.hideProjects = true;
  const r = recapForPhone(history, NEXT_WEEK);
  assert.equal(r.topProject, undefined);
  assert.equal(r.topAgent, "Claude Code");
});

test("nothing but counts, a date and two names is published", () => {
  const r = recapForPhone(sampleHistory(MONDAY), NEXT_WEEK);
  for (const [key, value] of Object.entries(r)) {
    if (key === "week" || key === "topAgent" || key === "topProject") assert.equal(typeof value, "string", key);
    else assert.ok(Number.isInteger(value) && value >= 0, key);
  }
  assert.equal(mondayOf(NEXT_WEEK).getDay(), 1);
});
