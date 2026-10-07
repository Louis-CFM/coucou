// Island open/close state machine (src/island/fsm.ts).

import { afterEach, beforeEach, mock, test } from "node:test";
import assert from "node:assert/strict";
import { IslandStateMachine } from "../src/island/fsm.ts";

let fsm;
let transitions;

beforeEach(() => {
  mock.timers.enable({ apis: ["setTimeout"] });
  fsm = new IslandStateMachine();
  transitions = [];
  fsm.onTransition = (from, to) => transitions.push(`${from}>${to}`);
});

afterEach(() => mock.timers.reset());

const seconds = (n) => mock.timers.tick(n * 1000);

test("starts hidden and opens on the greeting at launch", () => {
  assert.equal(fsm.state, "hidden");
  fsm.launch();
  assert.equal(fsm.state, "coucou");
  assert.deepEqual(transitions, ["hidden>coucou"]);
});

test("the greeting collapses to the compact island 0.6 s after it ends", () => {
  fsm.launch();
  fsm.greetComplete();
  seconds(0.5);
  assert.equal(fsm.state, "coucou");
  seconds(0.1);
  assert.equal(fsm.state, "petit");
});

test("a hovered greeting stays for 10 s, whatever the animation does", () => {
  fsm.launch();
  fsm.mouseEntered();
  fsm.greetComplete();
  seconds(9.9);
  assert.equal(fsm.state, "coucou");
  seconds(0.1);
  assert.equal(fsm.state, "petit");
});

test("leaving the greeting collapses it at once", () => {
  fsm.launch();
  fsm.mouseEntered();
  fsm.mouseLeft();
  assert.equal(fsm.state, "petit");
});

test("the mouse wakes a hidden island, which stays while it is hovered", () => {
  fsm.mouseEntered();
  assert.equal(fsm.state, "petit");
  seconds(600);
  assert.equal(fsm.state, "petit");
});

test("the compact island hides 60 s after the mouse leaves", () => {
  fsm.mouseEntered();
  fsm.mouseLeft();
  seconds(59);
  assert.equal(fsm.state, "petit");
  seconds(1);
  assert.equal(fsm.state, "hidden");
});

test("coming back before the 60 s are up cancels the hide", () => {
  fsm.mouseEntered();
  fsm.mouseLeft();
  seconds(59);
  fsm.mouseEntered();
  seconds(600);
  assert.equal(fsm.state, "petit");
});

test("a click opens the compact island, and only the compact island", () => {
  fsm.click();
  assert.equal(fsm.state, "hidden");
  fsm.mouseEntered();
  fsm.click();
  assert.equal(fsm.state, "home");
  fsm.click();
  assert.equal(fsm.state, "home");
  assert.deepEqual(transitions, ["hidden>petit", "petit>home"]);
});

test("the open island collapses 15 s after the mouse leaves", () => {
  fsm.forceHome();
  fsm.mouseLeft();
  seconds(14);
  assert.equal(fsm.state, "home");
  seconds(1);
  assert.equal(fsm.state, "petit");
});

test("coming back to the open island cancels the collapse", () => {
  fsm.forceHome();
  fsm.mouseLeft();
  seconds(14);
  fsm.mouseEntered();
  seconds(600);
  assert.equal(fsm.state, "home");
});

test("a pinned island stays open when the mouse leaves", () => {
  fsm.forceHome();
  fsm.pinned = true;
  fsm.mouseLeft();
  seconds(600);
  assert.equal(fsm.state, "home");
});

test("the collapse delay is the configured one", () => {
  fsm.homeToPetitDelay = 5;
  fsm.forceHome();
  fsm.mouseLeft();
  seconds(5);
  assert.equal(fsm.state, "petit");
});

test("reveal shows the compact island from hidden and hides it again after 60 s", () => {
  fsm.reveal();
  assert.equal(fsm.state, "petit");
  seconds(60);
  assert.equal(fsm.state, "hidden");
});

test("reveal leaves an island that is already showing alone", () => {
  fsm.forceHome();
  fsm.reveal();
  assert.equal(fsm.state, "home");
  assert.deepEqual(transitions, ["hidden>home"]);
});

test("forcing the island open cancels a pending hide", () => {
  fsm.reveal();
  fsm.forceHome();
  seconds(600);
  assert.equal(fsm.state, "home");
});

test("an explicit close goes to the compact island and cancels the collapse", () => {
  fsm.forceHome();
  fsm.mouseLeft();
  fsm.forcePetit();
  assert.equal(fsm.state, "petit");
  seconds(600);
  assert.equal(fsm.state, "petit");
});

test("forceHidden hides from any state", () => {
  fsm.forceHome();
  fsm.forceHidden();
  assert.equal(fsm.state, "hidden");
});

test("a transition to the current state is not reported", () => {
  fsm.forceHome();
  fsm.forceHome();
  assert.deepEqual(transitions, ["hidden>home"]);
});
