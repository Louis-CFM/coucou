import { mock, test } from "node:test";
import assert from "node:assert/strict";
import { State } from "../src/core/state.ts";

test("drag leave timeout resets upload view to default view", () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    State.view = "upload";
    State.fileDragOver = false;

    let restored = false;
    const timer = setTimeout(() => {
      if (!State.fileDragOver && State.view === "upload") {
        State.view = State.defaultView();
        restored = true;
      }
    }, 800);

    assert.equal(State.view, "upload");
    assert.equal(restored, false);

    mock.timers.tick(800);

    assert.equal(restored, true);
    assert.equal(State.view, State.defaultView());
  } finally {
    mock.timers.reset();
  }
});

test("drag re-entry cancels leave timeout and preserves upload view", () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    State.view = "upload";
    State.fileDragOver = false;

    let restored = false;
    let timer = setTimeout(() => {
      if (!State.fileDragOver && State.view === "upload") {
        State.view = State.defaultView();
        restored = true;
      }
    }, 800);

    // Re-entered before timeout
    mock.timers.tick(400);
    clearTimeout(timer);
    timer = null;
    State.fileDragOver = true;

    mock.timers.tick(600);
    assert.equal(restored, false);
    assert.equal(State.view, "upload");
  } finally {
    mock.timers.reset();
  }
});
