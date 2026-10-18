// The per-model ledger behind the plan card's "By model" rows (core/spend.ts).
import { test } from "node:test";
import assert from "node:assert/strict";
import { dayKey, emptyLedger, noteSpend, restoreLedger, spendOver } from "../src/core/spend.ts";

const T0 = new Date(2026, 9, 13, 10, 0, 0).getTime(); // Oct 13, 2026, local
const HOUR = 3_600_000;
const DAY = 24 * HOUR;

test("a session's running total is added as deltas, under its model", () => {
  const l = emptyLedger();
  assert.equal(noteSpend(l, "s1", "claude-opus-5-5", "Opus", 1.0, T0), true);
  assert.equal(noteSpend(l, "s1", "claude-opus-5-5", "Opus", 1.5, T0 + HOUR), true);
  // Nothing moved: nothing changes.
  assert.equal(noteSpend(l, "s1", "claude-opus-5-5", "Opus", 1.5, T0 + 2 * HOUR), false);
  assert.deepEqual(spendOver(l, 1, T0 + 2 * HOUR), [{ id: "claude-opus-5-5", name: "Opus", usd: 1.5 }]);
});

test("a model switch mid-session puts the next deltas under the new model", () => {
  const l = emptyLedger();
  noteSpend(l, "s1", "claude-opus-5-5", "Opus", 2.0, T0);
  noteSpend(l, "s1", "claude-sonnet-5-5", "Sonnet", 2.4, T0 + HOUR);
  assert.deepEqual(spendOver(l, 1, T0 + HOUR), [
    { id: "claude-opus-5-5", name: "Opus", usd: 2.0 },
    { id: "claude-sonnet-5-5", name: "Sonnet", usd: 0.4 },
  ]);
});

test("a total that went down is a session started over, counted from zero", () => {
  const l = emptyLedger();
  noteSpend(l, "s1", "claude-opus-5-5", "Opus", 3.0, T0);
  noteSpend(l, "s1", "claude-opus-5-5", "Opus", 0.2, T0 + HOUR); // after /clear
  assert.equal(spendOver(l, 1, T0 + HOUR)[0].usd, 3.2);
});

test("today and the week are separate sums, old days fall off", () => {
  const l = emptyLedger();
  noteSpend(l, "a", "claude-opus-5-5", "Opus", 5, T0 - 10 * DAY);
  noteSpend(l, "b", "claude-opus-5-5", "Opus", 2, T0 - 3 * DAY);
  noteSpend(l, "c", "claude-haiku-5-5", "Haiku", 1, T0);
  assert.deepEqual(spendOver(l, 1, T0), [{ id: "claude-haiku-5-5", name: "Haiku", usd: 1 }]);
  assert.deepEqual(spendOver(l, 7, T0), [
    { id: "claude-opus-5-5", name: "Opus", usd: 2 },
    { id: "claude-haiku-5-5", name: "Haiku", usd: 1 },
  ]);
  assert.equal(Object.keys(l.days).includes(dayKey(T0 - 10 * DAY)), false);
});

test("bad input changes nothing", () => {
  const l = emptyLedger();
  assert.equal(noteSpend(l, "", "claude-opus-5-5", "Opus", 1, T0), false);
  assert.equal(noteSpend(l, "s1", "", "Opus", 1, T0), false);
  assert.equal(noteSpend(l, "s1", "claude-opus-5-5", "Opus", Number.NaN, T0), false);
  assert.equal(noteSpend(l, "s1", "claude-opus-5-5", "Opus", -1, T0), false);
  assert.deepEqual(spendOver(l, 7, T0), []);
});

test("a stored ledger comes back, damage is dropped", () => {
  const l = emptyLedger();
  noteSpend(l, "s1", "claude-opus-5-5", "Opus", 1.25, T0);
  const back = restoreLedger(JSON.stringify(l));
  assert.deepEqual(back, l);
  assert.deepEqual(restoreLedger("not json"), emptyLedger());
  assert.deepEqual(restoreLedger(JSON.stringify({ days: { "2026-10-13": { x: "no" }, nope: {} } })).days, { "2026-10-13": {} });
});
