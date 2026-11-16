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
   * Captures an immutable 8-dimensional ContextSnapshot.
   */
  public static capture(
    category: CompanionCategory = "greeting_return",
    awayDurationSeconds = 0,
    now: Date = new Date(),
  ): ContextSnapshot {
    const nowMs = now.getTime();
    const resolvedName = GlobalWelcomeMessages.resolvedGreetingName;
    const wardrobe = State.settings?.mochiOutfit || "classic";

    return {
      version: this.sequenceVersion,
      timestamp: nowMs,
      awayDurationSeconds: Math.max(0, Math.floor(awayDurationSeconds)),
      circadianPhase: this.evaluateCircadianPhase(now),
      localTimeStr: this.formatLocalTime(now),
      dayOfWeek: this.getDayOfWeek(now),
      sessionDurationMinutes: this.getSessionDurationMinutes(nowMs),
      minutesSinceHydration: this.getMinutesSinceHydration(nowMs),
      resolvedName,
      identityVersion: this.hashIdentity(resolvedName),
      mochiWardrobe: wardrobe,
      category,
    };
  }
}
