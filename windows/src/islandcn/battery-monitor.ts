// ── Native Hardware Battery Monitor ───────────────────────────────────────────
// Authoritative single source of truth for battery state.
// Directly powered by Windows Win32 GetSystemPowerStatus via Tauri boot snapshot
// and real-time "battery-changed" push events.
// Chromium/WebView2's Web Battery API is intentionally avoided because
// Chromium unconditionally mocks level=1.0 (100%) for anti-fingerprinting.

import { Bridge, onEvent, IS_TAURI, type BatteryStatusDto } from "../core/bridge";
import type { BatteryState } from "./battery-activity";

export type BatterySubscriber = (state: BatteryState) => void;

class BatteryMonitorService {
  private currentState: BatteryState = {
    level: 1.0,
    charging: false,
    hasBattery: false,
  };
  private subscribers = new Set<BatterySubscriber>();
  private initialized = false;
  private hasAuthoritativeSnapshot = false;
  private unlistenEvent: (() => void) | null = null;
  private safetyTimer: number | null = null;

  /**
   * Immediately synchronizes with the authoritative snapshot retrieved during boot.
   * This guarantees that valid battery state is available in the very first render frame
   * without waiting for asynchronous commands or periodic polling.
   */
  public initialize(snapshot: BatteryStatusDto): void {
    if (!snapshot || typeof snapshot.percent !== "number") return;

    this.hasAuthoritativeSnapshot = true;
    const previous = { ...this.currentState };
    this.currentState = {
      level: Math.max(0, Math.min(1, snapshot.level)),
      charging: Boolean(snapshot.charging),
      hasBattery: Boolean(snapshot.hasBattery),
      chargingTime: snapshot.timeRemainingSeconds,
    };

    if (import.meta.env.DEV) {
      console.log(
        `[BatteryDiag] Initialized with authoritative snapshot: ${snapshot.percent}% (charging: ${snapshot.charging}, hasBattery: ${snapshot.hasBattery}) at ${performance.now().toFixed(2)}ms`
      );
    }

    if (
      previous.level !== this.currentState.level ||
      previous.charging !== this.currentState.charging ||
      previous.hasBattery !== this.currentState.hasBattery
    ) {
      this.notify();
    }
  }

  public async start(): Promise<void> {
    if (this.initialized) return;
    this.initialized = true;

    // Expose developer hook for quick testing in browser DevTools
    if (typeof window !== "undefined") {
      (window as any).__setBattery = (level: number, charging = false, hasBattery = true) => {
        this.currentState = {
          level: Math.max(0, Math.min(1, level)),
          charging,
          hasBattery,
        };
        this.notify();
      };
    }

    if (!IS_TAURI) {
      // In a standard browser tab (no Win32 API access), check for stored mock
      try {
        const stored = localStorage.getItem("coucou_mock_battery");
        if (stored) {
          const parsed = JSON.parse(stored);
          this.currentState = { ...this.currentState, ...parsed };
          this.notify();
        } else {
          // Default browser preview mock
          this.currentState = { level: 0.80, charging: true, hasBattery: true };
          this.notify();
        }
      } catch {}
      return;
    }

    // 1. If not hydrated by boot payload yet, query native power status immediately
    if (!this.hasAuthoritativeSnapshot) {
      await this.pollNative();
    }

    // 2. Listen to real-time "battery-changed" push events emitted by Rust background thread
    void onEvent<BatteryStatusDto>("battery-changed", (dto) => {
      if (dto) {
        if (import.meta.env.DEV) {
          console.log(
            `[BatteryDiag] Real-time "battery-changed" push received: ${dto.percent}% (charging: ${dto.charging}) at ${performance.now().toFixed(2)}ms`
          );
        }
        this.updateFromDto(dto);
      }
    }).then((unlisten) => {
      this.unlistenEvent = unlisten;
    });

    // 3. System resume / window focus reconciliation
    const handleFocus = () => {
      void this.pollNative();
    };
    window.addEventListener("focus", handleFocus);
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") {
        void this.pollNative();
      }
    });

    // 4. Gentle fallback heartbeat (every 10s) ensuring zero drift even through system power events
    this.safetyTimer = window.setInterval(() => {
      void this.pollNative();
    }, 10_000);
  }

  public stop(): void {
    if (this.unlistenEvent) {
      this.unlistenEvent();
      this.unlistenEvent = null;
    }
    if (this.safetyTimer != null) {
      window.clearInterval(this.safetyTimer);
      this.safetyTimer = null;
    }
    this.initialized = false;
  }

  private updateFromDto(dto: BatteryStatusDto): void {
    if (!dto || typeof dto.percent !== "number") return;

    const changed =
      dto.level !== this.currentState.level ||
      dto.charging !== this.currentState.charging ||
      dto.hasBattery !== this.currentState.hasBattery ||
      dto.timeRemainingSeconds !== this.currentState.chargingTime;

    this.hasAuthoritativeSnapshot = true;
    this.currentState = {
      level: Math.max(0, Math.min(1, dto.level)),
      charging: Boolean(dto.charging),
      hasBattery: Boolean(dto.hasBattery),
      chargingTime: dto.timeRemainingSeconds,
    };

    if (changed) {
      this.notify();
    }
  }

  public async pollNative(): Promise<BatteryState> {
    try {
      const native = await Bridge.getBatteryStatus();
      if (native) {
        this.updateFromDto(native);
      }
    } catch (e) {
      console.warn("[coucou] Native battery status check failed:", e);
    }
    return this.getState();
  }

  public async refresh(): Promise<BatteryState> {
    try {
      const native = await Bridge.refreshBatteryStatus();
      if (native) {
        this.updateFromDto(native);
      }
    } catch {
      return this.pollNative();
    }
    return this.getState();
  }

  public getState(): BatteryState {
    return { ...this.currentState };
  }

  public subscribe(cb: BatterySubscriber): () => void {
    this.subscribers.add(cb);
    cb(this.getState());
    return () => this.subscribers.delete(cb);
  }

  private notify(): void {
    const st = this.getState();
    for (const sub of this.subscribers) {
      try {
        sub(st);
      } catch (err) {
        console.error("Battery subscriber error:", err);
      }
    }
  }
}

export const BatteryMonitor = new BatteryMonitorService();
