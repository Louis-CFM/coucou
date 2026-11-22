import test, { beforeEach } from "node:test";
import assert from "node:assert/strict";
import {
  getActiveCall,
  subscribeActiveCall,
  setActiveCall,
  acceptCall,
  declineCall,
  dismissCall,
  formatMMSS,
} from "../src/components/islandcn/call-adapter.ts";
import { isCallNotification, initials } from "../src/core/whatsapp.ts";
import {
  getActiveTransfer,
  subscribeActiveTransfer,
  nearbyTransferManager,
  simulateTransfer,
} from "../src/components/islandcn/transfer-adapter.ts";
import { BatteryMonitor } from "../src/islandcn/battery-monitor.ts";
import { calls, emit, internals, sent } from "./tauri.mjs";
import { installFakeDom } from "./fakedom.mjs";

installFakeDom();

const originalInvoke = internals.invoke;
internals.invoke = async (cmd, args) => {
  if (cmd === "whatsapp_accept_call" || cmd === "whatsapp_decline_call") {
    calls.push([cmd, args]);
    return true;
  }
  return originalInvoke(cmd, args);
};

beforeEach(() => {
  dismissCall();
  calls.length = 0;
});

// ── TEST 1: Known contact with available profile image ──────────────────────
test("TEST 1: incoming call from known contact with available profile image", () => {
  let callUpdate = null;
  const unsubscribe = subscribeActiveCall((c) => {
    callUpdate = c;
  });

  setActiveCall({
    id: "call_001",
    caller: "Sophie Germain",
    subtitle: "Incoming WhatsApp call",
    avatar: "https://example.com/avatar.jpg",
    state: "ringing",
    timestamp: Date.now(),
  });

  assert.ok(callUpdate);
  assert.equal(callUpdate.id, "call_001");
  assert.equal(callUpdate.caller, "Sophie Germain");
  assert.equal(callUpdate.subtitle, "Incoming WhatsApp call");
  assert.equal(callUpdate.avatar, "https://example.com/avatar.jpg");
  assert.equal(callUpdate.state, "ringing");

  unsubscribe();
});

// ── TEST 2: Contact without profile image (Initials Fallback) ───────────────
test("TEST 2: incoming call from contact without profile image", () => {
  setActiveCall({
    id: "call_002",
    caller: "Alan Turing",
    subtitle: "Incoming WhatsApp call",
    state: "ringing",
    timestamp: Date.now(),
  });

  const current = getActiveCall();
  assert.ok(current);
  assert.equal(current.caller, "Alan Turing");
  assert.equal(current.avatar, undefined);
  assert.equal(initials(current.caller), "AT");
});

// ── TEST 3: Unknown caller (phone number or missing name) ───────────────────
test("TEST 3: incoming call from unknown caller", () => {
  setActiveCall({
    id: "call_003",
    caller: "+33612345678",
    subtitle: "Incoming WhatsApp call",
    state: "ringing",
    timestamp: Date.now(),
  });

  const current = getActiveCall();
  assert.ok(current);
  assert.equal(current.caller, "+33612345678");
  // Digits only produces clean fallback "#"
  assert.equal(initials(current.caller), "#");
});

// ── TEST 4: Accept a real incoming call ─────────────────────────────────────
test("TEST 4: accept real incoming call transitions to active with timer", async () => {
  setActiveCall({
    id: "call_004",
    caller: "Marie Curie",
    subtitle: "Incoming WhatsApp call",
    state: "ringing",
    timestamp: Date.now(),
  });

  const accepted = await acceptCall("call_004");
  assert.equal(accepted, true);

  const current = getActiveCall();
  assert.ok(current);
  assert.equal(current.state, "active");
  assert.ok(typeof current.since === "number" && current.since > 0);

  // Verifies that Tauri command whatsapp_accept_call was invoked with call ID
  const ipcCall = calls.find(([cmd]) => cmd === "whatsapp_accept_call");
  assert.ok(ipcCall, "whatsapp_accept_call command must be invoked");
  assert.equal(ipcCall[1].callId, "call_004");
});

// ── TEST 5: Decline a real incoming call ────────────────────────────────────
test("TEST 5: decline real incoming call transitions to ended and clears", async () => {
  setActiveCall({
    id: "call_005",
    caller: "Paul Dirac",
    subtitle: "Incoming WhatsApp call",
    state: "ringing",
    timestamp: Date.now(),
  });

  const declined = await declineCall("call_005");
  assert.equal(declined, true);

  const current = getActiveCall();
  assert.ok(current);
  assert.equal(current.state, "ended");

  // Verifies that Tauri command whatsapp_decline_call was invoked
  const ipcCall = calls.find(([cmd]) => cmd === "whatsapp_decline_call");
  assert.ok(ipcCall, "whatsapp_decline_call command must be invoked");
  assert.equal(ipcCall[1].callId, "call_005");
});

// ── TEST 6: Call ends normally ──────────────────────────────────────────────
test("TEST 6: call ends normally clears the active call", () => {
  setActiveCall({
    id: "call_006",
    caller: "Ada Lovelace",
    subtitle: "Incoming WhatsApp call",
    state: "ringing",
    timestamp: Date.now(),
  });

  assert.ok(getActiveCall());
  setActiveCall({
    id: "call_006",
    caller: "Ada Lovelace",
    subtitle: "WhatsApp call",
    state: "ended",
    timestamp: Date.now(),
  });

  assert.equal(getActiveCall()?.state, "ended");
});

// ── TEST 7: Missed call handling ────────────────────────────────────────────
test("TEST 7: missed call state transition", () => {
  setActiveCall({
    id: "call_007",
    caller: "Grace Hopper",
    subtitle: "Incoming WhatsApp call",
    state: "ringing",
    timestamp: Date.now(),
  });

  setActiveCall({
    id: "call_007",
    caller: "Grace Hopper",
    subtitle: "Missed Call",
    state: "missed",
    timestamp: Date.now(),
  });

  assert.equal(getActiveCall()?.state, "missed");
});

// ── TEST 8: Duplicate call event protection ─────────────────────────────────
test("TEST 8: duplicate call events are ignored safely", () => {
  let notifyCount = 0;
  const unsubscribe = subscribeActiveCall(() => {
    notifyCount++;
  });

  const payload = {
    id: "call_008",
    caller: "Linus Torvalds",
    subtitle: "Incoming WhatsApp call",
    state: "ringing",
    timestamp: 1_000_000,
  };

  setActiveCall(payload);
  assert.equal(notifyCount, 2); // Initial subscription (null) + first set

  // Re-sending exact same call ID and state
  setActiveCall(payload);
  assert.equal(notifyCount, 2, "Duplicate event must not trigger redundant listener dispatch");

  unsubscribe();
});

// ── TEST 9: Disconnect recovery ─────────────────────────────────────────────
test("TEST 9: disconnect recovery clears call activity cleanly", () => {
  setActiveCall({
    id: "call_009",
    caller: "Richard Feynman",
    subtitle: "Incoming WhatsApp call",
    state: "ringing",
    timestamp: Date.now(),
  });

  assert.ok(getActiveCall());
  dismissCall();
  assert.equal(getActiveCall(), null, "dismissCall must immediately nullify active call");
});

// ── TEST 10: File transfer active when call arrives ─────────────────────────
test("TEST 10: file transfer remains intact when incoming call arrives", () => {
  // 1. Start a transfer
  simulateTransfer({
    id: "transfer_100",
    direction: "send",
    deviceName: "Pixel 9",
    itemName: "archive.zip",
    totalBytes: 10_000_000,
    bytesTransferred: 5_000_000,
    progress: 0.5,
    status: "in_progress",
  });

  const activeTransferBefore = getActiveTransfer();
  assert.ok(activeTransferBefore);
  assert.equal(activeTransferBefore.progress, 0.5);

  // 2. Incoming call arrives
  setActiveCall({
    id: "call_010",
    caller: "Katherine Johnson",
    subtitle: "Incoming WhatsApp call",
    state: "ringing",
    timestamp: Date.now(),
  });

  // Call is active
  assert.equal(getActiveCall()?.id, "call_010");

  // Transfer is still intact and maintaining progress
  const activeTransferDuring = getActiveTransfer();
  assert.ok(activeTransferDuring);
  assert.equal(activeTransferDuring.progress, 0.5);
  assert.equal(activeTransferDuring.bytesTransferred, 5_000_000);

  // 3. Call ends
  dismissCall();
  assert.equal(getActiveCall(), null);

  // Transfer is still intact!
  const activeTransferAfter = getActiveTransfer();
  assert.ok(activeTransferAfter);
  assert.equal(activeTransferAfter.progress, 0.5);

  nearbyTransferManager.clear();
});

// ── TEST 11: Battery monitoring operates during call ────────────────────────
test("TEST 11: battery monitor remains functional during call activity", () => {
  let batteryUpdates = 0;
  const unsubBattery = BatteryMonitor.subscribe(() => {
    batteryUpdates++;
  });

  setActiveCall({
    id: "call_011",
    caller: "Emmy Noether",
    subtitle: "Incoming WhatsApp call",
    state: "ringing",
    timestamp: Date.now(),
  });

  assert.ok(getActiveCall());
  assert.ok(batteryUpdates >= 1, "Battery monitor must continue reporting state");

  unsubBattery();
});

// ── TEST 12: isCallNotification classification ──────────────────────────────
test("TEST 12: isCallNotification discriminates calls from chat messages", () => {
  // Real WhatsApp call toasts & window subtitles (from screenshot)
  assert.equal(isCallNotification("WhatsApp", "Yeshu Kutty 🫂🤍", "Voice call"), true);
  assert.equal(isCallNotification("WhatsApp", "Yeshu Kutty 🫂🤍", "Video call"), true);
  assert.equal(isCallNotification("WhatsApp", "John Doe", "Incoming voice call"), true);
  assert.equal(isCallNotification("WhatsApp", "Alice", "Incoming video call"), true);
  assert.equal(isCallNotification("WhatsApp", "Bob", "Incoming call"), true);
  assert.equal(isCallNotification("WhatsApp", "Claire", "Appel vocal entrant"), true);
  assert.equal(isCallNotification("WhatsApp", "Diego", "Llamada entrante"), true);

  // Ordinary WhatsApp chat messages
  assert.equal(isCallNotification("WhatsApp", "John Doe", "Hey, call me later"), false);
  assert.equal(isCallNotification("WhatsApp", "Alice", "Here is the document"), false);
  assert.equal(isCallNotification("WhatsApp", "Group Chat", "Meeting tomorrow at 10"), false);

  // Non-WhatsApp apps
  assert.equal(isCallNotification("Telegram", "Bob", "Incoming voice call"), false);
  assert.equal(isCallNotification("Discord", "Claire", "Calling..."), false);
});

// ── TEST 13: Native window-detected call with Accept and Decline ───────────
test("TEST 13: native window-detected call with Accept and Decline", async () => {
  setActiveCall({
    id: "win_21064",
    caller: "Yeshu Kutty 🫂🤍",
    subtitle: "Voice call",
    state: "ringing",
    timestamp: Date.now(),
  });

  const current = getActiveCall();
  assert.ok(current);
  assert.equal(current.id, "win_21064");
  assert.equal(current.caller, "Yeshu Kutty 🫂🤍");
  assert.equal(current.subtitle, "Voice call");

  const accepted = await acceptCall("win_21064");
  assert.equal(accepted, true);

  const active = getActiveCall();
  assert.ok(active);
  assert.equal(active.state, "active");

  const ipcCall = calls.find(([cmd]) => cmd === "whatsapp_accept_call");
  assert.ok(ipcCall);
  assert.equal(ipcCall[1].callId, "win_21064");

  const declined = await declineCall("win_21064");
  assert.equal(declined, true);
  assert.equal(getActiveCall()?.state, "ended");
});

// ── TEST 14: formatMMSS live call duration formatting ─────────────────────
test("TEST 14: formatMMSS formats live call duration with 2-digit minutes", () => {
  assert.equal(formatMMSS(0), "00:00");
  assert.equal(formatMMSS(5_000), "00:05");
  assert.equal(formatMMSS(42_000), "00:42");
  assert.equal(formatMMSS(310_000), "05:10");
  assert.equal(formatMMSS(599_000), "09:59");
  assert.equal(formatMMSS(600_000), "10:00");
  assert.equal(formatMMSS(3_600_000 + 120_000 + 45_000), "1:02:45");
});

// ── TEST 15: Call termination cleanup timing (250ms dismiss timer) ────────
test("TEST 15: call termination dismiss timer clears activeCall within 300ms", async () => {
  setActiveCall({
    id: "call_cleanup_001",
    caller: "Ada Lovelace",
    subtitle: "Incoming WhatsApp call",
    state: "ringing",
    timestamp: Date.now(),
  });

  assert.ok(getActiveCall());
  setActiveCall({
    id: "call_cleanup_001",
    caller: "Ada Lovelace",
    subtitle: "Incoming WhatsApp call",
    state: "ended",
    timestamp: Date.now(),
  });

  assert.equal(getActiveCall()?.state, "ended");

  // Wait 300ms (exceeding 250ms DISMISS_DELAY_MS)
  await new Promise((r) => setTimeout(r, 300));
  assert.equal(getActiveCall(), null, "activeCall must be cleanly dismissed to null");
});

// ── TEST 16: Consecutive calls cleanly reset without ghost state ──────────
test("TEST 16: consecutive calls cleanly transition through ended to new call", async () => {
  setActiveCall({
    id: "call_seq_1",
    caller: "First Caller",
    subtitle: "Incoming WhatsApp call",
    state: "ringing",
    timestamp: Date.now(),
  });

  await declineCall("call_seq_1");
  assert.equal(getActiveCall()?.state, "ended");

  // New call arrives
  setActiveCall({
    id: "call_seq_2",
    caller: "Second Caller",
    subtitle: "Incoming WhatsApp call",
    state: "ringing",
    timestamp: Date.now(),
  });

  const current = getActiveCall();
  assert.ok(current);
  assert.equal(current.id, "call_seq_2");
  assert.equal(current.caller, "Second Caller");
  assert.equal(current.state, "ringing");
});
