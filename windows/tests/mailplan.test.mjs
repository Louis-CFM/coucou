// The mail plan card (src/views/mailplan.ts) shows everything Run would send.

import { test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { emit } from "./tauri.mjs";

installFakeDom();
const { mailPlanCard } = await import("../src/views/mailplan.ts");

const mail = (extra) => ({ to: ["client@acme.fr"], cc: [], subject: "Devis", body: "Bonjour,\nvoici le devis.", attachments: [], problem: null, ...extra });
const run = (mails) => ({
  phase: { kind: "ready" }, summary: "Send the quote", sorts: [], replies: [], saves: [], mails, notes: [],
  testSentTo: null, myAddress: null, stepCount: mails.length,
});

test("every Cc, every attachment and the body of a mail are on the card", () => {
  const el = mailPlanCard("plan-1", "", "");
  emit("mail-plan", { id: "plan-1", run: run([mail({
    cc: ["x@example.org"],
    attachments: ["C:\\Users\\me\\Documents\\devis.pdf", "C:\\Users\\me\\Documents\\passport.pdf"],
  })]) });
  const text = el.textContent;
  assert.match(text, /Cc x@example\.org/);
  assert.match(text, /devis\.pdf/);
  assert.match(text, /passport\.pdf/);
  assert.doesNotMatch(text, /\+1/);
  const subject = el.querySelector(".plan-subject");
  assert.equal(subject.getAttribute("title"), "Bonjour,\nvoici le devis.");
});

test("a mail with one attachment and no Cc keeps a single row", () => {
  const el = mailPlanCard("plan-2", "", "");
  emit("mail-plan", { id: "plan-2", run: run([mail({ attachments: ["C:\\p\\page-1.pdf"] })]) });
  assert.equal(el.find(".plan-row").length, 1);
  assert.match(el.textContent, /📎 page-1\.pdf/);
});
