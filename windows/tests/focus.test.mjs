// The focus timer: the rules in src/core/focus.ts, the clock and the island in
// src/island/focus.ts, the card in src/views/focus.ts.

import { beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import {
  DURATIONS, FOCUS_ID, Focus, IDLE_FOCUS, ROUNDS, formatClock, next, pause, progressAt, remainingAt, reset, start,
} from "../src/core/focus.ts";
import { focusChanged, phaseEnded, registerFocusHandlers } from "../src/island/focus.ts";
import { buildFocusCard } from "../src/views/focus.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";
import { Sound } from "../src/core/sound.ts";
import { setLanguage } from "../src/i18n/i18n.ts";

installFakeDom();

const island = { reveals: 0, reveal() { this.reveals += 1; } };
registerFocusHandlers(island);
const played = [];
Sound.play = (name) => { played.push(name); };

beforeEach(() => {
  setLanguage("en");
  State.os = "windows";
  State.settings = { ...DEFAULT_SETTINGS, activeIntegrations: [FOCUS_ID] };
  State.tasks = [];
  State.mode = "hidden";
  State.paused = false;
  State.loadIntegrationTasks();
  Focus.state = { ...IDLE_FOCUS };
  island.reveals = 0;
  played.length = 0;
});

const task = () => State.tasks.find((t) => t.id === FOCUS_ID);

// ── Rules ─────────────────────────────────────────────────────────────────────

test("start, pause and resume keep the time left; reset goes back to the start", () => {
  let s = start(IDLE_FOCUS, 0);
  assert.equal(remainingAt(s, 60_000), DURATIONS.focus - 60);
  s = pause(s, 60_000);
  assert.equal(s.running, false);
  assert.equal(remainingAt(s, 999_999), DURATIONS.focus - 60, "paused, it stays put");
  s = start(s, 100_000);
  assert.equal(remainingAt(s, 110_000), DURATIONS.focus - 70);
  assert.equal(progressAt(s, 100_000 + (DURATIONS.focus - 60) * 1000), 1);
  assert.deepEqual(reset(), IDLE_FOCUS);
  assert.equal(remainingAt(start(IDLE_FOCUS, 0), 10_000_000), 0, "never below zero");
});

test("a break starts by itself; the next focus waits; a long break every fourth round", () => {
  let s = next({ ...IDLE_FOCUS, running: true }, 0);
  assert.equal(s.phase, "break");
  assert.ok(s.running, "the break runs");
  assert.equal(remainingAt(s, 0), DURATIONS.break);
  s = next(s, 0);
  assert.equal(s.phase, "focus");
  assert.ok(!s.running, "the next focus waits for a click");
  assert.equal(s.round, 2);

  s = next({ ...IDLE_FOCUS, round: ROUNDS }, 0);
  assert.equal(s.phase, "longBreak");
  assert.equal(remainingAt(s, 0), DURATIONS.longBreak);
  assert.equal(next(s, 0).round, 1, "after the long break, round 1 again");
});

test("the clock reads m:ss, rounded up so 0:00 means done", () => {
  assert.equal(formatClock(DURATIONS.focus), "25:00");
  assert.equal(formatClock(59.2), "1:00");
  assert.equal(formatClock(0.4), "0:01");
  assert.equal(formatClock(0), "0:00");
  assert.equal(formatClock(-3), "0:00");
});

// ── The island ────────────────────────────────────────────────────────────────

test("the pill wears the phase and time left once started, and its own name otherwise", () => {
  assert.equal(task().name, "Focus timer");
  Focus.state = start(IDLE_FOCUS, Date.now());
  focusChanged();
  assert.match(task().name, /^Focus (25:00|24:59)$/);
  assert.equal(task().state, "idle");
  Focus.state = reset();
  focusChanged();
  assert.equal(task().name, "Focus timer");
});

test("a focus that ends: a sound, the island out, and Mochi naps through the break", () => {
  Focus.state = start(IDLE_FOCUS, Date.now());
  phaseEnded();
  assert.deepEqual(played, ["finish"]);
  assert.equal(island.reveals, 1);
  assert.equal(Focus.state.phase, "break");
  assert.equal(task().state, "sleeping");
  assert.match(task().name, /^Break /);

  phaseEnded();
  assert.deepEqual(played, ["finish", "greet"], "the break's end wakes him");
  assert.equal(task().state, "idle");
  assert.equal(Focus.state.round, 2);
});

test("the end of a phase is a timeout, and it fires on time", () => {
  mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
  try {
    Focus.state = start(IDLE_FOCUS, Date.now());
    focusChanged();
    mock.timers.tick(DURATIONS.focus * 1000 - 1);
    assert.equal(Focus.state.phase, "focus");
    mock.timers.tick(1);
    assert.equal(Focus.state.phase, "break");
    assert.deepEqual(played, ["finish"]);
  } finally {
    mock.timers.reset();
  }
});

test("paused Coucou, or a pill taken away: no sound, no island; the timer stops with its pill", () => {
  State.paused = true;
  Focus.state = start(IDLE_FOCUS, Date.now());
  phaseEnded();
  assert.deepEqual(played, []);
  assert.equal(island.reveals, 0);

  State.paused = false;
  Focus.state = start(IDLE_FOCUS, Date.now());
  State.settings.activeIntegrations = [];
  State.loadIntegrationTasks();
  assert.equal(task(), undefined);
  assert.deepEqual(Focus.state, IDLE_FOCUS, "reset with its pill");
});

// ── The card ──────────────────────────────────────────────────────────────────

test("the card: Start, then Pause and Resume; Skip and Reset", () => {
  const card = buildFocusCard();
  card.sync();
  assert.match(card.el.textContent, /Focus timer.*Focus · Round 1 of 4.*25:00.*Start.*Skip/);
  const [primary, skip, resetBtn] = card.el.querySelector("int-actions").children;
  assert.equal(resetBtn.style.display, "none", "nothing to reset yet");

  primary.fire("click");
  card.sync();
  assert.ok(Focus.state.running);
  assert.equal(primary.textContent, "Pause");

  primary.fire("click");
  card.sync();
  assert.ok(!Focus.state.running);
  assert.equal(primary.textContent, "Resume");
  assert.equal(resetBtn.style.display, "");

  skip.fire("click");
  card.sync();
  assert.equal(Focus.state.phase, "break");
  assert.deepEqual(played, [], "skipping makes no sound");
  assert.match(card.el.textContent, /Break · Round 1 of 4/);

  resetBtn.fire("click");
  card.sync();
  assert.deepEqual(Focus.state, IDLE_FOCUS);

  setLanguage("fr");
  card.sync();
  assert.match(card.el.textContent, /Concentration · Tour 1 sur 4.*Démarrer/);
});
