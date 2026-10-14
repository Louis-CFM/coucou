import { test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { State } from "../src/core/state.ts";
import { buildQuestion } from "../src/views/views.ts";

installFakeDom();

test("open-text clarification hands control back to terminal", () => {
  const sent = [];
  State.pendingApproval = request([{ qid: "q0", question: "First?", multiSelect: false }]);
  const view = buildQuestion(actionsFor(sent));
  view.sync();
  assert.equal(view.el.find("input").length, 0);
  assert.ok(view.el.find("button").some((b) => b.textContent === "Answer in terminal"));
  view.el.find("button").find((b) => b.textContent === "Answer in terminal").fire("click");
  assert.equal(sent.length, 0);
  assert.equal(State.pendingApproval, null);
});

test("choice questions show options and terminal handoff without input", () => {
  const sent = [];
  State.pendingApproval = request([{ qid: "q0", question: "Pick?", choices: ["A", "B"], multiSelect: false }]);
  const view = buildQuestion(actionsFor(sent));
  view.sync();
  assert.equal(view.el.find("input").length, 0);
  assert.ok(view.el.find("button").some((b) => b.textContent === "A"));
  assert.ok(view.el.find("button").some((b) => b.textContent === "Answer in terminal"));
});

// Terminal handoff releases the pending Coucou request.
const actionsFor = (answers) => ({
  answer: (value) => answers.push(value),
  answerInTerminal() { State.pendingApproval = null; },
  foldApproval() {},
});
const request = (questions) => ({
  requestId: "clarify-1", sessionId: "session-1", pillId: "agent_hermes",
  tool: "clarify", command: "clarify", clarification: { questions },
});

test("Hermes clarification choices submit by normalized qid", () => {
  const sent = [];
  State.pendingApproval = request([{ qid: "q0", question: "Pick?", choices: ["A (Recommended)", "B"], multiSelect: false }]);
  const view = buildQuestion(actionsFor(sent));
  view.sync();
  const buttons = view.el.find("button").filter((b) => b.classList.contains("btn"));
  buttons[1].fire("click");
  assert.deepEqual(sent, [{ q0: "B" }]);
});



test("Hermes clarification multi-select submits selected values as list", () => {
  const sent = [];
  State.pendingApproval = request([{ qid: "q0", question: "Pick?", choices: ["Lint (Recommended)", "Tests"], multiSelect: true }]);
  const view = buildQuestion(actionsFor(sent));
  view.sync();
  view.el.find("button").find((b) => b.textContent === "Lint (Recommended)").fire("click");
  view.sync();
  view.el.find("button").find((b) => b.textContent === "Tests").fire("click");
  view.sync();
  view.el.find("button").find((b) => b.textContent === "Done").fire("click");
  assert.deepEqual(sent, [{ q0: ["Lint (Recommended)", "Tests"] }]);
});
