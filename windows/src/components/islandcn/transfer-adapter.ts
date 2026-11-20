// ── IslandCN Nearby Transfer Activity Adapter ─────────────────────────────────
// Bridges Coucou's real-time bidirectional file transfer engine to IslandCN.
// Enforces single source of truth, monotonic progress updates, and zero-flickering UI.

import { Bridge, onEvent } from "../../core/bridge";
import { State } from "../../core/state";

export type NearbyDevice = "phone" | "tablet" | "laptop" | "desktop";
export type TransferDirection = "send" | "receive";
export type TransferStatus = "in_progress" | "paused" | "completed" | "failed" | "cancelled";

export interface NearbyTransferWords {
  /** What a screen reader says. */
  label: string;
  /** The grey line: what happens to what, such as "Sending 3 photos" or "Sent 3 photos". */
  action: string;
  /** The white line: who, such as "To Maya's Laptop". */
  party: string;
}

export interface NearbyTransferWordsOptions {
  direction?: TransferDirection;
  deviceName: string;
  itemName: string;
  progress: number;
  status?: TransferStatus;
}

/**
 * Computes the human-readable action, party, and screen reader labels
 * matching the IslandCN Nearby Transfer Activity.
 */
export const nearbyTransferWords = ({
  direction = "send",
  deviceName,
  itemName,
  progress,
  status = "in_progress",
}: NearbyTransferWordsOptions): NearbyTransferWords => {
  const value = Math.min(1, Math.max(0, Number.isFinite(progress) ? progress : 0));
  const done = status === "completed" || value >= 1;
  const isPaused = status === "paused";
  const isCancelled = status === "cancelled";
  const isFailed = status === "failed";
  const sending = direction === "send";

  let verb = sending ? (done ? "Sent" : "Sending") : done ? "Received" : "Receiving";
  if (isPaused) verb = "Paused";
  else if (isCancelled) verb = "Cancelled";
  else if (isFailed) verb = "Failed";

  return {
    label: `${verb} ${itemName} ${sending ? "to" : "from"} ${deviceName}${done || isPaused ? "" : `, ${Math.floor(value * 100)} percent`}`,
    action: `${verb} ${itemName}`,
    party: `${sending ? "To" : "From"} ${deviceName}`,
  };
};

export interface ActiveNearbyTransfer {
  id: string;
  direction: TransferDirection;
  deviceName: string;
  device: NearbyDevice;
  itemName: string;
  totalBytes: number;
  bytesTransferred: number;
  progress: number; // 0.0 to 0.99 in-flight, strictly 1.0 on verified completion
  status: TransferStatus;
  speedBytesPerSec?: number;
  timeRemainingSeconds?: number;
  isPaused?: boolean;
  cancelOrigin?: "phone" | "desktop" | "system";
  src?: string;
  accent?: string;
  startTime: number;
  lastProgressUpdate?: number;
  errorMessage?: string;
}

export type TransferListener = (transfer: ActiveNearbyTransfer | null) => void;

/** Structured debug logging helper */
function logDebug(tag: string, details: Record<string, unknown>): void {
  const payload = Object.entries(details)
    .map(([k, v]) => `${k}=${typeof v === "object" ? JSON.stringify(v) : v}`)
    .join(" ");
  console.debug(`[${tag}] ${payload}`);
}

class NearbyTransferManager {
  private activeTransfer: ActiveNearbyTransfer | null = null;
  private listeners = new Set<TransferListener>();
  private dismissTimer: number | null = null;
  private throttleTimer: number | null = null;
  private lastNotifyTime = 0;
  private initialized = false;

  constructor() {
    this.init();
  }

  getActiveTransfer(): ActiveNearbyTransfer | null {
    return this.activeTransfer;
  }

  subscribe(listener: TransferListener): () => void {
    this.listeners.add(listener);
    listener(this.activeTransfer);
    return () => this.listeners.delete(listener);
  }

  /** Immediately flushes the latest state to all subscribers without throttling */
  private notifyImmediate(): void {
    if (this.throttleTimer !== null) {
      window.clearTimeout(this.throttleTimer);
      this.throttleTimer = null;
    }
    this.lastNotifyTime = Date.now();
    this.dispatch();
  }

  /**
   * Throttles visual updates to ~20 fps (50ms interval) to prevent React DOM
   * re-render thrashing during rapid 32 KiB chunk arrivals while preserving
   * exact real-time byte counters.
   */
  private notifyThrottled(): void {
    if ((globalThis as any).__COUCOU_TEST__) {
      this.notifyImmediate();
      return;
    }
    const now = Date.now();
    const elapsed = now - this.lastNotifyTime;
    const THROTTLE_INTERVAL_MS = 50; // ~20 fps visual update target

    if (elapsed >= THROTTLE_INTERVAL_MS) {
      this.notifyImmediate();
    } else if (this.throttleTimer === null) {
      this.throttleTimer = window.setTimeout(() => {
        this.throttleTimer = null;
        this.notifyImmediate();
      }, THROTTLE_INTERVAL_MS - elapsed);
    }
  }

  private dispatch(): void {
    for (const listener of this.listeners) {
      try {
        listener(this.activeTransfer);
      } catch (err) {
        console.error("[islandcn-transfer] Listener error:", err);
      }
    }
  }

  private resolveDeviceName(): string {
    return State.coudropConnectedDevice || "Phone";
  }

  private clearDismissTimer(): void {
    if (this.dismissTimer !== null) {
      window.clearTimeout(this.dismissTimer);
      this.dismissTimer = null;
    }
  }

  private mapErrorReason(rawReason: string): string {
    if (!rawReason) return "Connection interrupted";
    if (rawReason.includes("state: 2") || rawReason.includes("IllegalStateException") || rawReason.includes("STATE_OPEN_REQUEST_BODY")) {
      return "Transfer interrupted";
    } else if (rawReason.includes("insufficient_storage")) {
      return "Not enough phone storage";
    } else if (rawReason.includes("checksum_mismatch")) {
      return "File verification failed";
    } else if (rawReason.includes("SocketTimeoutException") || rawReason.toLowerCase().includes("timeout")) {
      return "Transfer timed out (Wi-Fi stalled)";
    } else if (rawReason.includes("ConnectException")) {
      return "Connection refused by phone";
    } else if (rawReason.includes("Cleartext HTTP traffic") || rawReason.includes("not permitted")) {
      return "Cleartext HTTP traffic blocked";
    } else if (rawReason.includes("SocketException") || rawReason.toLowerCase().includes("reset") || rawReason.toLowerCase().includes("abort")) {
      return "Connection reset by network";
    } else if (rawReason.includes("io_error") || rawReason.includes("save_error")) {
      return "Could not save file to disk";
    } else if (rawReason.toLowerCase().includes("rejected")) {
      return "Declined by phone";
    } else if (rawReason.trim().length > 0) {
      return rawReason.replace(/^(download_error|upload_error|network_error):\s*/i, "").slice(0, 60);
    }
    return "Connection interrupted";
  }

  init(): void {
    if (this.initialized) return;
    this.initialized = true;

    // 1. Transfer started (either sending or receiving)
    void onEvent<{
      transferId?: string;
      id?: string;
      name?: string;
      fileName?: string;
      totalBytes?: number;
      total?: number;
      direction?: TransferDirection;
    }>("coudrop-transfer-started", (payload) => {
      this.clearDismissTimer();
      const id = payload.transferId || payload.id || "nearby-transfer";
      const name = payload.name || payload.fileName || "File";
      const total = typeof payload.totalBytes === "number" && Number.isFinite(payload.totalBytes)
        ? payload.totalBytes
        : typeof payload.total === "number" && Number.isFinite(payload.total)
        ? payload.total
        : 0;
      const direction = payload.direction || "send";

      // If this transfer is ALREADY active with progress in flight, do NOT wipe progress!
      if (this.activeTransfer && this.activeTransfer.id === id && this.activeTransfer.status === "in_progress") {
        logDebug("TRANSFER_INITIALIZED", {
          transferId: id,
          action: "preserve_active_progress",
          currentProgress: this.activeTransfer.progress,
          bytesTransferred: this.activeTransfer.bytesTransferred,
        });
        this.activeTransfer = {
          ...this.activeTransfer,
          itemName: name || this.activeTransfer.itemName,
          totalBytes: total > 0 ? total : this.activeTransfer.totalBytes,
          direction: direction || this.activeTransfer.direction,
        };
        this.notifyImmediate();
        return;
      }

      logDebug("TRANSFER_CREATED", {
        transferId: id,
        itemName: name,
        totalBytes: total,
        direction,
        timestamp: Date.now(),
      });

      this.activeTransfer = {
        id,
        direction,
        deviceName: this.resolveDeviceName(),
        device: "phone",
        itemName: name,
        totalBytes: total,
        bytesTransferred: 0,
        progress: 0,
        status: "in_progress",
        startTime: Date.now(),
        lastProgressUpdate: Date.now(),
      };
      this.notifyImmediate();
    });

    // 2. Real-time transfer progress from actual bytes
    void onEvent<{
      transferId?: string;
      id?: string;
      name?: string;
      fileName?: string;
      bytesRead?: number;
      bytesTransferred?: number;
      bytes?: number;
      bytesReceived?: number;
      totalBytes?: number;
      total?: number;
      progress?: number;
      speedBytesPerSec?: number;
      timeRemainingSeconds?: number;
      direction?: TransferDirection;
      isPaused?: boolean;
    }>("coudrop-progress", (prog) => {
      if (!prog) return;

      // Terminal state guard: strictly ignore late progress events if transfer is already terminal
      if (
        this.activeTransfer &&
        (this.activeTransfer.status === "completed" ||
          this.activeTransfer.status === "cancelled" ||
          this.activeTransfer.status === "failed")
      ) {
        return;
      }

      this.clearDismissTimer();

      const incomingId = prog.transferId || prog.id;
      const incomingName = prog.name || prog.fileName;

      // Extract bytes transferred from any supported property alias
      const incomingBytes =
        typeof prog.bytesRead === "number" && Number.isFinite(prog.bytesRead)
          ? prog.bytesRead
          : typeof prog.bytesTransferred === "number" && Number.isFinite(prog.bytesTransferred)
          ? prog.bytesTransferred
          : typeof prog.bytes === "number" && Number.isFinite(prog.bytes)
          ? prog.bytes
          : typeof prog.bytesReceived === "number" && Number.isFinite(prog.bytesReceived)
          ? prog.bytesReceived
          : undefined;

      // Extract total bytes from any supported property alias
      const incomingTotal =
        typeof prog.totalBytes === "number" && Number.isFinite(prog.totalBytes)
          ? prog.totalBytes
          : typeof prog.total === "number" && Number.isFinite(prog.total)
          ? prog.total
          : undefined;

      const currentTransfer = this.activeTransfer;

      // Association check: ignore progress events from stale transfers if an active one is running
      if (currentTransfer && incomingId && incomingId !== currentTransfer.id && currentTransfer.status === "in_progress") {
        logDebug("PROGRESS_STATE_REJECTED", {
          reason: "mismatched_transfer_id",
          activeId: currentTransfer.id,
          incomingId,
        });
        return;
      }

      logDebug("PROGRESS_EVENT_RECEIVED", {
        incomingId: incomingId || currentTransfer?.id,
        incomingBytes,
        incomingTotal,
        rawProgress: prog.progress,
      });

      const currentBytes = currentTransfer?.bytesTransferred ?? 0;
      const currentTotal = currentTransfer?.totalBytes ?? 0;
      const currentProgress = currentTransfer?.progress ?? 0;

      // Resolve totalBytes: use incomingTotal if positive, otherwise keep previous
      const totalBytes = incomingTotal !== undefined && incomingTotal > 0 ? incomingTotal : currentTotal;

      // Monotonic bytes protection: bytesTransferred must never drop backwards
      let bytesTransferred = currentBytes;
      if (incomingBytes !== undefined) {
        if (incomingBytes < currentBytes && currentTransfer?.status === "in_progress") {
          logDebug("PROGRESS_STATE_REJECTED", {
            reason: "regressive_bytes",
            currentBytes,
            incomingBytes,
          });
        } else {
          bytesTransferred = Math.max(currentBytes, incomingBytes);
        }
      }

      // Compute normalized progress [0.0, 0.99] during transfer.
      // Strict rule: 1.0 is exclusively reserved for verified completion events!
      let calcProgress = currentProgress;
      if (totalBytes > 0 && bytesTransferred > 0) {
        const ratio = Math.min(0.99, Math.max(0, bytesTransferred / totalBytes));
        calcProgress = Math.max(currentProgress, ratio);
      } else if (typeof prog.progress === "number" && Number.isFinite(prog.progress) && prog.progress > 0) {
        const ratio = Math.min(0.99, Math.max(0, prog.progress));
        calcProgress = Math.max(currentProgress, ratio);
      }

      // CRUCIAL ANTI-FLICKERING RULE:
      // Never allow progress to drop from a positive value back to 0 during an active transfer
      if (calcProgress === 0 && currentProgress > 0) {
        logDebug("PROGRESS_STATE_REJECTED", {
          reason: "zero_reset_blocked",
          currentProgress,
          attemptedProgress: 0,
        });
        calcProgress = currentProgress;
      }

      const name = incomingName || currentTransfer?.itemName || "File";
      const direction = prog.direction || currentTransfer?.direction || "send";
      const id = incomingId || currentTransfer?.id || "nearby-transfer";

      const speed = typeof prog.speedBytesPerSec === "number" && Number.isFinite(prog.speedBytesPerSec)
        ? prog.speedBytesPerSec
        : undefined;
      const eta = typeof prog.timeRemainingSeconds === "number" && Number.isFinite(prog.timeRemainingSeconds)
        ? prog.timeRemainingSeconds
        : undefined;
      const isPaused = prog.isPaused === true || currentTransfer?.status === "paused";

      // Client-side fallback moving-window speed calculation
      let calculatedSpeed = speed;
      let calculatedEta = eta;
      if (calculatedSpeed === undefined || calculatedSpeed === 0) {
        const now = Date.now();
        const lastTime = currentTransfer?.lastProgressUpdate || currentTransfer?.startTime || now;
        const timeDiff = (now - lastTime) / 1000;
        if (timeDiff >= 0.3) {
          const byteDiff = bytesTransferred - (currentTransfer?.bytesTransferred || 0);
          if (byteDiff > 0) {
            calculatedSpeed = Math.round(byteDiff / timeDiff);
            const remainingBytes = totalBytes - bytesTransferred;
            if (calculatedSpeed > 0 && remainingBytes > 0) {
              calculatedEta = Math.round(remainingBytes / calculatedSpeed);
            }
          }
        }
      }

      const status: TransferStatus = isPaused ? "paused" : "in_progress";

      logDebug("PROGRESS_STATE_UPDATED", {
        transferId: id,
        previousProgress: currentProgress,
        newProgress: calcProgress,
        bytesTransferred,
        totalBytes,
        speed: calculatedSpeed,
        eta: calculatedEta,
        isPaused,
      });

      this.activeTransfer = {
        id,
        direction,
        deviceName: this.resolveDeviceName(),
        device: "phone",
        itemName: name,
        totalBytes,
        bytesTransferred,
        progress: calcProgress,
        status,
        speedBytesPerSec: calculatedSpeed ?? currentTransfer?.speedBytesPerSec,
        timeRemainingSeconds: calculatedEta ?? currentTransfer?.timeRemainingSeconds,
        isPaused,
        startTime: currentTransfer?.startTime || Date.now(),
        lastProgressUpdate: Date.now(),
      };

      // Snappy first update: if previous progress was 0, notify immediately
      if (currentProgress === 0) {
        this.notifyImmediate();
      } else {
        this.notifyThrottled();
      }
    });

    // 2b. Transfer paused
    void onEvent<{ transferId?: string }>("coudrop-transfer-paused", (payload) => {
      this.clearDismissTimer();
      if (this.activeTransfer) {
        logDebug("TRANSFER_PAUSED", { transferId: payload?.transferId || this.activeTransfer.id });
        this.activeTransfer = {
          ...this.activeTransfer,
          status: "paused",
          isPaused: true,
          speedBytesPerSec: 0,
        };
        this.notifyImmediate();
      }
    });

    // 2c. Transfer resumed
    void onEvent<{ transferId?: string }>("coudrop-transfer-resumed", (payload) => {
      this.clearDismissTimer();
      if (this.activeTransfer) {
        logDebug("TRANSFER_RESUMED", { transferId: payload?.transferId || this.activeTransfer.id });
        this.activeTransfer = {
          ...this.activeTransfer,
          status: "in_progress",
          isPaused: false,
          lastProgressUpdate: Date.now(),
        };
        this.notifyImmediate();
      }
    });

    // 3. Desktop -> Android: Verified completion
    void onEvent<{ name: string; path?: string; size: number }>("coudrop-file-sent", (file) => {
      this.clearDismissTimer();
      const size = typeof file.size === "number" && Number.isFinite(file.size) ? file.size : 0;
      const prevProgress = this.activeTransfer?.progress ?? 0;

      logDebug("TRANSFER_COMPLETED", {
        transferId: this.activeTransfer?.id,
        direction: "send",
        name: file.name,
        size,
        previousProgress: prevProgress,
        finalProgress: 1.0,
      });

      this.activeTransfer = {
        id: this.activeTransfer?.id || "nearby-transfer",
        direction: "send",
        deviceName: this.resolveDeviceName(),
        device: "phone",
        itemName: file.name,
        totalBytes: size > 0 ? size : (this.activeTransfer?.totalBytes || 0),
        bytesTransferred: size > 0 ? size : (this.activeTransfer?.bytesTransferred || 0),
        progress: 1.0, // Signals 100% verified completion check
        status: "completed",
        startTime: this.activeTransfer?.startTime || Date.now(),
        lastProgressUpdate: Date.now(),
      };
      this.notifyImmediate();

      // Gracefully settle and dismiss after 3.5 seconds
      this.dismissTimer = window.setTimeout(() => {
        logDebug("ACTIVITY_UNMOUNTED", { transferId: this.activeTransfer?.id, reason: "completion_dismiss" });
        this.activeTransfer = null;
        this.notifyImmediate();
      }, 3500);
    });

    // 4. Android -> Desktop: Verified completion
    void onEvent<{ name: string; path?: string; size: number }>("coudrop-file-received", (file) => {
      this.clearDismissTimer();
      const size = typeof file.size === "number" && Number.isFinite(file.size) ? file.size : 0;
      const prevProgress = this.activeTransfer?.progress ?? 0;

      logDebug("TRANSFER_COMPLETED", {
        transferId: this.activeTransfer?.id,
        direction: "receive",
        name: file.name,
        size,
        previousProgress: prevProgress,
        finalProgress: 1.0,
      });

      this.activeTransfer = {
        id: this.activeTransfer?.id || "nearby-transfer",
        direction: "receive",
        deviceName: this.resolveDeviceName(),
        device: "phone",
        itemName: file.name,
        totalBytes: size > 0 ? size : (this.activeTransfer?.totalBytes || 0),
        bytesTransferred: size > 0 ? size : (this.activeTransfer?.bytesTransferred || 0),
        progress: 1.0, // Signals 100% verified completion check
        status: "completed",
        startTime: this.activeTransfer?.startTime || Date.now(),
        lastProgressUpdate: Date.now(),
      };
      this.notifyImmediate();

      // Gracefully settle and dismiss after 3.5 seconds
      this.dismissTimer = window.setTimeout(() => {
        logDebug("ACTIVITY_UNMOUNTED", { transferId: this.activeTransfer?.id, reason: "completion_dismiss" });
        this.activeTransfer = null;
        this.notifyImmediate();
      }, 3500);
    });

    // 5. Transfer cancelled
    void onEvent<{ transferId?: string; reason?: string; origin?: string }>("coudrop-cancel", (payload) => {
      this.clearDismissTimer();
      if (this.activeTransfer) {
        const rawReason = payload?.reason || "";
        const rawOrigin = (payload?.origin || "").toLowerCase();
        const cancelOrigin: "phone" | "desktop" | "system" =
          rawOrigin === "desktop" || rawOrigin === "windows" || rawReason.includes("desktop")
            ? "desktop"
            : rawOrigin === "phone" || rawOrigin === "android" || rawReason.includes("phone")
            ? "phone"
            : "phone";

        const isExplicitUserCancel =
          rawReason === "user_cancelled" ||
          rawReason === "cancelled_by_user" ||
          rawReason === "cancelled_by_desktop" ||
          rawReason === "cancelled_by_phone" ||
          rawReason === "cancelled" ||
          rawReason === "" ||
          payload?.origin !== undefined;

        if (isExplicitUserCancel) {
          const cancelMsg = cancelOrigin === "desktop" ? "Cancelled from PC" : "Cancelled from phone";
          logDebug("TRANSFER_CANCELLED", { transferId: this.activeTransfer.id, rawReason, origin: cancelOrigin });
          this.activeTransfer = {
            ...this.activeTransfer,
            status: "cancelled",
            cancelOrigin,
            errorMessage: cancelMsg,
            isPaused: false,
            speedBytesPerSec: 0,
          };
          this.notifyImmediate();
          this.dismissTimer = window.setTimeout(() => {
            logDebug("ACTIVITY_UNMOUNTED", { transferId: this.activeTransfer?.id, reason: "cancel_dismiss" });
            this.activeTransfer = null;
            this.notifyImmediate();
          }, 3000);
        } else {
          // Failure or abort masquerading as cancel: map accurately to failed!
          const friendlyReason = this.mapErrorReason(rawReason);
          logDebug("TRANSFER_FAILED", { transferId: this.activeTransfer.id, rawReason, friendlyReason });
          this.activeTransfer = {
            ...this.activeTransfer,
            status: "failed",
            errorMessage: friendlyReason,
            isPaused: false,
            speedBytesPerSec: 0,
          };
          this.notifyImmediate();
          this.dismissTimer = window.setTimeout(() => {
            logDebug("ACTIVITY_UNMOUNTED", { transferId: this.activeTransfer?.id, reason: "failed_dismiss" });
            this.activeTransfer = null;
            this.notifyImmediate();
          }, 6500);
        }
      }
    });

    // 6. Transfer rejected / failed
    void onEvent<{ transferId?: string; reason?: string }>("coudrop-reject", (payload) => {
      this.clearDismissTimer();
      if (this.activeTransfer) {
        const rawReason = payload?.reason || "";
        const friendlyReason = this.mapErrorReason(rawReason);

        logDebug("TRANSFER_FAILED", { transferId: this.activeTransfer.id, rawReason, friendlyReason });
        this.activeTransfer = {
          ...this.activeTransfer,
          status: "failed",
          errorMessage: friendlyReason,
        };
        this.notifyImmediate();
        // Give the user ample time to read why the transfer failed (6.5s)
        this.dismissTimer = window.setTimeout(() => {
          logDebug("ACTIVITY_UNMOUNTED", { transferId: this.activeTransfer?.id, reason: "failed_dismiss" });
          this.activeTransfer = null;
          this.notifyImmediate();
        }, 6500);
      }
    });

    // 7. Device connected / disconnected sync
    void onEvent<{ device?: string; name?: string }>("coudrop-phone-connected", (payload) => {
      if (this.activeTransfer) {
        this.activeTransfer.deviceName = payload.name || payload.device || "Phone";
        this.notifyImmediate();
      }
    });

    // 8. Hydrate active transfer if app reloaded or was launched during ongoing transfer
    void Bridge.coudropGetActiveTransfer().then((active) => {
      if (active && !this.activeTransfer) {
        logDebug("ACTIVE_TRANSFER_HYDRATED", { id: active.id, status: active.status });
        this.activeTransfer = {
          id: active.id,
          direction: active.direction as TransferDirection,
          deviceName: this.resolveDeviceName(),
          device: "phone",
          itemName: active.name,
          totalBytes: active.totalBytes,
          bytesTransferred: active.bytesTransferred,
          progress: active.progress,
          status: active.isPaused ? "paused" : "in_progress",
          speedBytesPerSec: active.speedBytesPerSec,
          timeRemainingSeconds: active.timeRemainingSeconds,
          isPaused: active.isPaused,
          startTime: Date.now(),
          lastProgressUpdate: Date.now(),
        };
        this.notifyImmediate();
      }
    }).catch(() => {});
  }

  async pause(transferId?: string): Promise<void> {
    if (this.activeTransfer) {
      this.activeTransfer = {
        ...this.activeTransfer,
        status: "paused",
        isPaused: true,
        speedBytesPerSec: 0,
      };
      this.notifyImmediate();
    }
    await Bridge.coudropPauseTransfer(transferId ?? this.activeTransfer?.id);
  }

  async resume(transferId?: string): Promise<void> {
    if (this.activeTransfer) {
      this.activeTransfer = {
        ...this.activeTransfer,
        status: "in_progress",
        isPaused: false,
        lastProgressUpdate: Date.now(),
      };
      this.notifyImmediate();
    }
    await Bridge.coudropResumeTransfer(transferId ?? this.activeTransfer?.id);
  }

  async cancel(transferId?: string): Promise<void> {
    this.clearDismissTimer();
    const current = this.activeTransfer;
    if (this.activeTransfer) {
      logDebug("TRANSFER_CANCELLED", { transferId: this.activeTransfer.id, source: "user_cancel" });
      this.activeTransfer = {
        ...this.activeTransfer,
        status: "cancelled",
        cancelOrigin: "desktop",
        errorMessage: "Cancelled from PC",
        isPaused: false,
        speedBytesPerSec: 0,
      };
      this.notifyImmediate();
      this.dismissTimer = window.setTimeout(() => {
        this.activeTransfer = null;
        this.notifyImmediate();
      }, 3000);
    }

    const id = transferId ?? current?.id;
    await Bridge.coudropCancelTransfer(id);
    if (current?.direction === "receive") {
      await Bridge.coudropCancel();
    } else {
      await Bridge.coudropCancelSend();
    }
  }

  /** Manual simulation helper for automated testing */
  simulateTransfer(mock: Partial<ActiveNearbyTransfer>): void {
    this.clearDismissTimer();
    this.activeTransfer = {
      id: mock.id || "test-transfer",
      direction: mock.direction || "send",
      deviceName: mock.deviceName || "RMX5003",
      device: mock.device || "phone",
      itemName: mock.itemName || "test.pdf",
      totalBytes: mock.totalBytes || 1024 * 1024,
      bytesTransferred: mock.bytesTransferred || 0,
      progress: mock.progress ?? 0,
      status: mock.status || "in_progress",
      startTime: Date.now(),
      lastProgressUpdate: Date.now(),
    };
    this.notifyImmediate();
  }

  clear(): void {
    this.clearDismissTimer();
    if (this.throttleTimer !== null) {
      window.clearTimeout(this.throttleTimer);
      this.throttleTimer = null;
    }
    this.activeTransfer = null;
    this.notifyImmediate();
  }

  dismiss(): void {
    this.clear();
  }
}

export const nearbyTransferManager = new NearbyTransferManager();

export const getActiveTransfer = () => nearbyTransferManager.getActiveTransfer();
export const subscribeActiveTransfer = (listener: TransferListener) => nearbyTransferManager.subscribe(listener);
export const pauseTransfer = (id?: string) => nearbyTransferManager.pause(id);
export const resumeTransfer = (id?: string) => nearbyTransferManager.resume(id);
export const cancelTransfer = (id?: string) => nearbyTransferManager.cancel(id);
export const dismissTransfer = () => nearbyTransferManager.dismiss();
export const simulateTransfer = (mock: Partial<ActiveNearbyTransfer>) => nearbyTransferManager.simulateTransfer(mock);
