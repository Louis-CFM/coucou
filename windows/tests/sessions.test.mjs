// The live sessions behind each pill (src/island/sessions.ts) — a port of
// PillSessionRegistryTests.swift (Mac #245).

import { test } from "node:test";
import assert from "node:assert/strict";
import { SessionRegistry } from "../src/island/sessions.ts";

const CLAUDE = "integration_claude";
const display = (session, project, cwd = "") => ({ session, projectName: project, cwd });

test("one session alone: the pill follows it all the way", () => {
  const reg = new SessionRegistry();
  reg.note(CLAUDE, display("a", "coucou", "/tmp/coucou"), false);
  assert.equal(reg.liveCount(CLAUDE), 1);
  assert.equal(reg.workingCount(CLAUDE), 0);

  reg.note(CLAUDE, display("a", "coucou", "/tmp/coucou"), true);
  assert.equal(reg.workingCount(CLAUDE), 1);

  assert.equal(reg.endTurn(CLAUDE, "a"), "pill");
  assert.equal(reg.liveCount(CLAUDE), 1);
  assert.equal(reg.endSession(CLAUDE, "a"), "pill");
  assert.equal(reg.liveCount(CLAUDE), 0);
});

test("two sessions behind one pill: an end reaches only as far as it may", () => {
  const reg = new SessionRegistry();
  reg.note(CLAUDE, display("a", "coucou", "/a"), true);
  reg.note(CLAUDE, display("b", "lokil", "/b"), true);
  assert.equal(reg.liveCount(CLAUDE), 2);
  assert.equal(reg.workingCount(CLAUDE), 2);

  assert.equal(reg.endTurn(CLAUDE, "a"), "sessionOnly"); // A's Stop must not touch the pill while B works
  assert.equal(reg.workingCount(CLAUDE), 1);
  assert.equal(reg.endSession(CLAUDE, "a"), "sessionOnly"); // A's SessionEnd must not remove the card
  assert.equal(reg.liveCount(CLAUDE), 1);

  assert.equal(reg.endTurn(CLAUDE, "b"), "pill");
  assert.equal(reg.endSession(CLAUDE, "b"), "pill");
});

test("a resting sibling does not hold the pill back", () => {
  const reg = new SessionRegistry();
  reg.note(CLAUDE, display("a", "coucou"), true);
  reg.note(CLAUDE, display("b", "lokil"), true);
  reg.endTurn(CLAUDE, "b");
  assert.equal(reg.endTurn(CLAUDE, "a"), "pill");
  assert.equal(reg.endSession(CLAUDE, "a"), "sessionOnly");
});

test("display ownership: one session names the card, a sibling inherits it", () => {
  const reg = new SessionRegistry();
  reg.note(CLAUDE, display("a", "coucou", "/a"), true);
  reg.note(CLAUDE, display("b", "lokil", "/b"), true);
  assert.equal(reg.displayOwner(CLAUDE)?.session, "a");
  assert.equal(reg.displayOwner(CLAUDE)?.projectName, "coucou");
  assert.ok(reg.ownsDisplay(CLAUDE, "a"));
  assert.ok(!reg.ownsDisplay(CLAUDE, "b"));

  reg.note(CLAUDE, display("b", "lokil", "/b"), true);
  assert.equal(reg.displayOwner(CLAUDE)?.projectName, "coucou");

  reg.endSession(CLAUDE, "a");
  assert.equal(reg.displayOwner(CLAUDE)?.session, "b");
  assert.equal(reg.displayOwner(CLAUDE)?.projectName, "lokil");
  assert.equal(reg.displayOwner(CLAUDE)?.cwd, "/b");
  assert.ok(reg.ownsDisplay(CLAUDE, "b"));
});

test("empty cwd must not erase a known one; working is sticky inside a turn", () => {
  const reg = new SessionRegistry();
  reg.note(CLAUDE, display("a", "coucou", "/a"), true);
  reg.note(CLAUDE, display("a", "coucou", ""), false);
  assert.equal(reg.displayOwner(CLAUDE)?.cwd, "/a");
  assert.equal(reg.workingCount(CLAUDE), 1);
});

test("pills are independent", () => {
  const reg = new SessionRegistry();
  reg.note(CLAUDE, display("a", "coucou"), true);
  reg.note("agent_cursor", display("b", "lokil"), true);
  assert.equal(reg.endTurn("agent_cursor", "b"), "pill");
  assert.equal(reg.workingCount(CLAUDE), 1);
  assert.equal(reg.liveCount("agent_codex"), 0);
});

test("sessions we never saw start: a Stop from nowhere", () => {
  const reg = new SessionRegistry();
  assert.equal(reg.endTurn(CLAUDE, "ghost"), "pill");
  assert.equal(reg.liveCount(CLAUDE), 0);
  assert.equal(reg.endSession(CLAUDE, "ghost"), "pill");

  reg.note(CLAUDE, display("a", "coucou"), true);
  assert.equal(reg.endTurn(CLAUDE, "ghost"), "sessionOnly");
  assert.equal(reg.endSession(CLAUDE, "ghost"), "sessionOnly");
});

test("a Stop that never arrives must not hold the other session back", () => {
  const reg = new SessionRegistry();
  const start = 1_000_000_000;
  reg.note(CLAUDE, display("a", "coucou"), true, start);
  reg.note(CLAUDE, display("b", "lokil"), true, start);

  const soon = start + SessionRegistry.maxTurnSilence - 60_000;
  reg.note(CLAUDE, display("b", "lokil"), true, soon);
  assert.equal(reg.endTurn(CLAUDE, "b", soon), "sessionOnly");

  const late = start + SessionRegistry.maxTurnSilence + 60_000;
  reg.note(CLAUDE, display("b", "lokil"), true, late);
  assert.equal(reg.workingCount(CLAUDE), 1); // silent A no longer counts
  assert.equal(reg.endTurn(CLAUDE, "b", late), "pill");
  assert.equal(reg.liveCount(CLAUDE), 2); // A is still live
  assert.equal(reg.displayOwner(CLAUDE)?.session, "a");
});

test("a SessionEnd that never arrives must not pin the card forever", () => {
  const reg = new SessionRegistry();
  const start = 1_000_000_000;
  reg.note(CLAUDE, display("a", "coucou"), true, start);
  reg.note(CLAUDE, display("b", "lokil"), true, start);

  const later = start + SessionRegistry.maxSilence + 60_000;
  reg.note(CLAUDE, display("b", "lokil"), true, later);
  assert.equal(reg.liveCount(CLAUDE), 1); // silent A swept
  assert.equal(reg.displayOwner(CLAUDE)?.session, "b");
  assert.equal(reg.endSession(CLAUDE, "b", later), "pill");
});

// Not every payload carries session_id — an empty one still has to reach the
// pill sensibly: it registers nothing (it cannot be told apart from anyone),
// and a lone live session can only be the one it means.

test("anonymous events register no session, but the pill still works", () => {
  const reg = new SessionRegistry();
  reg.note(CLAUDE, display("", "coucou", "/a"), true);
  assert.equal(reg.liveCount(CLAUDE), 0);
  assert.equal(reg.endTurn(CLAUDE, ""), "pill");
  assert.equal(reg.endSession(CLAUDE, ""), "pill");
});

test("an anonymous end is the one live session's, but never a guess in a crowd", () => {
  const reg = new SessionRegistry();
  reg.note(CLAUDE, display("a", "coucou"), true);
  assert.equal(reg.endTurn(CLAUDE, ""), "pill"); // only A is live: the Stop is A's
  assert.equal(reg.endSession(CLAUDE, ""), "pill");
  assert.equal(reg.liveCount(CLAUDE), 0);

  reg.note(CLAUDE, display("a", "coucou"), true);
  reg.note(CLAUDE, display("b", "lokil"), true);
  assert.equal(reg.endSession(CLAUDE, ""), "sessionOnly"); // ambiguous — ends nothing
  assert.equal(reg.liveCount(CLAUDE), 2);
  assert.equal(reg.endTurn(CLAUDE, ""), "sessionOnly");
});

test("an event the relay sent before the session's Stop is recognised as late", () => {
  const reg = new SessionRegistry();
  reg.note(CLAUDE, display("s1", "app", "/p"), true, 0);
  reg.endTurn(CLAUDE, "s1", 10, 3000);
  assert.equal(reg.sentBeforeTurnEnded(CLAUDE, "s1", 2000), true);
  assert.equal(reg.sentBeforeTurnEnded(CLAUDE, "s1", 4000), false);
  assert.equal(reg.sentBeforeTurnEnded(CLAUDE, "other", 2000), false);
});
