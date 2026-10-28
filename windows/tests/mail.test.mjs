// Mail view (src/views/mail.ts) on fake DOM:
// sends dropped file through Bridge.sendEmail, checks validation, and provides cancel.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { calls, internals, sent } from "./tauri.mjs";

installFakeDom();
const { buildMail } = await import("../src/views/mail.ts");
const { State } = await import("../src/core/state.ts");

let answers;
const plainInvoke = internals.invoke;
internals.invoke = async (cmd, args) => {
  const result = await plainInvoke(cmd, args);
  if (cmd in answers) return typeof answers[cmd] === "function" ? answers[cmd](args) : answers[cmd];
  return result;
};

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

let actions;
let lastView = "";
let view;

beforeEach(() => {
  calls.length = 0;
  answers = {};
  lastView = "";
  actions = {
    setView: (v) => { lastView = v; },
    cancelDrop: () => { lastView = "cancelled"; },
    keyboard: () => {},
  };
  State.droppedFile = { name: "report.pdf", path: "C:\\Users\\test\\report.pdf", size: 1024 };
  view = buildMail(actions);
  view.sync();
});

test("mail view renders recipient, subject, body fields and action buttons", () => {
  const inputs = view.el.find(".mail-input");
  assert.equal(inputs.length, 2);
  const body = view.el.querySelector(".mail-body");
  assert.ok(body);
  const btns = view.el.find(".btn");
  assert.equal(btns.length, 2);
  assert.equal(view.el.querySelector(".mail-sub").textContent, " — report.pdf");
});

test("sending without recipient shows missing recipient error", async () => {
  const sendBtn = view.el.querySelector(".btn.primary");
  sendBtn.fire("click");
  await flush();

  const status = view.el.querySelector(".mail-status");
  assert.equal(status.textContent, "Missing recipient.");
  assert.ok(status.classList.contains("error"));
  assert.equal(sent("send_email").length, 0);
});

test("sending with recipient invokes send_email command", async () => {
  const inputs = view.el.find(".mail-input");
  const toInput = inputs[0];
  const subjInput = inputs[1];
  const bodyInput = view.el.querySelector(".mail-body");

  toInput.value = "user@example.com";
  subjInput.value = "Project Update";
  bodyInput.value = "Here is the file attached.";

  answers.send_email = true;
  const sendBtn = view.el.querySelector(".btn.primary");
  sendBtn.fire("click");
  await flush();

  const invocations = sent("send_email");
  assert.equal(invocations.length, 1);
  assert.deepEqual(invocations[0].req, {
    to: "user@example.com",
    subject: "Project Update",
    body: "Here is the file attached.",
    filePath: "C:\\Users\\test\\report.pdf",
  });
});

test("clicking cancel returns to choose view", () => {
  const cancelBtn = view.el.querySelector(".btn.secondary");
  cancelBtn.fire("click");
  assert.equal(lastView, "choose");
});

test("when Resend is not configured, shows notice and 'Open in Gmail' button", async () => {
  answers.secret_present = (args) => args?.key === "resend-api-key" ? false : false;
  view.sync();
  await flush();

  const notice = view.el.querySelector(".mail-notice");
  assert.ok(notice);
  assert.notEqual(notice.style.display, "none");
  assert.ok(notice.textContent.includes("Resend not set: opens Gmail"));

  const sendBtn = view.el.querySelector(".btn.primary");
  assert.equal(sendBtn.textContent, "Open in Gmail");

  // Clicking Settings link in notice opens Settings
  let settingsOpened = false;
  actions.openSettingsWindow = () => { settingsOpened = true; };
  const link = notice.querySelector(".mail-notice-link");
  assert.ok(link);
  link.fire("click");
  assert.equal(settingsOpened, true);
});

test("when Resend is configured, notice is hidden and button says 'Send'", async () => {
  answers.secret_present = (args) => args?.key === "resend-api-key" ? true : false;
  view.sync();
  await flush();

  const notice = view.el.querySelector(".mail-notice");
  assert.equal(notice.style.display, "none");

  const sendBtn = view.el.querySelector(".btn.primary");
  assert.equal(sendBtn.textContent, "Send");
});

test("sending via Gmail fallback updates status to Opened in Gmail", async () => {
  answers.secret_present = () => false;
  answers.send_email = { method: "gmail", sent: false };
  view.sync();
  await flush();

  const inputs = view.el.find(".mail-input");
  inputs[0].value = "user@example.com";

  const sendBtn = view.el.querySelector(".btn.primary");
  sendBtn.fire("click");
  await flush();

  const status = view.el.querySelector(".mail-status");
  assert.ok(status.textContent.includes("Opened in Gmail"));
  assert.ok(status.classList.contains("success"));
});
