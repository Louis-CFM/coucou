"use client";

import { useEffect, useState } from "react";
import { IslandProvider } from "../../lib/island/index";
import { type ActiveCall, getActiveCall, subscribeActiveCall } from "./call-adapter";
import { CallActivityView } from "./call-activity-view";
import {
  type ActiveNearbyTransfer,
  cancelTransfer,
  getActiveTransfer,
  pauseTransfer,
  resumeTransfer,
  subscribeActiveTransfer,
} from "./transfer-adapter";
import { NearbyTransferActivity } from "./nearby-transfer-activity";
import { NearbyTransferView } from "./nearby-transfer-host";
import { islandAccent } from "./theme";

/**
 * Unified IslandCN Activity Dispatcher for Coucou Dynamic Island.
 *
 * Enforces strict activity priority:
 * 1. WhatsApp Call Activity (Priority 100 — highest attention)
 * 2. Nearby File Transfer Activity (Priority 50 — ongoing data transfer)
 *
 * When no activity is active, returns null and allows the resting notch to show.
 */
export function ActivityDispatcherHost() {
  const [call, setCall] = useState<ActiveCall | null>(() => getActiveCall());
  const [transfer, setTransfer] = useState<ActiveNearbyTransfer | null>(() => getActiveTransfer());

  useEffect(() => {
    const unsubCall = subscribeActiveCall((active) => {
      setCall(active);
    });
    const unsubTransfer = subscribeActiveTransfer((active) => {
      setTransfer(active);
    });
    return () => {
      unsubCall();
      unsubTransfer();
    };
  }, []);

  // ── PRIORITY 1: Active WhatsApp Call (Ringing, Answered, or Exiting) ──────
  if (call) {
    return (
      <IslandProvider>
        <CallActivityView call={call} />
      </IslandProvider>
    );
  }

  // ── PRIORITY 2: Active Nearby File Transfer ────────────────────────────────
  if (transfer) {
    const isDone = transfer.status === "completed" || (typeof transfer.progress === "number" && transfer.progress >= 1);
    const clampedProgress = typeof transfer.progress === "number" && Number.isFinite(transfer.progress)
      ? Math.min(1, Math.max(0, transfer.progress))
      : 0;
    const accent = transfer.status === "paused"
      ? islandAccent.orange
      : isDone
        ? islandAccent.green
        : islandAccent.blue;

    return (
      <IslandProvider>
        <NearbyTransferActivity
          id={transfer.id}
          priority={50}
          direction={transfer.direction}
          deviceName={transfer.deviceName}
          device={transfer.device || "phone"}
          itemName={transfer.itemName}
          progress={isDone ? 1.0 : clampedProgress}
          accent={accent}
          isPaused={transfer.status === "paused"}
          onCancel={() => void cancelTransfer(transfer.id)}
          onPause={() => void pauseTransfer(transfer.id)}
          onResume={() => void resumeTransfer(transfer.id)}
        />
        <NearbyTransferView transfer={transfer} />
      </IslandProvider>
    );
  }

  return null;
}

export default ActivityDispatcherHost;
