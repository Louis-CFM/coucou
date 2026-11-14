// Small Notch Notification Queue & Dispatcher
// Manages incoming notifications from WhatsApp, social apps, and Windows system toasts.
// Provides burst debouncing (e.g. "WhatsApp · 2 msgs"), auto-dismiss timing (5.5s),
// and feeds the small notch (closed island) with liquid morphing data.

import { State } from "./state";

export interface NotchNotificationItem {
  id: string;
  app: string;
  title?: string;
  body?: string;
  color: string;
  count: number;
  timestamp: number;
}

export interface NotchNotificationDisplay {
  id: string;
  app: string;
  text: string;
  color: string;
  count: number;
  raw: NotchNotificationItem;
}

export type NotificationPreviewMode = "summary" | "detailed";

export class NotchNotificationQueue {
  private static instance: NotchNotificationQueue;

  /** Auto-dismiss timeout for small notch notification banner (5.5 seconds). */
  static readonly DISPLAY_DURATION_MS = 5500;
  /** Burst grouping window (messages within 4 seconds increment count). */
  static readonly BURST_WINDOW_MS = 4000;

  private queue: NotchNotificationItem[] = [];
  private current: NotchNotificationItem | null = null;
  private timer: number | null = null;
  private listeners = new Set<() => void>();

  previewMode: NotificationPreviewMode = "summary";
  enabled = true;

  static get shared(): NotchNotificationQueue {
    if (!NotchNotificationQueue.instance) {
      NotchNotificationQueue.instance = new NotchNotificationQueue();
    }
    return NotchNotificationQueue.instance;
  }

  private constructor() {
    this.loadSettings();
  }

  loadSettings() {
    try {
      if (typeof localStorage !== "undefined") {
        const en = localStorage.getItem("coucou_notch_notifs_enabled");
        if (en != null) this.enabled = en === "true";
        const mode = localStorage.getItem("coucou_notch_notifs_mode");
        if (mode === "detailed" || mode === "summary") this.previewMode = mode;
      }
    } catch {}
  }

  saveSettings() {
    try {
      if (typeof localStorage !== "undefined") {
        localStorage.setItem("coucou_notch_notifs_enabled", String(this.enabled));
        localStorage.setItem("coucou_notch_notifs_mode", this.previewMode);
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
        console.error("Notch notification listener error:", err);
      }
    }
    try {
      State.notify();
    } catch {}
  }

  /**
   * Pushes an incoming notification (WhatsApp, Slack, System Toast, etc.).
   */
  push(input: { app: string; title?: string; body?: string; color?: string; id?: string }) {
    if (!this.enabled) return;

    const now = Date.now();
    const appColor = input.color || this.detectAppColor(input.app);
    const id = input.id || `${input.app}_${now}`;

    // Burst grouping: If the active or most recent notification is from the same app within BURST_WINDOW_MS
    if (this.current && this.current.app.toLowerCase() === input.app.toLowerCase()) {
      if (now - this.current.timestamp < NotchNotificationQueue.BURST_WINDOW_MS) {
        this.current.count += 1;
        this.current.timestamp = now;
        if (input.title) this.current.title = input.title;
        if (input.body) this.current.body = input.body;
        this.restartTimer();
        this.notify();
        return;
      }
    }

    const item: NotchNotificationItem = {
      id,
      app: input.app,
      title: input.title,
      body: input.body,
      color: appColor,
      count: 1,
      timestamp: now,
    };

    if (!this.current) {
      this.current = item;
      this.restartTimer();
      this.notify();
    } else {
      this.queue.push(item);
    }
  }

  /** Dismisses the current notification and advances the queue. */
  dismiss() {
    if (this.timer != null) {
      window.clearTimeout(this.timer);
      this.timer = null;
    }
    this.current = null;
    if (this.queue.length > 0) {
      this.current = this.queue.shift()!;
      this.restartTimer();
    }
    this.notify();
  }

  /** Clears all notifications. */
  clear() {
    if (this.timer != null) {
      window.clearTimeout(this.timer);
      this.timer = null;
    }
    this.current = null;
    this.queue = [];
    this.notify();
  }

  /** Gets the active display payload for the closed island notch. */
  active(): NotchNotificationDisplay | null {
    if (!this.enabled || !this.current) return null;

    const c = this.current;
    let text = "";

    if (this.previewMode === "detailed" && (c.title || c.body)) {
      const sender = c.title ? `${c.title}: ` : "";
      const snippet = c.body || (c.count > 1 ? `${c.count} msgs` : "1 msg");
      text = `${c.app} · ${sender}${snippet}`;
    } else {
      // Summary mode: e.g. "WhatsApp · 1 msg" or "WhatsApp · 3 msgs"
      const countLabel = c.count === 1 ? "1 msg" : `${c.count} msgs`;
      text = `${c.app} · ${countLabel}`;
    }

    return {
      id: c.id,
      app: c.app,
      text,
      color: c.color,
      count: c.count,
      raw: c,
    };
  }

  private restartTimer() {
    if (this.timer != null) {
      window.clearTimeout(this.timer);
    }
    this.timer = window.setTimeout(() => {
      this.timer = null;
      this.dismiss();
    }, NotchNotificationQueue.DISPLAY_DURATION_MS);
  }

  /** Helper to map well-known apps to their iconic brand colors */
  private detectAppColor(appName: string): string {
    const lower = appName.toLowerCase();
    if (lower.includes("whatsapp")) return "#25D366";
    if (lower.includes("telegram")) return "#0088CC";
    if (lower.includes("discord")) return "#5865F2";
    if (lower.includes("slack")) return "#E01E5A";
    if (lower.includes("mail") || lower.includes("outlook")) return "#0EA5E9";
    if (lower.includes("claude")) return "#D97706";
    if (lower.includes("antigravity")) return "#3B82F6";
    if (lower.includes("github")) return "#F5F6F8";
    if (lower.includes("spotify")) return "#1ED760";
    return "#0EA5E9"; // Coucou default sky blue
  }
}

export const GlobalNotifications = NotchNotificationQueue.shared;
