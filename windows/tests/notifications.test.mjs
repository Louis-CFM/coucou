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

test("NotchNotificationQueue deduplicates dual ingestion (toast + whatsapp-pill)", () => {
  const queue = NotchNotificationQueue.shared;
  queue.clear();
  // 1. WinRT toast arrives with app, title, and body
  queue.push({ app: "WhatsApp", title: "Alice", body: "Hello from phone" });
  assert.equal(queue.active()?.count, 1);
  assert.equal(queue.active()?.raw.body, "Hello from phone");

  // 2. WhatsApp pill event arrives for same message without body
  queue.push({ app: "WhatsApp", title: "Alice", color: "#25D366" });
  assert.equal(queue.active()?.count, 1, "Count should remain 1 (no double counting)");
  assert.equal(queue.active()?.raw.body, "Hello from phone", "Original body preserved");

  // 3. Reverse order: pill arrives first, then toast
  queue.clear();
  queue.push({ app: "WhatsApp", title: "Bob" });
  assert.equal(queue.active()?.count, 1);
  queue.push({ app: "WhatsApp", title: "Bob", body: "Are you there?" });
  assert.equal(queue.active()?.count, 1, "Count should remain 1");
  assert.equal(queue.active()?.raw.body, "Are you there?", "Body enriched from toast");
});

test("NotchNotification dynamic content handling: icons, short/long titles, and iconless mode", () => {
  const queue = NotchNotificationQueue.shared;
  queue.clear();

  // A. Application icon resolution (e.g. Snipping Tool)
  queue.push({ app: "Snipping Tool", title: "Screenshot", body: "Captured" });
  let active = queue.active();
  assert.ok(active);
  assert.equal(active.app, "Snipping Tool");
  assert.equal(active.text, "Snipping Tool · 1 msg");
  assert.ok(active.icon && active.icon.includes("<svg"), "Snipping Tool has SVG vector icon");

  // B. Short notification title
  queue.clear();
  queue.push({ app: "Mail", title: "Hi" });
  active = queue.active();
  assert.ok(active);
  assert.equal(active.text, "Mail · 1 msg");

  // C. Long notification title in detailed mode
  queue.clear();
  queue.previewMode = "detailed";
  const longBody = "This is a very long notification message that tests ellipsis truncation and zero-shift layout bounds";
  queue.push({ app: "System", title: "Security Alert", body: longBody });
  active = queue.active();
  assert.ok(active);
  assert.ok(active.text.includes(longBody));
  queue.previewMode = "summary";

  // D. Notification without icon explicitly
  queue.clear();
  queue.push({ app: "Terminal", title: "Build done", icon: null });
  active = queue.active();
  assert.ok(active);
  assert.equal(active.icon, null, "Icon explicitly omitted");
  assert.equal(active.text, "Terminal · 1 msg");

  // E. Rapid notification replacement (queue sequencing)
  queue.clear();
  for (let i = 1; i <= 5; i++) {
    queue.push({ app: `App${i}`, title: `Notification ${i}`, icon: null });
  }
  assert.equal(queue.active()?.app, "App1");
  queue.dismiss();
  assert.equal(queue.active()?.app, "App2");
  queue.dismiss();
  assert.equal(queue.active()?.app, "App3");
  queue.clear();
  assert.equal(queue.active(), null);
});
