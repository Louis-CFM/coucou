import test from "node:test";
import assert from "node:assert/strict";
import {
  nearbyTransferWords,
  nearbyTransferManager,
  getActiveTransfer,
  subscribeActiveTransfer,
  cancelTransfer,
  simulateTransfer,
} from "../src/components/islandcn/transfer-adapter";
import { emit, sent } from "./tauri.mjs";

test("nearbyTransferWords produces precise accessible copy for send and receive", () => {
  // 1. Sending in progress
  const sendWords = nearbyTransferWords({
    direction: "send",
    deviceName: "Pixel 9",
    itemName: "photo.jpg",
    progress: 0.456,
  });
  assert.equal(sendWords.action, "Sending photo.jpg");
  assert.equal(sendWords.party, "To Pixel 9");
  assert.equal(sendWords.label, "Sending photo.jpg to Pixel 9, 45 percent");

  // 2. Sending complete (progress = 1.0)
  const sentWords = nearbyTransferWords({
    direction: "send",
    deviceName: "Pixel 9",
    itemName: "photo.jpg",
    progress: 1.0,
  });
  assert.equal(sentWords.action, "Sent photo.jpg");
  assert.equal(sentWords.party, "To Pixel 9");
  assert.equal(sentWords.label, "Sent photo.jpg to Pixel 9");

  // 3. Receiving in progress
  const receiveWords = nearbyTransferWords({
    direction: "receive",
    deviceName: "Galaxy S24",
    itemName: "report.pdf",
    progress: 0.8,
  });
  assert.equal(receiveWords.action, "Receiving report.pdf");
  assert.equal(receiveWords.party, "From Galaxy S24");
  assert.equal(receiveWords.label, "Receiving report.pdf from Galaxy S24, 80 percent");

  // 4. Receiving complete (progress = 1.0)
  const receivedWords = nearbyTransferWords({
    direction: "receive",
    deviceName: "Galaxy S24",
    itemName: "report.pdf",
    progress: 1.0,
  });
  assert.equal(receivedWords.action, "Received report.pdf");
  assert.equal(receivedWords.party, "From Galaxy S24");
  assert.equal(receivedWords.label, "Received report.pdf from Galaxy S24");
});

test("NearbyTransferManager tracks transfer lifecycle and clamps progress accurately", async () => {
  nearbyTransferManager.clear();
  assert.equal(getActiveTransfer(), null);

  let notifiedTransfer = null;
  const unsubscribe = subscribeActiveTransfer((transfer) => {
    notifiedTransfer = transfer;
  });

  // 1. Simulate starting a send transfer
  simulateTransfer({
    id: "tx-1",
    direction: "send",
    deviceName: "RMX5003",
    itemName: "notes.txt",
    totalBytes: 1000,
    bytesTransferred: 250,
    progress: 0.25,
    status: "in_progress",
  });

  assert.ok(notifiedTransfer);
  assert.equal(notifiedTransfer.id, "tx-1");
  assert.equal(notifiedTransfer.direction, "send");
  assert.equal(notifiedTransfer.itemName, "notes.txt");
  assert.equal(notifiedTransfer.progress, 0.25);
  assert.equal(notifiedTransfer.status, "in_progress");

  // 2. Progress update via Tauri event
  emit("coudrop-progress", {
    transferId: "tx-1",
    name: "notes.txt",
    bytesRead: 500,
    totalBytes: 1000,
  });

  assert.equal(notifiedTransfer.bytesTransferred, 500);
  assert.equal(notifiedTransfer.progress, 0.5);

  // 3. Ensure progress during active transfer is clamped below 1.0
  emit("coudrop-progress", {
    transferId: "tx-1",
    name: "notes.txt",
    bytesRead: 1000,
    totalBytes: 1000,
  });
  // During transfer, progress must never be 1.0 until completion event
  assert.equal(notifiedTransfer.progress, 0.99);
  assert.equal(notifiedTransfer.status, "in_progress");

  // 4. Verified completion via coudrop-file-sent sets progress strictly to 1.0
  emit("coudrop-file-sent", {
    name: "notes.txt",
    size: 1000,
  });

  assert.equal(notifiedTransfer.progress, 1.0);
  assert.equal(notifiedTransfer.status, "completed");

  // 5. Test reverse transfer (Android -> Desktop receive)
  emit("coudrop-transfer-started", {
    transferId: "tx-recv-1",
    name: "screenshot.png",
    totalBytes: 2000,
    direction: "receive",
  });

  assert.equal(notifiedTransfer.id, "tx-recv-1");
  assert.equal(notifiedTransfer.direction, "receive");
  assert.equal(notifiedTransfer.itemName, "screenshot.png");
  assert.equal(notifiedTransfer.totalBytes, 2000);
  assert.equal(notifiedTransfer.progress, 0);

  // In-flight progress
  emit("coudrop-progress", {
    transferId: "tx-recv-1",
    name: "screenshot.png",
    bytesRead: 1500,
    totalBytes: 2000,
    direction: "receive",
  });
  assert.equal(notifiedTransfer.bytesTransferred, 1500);
  assert.equal(notifiedTransfer.progress, 0.75);

  // Verified receive completion
  emit("coudrop-file-received", {
    name: "screenshot.png",
    size: 2000,
  });
  assert.equal(notifiedTransfer.progress, 1.0);
  assert.equal(notifiedTransfer.status, "completed");

  // 6. Test cancellation commands
  // Sending cancellation
  simulateTransfer({
    id: "tx-send-cancel",
    direction: "send",
    itemName: "bigfile.zip",
    totalBytes: 50000,
  });
  assert.ok(getActiveTransfer());
  await cancelTransfer("tx-send-cancel");
  assert.equal(getActiveTransfer().status, "cancelled");
  assert.ok(sent("coudrop_cancel_send").length > 0);

  // Receiving cancellation
  simulateTransfer({
    id: "tx-recv-cancel",
    direction: "receive",
    itemName: "incoming.mp4",
    totalBytes: 90000,
  });
  assert.ok(getActiveTransfer());
  await cancelTransfer("tx-recv-cancel");
  assert.equal(getActiveTransfer().status, "cancelled");
  assert.ok(sent("coudrop_cancel").length > 0);

  // 7. Reject / cancel events clear transfer
  simulateTransfer({ id: "tx-reject", itemName: "reject.txt" });
  assert.ok(getActiveTransfer());
  emit("coudrop-reject", {});
  assert.equal(getActiveTransfer().status, "failed");

  unsubscribe();
});

test("Progress calculation is resilient against zero-byte files and undefined totalBytes", () => {
  nearbyTransferManager.clear();
  let latest = null;
  const unsubscribe = subscribeActiveTransfer((transfer) => {
    latest = transfer;
  });

  // 1. Zero-byte start
  emit("coudrop-transfer-started", {
    transferId: "zero-byte-tx",
    name: "empty.txt",
    totalBytes: 0,
    direction: "send",
  });
  assert.equal(latest.totalBytes, 0);
  assert.equal(latest.progress, 0);
  assert.equal(Number.isFinite(latest.progress), true);

  // 2. Zero-byte progress
  emit("coudrop-progress", {
    transferId: "zero-byte-tx",
    name: "empty.txt",
    bytesRead: 0,
    totalBytes: 0,
  });
  assert.equal(latest.progress, 0);
  assert.equal(Number.isFinite(latest.progress), true);
  assert.notEqual(Number.isNaN(latest.progress), true);

  // 3. Undefined / null bytes
  emit("coudrop-progress", {
    transferId: "zero-byte-tx",
    name: "empty.txt",
    bytesRead: undefined,
    totalBytes: undefined,
  });
  assert.equal(latest.progress, 0);
  assert.equal(Number.isFinite(latest.progress), true);
  assert.notEqual(Number.isNaN(latest.progress), true);

  unsubscribe();
});

test("Anti-flickering guarantee: progress is strictly monotonic and never flashes to zero", async () => {
  nearbyTransferManager.clear();
  let latest = null;
  const unsubscribe = subscribeActiveTransfer((transfer) => {
    latest = transfer;
  });

  // 1. Start transfer
  emit("coudrop-transfer-started", {
    transferId: "tx-flicker-test",
    name: "video.mp4",
    totalBytes: 10000,
    direction: "send",
  });
  assert.equal(latest.progress, 0);

  // 2. Advance to 50%
  emit("coudrop-progress", {
    transferId: "tx-flicker-test",
    name: "video.mp4",
    bytesRead: 5000,
    totalBytes: 10000,
  });

  // Wait for throttle flush if needed
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(latest.progress, 0.5);
  assert.equal(latest.bytesTransferred, 5000);

  // 3. Simulated malformed or Android ack payload (missing bytesRead / totalBytes)
  // MUST NOT reset progress to 0!
  emit("coudrop-progress", {
    transferId: "tx-flicker-test",
    bytes: undefined,
    bytesRead: undefined,
  });
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(latest.progress, 0.5, "Progress must never reset to 0 from missing bytesRead");

  // 4. Stale/regressive packet (bytesRead: 2000 < 5000)
  // MUST NOT decrease progress!
  emit("coudrop-progress", {
    transferId: "tx-flicker-test",
    bytesRead: 2000,
    totalBytes: 10000,
  });
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(latest.progress, 0.5, "Progress must never regress from stale/lower packets");

  // 5. Zero-reset packet (bytesRead: 0)
  emit("coudrop-progress", {
    transferId: "tx-flicker-test",
    bytesRead: 0,
    totalBytes: 10000,
  });
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(latest.progress, 0.5, "Progress must never reset to 0 from 0-byte packet during active transfer");

  // 6. Repeated metadata refresh / transfer-started for active transfer
  emit("coudrop-transfer-started", {
    transferId: "tx-flicker-test",
    name: "video.mp4",
    totalBytes: 10000,
  });
  assert.equal(latest.progress, 0.5, "Metadata refresh must preserve active progress");

  // 7. Legitimate progress advance (7500 bytes -> 75%)
  emit("coudrop-progress", {
    transferId: "tx-flicker-test",
    bytesRead: 7500,
    totalBytes: 10000,
  });
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(latest.progress, 0.75);

  // 8. Verified completion reached strictly on completion event
  emit("coudrop-file-sent", {
    name: "video.mp4",
    size: 10000,
  });
  assert.equal(latest.progress, 1.0);
  assert.equal(latest.status, "completed");

  unsubscribe();
});
