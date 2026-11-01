// Compact island hide delay and eyes follow pointer setting (Issue #575).

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { IslandStateMachine } from "../src/island/fsm.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

test("DEFAULT_SETTINGS: compactHideDelay is 60 and eyesFollowPointer is true", () => {
  assert.equal(DEFAULT_SETTINGS.compactHideDelay, 60);
  assert.equal(DEFAULT_SETTINGS.eyesFollowPointer, true);
});

test("IslandStateMachine: petitToHiddenDelay defaults to 60s and transitions to hidden after delay", () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    const fsm = new IslandStateMachine();
    assert.equal(fsm.petitToHiddenDelay, 60);

    // Launch into greeting, then complete into compact (petit)
    fsm.launch();
    fsm.greetComplete();
    mock.timers.tick(600); // 0.6s greetAutoCollapseDelay
    assert.equal(fsm.state, "petit");

    // Mouse enters and leaves compact island
    fsm.mouseEntered();
    fsm.mouseLeft();
    assert.equal(fsm.state, "petit");

    // 59s passes -> still petit
    mock.timers.tick(59_000);
    assert.equal(fsm.state, "petit");

    // 1s more -> hidden
    mock.timers.tick(1_000);
    assert.equal(fsm.state, "hidden");
  } finally {
    mock.timers.reset();
  }
});

test("IslandStateMachine: changing petitToHiddenDelay while timer runs reschedules with new delay", () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    const fsm = new IslandStateMachine();
    fsm.state = "petit";
    fsm.mouseLeft(); // starts countdown with default 60s

    mock.timers.tick(10_000); // 10s elapsed
    assert.equal(fsm.state, "petit");

    // Change delay to 20s: timer restarts with 20s
    fsm.petitToHiddenDelay = 20;
    assert.equal(fsm.petitToHiddenDelay, 20);

    mock.timers.tick(19_000);
    assert.equal(fsm.state, "petit");

    mock.timers.tick(1_000);
    assert.equal(fsm.state, "hidden");
  } finally {
    mock.timers.reset();
  }
});

test("IslandStateMachine: invalid petitToHiddenDelay values are ignored", () => {
  const fsm = new IslandStateMachine();
  fsm.petitToHiddenDelay = -10;
  assert.equal(fsm.petitToHiddenDelay, 60);
  fsm.petitToHiddenDelay = NaN;
  assert.equal(fsm.petitToHiddenDelay, 60);
  fsm.petitToHiddenDelay = Infinity;
  assert.equal(fsm.petitToHiddenDelay, 60);
});

test("eyesFollowPointer: State settings reflect toggle", () => {
  State.settings.eyesFollowPointer = false;
  assert.equal(State.settings.eyesFollowPointer, false);

  State.settings.eyesFollowPointer = true;
  assert.equal(State.settings.eyesFollowPointer, true);
});

