// WhatsApp (experimental): the page's rules in src/core/whatsapp.ts, the pill's reactions in
// src/island/whatsapp.ts, the card in src/views/whatsapp.ts. The gateway side — payloads,
// signatures, filters, the inbox, the installer — is tested in src-tauri/src/whatsapp/.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { emit, internals, sent } from "./tauri.mjs";
import { installFakeDom } from "./fakedom.mjs";
import {
  IDLE_WHATSAPP, WHATSAPP_ID, WhatsApp, canSend, duration, initials, installError, installFailure, installStepLabel,
  chatList, keyAction, lastMessages, linkColor, linkLabel, mergeMessages, preview, sendErrorLabel, showsLinkState,
  testResultLabel, timeAgo, webhookLine,
} from "../src/core/whatsapp.ts";
import { handlePillEvent, registerWhatsAppHandlers } from "../src/island/whatsapp.ts";
import { buildWhatsAppCard, buildWhatsAppChat, showsWhatsAppChat, whatsAppDropTarget } from "../src/views/whatsapp.ts";
import { pillDefinition } from "../src/core/pills.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";
import { lookup, setLanguage } from "../src/i18n/i18n.ts";

installFakeDom();

const NOW = 1_800_000_000_000;

const msg = (over = {}) => ({
  id: "m1", chat: "33612345678@s.whatsapp.net", sender: "33612345678@s.whatsapp.net", senderName: "",
  text: "Hello", media: { kind: "none" }, date: NOW - 30_000, fromMe: false, mentionsMe: false, ...over,
});

const conversation = (over = {}) => ({
  id: "33612345678@s.whatsapp.net", name: "Marie", isGroup: false, messages: [msg()], unread: 1,
  lastActivity: NOW - 30_000, ...over,
});

const connected = (over = {}) => ({ ...IDLE_WHATSAPP, on: true, link: { state: "connected" }, ...over });

// ── The pure rules (WhatsAppModels.swift, WhatsAppViews.swift) ─────────────────

test("initials: the first letters of two words, # when there are none", () => {
  assert.equal(initials("Marie Curie"), "MC");
  assert.equal(initials("jean-luc picard"), "JL");
  assert.equal(initials("Élodie"), "É");
  assert.equal(initials("+33612345678"), "#");
  assert.equal(initials(""), "#");
  assert.equal(duration(12), "0:12");
  assert.equal(duration(75), "1:15");
});

test("previews: one line, media as a label only, who wrote it in a group", () => {
  assert.equal(preview(msg({ text: "see\nyou" }), false), "see you");
  assert.equal(preview(msg({ fromMe: true, text: "ok" }), false), "You: ok");
  assert.equal(preview(msg({ senderName: "Paul", text: "hi" }), true), "Paul: hi");
  assert.equal(preview(msg({ senderName: "Paul", text: "hi" }), false), "hi", "a private chat needs no name");
  assert.equal(preview(msg({ media: { kind: "image" }, text: "look" }), false), "Photo · look");
  assert.equal(preview(msg({ media: { kind: "voice", seconds: null }, text: "" }), false), "Voice message");
  assert.equal(preview(msg({ media: { kind: "voice", seconds: 75 }, text: "" }), false), "Voice message · 1:15");
  assert.equal(preview(msg({ media: { kind: "document", name: "devis.pdf" }, text: "" }), false), "Document · devis.pdf");
  assert.equal(preview(msg({ media: { kind: "sticker" }, text: "" }), false), "Sticker");
  assert.equal(preview(msg({ media: { kind: "other" }, text: "" }), false), "Message");
});

test("the time since reads like the Mac's", () => {
  assert.equal(timeAgo(NOW - 10_000, NOW), "now");
  assert.equal(timeAgo(NOW - 5 * 60_000, NOW), "5m");
  assert.equal(timeAgo(NOW - 3 * 3_600_000, NOW), "3h");
  assert.equal(timeAgo(NOW - 2 * 86_400_000, NOW), "2d");
});

test("Rust's codes become words, a gateway's own message is shown as it is", () => {
  assert.equal(linkLabel({ state: "off" }), "Turned off in Settings");
  assert.equal(linkLabel({ state: "needsQr" }), "Scan the QR code in Settings");
  assert.equal(linkLabel({ state: "unreachable" }), "The gateway doesn’t answer: is it running?");
  assert.equal(linkLabel({ state: "failed", detail: "DEVICE_ID_REQUIRED" }), "DEVICE_ID_REQUIRED");
  assert.equal(linkColor({ state: "connected" }), "#22C55E");
  assert.equal(linkColor({ state: "needsQr" }), "#F5B83D");
  assert.equal(linkColor({ state: "unauthorized" }), "#F4505E");
  assert.equal(sendErrorLabel({ code: "tooFast" }), "A few replies a minute at most: wait a moment.");
  assert.equal(sendErrorLabel({ code: "refused", detail: "INVALID_JID" }), "INVALID_JID");
  assert.equal(webhookLine({ state: "registered" }), "Live: new messages arrive at once.");
  assert.equal(webhookLine({ state: "portBusy", port: 47823 }),
    "Port 47823 is taken: pick another one. Checking every 20 s meanwhile.");
  assert.equal(webhookLine({ state: "listening" }), "Checking for new messages every 20 s.");
  assert.equal(testResultLabel({ result: "connected", who: "+33612345678" }), "Connected as +33612345678.");
  assert.equal(testResultLabel({ result: "unreachable" }), "The gateway doesn’t answer: is it running?");
  assert.equal(installStepLabel({ step: "downloading", megabytes: 15 }), "Downloading (15 MB)…");
  assert.equal(installStepLabel({ step: "idle" }), "");
  assert.match(installFailure("badChecksum"), /doesn't match the file GOWA published/);
  assert.match(installFailure("anything else"), /didn't go through/);
  assert.equal(installError({ step: "done", version: "9.6.0" }), null);
  assert.match(installError({ step: "failed", reason: "noBuild" }), /No GOWA build for this computer/);
});

test("the status and QR show once there is a gateway to talk to", () => {
  const base = {
    prefs: { gateway: "gowa" }, url: "", installed: false, link: { state: "unreachable" },
  };
  assert.equal(showsLinkState(base), false, "before the install, 'it doesn't answer' would only confuse");
  assert.equal(showsLinkState({ ...base, installed: true }), true);
  assert.equal(showsLinkState({ ...base, url: "http://127.0.0.1:3001" }), true);
  assert.equal(showsLinkState({ ...base, prefs: { gateway: "openwa" } }), true);
  assert.equal(showsLinkState({ ...base, link: { state: "needsQr" } }), true);
});

test("Enter sends, Shift+Enter is a new line, Escape goes back, a composition never sends", () => {
  assert.equal(keyAction({ key: "Enter", shiftKey: false }), "send");
  assert.equal(keyAction({ key: "Enter", shiftKey: true }), "newline");
  assert.equal(keyAction({ key: "Enter", shiftKey: false, isComposing: true }), null);
  assert.equal(keyAction({ key: "Escape", shiftKey: false }), "back");
  assert.equal(keyAction({ key: "a", shiftKey: false }), null);
  assert.equal(canSend("  \n ", false), false);
  assert.equal(canSend("hi", true), false, "one reply at a time");
  assert.equal(canSend("hi", false), true);
  const many = conversation({ messages: Array.from({ length: 20 }, (_, i) => msg({ id: `m${i}` })) });
  assert.deepEqual(lastMessages(many).map((m) => m.id), ["m10", "m11", "m12", "m13", "m14", "m15", "m16", "m17", "m18", "m19"]);
});

test("the words are translated", () => {
  setLanguage("fr");
  try {
    assert.equal(linkLabel({ state: "connected" }), lookup("Connected", "fr"));
    assert.equal(preview(msg({ media: { kind: "image" }, text: "" }), false), lookup("Photo", "fr"));
    assert.ok(!webhookLine({ state: "registered" }).startsWith("Live"));
  } finally {
    setLanguage("en");
  }
});

// ── The pill (WhatsAppController.announce) ────────────────────────────────────

const host = { reveals: 0, emotes: [], reveal() { this.reveals++; }, emote(name) { this.emotes.push(name); } };
registerWhatsAppHandlers(host);

beforeEach(() => {
  State.settings = { ...DEFAULT_SETTINGS, activeIntegrations: [WHATSAPP_ID] };
  State.os = "windows";
  State.tasks = [];
  State.focusId = null;
  State.mode = "hidden";
  State.view = "overview";
  State.paused = false;
  State.loadIntegrationTasks();
  WhatsApp.view = { ...IDLE_WHATSAPP };
  host.reveals = 0;
  host.emotes = [];
});

const pill = () => State.tasks.find((t) => t.id === WHATSAPP_ID);

test("the pill is the Mac's, connected with nothing to enter", () => {
  const def = pillDefinition(WHATSAPP_ID);
  assert.equal(def.color, "#25D366");
  assert.equal(def.support, "yes");
  assert.deepEqual(def.connect, { kind: "none" });
  assert.ok(pill(), "declared, it is on the island");
});

test("a new message lights the pill with the chat's name only, and Mochi smiles once per burst", () => {
  handlePillEvent(host, { kind: "message", name: "Marie" }, 10_000);
  assert.equal(pill().state, "finished");
  assert.deepEqual(pill().steps, ["Marie"]);
  assert.equal(pill().pillBadge, "finished");
  assert.deepEqual(host.emotes, ["happy"]);
  assert.equal(host.reveals, 1);
  handlePillEvent(host, { kind: "message", name: "Paul" }, 12_000);
  assert.deepEqual(pill().steps, ["Paul"]);
  assert.deepEqual(host.emotes, ["happy"], "a burst is one reaction");
  handlePillEvent(host, { kind: "message", name: "Paul" }, 20_000);
  assert.deepEqual(host.emotes, ["happy", "happy"]);
  // Read: the badge goes.
  emit("whatsapp-pill", { kind: "read" });
  assert.equal(pill().pillBadge, null);
  // Turned off: back to idle.
  emit("whatsapp-pill", { kind: "reset" });
  assert.equal(pill().state, "idle");
  assert.deepEqual(pill().steps, []);
});

test("paused, or the pill on screen: no badge", () => {
  State.paused = true;
  handlePillEvent(host, { kind: "message", name: "Marie" }, 100_000);
  assert.equal(pill().state, "idle");
  State.paused = false;
  State.focusId = WHATSAPP_ID;
  handlePillEvent(host, { kind: "message", name: "Marie" }, 200_000);
  assert.equal(pill().state, "finished");
  assert.equal(pill().pillBadge ?? null, null);
});

test("the gateway down twice: the small red dot, gone when it answers", () => {
  emit("whatsapp", connected({ down: true }));
  assert.equal(pill().pillBadge, "error");
  emit("whatsapp", connected({ down: false }));
  assert.equal(pill().pillBadge, null);
});

// ── The card (WhatsAppCardView, WhatsAppConversationView) ─────────────────────

function card() {
  const calls = { settings: 0, keyboard: [], hold: [] };
  const built = buildWhatsAppCard({
    openSettings: () => calls.settings++,
    keyboard: (on) => calls.keyboard.push(on),
    holdOpen: (on) => calls.hold.push(on),
  });
  return { ...built, calls };
}

const key = (el, k, shiftKey = false) => {
  const event = { key: k, shiftKey, defaultPrevented: false, propagationStopped: false,
    preventDefault() { this.defaultPrevented = true; }, stopPropagation() { this.propagationStopped = true; } };
  for (const fn of el.listeners.get("keydown") ?? []) fn(event);
  return event;
};

test("not linked: why, and the way to Settings", () => {
  const c = card();
  WhatsApp.view = { ...IDLE_WHATSAPP, on: true, link: { state: "unreachable" } };
  c.sync();
  assert.match(c.el.textContent, /WhatsApp.*The gateway doesn’t answer: is it running\?.*Settings…/);
  c.el.find(".wa-settings")[0].fire("click");
  assert.equal(c.calls.settings, 1);
});

test("linked: one row per conversation, the unread count, or nothing new", () => {
  const c = card();
  WhatsApp.view = connected();
  c.sync();
  assert.match(c.el.textContent, /No new messages/);
  WhatsApp.view = connected({
    unread: 3,
    conversations: [
      conversation({ unread: 2 }),
      conversation({ id: "1203@g.us", name: "Famille", isGroup: true, unread: 1,
        messages: [msg({ chat: "1203@g.us", senderName: "Paul", text: "<b>@33612345678</b> tu viens ?" })] }),
    ],
  });
  c.sync();
  const rows = c.el.find(".wa-row");
  assert.equal(rows.length, 2);
  assert.match(c.el.textContent, /3 unread/);
  assert.match(rows[0].textContent, /Marie.*Hello.*2/);
  // Text is text, never markup (the fake DOM throws on innerHTML).
  assert.match(rows[1].textContent, /Paul: <b>@33612345678<\/b> tu viens \?/);
});

test("a right-click offers to ignore the chat, and only a click does it", () => {
  const c = card();
  WhatsApp.view = connected({ unread: 1, conversations: [conversation()] });
  c.sync();
  c.el.find(".wa-row")[0].fire("contextmenu");
  assert.equal(sent("whatsapp_ignore").length, 0);
  c.el.find(".wa-ignore")[0].fire("click");
  assert.deepEqual(sent("whatsapp_ignore").at(-1), { chat: "33612345678@s.whatsapp.net" });
});

test("a conversation: its messages, a reply sent on Enter only, Escape back to the list", async () => {
  const c = card();
  WhatsApp.view = connected({
    unread: 1,
    conversations: [conversation({ messages: [msg(), msg({ id: "m2", fromMe: true, text: "Salut !" })] })],
  });
  State.mode = "expanded";
  State.focusId = WHATSAPP_ID;
  c.sync();
  const before = sent("whatsapp_open").length;
  c.el.find(".wa-row")[0].fire("click");
  assert.deepEqual(sent("whatsapp_open").slice(before), [{ chat: "33612345678@s.whatsapp.net" }]);
  assert.deepEqual(c.calls.keyboard, [true], "the island takes the keyboard for the field");
  const bubbles = c.el.find(".wa-bubble");
  assert.equal(bubbles.length, 2);
  assert.ok(bubbles[1].classList.contains("mine"));

  const field = c.el.find("TEXTAREA")[0];
  const sends = () => sent("whatsapp_send").length;
  const start = sends();
  // Nothing to send: nothing goes.
  field.value = "   ";
  key(field, "Enter");
  assert.equal(sends(), start);
  // Typing holds the island open; Shift+Enter is a new line, not a send.
  field.value = "On arrive";
  for (const fn of field.listeners.get("input")) fn({});
  assert.deepEqual(c.calls.hold, [true]);
  const shifted = key(field, "Enter", true);
  assert.equal(shifted.defaultPrevented, false);
  assert.equal(sends(), start);
  const enter = key(field, "Enter");
  assert.equal(enter.defaultPrevented, true);
  await Promise.resolve();
  assert.deepEqual(sent("whatsapp_send").slice(start), [{ chat: "33612345678@s.whatsapp.net", text: "On arrive" }]);

  // A send refused: the reason shows under the field, the draft stays.
  WhatsApp.view = { ...WhatsApp.view, sendError: { code: "tooLong" } };
  c.sync();
  assert.match(c.el.find(".wa-note")[0].textContent, /Too long for one message/);

  // Escape: back to the list, not the island folding away.
  const esc = key(field, "Escape");
  assert.equal(esc.propagationStopped, true);
  assert.deepEqual(sent("whatsapp_close").at(-1), { chat: "33612345678@s.whatsapp.net" });
  assert.deepEqual(c.calls.keyboard, [true, false]);
  assert.equal(c.calls.hold.at(-1), false);
  assert.equal(c.el.find(".wa-row").length, 1);
});

test("the conversation closes when WhatsApp is turned off or the island folds", () => {
  const c = card();
  WhatsApp.view = connected({ unread: 1, conversations: [conversation()] });
  State.mode = "expanded";
  State.focusId = WHATSAPP_ID;
  c.sync();
  c.el.find(".wa-row")[0].fire("click");
  const closes = sent("whatsapp_close").length;
  State.mode = "compact";
  State.notify();
  assert.equal(sent("whatsapp_close").length, closes + 1);
  // Opened again, then the integration turned off.
  State.mode = "expanded";
  c.sync();
  c.el.find(".wa-row")[0].fire("click");
  WhatsApp.view = { ...IDLE_WHATSAPP };
  c.sync();
  assert.equal(sent("whatsapp_close").length, closes + 2);
});

// ── The big WhatsApp chat (the chat view on WhatsApp's Mochi) ─────────────────

test("the big chat's list: the inbox's conversations, then the gateway's others, newest first", () => {
  const inbox = [conversation({ lastActivity: NOW - 60_000 })];
  const gateway = [
    { id: "33612345678@s.whatsapp.net", name: "Marie (gateway)", isGroup: false, lastActivity: NOW, archived: false },
    { id: "1203@g.us", name: "Famille", isGroup: true, lastActivity: NOW - 30_000, archived: false },
    { id: "336999@s.whatsapp.net", name: "Paul", isGroup: false, lastActivity: NOW - 9_000_000, archived: true },
  ];
  const list = chatList(inbox, gateway);
  assert.deepEqual(list.map((c) => c.name), ["Famille", "Marie", "Paul"], "the inbox's copy wins");
  assert.deepEqual([list[0].messages, list[0].unread], [[], 0]);
  // Archived on the phone: out of the list, under "Archived" (an inbox chat too).
  assert.deepEqual(chatList(inbox, gateway, false).map((c) => c.name), ["Famille", "Marie"]);
  assert.deepEqual(chatList(inbox, gateway, true).map((c) => c.name), ["Paul"]);
  const archivedMarie = gateway.map((g) => (g.name === "Marie (gateway)" ? { ...g, archived: true } : g));
  assert.deepEqual(chatList(inbox, archivedMarie, true).map((c) => c.name), ["Marie", "Paul"]);
  const merged = mergeMessages([msg({ id: "a", date: 3 }), msg({ id: "b", date: 1 })], [msg({ id: "a", date: 3 }), msg({ id: "c", date: 2 })]);
  assert.deepEqual(merged.map((m) => m.id), ["b", "c", "a"]);
});

test("the chat view is WhatsApp on WhatsApp's Mochi only, and never with a file to ask about", () => {
  State.focusId = WHATSAPP_ID;
  assert.equal(showsWhatsAppChat(), true);
  State.droppedFile = { name: "a.png", path: "C:/a.png" };
  assert.equal(showsWhatsAppChat(), false);
  State.droppedFile = null;
  State.tasks.push({ ...pill(), id: "integration_github" });
  State.focusId = "integration_github";
  assert.equal(showsWhatsAppChat(), false);
});

test("the big chat: a click opens a chat with its history, older pages on scrolling up, Escape back", async () => {
  const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
  const pages = {
    latest: [msg({ id: "h2", date: NOW - 90_000, text: "older" }), msg({ id: "m1" })],
    before: [msg({ id: "h1", date: NOW - 900_000, text: "oldest" })],
  };
  const history = [];
  const plain = internals.invoke;
  internals.invoke = async (cmd, args) => {
    const result = await plain(cmd, args);
    if (cmd === "whatsapp_chats") return [{ id: "1203@g.us", name: "Famille", isGroup: true, lastActivity: NOW - 3_600_000, archived: false }];
    if (cmd === "whatsapp_history") {
      history.push(args);
      return args.before == null ? pages.latest : pages.before;
    }
    return result;
  };
  try {
    const calls = { settings: 0, hold: [], back: 0 };
    const chat = buildWhatsAppChat({
      openSettings: () => calls.settings++,
      holdOpen: (on) => calls.hold.push(on),
      back: () => calls.back++,
    });
    WhatsApp.view = connected({ unread: 1, conversations: [conversation()] });
    State.mode = "expanded";
    State.view = "prompt";
    State.focusId = WHATSAPP_ID;
    const opens = sent("whatsapp_open").length;
    chat.sync();
    await flush();
    let rows = chat.el.find(".wa-chat-row");
    assert.equal(rows.length, 2, "Marie from the inbox, Famille from the gateway");
    assert.match(rows[1].textContent, /Famille/);
    assert.equal(sent("whatsapp_open").length, opens, "nothing opens on its own (a read receipt may go)");
    assert.match(chat.el.textContent, /Choose a conversation/);

    rows[0].fire("click");
    await flush();
    assert.deepEqual(sent("whatsapp_open").slice(opens), [{ chat: "33612345678@s.whatsapp.net" }]);
    assert.deepEqual(history[0], { chat: "33612345678@s.whatsapp.net", before: null });
    assert.deepEqual(chat.el.find(".wa-text").map((b) => b.textContent), ["older", "Hello"]);
    assert.ok(chat.el.find(".wa-chat-row")[0].classList.contains("on"));

    // Scrolled to the top: the page before the oldest shown, until nothing new comes.
    const scroller = chat.el.find(".wa-messages")[0];
    scroller.fire("scroll");
    await flush();
    assert.deepEqual(history[1], { chat: "33612345678@s.whatsapp.net", before: NOW - 90_000 });
    assert.deepEqual(chat.el.find(".wa-text").map((b) => b.textContent), ["oldest", "older", "Hello"]);
    scroller.fire("scroll");
    await flush();
    scroller.fire("scroll");
    await flush();
    assert.equal(history.length, 3, "the whole history is there: no more asking");

    // Sent on Enter only; Escape goes back to the card.
    const field = chat.el.find("TEXTAREA")[0];
    field.value = "On arrive";
    for (const fn of field.listeners.get("input")) fn({});
    assert.deepEqual(calls.hold, [true]);
    const sends = sent("whatsapp_send").length;
    key(field, "Enter", true);
    assert.equal(sent("whatsapp_send").length, sends);
    key(field, "Enter");
    await flush();
    assert.deepEqual(sent("whatsapp_send").slice(sends), [{ chat: "33612345678@s.whatsapp.net", text: "On arrive" }]);
    const esc = key(chat.el, "Escape");
    assert.equal(esc.propagationStopped, true);
    assert.equal(calls.back, 1);

    // Another chat: the first one closes; leaving the chat view closes the second.
    chat.el.find(".wa-chat-row")[1].fire("click");
    assert.deepEqual(sent("whatsapp_close").at(-1), { chat: "33612345678@s.whatsapp.net" });
    assert.deepEqual(sent("whatsapp_open").at(-1), { chat: "1203@g.us" });
    State.view = "overview";
    State.notify();
    assert.deepEqual(sent("whatsapp_close").at(-1), { chat: "1203@g.us" });
    assert.equal(calls.hold.at(-1), false);
  } finally {
    internals.invoke = plain;
  }
});

test("the big chat: archived chats apart, photos shown, forwards and files sent only on a click", async () => {
  const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
  const plain = internals.invoke;
  internals.invoke = async (cmd, args) => {
    const result = await plain(cmd, args);
    if (cmd === "whatsapp_chats") {
      return [
        { id: "1203@g.us", name: "Famille", isGroup: true, lastActivity: NOW - 3_600_000, archived: false },
        { id: "336999@s.whatsapp.net", name: "Paul", isGroup: false, lastActivity: NOW - 7_200_000, archived: true },
      ];
    }
    if (cmd === "whatsapp_history") return [];
    if (cmd === "whatsapp_media") return new Uint8Array([0xff, 0xd8, 0xff]).buffer;
    if (cmd === "whatsapp_forward" || cmd === "whatsapp_send_file") return true;
    return result;
  };
  try {
    const calls = { back: 0 };
    const chat = buildWhatsAppChat({ openSettings() {}, holdOpen() {}, back: () => calls.back++ });
    WhatsApp.view = connected({
      conversations: [conversation({ unread: 0, messages: [
        msg({ id: "m1", date: NOW - 90_000, text: "hello" }),
        msg({ id: "p1", date: NOW - 80_000, text: "look", media: { kind: "image" } }),
        msg({ id: "f1", date: NOW - 70_000, text: "a joke", forwarded: true }),
      ] })],
    });
    State.mode = "expanded";
    State.view = "prompt";
    State.focusId = WHATSAPP_ID;
    chat.sync();
    await flush();

    // Archived on the phone: one row at the top, the chats behind it.
    let rows = chat.el.find(".wa-chat-row");
    assert.match(rows[0].textContent, /Archived.*1/);
    assert.deepEqual(rows.slice(1).map((r) => r.find(".wa-row-name")[0].textContent), ["Marie", "Famille"]);
    rows[0].fire("click");
    assert.deepEqual(chat.el.find(".wa-chat-row").map((r) => r.find(".wa-row-name")[0].textContent), ["Paul"]);
    chat.el.find(".wa-back")[0].fire("click");
    rows = chat.el.find(".wa-chat-row");
    assert.equal(rows.length, 3);

    // A photo comes through the gateway, in memory; "Forwarded" is said.
    rows[1].fire("click");
    await flush();
    assert.deepEqual(sent("whatsapp_media").at(-1), { chat: "33612345678@s.whatsapp.net", id: "p1" });
    assert.match(chat.el.find(".wa-thumb-img")[0].getAttribute("src"), /^blob:/);
    assert.deepEqual(chat.el.find(".wa-forwarded").map((f) => f.textContent), ["Forwarded"]);
    chat.el.find(".wa-thumb")[0].fire("click");
    await flush();
    const viewer = chat.el.find(".wa-viewer")[0];
    assert.ok(viewer.classList.contains("on"), "full size over the panel");
    key(chat.el, "Escape");
    assert.ok(!viewer.classList.contains("on"));
    assert.equal(calls.back, 0, "Escape closed the photo, not the chat");

    // Forward: the message, the chat, then the click that sends it.
    const forwards = sent("whatsapp_forward").length;
    chat.el.find(".wa-fwd")[0].fire("click");
    assert.match(chat.el.find(".wa-forward-text")[0].textContent, /Pick the chat to forward to/);
    chat.el.find(".wa-chat-row")[2].fire("click");
    assert.equal(chat.el.find(".wa-forward-send")[0].textContent, "Forward to Famille");
    assert.equal(sent("whatsapp_forward").length, forwards, "picking the chat sends nothing");
    chat.el.find(".wa-forward-send")[0].fire("click");
    await flush();
    assert.deepEqual(sent("whatsapp_forward").slice(forwards), [{ from: "33612345678@s.whatsapp.net", id: "m1", to: "1203@g.us" }]);
    assert.equal(chat.el.find(".wa-note")[0].textContent, "Forwarded to Famille");
    chat.el.find(".wa-fwd")[0].fire("click");
    key(chat.el, "Escape");
    assert.equal(chat.el.find(".wa-forward")[0].style.display, "none", "Escape drops the forward");
    assert.equal(calls.back, 0);

    // A dropped photo waits for Enter, the field as its caption.
    const files = sent("whatsapp_send_file").length;
    whatsAppDropTarget()("C:/Pictures/beach.jpg");
    assert.equal(chat.el.find(".wa-attached-name")[0].textContent, "beach.jpg");
    assert.equal(sent("whatsapp_send_file").length, files);
    const field = chat.el.find("TEXTAREA")[0];
    field.value = "the sea";
    key(field, "Enter");
    await flush();
    assert.deepEqual(sent("whatsapp_send_file").slice(files), [{ chat: "33612345678@s.whatsapp.net", path: "C:/Pictures/beach.jpg", caption: "the sea" }]);
    assert.equal(chat.el.find(".wa-attached")[0].style.display, "none");

    // Leaving: nothing more is taken from a drop.
    State.view = "overview";
    State.notify();
    assert.equal(whatsAppDropTarget(), null);
  } finally {
    internals.invoke = plain;
  }
});
