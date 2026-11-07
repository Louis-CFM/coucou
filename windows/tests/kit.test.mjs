// The Kit page's rules: focus rounds, water, the to-do order and reminders, the shelf (src/core/kit.ts).

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  addToShelf, clock, defaults, dueFromTime, dueTodos, focusLive, IDLE, nextPhase, normalize, pauseFocus,
  resumeFocus, size, sortedTodos, startFocus, tickFocus, waterDue, waterToday, waterWeek,
} from "../src/core/kit.ts";

const at = (h, m = 0, day = 7) => new Date(2026, 10, day, h, m, 0, 0).getTime();
const MIN = 60_000;

test("the clock reads minutes and seconds, hours when there are some", () => {
  assert.equal(clock(25 * MIN), "25:00");
  assert.equal(clock(61_500), "01:02", "a started second counts");
  assert.equal(clock(3_725_000), "1:02:05");
  assert.equal(clock(-5), "00:00");
});

test("a focus run goes work → break → work … → long break → done", () => {
  const p = { workMin: 25, breakMin: 5, longMin: 15, rounds: 2 };
  let run = startFocus(p, 0);
  assert.deepEqual([run.phase, run.round, run.endsAt], ["work", 1, 25 * MIN]);
  let r = tickFocus(run, p, 10 * MIN);
  assert.equal(r.ended, null, "nothing ends early");
  r = tickFocus(run, p, 25 * MIN);
  assert.deepEqual([r.ended, r.run.phase, r.run.round], ["work", "break", 1]);
  run = nextPhase(r.run, p, 30 * MIN);
  assert.deepEqual([run.phase, run.round], ["work", 2]);
  run = nextPhase(run, p, 55 * MIN);
  assert.equal(run.phase, "long", "after the last round, the long break");
  assert.equal(nextPhase(run, p, 70 * MIN), IDLE, "after it, the timer stops");
});

test("a paused timer keeps what was left and starts from there again", () => {
  const p = defaults().focus;
  const run = startFocus(p, 0);
  const paused = pauseFocus(run, 10 * MIN);
  assert.equal(paused.endsAt, null);
  assert.equal(paused.leftMs, 15 * MIN);
  assert.equal(tickFocus(paused, p, 99 * MIN).ended, null, "a paused timer never ends");
  const resumed = resumeFocus(paused, 50 * MIN);
  assert.equal(resumed.endsAt, 65 * MIN);
});

test("the compact island shows the phase and what is left", () => {
  const labels = { work: "Focus", break: "Break", long: "Long break" };
  assert.equal(focusLive(IDLE, 0, labels), null);
  const run = startFocus(defaults().focus, 0);
  assert.equal(focusLive(run, 6 * MIN + 18_000, labels), "Focus 18:42");
  assert.equal(focusLive(pauseFocus(run, 5 * MIN), 9 * MIN, labels), "Focus 20:00 ‖");
});

test("water counts today only, and the week ends today", () => {
  const w = { ...defaults().water, log: [
    { at: at(23, 0, 6), ml: 500 },
    { at: at(9, 30), ml: 250 },
    { at: at(11), ml: 300 },
  ] };
  assert.equal(waterToday(w, at(12)), 550);
  const week = waterWeek(w, at(12));
  assert.equal(week.length, 7);
  assert.deepEqual(week.slice(-2), [500, 550]);
});

test("water reminds within its hours, after the gap, until the goal", () => {
  const w = { ...defaults().water, everyMin: 60, fromHour: 9, toHour: 21, log: [] };
  assert.equal(waterDue(w, at(8, 30), 0), false, "before the hours");
  assert.equal(waterDue(w, at(9, 30), 0), false, "the first one an hour after the hours start");
  assert.equal(waterDue(w, at(10, 0), 0), true);
  assert.equal(waterDue(w, at(10, 30), at(10, 0)), false, "not again right after a reminder");
  const drank = { ...w, log: [{ at: at(10, 15), ml: 250 }] };
  assert.equal(waterDue(drank, at(11, 0), at(10, 0)), false, "a drink resets the gap");
  assert.equal(waterDue(drank, at(11, 15), at(10, 0)), true);
  assert.equal(waterDue({ ...drank, log: [{ at: at(10, 15), ml: 2000 }] }, at(15), 0), false, "goal reached");
  assert.equal(waterDue({ ...w, remind: false }, at(15), 0), false, "reminders off");
  assert.equal(waterDue(w, at(21, 30), 0), false, "after the hours");
});

test("a time for a task is today, or tomorrow once it has passed", () => {
  const now = at(14, 0);
  assert.equal(dueFromTime("15:30", now), at(15, 30));
  assert.equal(dueFromTime("09:00", now), at(9, 0, 8));
  assert.equal(dueFromTime("14:00", now), at(14, 0, 8), "now itself is already past");
  assert.equal(dueFromTime("25:00", now), null);
  assert.equal(dueFromTime("soon", now), null);
});

test("tasks: open ones first by time (none last), done ones after; due ones remind once", () => {
  const todo = (id, over) => ({ id, text: `t${id}`, due: null, done: false, told: false, createdAt: id, ...over });
  const list = [todo(1, { done: true }), todo(2), todo(3, { due: at(16) }), todo(4, { due: at(10) })];
  assert.deepEqual(sortedTodos(list).map((t) => t.id), [4, 3, 2, 1]);
  assert.deepEqual(dueTodos(list, at(12)).map((t) => t.id), [4]);
  assert.deepEqual(dueTodos([todo(5, { due: at(10), told: true }), todo(6, { due: at(10), done: true })], at(12)), []);
});

test("the shelf puts new files first, never twice, at most 60", () => {
  assert.deepEqual(addToShelf(["C:\\a.txt", "C:\\b.png"], ["C:\\c.pdf", "c:\\A.TXT"]), ["C:\\c.pdf", "c:\\A.TXT", "C:\\b.png"]);
  assert.deepEqual(addToShelf([], ["x", "x", ""]), ["x"]);
  const many = Array.from({ length: 70 }, (_, i) => `f${i}`);
  assert.equal(addToShelf([], many).length, 60);
});

test("sizes read like Explorer's", () => {
  assert.equal(size(512), "512 B");
  assert.equal(size(2_516_582), "2.4 MB");
  assert.equal(size(15 * 1024 * 1024), "15 MB");
});

test("a broken or old kit.json falls back to the defaults, field by field", () => {
  assert.deepEqual(normalize(null), defaults());
  const d = normalize({ focus: { workMin: 999, rounds: "4" }, water: { goalMl: 3000, remind: false }, todos: [{ id: 1, text: "  " }, { id: 2, text: "Reply to Dina", due: 5 }], shelf: ["a", "a", 3] });
  assert.equal(d.focus.workMin, 180, "clamped");
  assert.equal(d.focus.rounds, 4, "a wrong type keeps the default");
  assert.equal(d.water.goalMl, 3000);
  assert.equal(d.water.remind, false);
  assert.deepEqual(d.todos.map((t) => t.text), ["Reply to Dina"]);
  assert.deepEqual(d.shelf, ["a"]);
});
