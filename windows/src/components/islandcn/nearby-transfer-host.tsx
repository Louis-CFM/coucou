"use client";

import React, { useEffect, useState } from "react";
import { IslandProvider } from "../../lib/island/index";
import { NearbyTransferActivity } from "./nearby-transfer-activity";
import {
  type ActiveNearbyTransfer,
  cancelTransfer,
  dismissTransfer,
  getActiveTransfer,
  nearbyTransferWords,
  pauseTransfer,
  resumeTransfer,
  subscribeActiveTransfer,
} from "./transfer-adapter";
import { DesktopGlyph, LaptopGlyph, PhoneDeviceGlyph, TabletGlyph, type IslandGlyph } from "./glyphs";
import { SharePicture } from "./media-row";
import { islandAccent } from "./theme";

const deviceGlyphs = {
  phone: PhoneDeviceGlyph,
  tablet: TabletGlyph,
  laptop: LaptopGlyph,
  desktop: DesktopGlyph,
} as const satisfies Record<string, IslandGlyph>;

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.floor(Math.log(bytes) / Math.log(1024));
  const val = bytes / Math.pow(1024, i);
  return `${val.toFixed(val >= 10 || i === 0 ? 0 : 1)} ${units[i]}`;
}

function formatSpeed(bytesPerSec?: number): string {
  if (!bytesPerSec || bytesPerSec <= 0) return "";
  return `${formatBytes(bytesPerSec)}/s`;
}

function formatEta(seconds?: number): string {
  if (seconds === undefined || seconds === null || seconds < 1 || !Number.isFinite(seconds)) return "";
  if (seconds < 60) return `${Math.round(seconds)}s left`;
  const mins = Math.floor(seconds / 60);
  const secs = Math.round(seconds % 60);
  if (mins < 60) {
    return secs > 0 ? `${mins}m ${secs}s left` : `${mins}m left`;
  }
  const hours = Math.floor(mins / 60);
  const remMins = mins % 60;
  return remMins > 0 ? `${hours}h ${remMins}m left` : `${hours}h left`;
}

interface NearbyTransferViewProps {
  transfer: ActiveNearbyTransfer;
}

export const NearbyTransferView = React.memo(function NearbyTransferView({ transfer }: NearbyTransferViewProps) {
  const glyph = deviceGlyphs[transfer.device || "phone"] || PhoneDeviceGlyph;
  const sending = transfer.direction === "send";
  const rawProgress = typeof transfer.progress === "number" && Number.isFinite(transfer.progress) ? transfer.progress : 0;
  const value = Math.min(1, Math.max(0, rawProgress));
  const percent = Math.floor(value * 100);
  const done = transfer.status === "completed" || value >= 1;
  const paused = transfer.status === "paused";
  const cancelled = transfer.status === "cancelled";
  const error = transfer.status === "failed";

  const { party } = nearbyTransferWords({
    direction: transfer.direction,
    deviceName: transfer.deviceName,
    itemName: transfer.itemName,
    progress: done ? 1 : value,
    status: transfer.status,
  });

  const accent = paused ? islandAccent.orange : done ? islandAccent.green : islandAccent.blue;
  const speedText = !done && !paused && transfer.speedBytesPerSec ? formatSpeed(transfer.speedBytesPerSec) : "";
  const etaText = !done && !paused && transfer.timeRemainingSeconds ? formatEta(transfer.timeRemainingSeconds) : "";

  // ── 1. Completed State (Single Authoritative Success Presentation) ──────────
  if (done) {
    const successTitle = sending ? "File sent successfully" : "File received successfully";
    return (
      <div className="nearby-transfer-activity-view status-completed">
        {/* Left: Device Glyph in refined green container (single clean device visual, no redundant badge) */}
        <div className="nearby-transfer-lead">
          <div className="nearby-transfer-glyph-container completed">
            <SharePicture icon={glyph} accent={islandAccent.green} size={36} />
          </div>
        </div>

        {/* Center: Clean success title + properly spaced secondary metadata */}
        <div className="nearby-transfer-body completed">
          <div className="nearby-transfer-title" title={successTitle}>
            {successTitle}
          </div>
          <div className="nearby-transfer-subtitle" title={`${transfer.itemName} · ${formatBytes(transfer.totalBytes)} · ${party}`}>
            <span className="nearby-transfer-filename-done">{transfer.itemName}</span>
            <span className="nearby-transfer-divider">·</span>
            <span>{formatBytes(transfer.totalBytes)}</span>
            <span className="nearby-transfer-divider">·</span>
            <span>{party}</span>
          </div>
        </div>

        {/* Right: Clean completion checkmark disc */}
        <div className="nearby-transfer-trail">
          <div className="nearby-transfer-done-icon" title={successTitle} aria-label="Completed">
            <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="#22c55e" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
              <polyline points="20 6 9 17 4 12" />
            </svg>
          </div>
        </div>
      </div>
    );
  }

  // ── 2. Cancelled or Failed State ───────────────────────────────────────────
  if (cancelled || error) {
    const statusTitle = cancelled ? "Transfer cancelled" : "Transfer failed";
    const statusReason = cancelled ? (transfer.errorMessage || "Cancelled by user") : (transfer.errorMessage || "Connection interrupted");
    return (
      <div className={`nearby-transfer-activity-view status-${transfer.status}`}>
        {/* Left: Device Glyph with warning/cancel badge */}
        <div className="nearby-transfer-lead">
          <div className="nearby-transfer-glyph-container stopped">
            <SharePicture icon={glyph} accent={islandAccent.red} size={36} />
            <div className="nearby-transfer-badge badge-stopped" aria-label="Stopped">
              ✕
            </div>
          </div>
        </div>

        {/* Center: Cancelled / Failed messaging */}
        <div className="nearby-transfer-body stopped">
          <div className="nearby-transfer-title" title={statusTitle}>
            {statusTitle}
          </div>
          <div className="nearby-transfer-subtitle" title={`${transfer.itemName} · ${statusReason}`}>
            <span className="nearby-transfer-filename-done">{transfer.itemName}</span>
            <span className="nearby-transfer-divider">·</span>
            <span>{statusReason}</span>
          </div>
        </div>

        {/* Right: Stopped icon (click to dismiss immediately) */}
        <div className="nearby-transfer-trail">
          <div
            className="nearby-transfer-stopped-icon"
            title="Dismiss"
            aria-label="Dismiss"
            onClick={dismissTransfer}
            role="button"
            tabIndex={0}
            style={{ cursor: "pointer" }}
          >
            <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="#ef4444" strokeWidth="2.5" strokeLinecap="round">
              <line x1="18" y1="6" x2="6" y2="18" />
              <line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </div>
        </div>
      </div>
    );
  }

  // ── 3. Active Transfer (Receiving / Sending / Paused) ──────────────────────
  return (
    <div className={`nearby-transfer-activity-view status-${transfer.status}`}>
      {/* Left: Device Glyph with direction or pause badge */}
      <div className="nearby-transfer-lead">
        <div className={`nearby-transfer-glyph-container ${paused ? "paused" : "active"}`}>
          <SharePicture icon={glyph} accent={accent} size={36} />
          <div
            className={`nearby-transfer-badge ${paused ? "badge-paused" : sending ? "badge-up" : "badge-down"}`}
            aria-label={paused ? "Paused" : sending ? "Sending" : "Receiving"}
          >
            {paused ? "⏸" : sending ? "↑" : "↓"}
          </div>
        </div>
      </div>

      {/* Center: Filename, Progress track, and Telemetry row */}
      <div className="nearby-transfer-body">
        <div className="nearby-transfer-header-row">
          <span className="nearby-transfer-filename" title={transfer.itemName}>
            {transfer.itemName}
          </span>
          <span className={`nearby-transfer-status-tag ${paused ? "paused" : ""}`}>
            {paused ? `Paused · ${percent}%` : `${sending ? "Sending" : "Receiving"} · ${percent}%`}
          </span>
        </div>

        {/* Apple-style sleek 4px progress track */}
        <div
          className="nearby-transfer-progress-track"
          role="progressbar"
          aria-valuenow={percent}
          aria-valuemin={0}
          aria-valuemax={100}
        >
          <div
            className={`nearby-transfer-progress-fill ${transfer.status}`}
            style={{ width: `${percent}%` }}
          />
        </div>

        {/* Telemetry row: Party, Bytes, Speed, ETA */}
        <div className="nearby-transfer-metrics-row">
          <span className="nearby-transfer-party-tag">{party}</span>
          <span className="nearby-transfer-divider">·</span>
          <span className="nearby-transfer-bytes">
            {formatBytes(transfer.bytesTransferred)} of {formatBytes(transfer.totalBytes)}
          </span>
          {speedText && !paused && (
            <>
              <span className="nearby-transfer-divider">·</span>
              <span className="nearby-transfer-speed">{speedText}</span>
            </>
          )}
          {etaText && !paused && (
            <>
              <span className="nearby-transfer-divider">·</span>
              <span className="nearby-transfer-eta">{etaText}</span>
            </>
          )}
        </div>
      </div>

      {/* Right: Tactile controls (Pause/Resume + Cancel) */}
      <div className="nearby-transfer-trail">
        <div className="nearby-transfer-controls">
          {paused ? (
            <button
              type="button"
              className="nearby-ctrl-btn resume-btn"
              onClick={(e) => {
                e.stopPropagation();
                void resumeTransfer(transfer.id);
              }}
              title="Resume transfer"
              aria-label="Resume transfer"
            >
              <svg viewBox="0 0 24 24" width="13" height="13" fill="currentColor">
                <polygon points="6 4 20 12 6 20 6 4" />
              </svg>
            </button>
          ) : (
            <button
              type="button"
              className="nearby-ctrl-btn pause-btn"
              onClick={(e) => {
                e.stopPropagation();
                void pauseTransfer(transfer.id);
              }}
              title="Pause transfer"
              aria-label="Pause transfer"
            >
              <svg viewBox="0 0 24 24" width="13" height="13" fill="currentColor">
                <rect x="6" y="5" width="3.5" height="14" rx="1" />
                <rect x="14.5" y="5" width="3.5" height="14" rx="1" />
              </svg>
            </button>
          )}
          <button
            type="button"
            className="nearby-ctrl-btn cancel-btn"
            onClick={(e) => {
              e.stopPropagation();
              void cancelTransfer(transfer.id);
            }}
            title="Cancel transfer"
            aria-label="Cancel transfer"
          >
            <svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round">
              <line x1="18" y1="6" x2="6" y2="18" />
              <line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>
        </div>
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
        priority={100}
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

export default NearbyTransferHost;
