// The WhatsApp card made bigger to read (whatsappHeight in src/core/whatsapp.ts): taller in front,
// and an open conversation takes the whole island.

import { test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { IDLE_WHATSAPP, WHATSAPP_ID, WhatsApp, whatsappHeight } from "../src/core/whatsapp.ts";
import { PANEL_H, WHATSAPP_CHAT_H, WHATSAPP_LIST_H } from "../src/core/layout.ts";
import { buildWhatsAppCard } from "../src/views/whatsapp.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";

installFakeDom();

const NOW = Date.now();
const conversation = {
  id: "447700900123@s.whatsapp.net", name: "Alex Example", isGroup: false, unread: 1, lastActivity: NOW,
  messages: [{
    id: "m1", chat: "447700900123@s.whatsapp.net", sender: "447700900123@s.whatsapp.net", senderName: "",
    text: "Hello", media: { kind: "none" }, date: NOW, fromMe: false, mentionsMe: false,
  }],
};

test("in front, the card is taller; an open conversation takes the island's chat height", () => {
  assert.equal(whatsappHeight("expanded", "overview", WHATSAPP_ID, true, false), WHATSAPP_LIST_H);
  assert.equal(whatsappHeight("expanded", "overview", WHATSAPP_ID, true, true), WHATSAPP_CHAT_H);
  assert.equal(whatsappHeight("expanded", "overview", "integration_claude", true, true), null, "another card in front");
  assert.equal(whatsappHeight("compact", "overview", WHATSAPP_ID, true, true), null, "folded");
  assert.equal(whatsappHeight("expanded", "approval", WHATSAPP_ID, true, true), null, "a permission card on top");
  assert.equal(whatsappHeight("expanded", "overview", WHATSAPP_ID, false, false), null, "WhatsApp turned off");
  assert.ok(WHATSAPP_LIST_H < WHATSAPP_CHAT_H && WHATSAPP_CHAT_H <= PANEL_H, "it fits the island's window");
});

test("the card says when a conversation is open, and Escape or leaving the card takes it back", () => {
  // The WhatsApp pill declared, as in Settings.
  State.settings = { ...DEFAULT_SETTINGS, activeIntegrations: [WHATSAPP_ID] };
  State.os = "windows";
  State.tasks = [];
  State.loadIntegrationTasks();
  const card = buildWhatsAppCard({ openSettings() {}, keyboard() {}, holdOpen() {} });
  WhatsApp.view = { ...IDLE_WHATSAPP, on: true, link: { state: "connected" }, unread: 1, conversations: [conversation] };
  State.mode = "expanded";
  State.view = "overview";
  State.focusId = WHATSAPP_ID;
  let notified = 0;
  State.subscribe(() => notified++);
  card.sync();
  assert.equal(WhatsApp.reading, false);
  card.el.find(".wa-row")[0].fire("click");
  assert.equal(WhatsApp.reading, true);
  assert.ok(notified > 0, "the island hears of it, to grow");
  const escape = { key: "Escape", shiftKey: false, preventDefault() {}, stopPropagation() {} };
  for (const fn of card.el.find("TEXTAREA")[0].listeners.get("keydown")) fn(escape);
  assert.equal(WhatsApp.reading, false);
  card.el.find(".wa-row")[0].fire("click");
  State.mode = "compact";
  State.notify();
  assert.equal(WhatsApp.reading, false, "folding the island closes it");
});
