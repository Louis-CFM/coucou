// CouCou Dynamic AI Companion — Context Intelligence Engine (Phase 1)
// Constructs immutable, monotonic-versioned 8-dimensional context snapshots
// for prompt construction, speculative pre-generation, and candidate freshness validation.

import type { CircadianPhase, CompanionCategory, ContextSnapshot } from "./types";
import { GlobalWelcomeMessages } from "../core/welcome";
import { State } from "../core/state";

export class ContextIntelligence {
  private static sequenceVersion = 1;
  private static sessionStartTime = Date.now();
  private static lastHydrationTime = Date.now();

  // Activity tracking state
  private static currentForegroundApp: string | null = null;
  private static currentAppStartTime = Date.now();
  private static appSwitchCount = 0;
  private static recentApps: string[] = [];
  private static activityOverride: Partial<{
    currentApp: string;
    appSwitchCount: number;
    continuousAppMinutes: number;
    recentApps: string[];
    activitySummary: string;
  }> | null = null;

  /** Current monotonic context version counter. */
  public static get currentVersion(): number {
    return this.sequenceVersion;
  }

  /** Advances the monotonic sequence version, invalidating pending speculative tasks. */
  public static incrementVersion(): number {
    this.sequenceVersion += 1;
    return this.sequenceVersion;
  }

  /** Resets or updates the active session timer. */
  public static markActiveSessionStart(startTimeMs: number = Date.now()): void {
    this.sessionStartTime = startTimeMs;
  }

  /** Records that the user has hydrated. */
  public static recordHydration(timeMs: number = Date.now()): void {
    this.lastHydrationTime = timeMs;
  }

  /**
   * Normalizes raw process names to user-friendly application labels.
   */
  public static normalizeAppName(raw: string | null): string | null {
    if (!raw) return null;
    const lower = raw.trim().toLowerCase();
    if (lower === "code" || lower.includes("vscode") || lower.includes("visual studio code")) return "VS Code";
    if (lower === "chrome" || lower.includes("google chrome")) return "Chrome";
    if (lower === "firefox") return "Firefox";
    if (lower === "msedge" || lower.includes("edge")) return "Edge";
    if (lower === "windowsterminal" || lower === "cmd" || lower === "powershell" || lower === "pwsh") return "Terminal";
    if (lower === "spotify") return "Spotify";
    if (lower === "slack") return "Slack";
    if (lower === "discord") return "Discord";
    if (lower === "notion") return "Notion";
    if (lower === "explorer") return "File Explorer";
    return raw.trim();
  }

  /**
   * Tracks foreground application switches and duration in real time.
   */
  public static recordForegroundApp(rawApp: string | null, nowMs: number = Date.now()): void {
    const normalized = this.normalizeAppName(rawApp);
    if (normalized === "Coucou" || normalized === "coucou") return; // Ignore Coucou itself

    if (normalized !== this.currentForegroundApp) {
      if (this.currentForegroundApp !== null) {
        this.appSwitchCount++;
        if (!this.recentApps.includes(this.currentForegroundApp)) {
          this.recentApps.unshift(this.currentForegroundApp);
          if (this.recentApps.length > 5) this.recentApps.pop();
        }
      }
      this.currentForegroundApp = normalized;
      this.currentAppStartTime = nowMs;
    }
  }

  /** Allows test suites to inject simulated activity context. */
  public static setActivityContextOverride(override: typeof ContextIntelligence.activityOverride): void {
    this.activityOverride = override;
  }

  /**
   * Formats a concise, factual summary of actual computer activity.
   */
  public static computeActivitySummary(
    app: string | null,
    continuousMins: number,
    switchCount: number,
    recentApps: string[],
    sessionMins: number,
  ): string {
    if (switchCount >= 5 && recentApps.length >= 2) {
      const topApps = recentApps.slice(0, 3).join(" and ");
      return `Frequent switching between ${topApps} with ${switchCount} window transitions in the session`;
    }
    if (continuousMins >= 45 && app) {
      return `Long continuous session in ${app} for ${continuousMins} minutes with no application switching`;
    }
    if (app) {
      return `${continuousMins} minutes focused on ${app} (${sessionMins} minutes overall session)`;
    }
    return `${sessionMins} minutes of active desktop session`;
  }

  /**
   * Evaluates the circadian rhythm phase from a given Date object.
   * - 05:00 to 11:59: morning
   * - 12:00 to 16:59: afternoon
   * - 17:00 to 20:59: evening
   * - 21:00 to 23:59: night
   * - 00:00 to 04:59: deep_night
   */
  public static evaluateCircadianPhase(date: Date = new Date()): CircadianPhase {
    const hour = date.getHours();
    if (hour >= 5 && hour < 12) return "morning";
    if (hour >= 12 && hour < 17) return "afternoon";
    if (hour >= 17 && hour < 21) return "evening";
    if (hour >= 21) return "night";
    return "deep_night";
  }

  /** Formats a 2-digit 24-hour time string ("HH:MM"). */
  public static formatLocalTime(date: Date = new Date()): string {
    const hours = String(date.getHours()).padStart(2, "0");
    const minutes = String(date.getMinutes()).padStart(2, "0");
    return `${hours}:${minutes}`;
  }

  /** Returns English full day of week name ("Monday", ...). */
  public static getDayOfWeek(date: Date = new Date()): string {
    const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
    return days[date.getDay()] ?? "Monday";
  }

  /** Computes active session duration in minutes. */
  public static getSessionDurationMinutes(nowMs: number = Date.now()): number {
    const diff = Math.max(0, nowMs - this.sessionStartTime);
    return Math.floor(diff / 60000);
  }

  /** Computes elapsed minutes since last hydration. */
  public static getMinutesSinceHydration(nowMs: number = Date.now()): number {
    const diff = Math.max(0, nowMs - this.lastHydrationTime);
    return Math.floor(diff / 60000);
  }

  /**
   * Generates a stable identity hash string for context versioning.
   * Simple 32-bit FNV-1a hex representation.
   */
  public static hashIdentity(name: string): string {
    let hash = 0x811c9dc5;
    const str = name.trim().toLowerCase();
    for (let i = 0; i < str.length; i++) {
      hash ^= str.charCodeAt(i);
      hash = Math.imul(hash, 0x01000193);
    }
    return (hash >>> 0).toString(16).padStart(8, "0");
  }

  /**
   * Captures an immutable, activity-enriched ContextSnapshot.
   */
  public static capture(
    category: CompanionCategory = "greeting_return",
    awayDurationSeconds = 0,
    now: Date = new Date(),
  ): ContextSnapshot {
    const nowMs = now.getTime();
    const resolvedName = GlobalWelcomeMessages.resolvedGreetingName;
    const wardrobe = State.settings?.mochiOutfit || "classic";

    const sessionDurationMinutes = this.getSessionDurationMinutes(nowMs);
    const continuousAppMinutes = Math.max(0, Math.floor((nowMs - this.currentAppStartTime) / 60000));
    const currentApp = this.activityOverride?.currentApp ?? (this.currentForegroundApp || State.foregroundApp || null);
    const appSwitchCount = this.activityOverride?.appSwitchCount ?? this.appSwitchCount;
    const continuousMins = this.activityOverride?.continuousAppMinutes ?? continuousAppMinutes;
    const recentApps = this.activityOverride?.recentApps ?? [...this.recentApps];
    const activitySummary =
      this.activityOverride?.activitySummary ??
      this.computeActivitySummary(currentApp, continuousMins, appSwitchCount, recentApps, sessionDurationMinutes);

    return {
      version: this.sequenceVersion,
      timestamp: nowMs,
      awayDurationSeconds: Math.max(0, Math.floor(awayDurationSeconds)),
      circadianPhase: this.evaluateCircadianPhase(now),
      localTimeStr: this.formatLocalTime(now),
      dayOfWeek: this.getDayOfWeek(now),
      sessionDurationMinutes,
      minutesSinceHydration: this.getMinutesSinceHydration(nowMs),
      resolvedName,
      identityVersion: this.hashIdentity(resolvedName),
      mochiWardrobe: wardrobe,
      category,
      currentApp,
      appSwitchCount,
      continuousAppMinutes: continuousMins,
      recentApps,
      activitySummary,
    };
  }
}
