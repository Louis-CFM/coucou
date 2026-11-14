// Coucoudoro clock — work and rest timer in the notch (#1055 by @PeachyCad).
// Port of NotchBuddy/Sources/App/CoucoudoroEngine.swift and CoucoudoroController.swift.

import { State } from "./state";

export interface CoucoudoroConfig {
  work: number; // in seconds
  rest: number; // in seconds
}

export type CoucoudoroPhase = "idle" | "work" | "rest";
export type CoucoudoroEvent = "restStarts" | "workStarts";

export interface CoucoudoroSnapshot {
  phase: CoucoudoroPhase;
  paused: boolean;
  deadline: number | null; // epoch ms
  pausedRemaining: number | null; // seconds
  notice: CoucoudoroEvent | null;
}

export const DEFAULT_CONFIG: CoucoudoroConfig = {
  work: 25 * 60,
  rest: 5 * 60,
};

export const IDLE_SNAPSHOT: CoucoudoroSnapshot = {
  phase: "idle",
  paused: false,
  deadline: null,
  pausedRemaining: null,
  notice: null,
};

export const CoucoudoroEngine = {
  sanitize(raw: CoucoudoroConfig): CoucoudoroConfig {
    return {
      work: Math.max(Math.floor(raw.work), 1),
      rest: Math.max(Math.floor(raw.rest), 1),
    };
  },

  start(raw: CoucoudoroConfig, nowMs: number): { snapshot: CoucoudoroSnapshot; events: CoucoudoroEvent[] } {
    const config = this.sanitize(raw);
    const deadline = nowMs + config.work * 1000;
    const snapshot: CoucoudoroSnapshot = {
      phase: "work",
      paused: false,
      deadline,
      pausedRemaining: null,
      notice: "workStarts",
    };
    return { snapshot, events: ["workStarts"] };
  },

  stop(): CoucoudoroSnapshot {
    return { ...IDLE_SNAPSHOT };
  },

  pause(s: CoucoudoroSnapshot, nowMs: number): CoucoudoroSnapshot {
    if (s.phase === "idle" || s.paused) return s;
    const remaining = s.deadline != null ? Math.max(0, (s.deadline - nowMs) / 1000) : 0;
    return {
      ...s,
      paused: true,
      pausedRemaining: remaining,
      deadline: null,
    };
  },

  resume(s: CoucoudoroSnapshot, nowMs: number): CoucoudoroSnapshot {
    if (!s.paused) return s;
    const left = Math.max(0, s.pausedRemaining ?? 0);
    return {
      ...s,
      paused: false,
      pausedRemaining: null,
      deadline: nowMs + left * 1000,
    };
  },

  tick(s: CoucoudoroSnapshot, raw: CoucoudoroConfig, nowMs: number): { snapshot: CoucoudoroSnapshot; events: CoucoudoroEvent[] } {
    if (s.phase === "idle" || s.paused || s.deadline == null) return { snapshot: s, events: [] };
    if (nowMs < s.deadline) return { snapshot: s, events: [] };

    const config = this.sanitize(raw);
    // Switch phase
    const nextPhase: CoucoudoroPhase = s.phase === "work" ? "rest" : "work";
    const durationSec = nextPhase === "work" ? config.work : config.rest;
    const nextDeadline = nowMs + durationSec * 1000;
    const event: CoucoudoroEvent = nextPhase === "work" ? "workStarts" : "restStarts";

    const nextSnapshot: CoucoudoroSnapshot = {
      ...s,
      phase: nextPhase,
      deadline: nextDeadline,
      pausedRemaining: null,
      notice: event,
    };
    return { snapshot: nextSnapshot, events: [event] };
  },

  remaining(s: CoucoudoroSnapshot, nowMs: number): number | null {
    if (s.paused) return s.pausedRemaining;
    if (s.phase === "idle" || s.deadline == null) return null;
    return Math.max(0, (s.deadline - nowMs) / 1000);
  },

  clock(seconds: number): string {
    const whole = Math.max(0, Math.ceil(seconds));
    const m = Math.floor(whole / 60);
    const sec = whole % 60;
    const secStr = sec < 10 ? `0${sec}` : `${sec}`;
    if (m >= 100) return `${m}:${secStr}`;
    const mStr = m < 10 ? `0${m}` : `${m}`;
    return `${mStr}:${secStr}`;
  },
};

/** Shared state manager for Coucoudoro */
export class CoucoudoroController {
  private static instance: CoucoudoroController;
  static readonly PILL_ID = "integration_coucoudoro";

  config: CoucoudoroConfig = { ...DEFAULT_CONFIG };
  snapshot: CoucoudoroSnapshot = { ...IDLE_SNAPSHOT };
  private listeners = new Set<() => void>();

  private timerId: ReturnType<typeof setInterval> | null = null;

  static get shared(): CoucoudoroController {
    if (!CoucoudoroController.instance) {
      CoucoudoroController.instance = new CoucoudoroController();
    }
    return CoucoudoroController.instance;
  }

  private constructor() {
    this.loadConfig();
  }

  loadConfig() {
    try {
      if (typeof localStorage !== "undefined") {
        const saved = localStorage.getItem("coucou_coucoudoro_config");
        if (saved) {
          const p = JSON.parse(saved);
          if (typeof p.work === "number" && typeof p.rest === "number") {
            this.config = CoucoudoroEngine.sanitize(p);
          }
        }
      }
    } catch {}
  }

  saveConfig() {
    try {
      if (typeof localStorage !== "undefined") {
        localStorage.setItem("coucou_coucoudoro_config", JSON.stringify(this.config));
      }
    } catch {}
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private notify() {
    for (const l of this.listeners) {
      try {
        l();
      } catch (err) {
        console.error("Coucoudoro listener error:", err);
      }
    }
    try {
      State.notify();
    } catch {}
  }

  start() {
    const res = CoucoudoroEngine.start(this.config, Date.now());
    this.snapshot = res.snapshot;
    this.syncTimer();
    this.notify();
  }

  stop() {
    this.snapshot = CoucoudoroEngine.stop();
    this.syncTimer();
    this.notify();
  }

  pause() {
    this.snapshot = CoucoudoroEngine.pause(this.snapshot, Date.now());
    this.syncTimer();
    this.notify();
  }

  resume() {
    this.snapshot = CoucoudoroEngine.resume(this.snapshot, Date.now());
    this.syncTimer();
    this.notify();
  }

  remaining(nowMs = Date.now()): number {
    return CoucoudoroEngine.remaining(this.snapshot, nowMs) ?? this.config.work;
  }

  clock(nowMs = Date.now()): string {
    return CoucoudoroEngine.clock(this.remaining(nowMs));
  }

  private syncTimer() {
    if (this.snapshot.phase !== "idle" && !this.snapshot.paused) {
      if (this.timerId == null) {
        let lastReportedSec = Math.ceil(this.remaining());
        this.timerId = setInterval(() => {
          const res = CoucoudoroEngine.tick(this.snapshot, this.config, Date.now());
          const curSec = Math.ceil(this.remaining());
          if (res.snapshot !== this.snapshot) {
            this.snapshot = res.snapshot;
            lastReportedSec = curSec;
            this.notify();
          } else if (curSec !== lastReportedSec) {
            lastReportedSec = curSec;
            this.notify();
          }
        }, 200);
      }
    } else if (this.timerId != null) {
      clearInterval(this.timerId);
      this.timerId = null;
    }
  }
}
