// ── IslandCN WhatsApp Call Activity Adapter ──────────────────────────────────
// Bridges real-time incoming WhatsApp calls to Coucou Dynamic Island.

import { Bridge } from "../../core/bridge";
import { State } from "../../core/state";

export type CallLifecycleState = "ringing" | "accepting" | "active" | "declining" | "ended" | "missed";

export interface ActiveCall {
  id: string;
  caller: string;
  subtitle: string;
  avatar?: string;
  state: CallLifecycleState;
  /** Unix timestamp in ms when the call was answered. */
  since?: number;
  /** Arrival timestamp. */
  timestamp: number;
}

type CallListener = (call: ActiveCall | null) => void;

let activeCall: ActiveCall | null = null;
const listeners = new Set<CallListener>();
let ringingTimeoutTimer: number | null = null;
let dismissTimer: number | null = null;

const RINGING_TIMEOUT_MS = 60_000;
const DISMISS_DELAY_MS = 250;

/** "00:42" with two-digit minutes, "1:02:09" from an hour on. Standard macOS call format. */
export const formatMMSS = (ms: number): string => {
  const total = Math.max(0, Math.floor(ms / 1000));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const mm = String(minutes).padStart(2, "0");
  const ss = String(seconds).padStart(2, "0");
  return hours > 0 ? `${hours}:${mm}:${ss}` : `${mm}:${ss}`;
};

export function getActiveCall(): ActiveCall | null {
  return activeCall;
}

export function subscribeActiveCall(listener: CallListener): () => void {
  listeners.add(listener);
  listener(activeCall);
  return () => {
    listeners.delete(listener);
  };
}

function notify() {
  for (const listener of listeners) {
    try {
      listener(activeCall);
    } catch (err) {
      console.error("[call-adapter] Listener error:", err);
    }
  }
  try {
    State.notify();
  } catch {}
}

export function setActiveCall(call: ActiveCall | null) {
  if (ringingTimeoutTimer != null) {
    window.clearTimeout(ringingTimeoutTimer);
    ringingTimeoutTimer = null;
  }
  if (dismissTimer != null) {
    window.clearTimeout(dismissTimer);
    dismissTimer = null;
  }

  // Deduplication: if identical call ID and state, ignore redundant set
  if (activeCall && call && activeCall.id === call.id && activeCall.state === call.state) {
    return;
  }

  activeCall = call;
  notify();

  if (call && call.state === "ringing") {
    // 60-second safety timeout for unanswered ringing calls
    ringingTimeoutTimer = window.setTimeout(() => {
      if (activeCall && activeCall.id === call.id && activeCall.state === "ringing") {
        activeCall = { ...activeCall, state: "missed" };
        notify();
        dismissTimer = window.setTimeout(() => {
          activeCall = null;
          notify();
        }, DISMISS_DELAY_MS);
      }
    }, RINGING_TIMEOUT_MS);
  } else if (call && (call.state === "ended" || call.state === "missed")) {
    dismissTimer = window.setTimeout(() => {
      if (activeCall && activeCall.id === call.id) {
        activeCall = null;
        notify();
      }
    }, DISMISS_DELAY_MS);
  }
}

export async function acceptCall(callId?: string): Promise<boolean> {
  const current = activeCall;
  const id = callId || current?.id;
  if (!id || !current || current.state === "accepting" || current.state === "active") {
    return false;
  }

  // Prevent duplicate submissions
  activeCall = { ...current, state: "accepting" };
  notify();

  try {
    const success = (await Bridge.whatsappAcceptCall(id)) ?? false;
    if (success) {
      activeCall = {
        ...current,
        state: "active",
        since: Date.now(),
      };
      notify();
      return true;
    } else {
      activeCall = { ...current, state: "ringing" };
      notify();
      return false;
    }
  } catch (err) {
    console.error("[call-adapter] Failed to accept call:", err);
    activeCall = { ...current, state: "ringing" };
    notify();
    return false;
  }
}

export async function declineCall(callId?: string): Promise<boolean> {
  const current = activeCall;
  const id = callId || current?.id;
  if (!id || !current || current.state === "declining" || current.state === "ended") {
    return false;
  }

  activeCall = { ...current, state: "declining" };
  notify();

  try {
    const success = (await Bridge.whatsappDeclineCall(id)) ?? false;
    activeCall = { ...current, state: "ended" };
    notify();

    dismissTimer = window.setTimeout(() => {
      activeCall = null;
      notify();
    }, DISMISS_DELAY_MS);

    return success;
  } catch (err) {
    console.error("[call-adapter] Failed to decline call:", err);
    activeCall = { ...current, state: "ended" };
    notify();
    dismissTimer = window.setTimeout(() => {
      activeCall = null;
      notify();
    }, DISMISS_DELAY_MS);
    return false;
  }
}

export function dismissCall() {
  if (ringingTimeoutTimer != null) {
    window.clearTimeout(ringingTimeoutTimer);
    ringingTimeoutTimer = null;
  }
  if (dismissTimer != null) {
    window.clearTimeout(dismissTimer);
    dismissTimer = null;
  }
  activeCall = null;
  notify();
}
