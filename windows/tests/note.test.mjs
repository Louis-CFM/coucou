// The note view (buildNote in src/views/views.ts) on a fake DOM: a note that says
// where it came from can be sent back there, and folds the island if left alone.

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";

installFakeDom();
const { NOTE_SECONDS, buildNote } = await import("../src/views/views.ts");
const { State } = await import("../src/core/state.ts");

let went;
let folded;
let view;
let at = 1000;

/** Puts a note up the way the chat (or a failed drop, with `then` null) does. */
function show(message, then) {
  State.noteMessage = message;
  State.noteThen = then;
  State.noteAt = ++at;
  State.view = "note";
  view.sync();
}

beforeEach(() => {
  mock.timers.enable({ apis: ["setTimeout"] });
  went = [];
  folded = 0;
  view = buildNote({ setView: (v) => went.push(v), collapse: () => folded++ });
});
afterEach(() => mock.timers.reset());

const seconds = (n) => mock.timers.tick(n * 1000);
const okRow = () => view.el.querySelector(".actions");

test("a note from the chat has an OK button that goes back to the chat", () => {
  show("Google AI: model not found (404).", "prompt");
  assert.equal(view.el.querySelector(".title").textContent, "Google AI: model not found (404).");
  assert.notEqual(okRow().style.display, "none");
  view.el.querySelector(".btn").fire("click");
  assert.deepEqual(went, ["prompt"]);
  assert.equal(folded, 0);
});

test("left alone, it folds the island instead of taking the keyboard back to the chat", () => {
  show("Network error", "prompt");
  seconds(NOTE_SECONDS - 1);
  assert.equal(folded, 0);
  seconds(1);
  assert.equal(folded, 1);
  assert.deepEqual(went, []);
});

test("a note someone already left is not closed again", () => {
  show("Network error", "prompt");
  State.view = "overview"; // a tab was clicked, or OK
  seconds(NOTE_SECONDS);
  assert.equal(folded, 0);
});

test("a new note gets its own ten seconds, even with the same words", () => {
  show("Network error", "prompt");
  seconds(NOTE_SECONDS - 2);
  show("Network error", "prompt");
  seconds(NOTE_SECONDS - 2);
  assert.equal(folded, 0, "the first note's timer is gone");
  seconds(2);
  assert.equal(folded, 1);
});

test("redrawing the same note does not start its time over", () => {
  show("Network error", "prompt");
  seconds(NOTE_SECONDS - 1);
  view.sync();
  seconds(1);
  assert.equal(folded, 1);
});

test("a note with its own timing has no OK button and is left alone", () => {
  show("Could not read the file", null);
  assert.equal(okRow().style.display, "none");
  seconds(NOTE_SECONDS * 2);
  assert.equal(folded, 0);
  assert.deepEqual(went, []);
});
