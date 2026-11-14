// ── Native Hardware Battery Monitor ───────────────────────────────────────────
// Directly powered by Windows Win32 GetSystemPowerStatus via Tauri IPC events
// and polling. Chromium/WebView2's Web Battery API is intentionally avoided
// because Chromium unconditionally mocks level=1.0 (100%) for anti-fingerprinting.

import { Bridge, onEvent, IS_TAURI, type BatteryStatusDto } from "../core/bridge";
import type { BatteryState } from "./battery-activity";

export type BatterySubscriber = (state: BatteryState) => void;

class BatteryMonitorService {
  private currentState: BatteryState = {
    level: 0.80,
    charging: true,
    hasBattery: true,
  };
  private subscribers = new Set<BatterySubscriber>();
  private initialized = false;

  public async start(): Promise<void> {
    if (this.initialized) return;
    this.initialized = true;

    // Expose developer hook for quick testing in browser DevTools
    if (typeof window !== "undefined") {
      (window as any).__setBattery = (level: number, charging = false) => {
        this.currentState = {
          level: Math.max(0, Math.min(1, level)),
          charging,
          hasBattery: true,
        };
        this.notify();
      };
    }

    if (!IS_TAURI) {
      // In a standard browser tab (no Win32 API access), check for stored mock or default to 80% charging
      try {
        const stored = localStorage.getItem("coucou_mock_battery");
        if (stored) {
          const parsed = JSON.parse(stored);
          this.currentState = { ...this.currentState, ...parsed };
          this.notify();
        }
      } catch {}
      return;
    }

    // 1. Initial query from native Win32 power status
    await this.pollNative();

    // 2. Listen to real-time "battery-changed" push events emitted by Rust background thread
    void onEvent<BatteryStatusDto>("battery-changed", (dto) => {
      if (dto) {
        this.updateFromDto(dto);
      }
    });

    // 3. Periodic 2s polling interval ensuring constant real-time synchronization
    window.setInterval(() => {
      void this.pollNative();
    }, 2000);
  }

  private updateFromDto(dto: BatteryStatusDto): void {
    const changed =
      dto.level !== this.currentState.level ||
      dto.charging !== this.currentState.charging ||
      dto.hasBattery !== this.currentState.hasBattery ||
      dto.timeRemainingSeconds !== this.currentState.chargingTime;

    this.currentState = {
      level: dto.level,
      charging: dto.charging,
      hasBattery: dto.hasBattery,
      chargingTime: dto.timeRemainingSeconds,
    };

    if (changed) {
      this.notify();
    }
  }

  private async pollNative(): Promise<void> {
    try {
      const native = await Bridge.getBatteryStatus();
      if (native) {
        this.updateFromDto(native);
      }
    } catch (e) {
      console.warn("Native battery status check failed:", e);
    }
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
