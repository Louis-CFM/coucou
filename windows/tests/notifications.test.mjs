// Unit tests for Small Notch Notification System (#1055 & Dynamic Island)
// Tests NotchNotificationQueue, burst grouping, auto-dismiss, summary/detailed modes, and app colors.

import { test } from "node:test";
import assert from "node:assert/strict";
import { NotchNotificationQueue } from "../src/core/notifications.ts";

test("NotchNotificationQueue pushes and formats single notification", () => {
  const queue = NotchNotificationQueue.shared;
  queue.clear();
  queue.push({ app: "WhatsApp", title: "Alice", body: "Hello Coucou!" });

  const active = queue.active();
  assert.ok(active);
  assert.equal(active.app, "WhatsApp");
  assert.equal(active.text, "WhatsApp · 1 msg");
  assert.equal(active.color, "#25D366");
  assert.equal(active.count, 1);
});

test("NotchNotificationQueue burst grouping increments count for repeated messages", () => {
  const queue = NotchNotificationQueue.shared;
  queue.clear();
  queue.push({ app: "WhatsApp", title: "Alice", body: "Msg 1" });
  queue.push({ app: "WhatsApp", title: "Alice", body: "Msg 2" });
  queue.push({ app: "WhatsApp", title: "Alice", body: "Msg 3" });

  const active = queue.active();
  assert.ok(active);
  assert.equal(active.app, "WhatsApp");
  assert.equal(active.text, "WhatsApp · 3 msgs");
  assert.equal(active.count, 3);
});

test("NotchNotificationQueue detailed preview mode formats sender and snippet", () => {
  const queue = NotchNotificationQueue.shared;
  queue.clear();
  queue.previewMode = "detailed";
  queue.push({ app: "Telegram", title: "Bob", body: "Meeting in 5 min" });

  const active = queue.active();
  assert.ok(active);
  assert.equal(active.app, "Telegram");
  assert.equal(active.text, "Telegram · Bob: Meeting in 5 min");
  assert.equal(active.color, "#0088CC");

  // Revert back to summary
  queue.previewMode = "summary";
});

test("NotchNotificationQueue dismiss advances queue to next item", () => {
  const queue = NotchNotificationQueue.shared;
  queue.clear();
  queue.push({ app: "Slack", title: "Dev Team", body: "Build succeeded", color: "#E01E5A" });
  queue.push({ app: "Discord", title: "Gamer", body: "GG" });

  assert.equal(queue.active()?.app, "Slack");
  queue.dismiss();
  assert.equal(queue.active()?.app, "Discord");
  assert.equal(queue.active()?.color, "#5865F2");
  queue.dismiss();
  assert.equal(queue.active(), null);
});

test("NotchNotificationQueue clear removes all items", () => {
  const queue = NotchNotificationQueue.shared;
  queue.clear();
  queue.push({ app: "Mail", title: "Daily Digest" });
  assert.ok(queue.active());
  queue.clear();
  assert.equal(queue.active(), null);
});
