// What came in since you last looked (src/island/unread.ts): the WhatsApp and Mail pills count
// it, wiggle when it grows, and forget it once their card has been open.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { IDLE_WHATSAPP, WHATSAPP_ID, WhatsApp } from "../src/core/whatsapp.ts";
import { MAIL_ID } from "../src/core/mail.ts";
import { State } from "../src/core/state.ts";
import {
  WIGGLE_MS, grewAt, newSince, resetUnread, trackUnread, unreadOf, wiggling,
} from "../src/island/unread.ts";

installFakeDom();

const whatsapp = (unread, on = true) => {
  WhatsApp.view = { ...IDLE_WHATSAPP, on, link: { state: "connected" }, unread };
};
const mail = (unread) => {
  State.integrations[MAIL_ID] = { data: { running: true, unread }, error: null, loaded: true, configured: true };
};
const look = (id) => {
  State.mode = "expanded";
  State.view = "overview";
  State.focusId = id;
};

beforeEach(() => {
  resetUnread();
  State.mode = "compact";
  State.view = "overview";
  State.focusId = "integration_claude";
  State.paused = false;
  WhatsApp.view = { ...IDLE_WHATSAPP };
  delete State.integrations[MAIL_ID];
});

test("what was already unread is not new; what comes in is counted, with a short wiggle", () => {
  whatsapp(2);
  trackUnread(1_000);
  assert.equal(newSince(WHATSAPP_ID, 1_000), 0);
  assert.equal(wiggling(WHATSAPP_ID, 1_000), false);
  whatsapp(5);
  assert.equal(newSince(WHATSAPP_ID, 2_000), 3);
  assert.equal(grewAt(WHATSAPP_ID), 2_000);
  assert.equal(wiggling(WHATSAPP_ID, 2_000), true);
  assert.equal(wiggling(WHATSAPP_ID, 2_000 + WIGGLE_MS), false, "it wiggles once, then stays still");
  assert.equal(newSince(WHATSAPP_ID, 2_000 + WIGGLE_MS), 3, "the count stays until it is looked at");
});

test("opening the card clears it; the compact island or another card is not looking", () => {
  whatsapp(0);
  trackUnread(1_000);
  whatsapp(4);
  State.focusId = WHATSAPP_ID;
  trackUnread(2_000);
  assert.equal(newSince(WHATSAPP_ID, 2_000), 4, "compact: the card isn't open");
  look("integration_claude");
  trackUnread(3_000);
  assert.equal(newSince(WHATSAPP_ID, 3_000), 4, "another card is open");
  look(WHATSAPP_ID);
  trackUnread(4_000);
  assert.equal(newSince(WHATSAPP_ID, 4_000), 0);
  assert.equal(wiggling(WHATSAPP_ID, 4_000), false);
  // A message that comes in while the card is open is seen at once.
  whatsapp(5);
  trackUnread(5_000);
  assert.equal(newSince(WHATSAPP_ID, 5_000), 0);
  look("integration_claude");
  whatsapp(6);
  assert.equal(newSince(WHATSAPP_ID, 6_000), 1);
});

test("read somewhere else, nothing is new; turned off, nothing is counted", () => {
  whatsapp(3);
  trackUnread(1_000);
  whatsapp(5);
  assert.equal(newSince(WHATSAPP_ID, 2_000), 2);
  whatsapp(0);
  assert.equal(newSince(WHATSAPP_ID, 3_000), 0);
  whatsapp(1);
  assert.equal(newSince(WHATSAPP_ID, 4_000), 1);
  whatsapp(1, false);
  assert.equal(unreadOf(WHATSAPP_ID), null);
  assert.equal(newSince(WHATSAPP_ID, 5_000), 0);
});

test("Mail counts Outlook's unread mail the same way", () => {
  assert.equal(unreadOf(MAIL_ID), null, "not set up: nothing to count");
  mail(120);
  trackUnread(1_000);
  assert.equal(newSince(MAIL_ID, 1_000), 0, "an inbox already full of unread mail is not news");
  mail(123);
  assert.equal(newSince(MAIL_ID, 2_000), 3);
  assert.equal(wiggling(MAIL_ID, 2_000), true);
  look(MAIL_ID);
  trackUnread(3_000);
  assert.equal(newSince(MAIL_ID, 3_000), 0);
  assert.equal(newSince("integration_github", 3_000), 0, "only WhatsApp and Mail count");
});

test("paused: still counted, but no wiggle", () => {
  whatsapp(0);
  trackUnread(1_000);
  State.paused = true;
  whatsapp(2);
  assert.equal(newSince(WHATSAPP_ID, 2_000), 2);
  assert.equal(wiggling(WHATSAPP_ID, 2_000), false);
});
