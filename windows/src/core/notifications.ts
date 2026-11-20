// Small Notch Notification Queue & Dispatcher
// Manages incoming notifications from WhatsApp, social apps, and Windows system toasts.
// Provides burst debouncing (e.g. "WhatsApp · 2 msgs"), auto-dismiss timing (5.5s),
// and feeds the small notch (closed island) with liquid morphing data.

import { State } from "./state";
import { Diagnostics } from "./diagnostics";

export interface NotchNotificationItem {
  id: string;
  app: string;
  title?: string;
  body?: string;
  color: string;
  icon?: string | null;
  count: number;
  timestamp: number;
}

export interface NotchNotificationDisplay {
  id: string;
  app: string;
  text: string;
  color: string;
  icon?: string | null;
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
  private recordedFirstNotif = false;

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
  push(input: { app: string; title?: string; body?: string; color?: string; icon?: string | null; id?: string }) {
    if (!this.enabled) return;

    if (!this.recordedFirstNotif) {
      this.recordedFirstNotif = true;
      Diagnostics.record("first_notification_received");
    }

    const now = Date.now();
    const appColor = input.color || this.detectAppColor(input.app);
    const appIcon = input.icon !== undefined ? input.icon : this.detectAppIcon(input.app);
    const id = input.id || `${input.app}_${now}`;

    // Burst grouping & deduplication:
    // If the active or most recent notification is from the same app within BURST_WINDOW_MS
    if (this.current && this.current.app.toLowerCase() === input.app.toLowerCase()) {
      if (now - this.current.timestamp < NotchNotificationQueue.BURST_WINDOW_MS) {
        const sameTitle = (input.title || "").trim().toLowerCase() === (this.current.title || "").trim().toLowerCase();
        const currentBody = (this.current.body || "").trim();
        const inputBody = (input.body || "").trim();
        const isDuplicate = sameTitle && (
          currentBody === inputBody ||
          currentBody.length === 0 ||
          inputBody.length === 0
        );

        if (isDuplicate) {
          // Dual ingestion (WinRT toast + WhatsApp pill) or duplicate delivery:
          // Enrich body, title, or icon if missing, but do not increment count
          if (!this.current.title && input.title) this.current.title = input.title;
          if (!this.current.body && input.body) this.current.body = input.body;
          if (!this.current.icon && appIcon) this.current.icon = appIcon;
          this.restartTimer();
          this.notify();
          return;
        }

        this.current.count += 1;
        this.current.timestamp = now;
        if (input.title) this.current.title = input.title;
        if (input.body) this.current.body = input.body;
        if (appIcon !== undefined) this.current.icon = appIcon;
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
      icon: appIcon,
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
      icon: c.icon ?? null,
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
    if (lower.includes("snip") || lower.includes("screen")) return "#0EA5E9";
    return "#0EA5E9"; // Coucou default sky blue
  }

  /** Helper to map well-known apps to crisp 14x14 vector icons */
  private detectAppIcon(appName: string): string | null {
    const lower = appName.toLowerCase();
    if (lower.includes("snip") || lower.includes("screen")) {
      return `<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="#0EA5E9" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M14.5 10.5V13a1.5 1.5 0 0 1-1.5 1.5H3A1.5 1.5 0 0 1 1.5 13V5A1.5 1.5 0 0 1 3 3.5h2.5L7 1.5h2l1.5 2h2.5A1.5 1.5 0 0 1 14.5 5v1.5"/><circle cx="8" cy="8.5" r="2.5"/></svg>`;
    }
    if (lower.includes("whatsapp")) {
      return `<svg viewBox="0 0 16 16" width="14" height="14" fill="#25D366"><path d="M13.6 2.4A7.9 7.9 0 0 0 8 0C3.6 0 0 3.6 0 8c0 1.4.4 2.8 1.1 4L0 16l4.1-1.1c1.2.6 2.5 1 3.9 1 4.4 0 8-3.6 8-8 0-2.1-.8-4.2-2.4-5.5zM8 14.6c-1.2 0-2.4-.3-3.4-.9l-.2-.1-2.5.7.7-2.5-.2-.3A6.6 6.6 0 1 1 14.6 8c0 3.6-3 6.6-6.6 6.6z"/></svg>`;
    }
    if (lower.includes("telegram")) {
      return `<svg viewBox="0 0 16 16" width="14" height="14" fill="#0088CC"><path d="M14.8.4a.9.9 0 0 0-1-.1L.7 5.7c-.7.3-.7 1.1-.1 1.3l3.6 1.1 1.4 4.3c.2.5.7.6 1 .3l2-1.9 4 3c.6.4 1.2.2 1.4-.5l2-12c.1-.5-.2-.8-.7-.9z"/></svg>`;
    }
    if (lower.includes("slack")) {
      return `<svg viewBox="0 0 16 16" width="14" height="14" fill="#E01E5A"><path d="M3.5 10a1.5 1.5 0 1 1-1.5-1.5h1.5v1.5zm.8 0a1.5 1.5 0 0 1 3 0v3.5a1.5 1.5 0 0 1-3 0V10zm1.7-6.5a1.5 1.5 0 1 1 1.5-1.5v1.5H6zm0 .8a1.5 1.5 0 0 1 0 3H2.5a1.5 1.5 0 0 1 0-3H6zm6.5 1.7a1.5 1.5 0 1 1 1.5 1.5h-1.5V6zm-.8 0a1.5 1.5 0 0 1-3 0V2.5a1.5 1.5 0 0 1 3 0V6zm-1.7 6.5a1.5 1.5 0 1 1-1.5 1.5v-1.5h1.5zm0-.8a1.5 1.5 0 0 1 0-3h3.5a1.5 1.5 0 0 1 0 3H10z"/></svg>`;
    }
    if (lower.includes("mail") || lower.includes("outlook")) {
      return `<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="#0EA5E9" stroke-width="1.5"><rect x="1.5" y="3" width="13" height="10" rx="1.5"/><path d="M1.5 4.5 8 9l6.5-4.5"/></svg>`;
    }
    if (lower.includes("spotify")) {
      return `<svg viewBox="0 0 16 16" width="14" height="14" fill="#1ED760"><path d="M8 0a8 8 0 1 0 8 8 8 8 0 0 0-8-8zm3.7 11.5a.5.5 0 0 1-.7.2 7.7 7.7 0 0 1-4.4-.9.5.5 0 0 1 .5-.9 6.8 6.8 0 0 0 3.9.8.5.5 0 0 1 .7.3zm1-2.2a.6.6 0 0 1-.9.2 9.5 9.5 0 0 0-5.6-1.1.6.6 0 0 1 0-1.2 10.7 10.7 0 0 1 6.3 1.2.6.6 0 0 1 .2.9zm.1-2.4a12 12 0 0 0-6.7-1.3.7.7 0 0 0 0 1.5 10.5 10.5 0 0 1 5.9 1.2.7.7 0 0 0 .8-1.4z"/></svg>`;
    }
    // Return null so apps without specific brand SVGs cleanly use the pulsing brand dot or text
    return null;
  }
}

export const GlobalNotifications = NotchNotificationQueue.shared;
