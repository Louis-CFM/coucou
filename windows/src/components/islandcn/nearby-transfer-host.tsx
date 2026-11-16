"use client";

import React, { useEffect, useState } from "react";
import { IslandProvider } from "../../lib/island/index";
import {
  type ActiveNearbyTransfer,
  cancelTransfer,
  getActiveTransfer,
  nearbyTransferWords,
  subscribeActiveTransfer,
} from "./transfer-adapter";
import { DesktopGlyph, LaptopGlyph, PhoneDeviceGlyph, TabletGlyph, type IslandGlyph } from "./glyphs";
import { SharePicture, ShareRing } from "./media-row";
import { islandAccent } from "./theme";

const deviceGlyphs = {
  phone: PhoneDeviceGlyph,
  tablet: TabletGlyph,
  laptop: LaptopGlyph,
  desktop: DesktopGlyph,
} as const satisfies Record<string, IslandGlyph>;

interface NearbyTransferViewProps {
  transfer: ActiveNearbyTransfer;
}

export const NearbyTransferView = React.memo(function NearbyTransferView({ transfer }: NearbyTransferViewProps) {
  const glyph = deviceGlyphs[transfer.device || "phone"] || PhoneDeviceGlyph;
  const sending = transfer.direction === "send";
  const rawProgress = typeof transfer.progress === "number" && Number.isFinite(transfer.progress) ? transfer.progress : 0;
  const value = Math.min(1, Math.max(0, rawProgress));
  const done = transfer.status === "completed" || value >= 1;
  const cancelled = transfer.status === "cancelled";
  const error = transfer.status === "failed";

  const { action, party } = nearbyTransferWords({
    direction: transfer.direction,
    deviceName: transfer.deviceName,
    itemName: transfer.itemName,
    progress: done ? 1 : value,
  });

  const accent = islandAccent.blue;

  return (
    <div className="nearby-transfer-activity-view">
      <div className="nearby-transfer-lead">
        <SharePicture icon={glyph} accent={accent} size={42} />
      </div>
      <div className="nearby-transfer-body">
        <div className="nearby-transfer-action" title={action}>
          {action}
        </div>
        <div className="nearby-transfer-party" title={party}>
          {party}
        </div>
      </div>
      <div className="nearby-transfer-trail">
        <ShareRing
          value={done ? 1 : value}
          accent={accent}
          size={42}
          mark={cancelled || error ? "none" : !done ? "stop" : "none"}
          onStop={!done ? () => void cancelTransfer(transfer.id) : undefined}
          stopLabel={`Stop ${sending ? "sending to" : "receiving from"} ${transfer.deviceName}`}
        />
      </div>
    </div>
  );
});

/**
 * NearbyTransferHost mounts the IslandCN activity stack for Coucou.
 *
 * Integrated directly inside the existing Coucou Dynamic Island notch.
 * - When there is NO active transfer: returns null (preserves Coucou's resting notch).
 * - When a transfer is active: renders the expanded Nearby Transfer activity
 *   displaying the device icon, action label, party name, and real-time progress ring.
 */
export function NearbyTransferHost() {
  const [transfer, setTransfer] = useState<ActiveNearbyTransfer | null>(() => getActiveTransfer());

  useEffect(() => {
    const unsubscribe = subscribeActiveTransfer((active) => {
      setTransfer(active);
    });
    return unsubscribe;
  }, []);

  useEffect(() => {
    if (transfer) {
      console.debug(`[ACTIVITY_UPDATED] id=${transfer.id}, progress=${transfer.progress}, status=${transfer.status}`);
    } else {
      console.debug("[ACTIVITY_UNMOUNTED] idle");
    }
  }, [transfer?.id, transfer?.progress, transfer?.status]);

  if (!transfer) {
    return null;
  }

  return (
    <IslandProvider>
      <NearbyTransferView transfer={transfer} />
    </IslandProvider>
  );
}

export default NearbyTransferHost;
