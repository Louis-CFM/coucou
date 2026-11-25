// Mochi Contextual Companion & Ambient Messaging Engine (#1055 & Dynamic Island Notch).
// Evaluates a multi-factor live state vector (screen time, hydration intervals,
// circadian rhythm, absence duration, and day-of-week) to select heartwarming,
// personal messages with the user's name ({name}), displayed alongside Mochi in the small notch.

import { State } from "./state";
import { Bridge } from "./bridge";
import { companionPossessive, resolveCompanionName } from "./companion-identity";
import { ContextIntelligence } from "../companion/context";
import { MessagePolicyEngine } from "../companion/policy";
import { DeterministicCatalog } from "../companion/catalog";
import { SpeculativeEngine } from "../companion/speculative";
import { MessageValidator } from "../companion/validator";
import { CompanionMemory } from "../companion/memory";
import type {
  CompanionCategory,
  CompanionSettings,
  PersonalityMode,
  PrivacyConsentRecord,
  RoutingMode,
} from "../companion/types";

export type CircadianPhase =
  | "morning"
  | "afternoon"
  | "evening"
  | "night"
  | "deep_night"
  | "dawn"
  | "morning_peak"
  | "midday_lunch"
  | "afternoon_slump"
  | "golden_hour"
  | "evening_wrapup";

export interface WelcomeStateVector {
  awayMinutes: number;
  timeOfDay: CircadianPhase;
  hour: number;
  dayOfWeek: number; // 0 = Sunday, 1 = Monday, etc.
  sessionWorkHours: number;
  minutesSinceWater: number;
  userName: string;
  wardrobe: string;
}

export interface WelcomeMessageItem {
  id: string;
  category: "hydration" | "posture" | "circadian" | "work_streak" | "duration" | "day_of_week" | "wardrobe" | "classic";
  template: (name: string) => string;
  phase?: CircadianPhase;
  minWorkHours?: number;
  minWaterMinutes?: number;
  minAwayMinutes?: number;
  dayOfWeek?: number;
  wardrobe?: string;
  weight?: number;
}

export interface WelcomeMessageDisplay {
  id: string;
  text: string;
  bot: boolean;
  category: string;
  timestamp: number;
}

export class WelcomeMessageManager {
  private static instance: WelcomeMessageManager;

  static readonly DISPLAY_DURATION_MS = 6500;
  static readonly RETURN_COOLDOWN_MS = 2.5 * 60 * 1000; // 2.5 min return cooldown
  static readonly AMBIENT_COOLDOWN_MS = 30 * 60 * 1000; // 30 min between ambient nudges

  private current: WelcomeMessageDisplay | null = null;
  private timer: number | null = null;
  private tickerInterval: number | null = null;
  private listeners = new Set<() => void>();

  private recentHistory: string[] = [];
  private lastTriggerTime = 0;
  private lastWaterNudgeTime = Date.now();
  private lastPostureNudgeTime = Date.now();
  private lastCircadianPhase: CircadianPhase | null = null;
  private sessionStartTime = Date.now();
  private activeMinutes = 0;
  private hasGreetedOnLaunch = false;
  private isUserPresent = true;

  setUserPresent(present: boolean): void {
    this.isUserPresent = present;
  }

  get userPresent(): boolean {
    return this.isUserPresent;
  }

  recordHydrationDelivered(nowMs: number = Date.now()): void {
    this.lastWaterNudgeTime = nowMs;
    try {
      if (typeof localStorage !== "undefined") {
        localStorage.setItem("coucou_last_water_time", String(nowMs));
      }
    } catch {}
    MessagePolicyEngine.recordDelivered("hydration_reminder", nowMs);
    ContextIntelligence.recordHydration(nowMs);
    this.saveState();
  }

  private _preferredName = "";
  private _detectedGreetingName = "";
  private _legacyDefaultCleaned = false;

  enabled = true;
  wellnessEnabled = true;
  hydrationIntervalMinutes = 45; // default 45 min

  routingMode: RoutingMode = "auto";
  personalityMode: PersonalityMode = "warm_playful";
  quietHoursEnabled = false;
  quietHoursStart = "22:00";
  quietHoursEnd = "08:00";
  localEndpoint = "http://127.0.0.1:11434";
  localModel = "qwen3.5:4b";
  cloudProvider: "anthropic" | "openai" = "anthropic";
  cloudModel = "claude-3-5-haiku-20241022";

  /** Explicit user preferred name override. If empty, automatically uses detected Windows identity. */
  get preferredName(): string {
    return this._preferredName;
  }

  set preferredName(val: string) {
    this._preferredName = (val ?? "").trim();
    this.saveState();
    // Invalidate speculative prefetch cache on identity change
    void SpeculativeEngine.invalidate();
    ContextIntelligence.incrementVersion();
    this.notify();
  }

  /** Automatically detected Windows first name. */
  get detectedGreetingName(): string {
    return this._detectedGreetingName;
  }

  set detectedGreetingName(val: string) {
    this._detectedGreetingName = (val ?? "").trim();
    this.notify();
  }

  /**
   * Authoritative resolved greeting name for message personalization.
   * Priority: 1. Preferred name -> 2. Detected Windows name -> 3. "" (neutral fallback)
   */
  get resolvedGreetingName(): string {
    if (this._preferredName.length > 0) return this._preferredName;
    if (this._detectedGreetingName.length > 0) return this._detectedGreetingName;
    return "";
  }

  get companionName(): string {
    return resolveCompanionName(State.settings);
  }

  invalidateForCompanionRename(): void {
    ContextIntelligence.incrementVersion();
    void SpeculativeEngine.invalidate();
    if (this.current) {
      this.dismiss();
    } else {
      this.notify();
    }
  }

  /** Backward-compatible alias for resolvedGreetingName. */
  get userName(): string {
    return this.resolvedGreetingName;
  }

  set userName(val: string) {
    this.preferredName = val;
  }

  static get shared(): WelcomeMessageManager {
    if (!WelcomeMessageManager.instance) {
      WelcomeMessageManager.instance = new WelcomeMessageManager();
    }
    return WelcomeMessageManager.instance;
  }

  private constructor() {
    this.loadState();
    this.startAmbientTicker();
    void this.initIdentity();
  }

  async initIdentity() {
    try {
      const id = await Bridge.getUserIdentity();
      if (id?.detectedGreetingName && id.detectedGreetingName.trim().length > 0) {
        const detected = id.detectedGreetingName.trim();
        this._detectedGreetingName = detected;

        // Migration: If preferredName was loaded as "Madhan" from old hardcoded default,
        // but the detected Windows account is someone else and coucou_preferred_name was never
        // explicitly saved, reset preferredName so the real Windows identity is used.
        if (
          !this._legacyDefaultCleaned &&
          this._preferredName.toLowerCase() === "madhan" &&
          detected.toLowerCase() !== "madhan" &&
          typeof localStorage !== "undefined" &&
          localStorage.getItem("coucou_preferred_name") == null
        ) {
          this._preferredName = "";
          try {
            localStorage.removeItem("coucou_user_name");
          } catch {}
          this._legacyDefaultCleaned = true;
        }
      }
    } catch {}
    this.notify();
  }

  private loadState() {
    try {
      if (typeof localStorage !== "undefined") {
        const en = localStorage.getItem("coucou_welcome_enabled");
        if (en != null) this.enabled = en === "true";
        const well = localStorage.getItem("coucou_wellness_enabled");
        if (well != null) this.wellnessEnabled = well === "true";
        const water = localStorage.getItem("coucou_last_water_time");
        if (water) {
          const n = Number(water);
          if (!isNaN(n) && n > 0) {
            this.lastWaterNudgeTime = n;
            MessagePolicyEngine.recordDelivered("hydration_reminder", n);
            ContextIntelligence.recordHydration(n);
          }
        }
        const intv = localStorage.getItem("coucou_hydration_interval");
        if (intv) this.hydrationIntervalMinutes = Number(intv) || 45;

        const rm = localStorage.getItem("coucou_companion_routing_mode");
        if (rm === "auto" || rm === "local_only" || rm === "cloud_only" || rm === "classic") this.routingMode = rm;
        const pm = localStorage.getItem("coucou_companion_personality");
        if (pm === "warm_playful" || pm === "witty_sarcastic" || pm === "zen_mindful" || pm === "focus_coach") this.personalityMode = pm;
        const qh = localStorage.getItem("coucou_quiet_hours_enabled");
        if (qh != null) this.quietHoursEnabled = qh === "true";
        const qs = localStorage.getItem("coucou_quiet_hours_start");
        if (qs) this.quietHoursStart = qs;
        const qe = localStorage.getItem("coucou_quiet_hours_end");
        if (qe) this.quietHoursEnd = qe;
        const le = localStorage.getItem("coucou_companion_local_endpoint");
        if (le) this.localEndpoint = le;
        const lm = localStorage.getItem("coucou_companion_local_model");
        if (lm) {
          // If stored value is legacy "llama3.2", automatically migrate to "qwen3.5:4b"
          this.localModel = lm === "llama3.2" ? "qwen3.5:4b" : lm;
        } else {
          this.localModel = "qwen3.5:4b";
        }

        const pref = localStorage.getItem("coucou_preferred_name");
        if (pref != null && pref.trim().length > 0) {
          this._preferredName = pref.trim();
        } else {
          const legacy = localStorage.getItem("coucou_user_name");
          if (legacy != null && legacy.trim().length > 0) {
            this._preferredName = legacy.trim();
          }
        }
      }
    } catch {}
  }

  saveState() {
    try {
      if (typeof localStorage !== "undefined") {
        localStorage.setItem("coucou_welcome_enabled", String(this.enabled));
        localStorage.setItem("coucou_wellness_enabled", String(this.wellnessEnabled));
        localStorage.setItem("coucou_last_water_time", String(this.lastWaterNudgeTime));
        localStorage.setItem("coucou_hydration_interval", String(this.hydrationIntervalMinutes));
        localStorage.setItem("coucou_companion_routing_mode", this.routingMode);
        localStorage.setItem("coucou_companion_personality", this.personalityMode);
        localStorage.setItem("coucou_quiet_hours_enabled", String(this.quietHoursEnabled));
        localStorage.setItem("coucou_quiet_hours_start", this.quietHoursStart);
        localStorage.setItem("coucou_quiet_hours_end", this.quietHoursEnd);
        localStorage.setItem("coucou_companion_local_endpoint", this.localEndpoint);
        localStorage.setItem("coucou_companion_local_model", this.localModel);

        if (this._preferredName.length > 0) {
          localStorage.setItem("coucou_preferred_name", this._preferredName);
          localStorage.setItem("coucou_user_name", this._preferredName);
        } else {
          localStorage.removeItem("coucou_preferred_name");
          localStorage.removeItem("coucou_user_name");
        }
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
        console.error("WelcomeMessageManager listener error:", err);
      }
    }
    try {
      State.notify();
    } catch {}
  }

  active(): WelcomeMessageDisplay | null {
    return this.enabled ? this.current : null;
  }

  dismiss() {
    if (this.timer != null) {
      window.clearTimeout(this.timer);
      this.timer = null;
    }
    this.current = null;
    this.notify();
  }

  /**
   * Starts the 60-second background ambient ticker.
   * Regularly monitors hydration intervals, posture, eye breaks, and circadian shifts.
   */
  startAmbientTicker() {
    if (this.tickerInterval != null) return;
    if (typeof window === "undefined") return;

    // Initial companion greeting will trigger after intro finishes (via onGreetingDone)
    const interval = window.setInterval(() => {
      this.onAmbientTick();
    }, 60 * 1000) as unknown as { unref?: () => void };
    interval?.unref?.();

    this.tickerInterval = interval as unknown as number;
  }

  stopAmbientTicker() {
    if (this.tickerInterval != null) {
      window.clearInterval(this.tickerInterval);
      this.tickerInterval = null;
    }
  }

  /**
   * Warm greeting upon app launch / initial startup.
   */
  onAppLaunch() {
    if (!this.enabled || this.hasGreetedOnLaunch) return;
    this.hasGreetedOnLaunch = true;

    const now = Date.now();
    const d = new Date(now);
    const hour = d.getHours();
    const u = this.resolvedGreetingName;
    const c = this.companionName;
    const cp = companionPossessive(c);

    // Context-aware launch greeting pools categorized by actual local time
    let pool: { id: string; template: (name: string) => string }[] = [];

    if (hour >= 5 && hour < 9) {
      // Early morning (05:00 - 08:59)
      pool = [
        { id: "launch_early_1", template: (n) => n ? `Morning, ${n}. ${cp} awake and cheering you on ☕` : `Morning! ${cp} awake and cheering you on ☕` },
        { id: "launch_early_2", template: (n) => n ? `Early bird mode, ${n}! Let's make today great 🌅` : "Early bird mode! Let's make today great 🌅" },
        { id: "launch_early_3", template: (n) => n ? `Good morning, ${n}. ${cp} ready when you are ✨` : `Good morning! ${cp} ready when you are ✨` },
        { id: "launch_early_4", template: (n) => n ? `Morning, ${n}! Let's set a great tempo today 🚀` : "Morning! Let's set a great tempo today 🚀" },
      ];
    } else if (hour >= 9 && hour < 12) {
      // Peak morning focus (09:00 - 11:59)
      pool = [
        { id: "launch_morning_1", template: (n) => n ? `Good morning, ${n}. ${cp} ready when you are 🚀` : `Good morning! ${cp} ready when you are 🚀` },
        { id: "launch_morning_2", template: (n) => n ? `Focus mode ready, ${n}! Let's make every commit count 💻` : "Focus mode ready! Let's make every commit count 💻" },
        { id: "launch_morning_3", template: (n) => n ? `Hey ${n}! ${c} is right here with you today ⚡` : `Hey! ${c} is right here with you today ⚡` },
        { id: "launch_morning_4", template: (n) => n ? `Ready to build, ${n}? Today's looking promising ✨` : "Ready to build? Today's looking promising ✨" },
      ];
    } else if (hour >= 12 && hour < 14) {
      // Midday (12:00 - 13:59)
      pool = [
        { id: "launch_midday_1", template: (n) => n ? `Midday check-in, ${n}! ${cp} keeping things steady ✨` : `Midday check-in! ${cp} keeping things steady ✨` },
        { id: "launch_midday_2", template: (n) => n ? `Hey ${n}! Halfway through the day, staying strong 🥪` : "Hey! Halfway through the day, staying strong 🥪" },
        { id: "launch_midday_3", template: (n) => n ? `Solid progress so far, ${n}! Ready for the afternoon ⚡` : "Solid progress so far! Ready for the afternoon ⚡" },
      ];
    } else if (hour >= 14 && hour < 17) {
      // Afternoon (14:00 - 16:59)
      pool = [
        { id: "launch_afternoon_1", template: (n) => n ? `Good afternoon, ${n}! ${cp} right here in your Notch ⚡` : `Good afternoon! ${cp} right here in your Notch ⚡` },
        { id: "launch_afternoon_2", template: (n) => n ? `Afternoon building, ${n}! Let's keep the focus rolling 🚀` : "Afternoon building! Let's keep the focus rolling 🚀" },
        { id: "launch_afternoon_3", template: (n) => n ? `Hey ${n}! ${c} is ready for a strong afternoon sprint 💻` : `Hey! ${c} is ready for a strong afternoon sprint 💻` },
        { id: "launch_afternoon_4", template: (n) => n ? `Great momentum, ${n}! Second wind incoming ✨` : "Great momentum! Second wind incoming ✨" },
      ];
    } else if (hour >= 17 && hour < 21) {
      // Evening (17:00 - 20:59)
      pool = [
        { id: "launch_evening_1", template: (n) => n ? `Good evening, ${n}! ${cp} here for the wrap-up 🌇` : `Good evening! ${cp} here for the wrap-up 🌇` },
        { id: "launch_evening_2", template: (n) => n ? `Evening wrap-up, ${n}! Look at all you accomplished today ✨` : "Evening wrap-up! Look at all you accomplished today ✨" },
        { id: "launch_evening_3", template: (n) => n ? `Golden hour session, ${n}! ${c} saved your quiet corner 🌆` : `Golden hour session! ${c} saved your quiet corner 🌆` },
        { id: "launch_evening_4", template: (n) => n ? `Hey ${n}! Almost wrap-up time, you earned your evening 🛋️` : "Almost wrap-up time, you earned your evening 🛋️" },
      ];
    } else if (hour >= 21) {
      // Night (21:00 - 23:59)
      pool = [
        { id: "launch_night_1", template: (n) => {
          return n ? `Night owl mode, ${n}! ${cp} here with you 🌙` : `Night owl mode! ${cp} here with you 🌙`;
        } },
        { id: "launch_night_2", template: (n) => n ? `Late evening session, ${n}! Great work, take it easy tonight ✨` : "Late evening session! Great work, take it easy tonight ✨" },
        { id: "launch_night_3", template: (n) => n ? `Hey ${n}, burning the late hours? Remember to unwind soon 🛋️` : "Hey, burning the late hours? Remember to unwind soon 🛋️" },
      ];
    } else {
      // Deep night (00:00 - 04:59)
      pool = [
        { id: "launch_deepnight_1", template: (n) => n ? `Late night building, ${n}? Don't push too hard tonight 🌌` : "Late night building? Don't push too hard tonight 🌌" },
        { id: "launch_deepnight_2", template: (n) => {
          return n ? `Still awake, ${n}? ${cp} keeping watch, but rest is magic too 😴` : `Still awake? ${cp} keeping watch, but rest is magic too 😴`;
        } },
      ];
    }

    const unseen = pool.filter((item) => !this.recentHistory.includes(item.id));
    const candidate = (unseen.length > 0 ? unseen : pool)[Math.floor(Math.random() * (unseen.length > 0 ? unseen.length : pool.length))];
    const text = candidate ? candidate.template(u) : (u ? `Hello ${u}! Welcome back ✨` : "Hello! Welcome back ✨");
    const chosenId = candidate ? candidate.id : "launch_greeting";

    this.recentHistory.unshift(chosenId);
    if (this.recentHistory.length > 20) this.recentHistory.pop();

    this.displayMessage({
      id: chosenId,
      text,
      bot: true,
      category: "classic",
      timestamp: now,
    });
  }

  /**
   * 60-second active work evaluation loop.
   */
  private onAmbientTick() {
    if (!this.enabled || !this.isUserPresent) return;

    // Increment active work screen time
    this.activeMinutes += 1;
    const now = Date.now();
    const minutesSinceLastMsg = (now - this.lastTriggerTime) / (60 * 1000);

    // Enforce gentle ambient spacing (at least 30 minutes between proactive nudges)
    if (minutesSinceLastMsg < 30) return;

    const sessionWorkHours = this.activeMinutes / 60;
    const minutesSinceWater = (now - this.lastWaterNudgeTime) / (60 * 1000);
    const minutesSincePosture = (now - this.lastPostureNudgeTime) / (60 * 1000);

    // 1. Proactive Hydration Nudge
    if (this.wellnessEnabled && minutesSinceWater >= this.hydrationIntervalMinutes && sessionWorkHours >= 0.75) {
      const u = this.resolvedGreetingName;
      const hydrationItems = this.getCatalog().filter(c => c.category === "hydration");
      const unseenHydration = hydrationItems.filter(c => !this.recentHistory.includes(c.id));
      const pool = unseenHydration.length > 0 ? unseenHydration : hydrationItems;
      const item = pool[Math.floor(Math.random() * pool.length)];
      const text = item ? item.template(u) : (u ? `Hey ${u}! Grab a glass of water right now 💧` : "Hey! Grab a glass of water right now 💧");
      const chosenId = item ? item.id : "ambient_hydration";

      this.recentHistory.unshift(chosenId);
      if (this.recentHistory.length > 20) this.recentHistory.pop();

      this.recordHydrationDelivered(now);
      this.displayMessage({
        id: chosenId,
        text,
        bot: true,
        category: "hydration",
        timestamp: now,
      });
      return;
    }

    // 2. Posture & 20-20-20 Eye Relief Nudge
    if (this.wellnessEnabled && minutesSincePosture >= 90 && sessionWorkHours >= 1.5) {
      const u = this.resolvedGreetingName;
      const postureItems = this.getCatalog().filter(c => c.category === "posture");
      const unseenPosture = postureItems.filter(c => !this.recentHistory.includes(c.id));
      const pool = unseenPosture.length > 0 ? unseenPosture : postureItems;
      const item = pool[Math.floor(Math.random() * pool.length)];
      const text = item ? item.template(u) : (u ? `${u}, look 20 feet away for 20 seconds ✨` : "Look 20 feet away for 20 seconds ✨");
      const chosenId = item ? item.id : "ambient_posture";

      this.recentHistory.unshift(chosenId);
      if (this.recentHistory.length > 20) this.recentHistory.pop();

      this.lastPostureNudgeTime = now;
      this.displayMessage({
        id: chosenId,
        text,
        bot: true,
        category: "posture",
        timestamp: now,
      });
      return;
    }

    // 3. Circadian Phase Transition
    const currentPhase = this.computeStateVector(0, now).timeOfDay;
    if (this.lastCircadianPhase && this.lastCircadianPhase !== currentPhase) {
      const u = this.resolvedGreetingName;
      const circadianItems = this.getCatalog().filter(c => c.category === "circadian" && c.phase === currentPhase);
      const unseenCircadian = circadianItems.filter(c => !this.recentHistory.includes(c.id));
      const pool = unseenCircadian.length > 0 ? unseenCircadian : circadianItems;
      let phaseText = "";
      let chosenId = `circadian_${currentPhase}`;

      if (pool.length > 0) {
        const item = pool[Math.floor(Math.random() * pool.length)];
        phaseText = item.template(u);
        chosenId = item.id;
        this.recentHistory.unshift(chosenId);
        if (this.recentHistory.length > 20) this.recentHistory.pop();
      } else {
        if (currentPhase === "afternoon_slump") {
          const cp = companionPossessive(this.companionName);
          phaseText = u ? `2 PM slump? Not on ${cp} watch, ${u} ⚡` : `2 PM slump? Not on ${cp} watch ⚡`;
        } else if (currentPhase === "golden_hour") {
          phaseText = u ? `Golden hour, ${u}! Look at all you built today 🌇` : "Golden hour! Look at all you built today 🌇";
        } else if (currentPhase === "evening_wrapup") {
          phaseText = u ? `Almost wrap-up time, ${u}! You earned your evening ✨` : "Almost wrap-up time! You earned your evening ✨";
        } else if (currentPhase === "deep_night") {
          phaseText = u ? `Still awake, ${u}? Don't forget to rest soon 🌙` : "Still awake? Don't forget to rest soon 🌙";
        }
      }

      this.lastCircadianPhase = currentPhase;
      if (phaseText) {
        this.displayMessage({
          id: chosenId,
          text: phaseText,
          bot: true,
          category: "circadian",
          timestamp: now,
        });
        return;
      }
    }
    this.lastCircadianPhase = currentPhase;
  }

  getPrivacyConsent(): PrivacyConsentRecord {
    try {
      if (typeof localStorage !== "undefined") {
        const raw = localStorage.getItem("coucou_cloud_consent_v2");
        if (raw) return JSON.parse(raw);
      }
    } catch {}
    return {
      version: 2,
      consentedProviders: { anthropic: false, openai: false },
      consentedCategories: { userGreetingName: true, sessionMetrics: true },
      grantedAtTimestamp: null,
      consentRevoked: false,
    };
  }

  getCompanionSettings(): CompanionSettings {
    return {
      enabled: this.enabled,
      routingMode: this.routingMode,
      preferredName: this.preferredName,
      personality: this.personalityMode,
      absenceIntervalSeconds: 180,
      quietHoursEnabled: this.quietHoursEnabled,
      quietHoursStart: this.quietHoursStart,
      quietHoursEnd: this.quietHoursEnd,
    };
  }

  /**
   * Called when Win32 reports the user stepped away from keyboard/mouse.
   * Speculatively pre-generates an AI candidate in the background.
   */
  onUserAway(awayMinutes: number) {
    this.setUserPresent(false);
    if (!this.enabled) return;
    const awaySnap = ContextIntelligence.capture("greeting_return", awayMinutes * 60);
    const settings = this.getCompanionSettings();
    const consent = this.getPrivacyConsent();
    void SpeculativeEngine.onUserAway(
      awaySnap,
      settings,
      consent,
      CompanionMemory.getRecentExclusions(),
      this.localEndpoint,
      this.localModel,
    );
  }

  /**
   * Called when Win32 GetLastInputInfo reports the user returned after an idle period.
   */
  onUserReturned(awayMinutes: number, resolvedName?: string | null) {
    this.setUserPresent(true);
    // If user stepped away for 15+ minutes, break continuous fatigue streak
    if (awayMinutes >= 15) {
      this.activeMinutes = 0;
    }
    if (!this.enabled) return;

    const now = Date.now();
    if (!MessagePolicyEngine.canTriggerReturnGreeting(now)) {
      return;
    }

    if (resolvedName && resolvedName.trim().length > 0) {
      this._detectedGreetingName = resolvedName.trim();
    }

    const returnSnap = ContextIntelligence.capture("greeting_return", awayMinutes * 60);
    const settings = this.getCompanionSettings();

    // 1. Try consuming fresh speculative candidate from queue
    const specResult = SpeculativeEngine.consumeIfValid(returnSnap, settings, now);
    let chosenText: string | null = null;
    let chosenId = "";
    let chosenCategory: CompanionCategory = "greeting_return";
    let chosenProvider = "static";

    if (specResult.candidate) {
      const sanitized = MessageValidator.sanitizeAndValidate(specResult.candidate.text);
      if (sanitized && !CompanionMemory.isDuplicateOrSimilar(sanitized, now)) {
        chosenText = sanitized;
        chosenId = specResult.candidate.id;
        chosenCategory = specResult.candidate.category;
        chosenProvider = specResult.candidate.provider;
      }
    }

    // 2. If no valid candidate, use instant deterministic fallback (<1ms)
    if (!chosenText) {
      const fallback = DeterministicCatalog.resolveFallback(returnSnap, "greeting_return");
      chosenText = fallback.text;
      chosenId = fallback.id;
      chosenCategory = fallback.category;
      chosenProvider = "static";
    }

    // 3. Record in memory and deliver to Dynamic Island
    CompanionMemory.record(chosenText, chosenCategory, chosenProvider, now);
    MessagePolicyEngine.recordDelivered(chosenCategory, now);
    this.lastTriggerTime = now;

    this.displayMessage({
      id: chosenId,
      text: chosenText,
      bot: true,
      category: chosenCategory,
      timestamp: now,
    });
  }

  /**
   * User clicks or pokes Mochi directly in the Notch.
   */
  poke() {
    const now = Date.now();
    const u = this.resolvedGreetingName;
    const c = this.companionName;
    const cp = companionPossessive(c);
    const thoughts = [
      u ? `${cp} right here with you, ${u}! 💙` : `${cp} right here with you! 💙`,
      u ? `You're doing awesome work today, ${u}! 🚀` : "You're doing awesome work today! 🚀",
      u ? `${c} loves keeping you company here ✨` : `${c} loves keeping you company here ✨`,
      u ? `Remember to stretch and hydrate, ${u} 🧘` : "Remember to stretch and hydrate! 🧘",
      u ? `Keep up the momentum, ${u} — you're on a roll 🔥` : "Keep up the momentum — you're on a roll 🔥",
      u ? `Always in your corner, ${u}! 🌟` : "Always in your corner! 🌟",
      u ? `Step by step, ${u} — great things take time 🛠️` : "Step by step — great things take time 🛠️",
      u ? `High five from ${c}, ${u}! Keep building ✨` : `High five from ${c}! Keep building ✨`,
      u ? `Need a second, ${u}? Take a deep breath 🌿` : "Need a second? Take a deep breath 🌿",
      u ? `You and ${c} make a great team, ${u}! 💻` : `You and ${c} make a great team! 💻`,
    ];
    const text = thoughts[Math.floor(Math.random() * thoughts.length)];
    this.displayMessage({
      id: "poke_interaction",
      text,
      bot: true,
      category: "classic",
      timestamp: now,
    });
  }

  /**
   * Immediately shows a warm Notch welcome after completing first-run companion naming.
   */
  triggerOnboardingWelcome(companionName?: string, skipped = false) {
    this.hasGreetedOnLaunch = true;
    const c = resolveCompanionName({ companionName: companionName ?? State.settings.companionName });
    const u = this.resolvedGreetingName;
    const now = Date.now();
    const hour = new Date(now).getHours();
    const greeting =
      hour >= 5 && hour < 12 ? "Good morning" :
      hour >= 12 && hour < 17 ? "Good afternoon" :
      "Good evening";
    const text = skipped
      ? (u ? `${greeting}, ${u}! I'm ${c}, right here in your Notch ✨` : `${greeting}! I'm ${c}, right here in your Notch ✨`)
      : (u ? `${greeting}, ${u}! I'm ${c}. Happy to be here ✨` : `${greeting}! I'm ${c}. Happy to be here ✨`);
    this.displayMessage({
      id: "onboarding_welcome",
      text,
      bot: true,
      category: "classic",
      timestamp: now,
    });
  }

  /**
   * Immediately triggers a preview message (for Settings or test buttons).
   */
  triggerPreview(sampleText?: string) {
    const u = this.resolvedGreetingName;
    const c = this.companionName;
    const text = sampleText || (u ? `Hey ${u}! ${c} is active 🌟` : `Hey! ${c} is active 🌟`);
    this.displayMessage({
      id: "preview_test",
      text,
      bot: true,
      category: "classic",
      timestamp: Date.now(),
    });
  }

  private displayMessage(display: WelcomeMessageDisplay) {
    this.lastTriggerTime = Date.now();
    this.current = display;
    this.restartTimer();
    this.notify();
  }

  private restartTimer() {
    if (this.timer != null) {
      window.clearTimeout(this.timer);
    }
    const t = window.setTimeout(() => {
      this.timer = null;
      this.dismiss();
    }, WelcomeMessageManager.DISPLAY_DURATION_MS) as unknown as { unref?: () => void };
    t?.unref?.();
    this.timer = t as unknown as number;
  }

  computeStateVector(awayMinutes: number, now: number): WelcomeStateVector {
    const d = new Date(now);
    const hour = d.getHours() + d.getMinutes() / 60;
    const dayOfWeek = d.getDay();

    const sessionWorkHours = Math.max(0.1, (now - this.sessionStartTime) / (1000 * 60 * 60));
    const minutesSinceWater = this.lastWaterNudgeTime > 0
      ? Math.max(0, (now - this.lastWaterNudgeTime) / (1000 * 60))
      : 60;

    let timeOfDay: CircadianPhase;
    if (hour >= 5 && hour < 8.5) timeOfDay = "dawn";
    else if (hour >= 8.5 && hour < 12) timeOfDay = "morning_peak";
    else if (hour >= 12 && hour < 13.5) timeOfDay = "midday_lunch";
    else if (hour >= 13.5 && hour < 17) timeOfDay = "afternoon_slump";
    else if (hour >= 17 && hour < 19.5) timeOfDay = "golden_hour";
    else if (hour >= 19.5 && hour < 23) timeOfDay = "evening_wrapup";
    else timeOfDay = "deep_night";

    const wardrobe = State.settings?.mochiOutfit || "none";

    return {
      awayMinutes,
      timeOfDay,
      hour,
      dayOfWeek,
      sessionWorkHours,
      minutesSinceWater,
      userName: this.resolvedGreetingName,
      wardrobe,
    };
  }

  matchesPhase(candidatePhase: string | undefined, currentPhase: CircadianPhase): boolean {
    if (!candidatePhase) return false;
    if (candidatePhase === currentPhase) return true;
    if (currentPhase === "morning" && (candidatePhase === "dawn" || candidatePhase === "morning_peak")) return true;
    if (currentPhase === "dawn" && (candidatePhase === "morning" || candidatePhase === "morning_peak")) return true;
    if (currentPhase === "morning_peak" && (candidatePhase === "morning" || candidatePhase === "dawn")) return true;
    if (currentPhase === "afternoon" && (candidatePhase === "midday_lunch" || candidatePhase === "afternoon_slump")) return true;
    if (currentPhase === "midday_lunch" && (candidatePhase === "afternoon" || candidatePhase === "afternoon_slump")) return true;
    if (currentPhase === "afternoon_slump" && (candidatePhase === "afternoon" || candidatePhase === "midday_lunch")) return true;
    if (currentPhase === "evening" && (candidatePhase === "golden_hour" || candidatePhase === "evening_wrapup")) return true;
    if (currentPhase === "golden_hour" && (candidatePhase === "evening" || candidatePhase === "evening_wrapup")) return true;
    if (currentPhase === "evening_wrapup" && (candidatePhase === "evening" || candidatePhase === "golden_hour" || candidatePhase === "night")) return true;
    if (currentPhase === "night" && (candidatePhase === "evening_wrapup" || candidatePhase === "deep_night" || candidatePhase === "night")) return true;
    if (currentPhase === "deep_night" && (candidatePhase === "deep_night" || candidatePhase === "night")) return true;
    return false;
  }

  selectBestMessage(s: WelcomeStateVector, filterCategory?: string): WelcomeMessageItem {
    const candidates = this.getCatalog();
    let bestScore = -Infinity;
    let selected = candidates[0];

    // Determine how many recent IDs to track (scale with catalog size for meaningful variety)
    const recentWindow = Math.min(20, Math.floor(candidates.length * 0.08));

    for (const c of candidates) {
      // Category filter: when a category filter is specified (e.g. "greeting_return"),
      // exclude non-matching wellness or unrelated categories.
      if (filterCategory === "greeting_return") {
        if (c.category === "hydration" || c.category === "posture") {
          continue; // Hydration & posture NEVER intrude into return greetings!
        }
      } else if (filterCategory && c.category !== filterCategory) {
        continue;
      }

      let score = c.weight ?? 10;

      // Recency penalty — stronger penalty for recently shown messages
      const recentIdx = this.recentHistory.indexOf(c.id);
      if (recentIdx !== -1) {
        // Stronger penalty for most recent; fades with distance in history
        const recencyFraction = 1 - (recentIdx / recentWindow);
        score -= Math.round(30 * Math.max(0, recencyFraction));
      }

      // Wellness filter
      if (!this.wellnessEnabled && (c.category === "hydration" || c.category === "posture")) {
        continue;
      }

      // Priority 1: Deep night protection
      if (s.timeOfDay === "deep_night") {
        if (c.phase === "deep_night") score += 40;
        else score -= 15;
      }

      // Priority 2: Hydration & Health Nudges (when working > 1.5h and no water > 50m)
      if (c.category === "hydration") {
        if (s.minutesSinceWater >= 50 && s.sessionWorkHours >= 1.5) {
          score += 45;
        } else {
          score -= 10;
        }
      }

      if (c.category === "posture") {
        if (s.sessionWorkHours >= 2) score += 20;
        else score -= 10;
      }

      // Time of day affinity
      if (c.phase && this.matchesPhase(c.phase, s.timeOfDay)) {
        score += 20;
      }

      // Absence duration affinity
      if (c.minAwayMinutes != null) {
        if (s.awayMinutes >= c.minAwayMinutes) {
          score += 15;
        } else {
          score -= 30; // Not away long enough
        }
      }

      // Work streak affinity
      if (c.minWorkHours != null) {
        if (s.sessionWorkHours >= c.minWorkHours) {
          score += 20;
        } else {
          score -= 20;
        }
      }

      // Day of week affinity
      if (c.dayOfWeek != null) {
        if (c.dayOfWeek === s.dayOfWeek) score += 18;
        else score -= 15;
      }

      // Wardrobe synergy (normalized to a gentle +6 flavor touch, avoiding monopoly)
      if (c.wardrobe != null) {
        if (s.wardrobe.toLowerCase().includes(c.wardrobe.toLowerCase())) score += 6;
        else score -= 12;
      }

      // Category diversity bonus: prefer categories not seen in recent history
      const recentCategories = this.recentHistory.slice(0, 5).map(id => {
        const item = candidates.find(x => x.id === id);
        return item?.category ?? "";
      });
      const recentCategoryCount = recentCategories.filter(cat => cat === c.category).length;
      if (recentCategoryCount >= 2) score -= 8; // Soft penalty for over-represented category

      if (score > bestScore) {
        bestScore = score;
        selected = c;
      }
    }

    // Push selected ID into front of history (bounded ring buffer of 20)
    this.recentHistory.unshift(selected.id);
    if (this.recentHistory.length > 20) {
      this.recentHistory.pop();
    }

    return selected;
  }

  private getCatalog(): WelcomeMessageItem[] {
    return [
      // ═══════════════════════════════════════════════════════════════════
      // ORIGINAL CATALOG — 35 scripts. Do NOT modify or remove these.
      // ═══════════════════════════════════════════════════════════════════

      // ── Core & Classics ──
      {
        id: "core_back",
        category: "classic",
        template: (u) => (u ? `Hey ${u}, you're back! ✨` : "Hey, you're back! ✨"),
        weight: 15,
      },
      {
        id: "core_seat_warm",
        category: "classic",
        template: (u) => {
          const c = this.companionName;
          return u ? `${c} kept your seat warm, ${u}!` : `${c} kept your seat warm!`;
        },
        weight: 14,
      },
      {
        id: "core_missed_you",
        category: "classic",
        template: (u) => (u ? `Missed you, ${u}! Let's do this 🚀` : "Missed you! Let's do this 🚀"),
        weight: 14,
      },
      {
        id: "core_look_who",
        category: "classic",
        template: (u) => (u ? `Look who's back! Hey ${u} 💙` : "Look who's back! 💙"),
        weight: 13,
      },

      // ── Hydration & Health ──
      {
        id: "health_water_urgent",
        category: "hydration",
        template: (u) => (u ? `Hey ${u}! Grab a glass of water right now 💧` : "Hey! Grab a glass of water right now 💧"),
        minWaterMinutes: 50,
        weight: 22,
      },
      {
        id: "health_water_check",
        category: "hydration",
        template: (u) => (u ? `${u}, did you hydrate during your break? 💧` : "Did you hydrate during your break? 💧"),
        minWaterMinutes: 60,
        weight: 20,
      },
      {
        id: "health_posture",
        category: "posture",
        template: (u) => (u ? `Welcome back ${u}! Roll those shoulders back 🧘` : "Welcome back! Roll those shoulders back 🧘"),
        minWorkHours: 2,
        weight: 20,
      },
      {
        id: "health_eyes",
        category: "posture",
        template: (u) => (u ? `${u}, look 20 feet away for 20 seconds ✨` : "Look 20 feet away for 20 seconds ✨"),
        minWorkHours: 2.5,
        weight: 18,
      },
      {
        id: "health_breath",
        category: "posture",
        template: (u) => (u ? `Welcome back, ${u}! Deep breath in... and exhale 🌿` : "Welcome back! Deep breath in... and exhale 🌿"),
        weight: 16,
      },

      // ── Circadian Time Rhythm ──
      {
        id: "time_dawn_coffee",
        category: "circadian",
        phase: "dawn",
        template: (u) => (u ? `Fresh start, ${u}! First coffee poured? ☕` : "Fresh start! First coffee poured? ☕"),
        weight: 20,
      },
      {
        id: "time_dawn_quiet",
        category: "circadian",
        phase: "dawn",
        template: (u) => (u ? `Early bird ${u}! Quiet hours are the best 🌅` : "Early bird! Quiet hours are the best 🌅"),
        weight: 18,
      },
      {
        id: "time_morning_crush",
        category: "circadian",
        phase: "morning_peak",
        template: (u) => (u ? `Welcome back, ${u}! Ready to crush this morning? 🚀` : "Welcome back! Ready to crush this morning? 🚀"),
        weight: 20,
      },
      {
        id: "time_morning_momentum",
        category: "circadian",
        phase: "morning_peak",
        template: (u) => (u ? `Hey ${u}! Your momentum is looking great today ✨` : "Hey! Your momentum is looking great today ✨"),
        weight: 18,
      },
      {
        id: "time_lunch_food",
        category: "circadian",
        phase: "midday_lunch",
        template: (u) => (u ? `Welcome back, ${u}! Hope you had a tasty lunch 🥪` : "Welcome back! Hope you had a tasty lunch 🥪"),
        weight: 22,
      },
      {
        id: "time_slump_beater",
        category: "circadian",
        phase: "afternoon_slump",
        template: (u) => {
          const cp = companionPossessive(this.companionName);
          return u ? `Hey ${u}! 2 PM slump? Not on ${cp} watch ⚡` : `Hey! 2 PM slump? Not on ${cp} watch ⚡`;
        },
        weight: 22,
      },
      {
        id: "time_afternoon_second_wind",
        category: "circadian",
        phase: "afternoon_slump",
        template: (u) => (u ? `Welcome back, ${u}! Second wind incoming 🚀` : "Welcome back! Second wind incoming 🚀"),
        weight: 18,
      },
      {
        id: "time_golden_hour",
        category: "circadian",
        phase: "golden_hour",
        template: (u) => (u ? `Golden hour, ${u}! Take a look at all you built 🌇` : "Golden hour! Take a look at all you built 🌇"),
        weight: 20,
      },
      {
        id: "time_evening_wrapup",
        category: "circadian",
        phase: "evening_wrapup",
        template: (u) => (u ? `Almost wrap-up time, ${u}! You earned your evening ✨` : "Almost wrap-up time! You earned your evening ✨"),
        weight: 20,
      },
      {
        id: "time_night_owl",
        category: "circadian",
        phase: "deep_night",
        template: (u) => (u ? `Welcome back, ${u}! Night owl mode active 🦉` : "Welcome back! Night owl mode active 🦉"),
        weight: 25,
      },
      {
        id: "time_night_bed",
        category: "circadian",
        phase: "deep_night",
        template: (u) => (u ? `Still awake, ${u}? Your bed misses you too 🌙` : "Still awake? Your bed misses you too 🌙"),
        weight: 24,
      },
      {
        id: "time_night_care",
        category: "circadian",
        phase: "deep_night",
        template: (u) => (u ? `Hey ${u}, wrap up soon, okay? Rest is essential 💙` : "Hey, wrap up soon, okay? Rest is essential 💙"),
        weight: 23,
      },

      // ── Computer Usage Milestones ──
      {
        id: "work_streak_high",
        category: "work_streak",
        template: (u) => (u ? `You've been super productive today, ${u}! Keep flowing ✨` : "You've been super productive today! Keep flowing ✨"),
        minWorkHours: 3,
        weight: 20,
      },
      {
        id: "work_streak_marathon",
        category: "work_streak",
        template: (u) => (u ? `${u}, you've put in serious work today! Don't overdo it ☕` : "You've put in serious work today! Don't overdo it ☕"),
        minWorkHours: 5,
        weight: 22,
      },

      // ── Duration Aware ──
      {
        id: "dur_short_stretch",
        category: "duration",
        template: (u) => (u ? `Nice quick break, ${u}! Ready to dive back in?` : "Nice quick break! Ready to dive back in?"),
        minAwayMinutes: 3,
        weight: 14,
      },
      {
        id: "dur_long_reunion",
        category: "duration",
        template: (u) => {
          const c = this.companionName;
          return u ? `You're back! ${c} missed you so much, ${u}! 💙` : `You're back! ${c} missed you so much! 💙`;
        },
        minAwayMinutes: 30,
        weight: 25,
      },

      // ── Day of Week ──
      {
        id: "day_monday",
        category: "day_of_week",
        dayOfWeek: 1, // Monday
        template: (u) => (u ? `Happy Monday, ${u}! Let's set the tempo for the week 🚀` : "Happy Monday! Let's set the tempo for the week 🚀"),
        weight: 18,
      },
      {
        id: "day_friday",
        category: "day_of_week",
        dayOfWeek: 5, // Friday
        template: (u) => (u ? `Happy Friday, ${u}! Almost weekend mode 🏖️` : "Happy Friday! Almost weekend mode 🏖️"),
        weight: 20,
      },
      {
        id: "day_weekend",
        category: "day_of_week",
        dayOfWeek: 6, // Saturday
        template: (u) => (u ? `Weekend building, ${u}? Love the dedication! 🛠️` : "Weekend building? Love the dedication! 🛠️"),
        weight: 18,
      },

      // ── Seasonal & Wardrobe ──
      {
        id: "wardrobe_santa",
        category: "wardrobe",
        wardrobe: "santa",
        template: (u) => (u ? `Brrr! Welcome back into the warm, ${u} ❄️` : "Brrr! Welcome back into the warm ❄️"),
        weight: 14,
      },
      {
        id: "wardrobe_sunglasses",
        category: "wardrobe",
        wardrobe: "sunglasses",
        template: (u) => (u ? `Looking cool, ${u}! Welcome back 😎` : "Looking cool! Welcome back 😎"),
        weight: 14,
      },

      // ═══════════════════════════════════════════════════════════════════
      // EXPANDED CATALOG v2 — 220 additional scripts.
      // All messages: 6–20 words, single sentence where possible.
      // ═══════════════════════════════════════════════════════════════════

      // ── Focus & Productivity (30) ──
      { id: "focus_01", category: "work_streak", template: (u) => (u ? `Locked in, ${u}? Keep that flow going! ⚡` : "Locked in? Keep that flow going! ⚡"), weight: 14 },
      { id: "focus_02", category: "work_streak", template: (u) => (u ? `${u}, your focus game is strong today!` : "Your focus game is strong today!"), weight: 13 },
      { id: "focus_03", category: "work_streak", template: (u) => (u ? `Deep work mode suits you, ${u}!` : "Deep work mode suits you!"), minWorkHours: 1.5, weight: 14 },
      { id: "focus_04", category: "work_streak", template: (u) => (u ? `${u}, you're on a roll. Don't stop now!` : "You're on a roll. Don't stop now!"), weight: 13 },
      { id: "focus_05", category: "work_streak", template: (u) => (u ? `Flow state achieved, ${u}! Ride it ✨` : "Flow state achieved! Ride it ✨"), minWorkHours: 1, weight: 14 },
      { id: "focus_06", category: "work_streak", template: (u) => (u ? `Tasks falling like dominoes today, ${u}!` : "Tasks falling like dominoes today!"), weight: 13 },
      { id: "focus_07", category: "work_streak", template: (u) => (u ? `${u}, solid session. Keep that energy up!` : "Solid session. Keep that energy up!"), minWorkHours: 2, weight: 13 },
      { id: "focus_08", category: "work_streak", template: (_u) => "One thing at a time. You've got this! 🎯", weight: 12 },
      { id: "focus_09", category: "work_streak", template: (u) => { const c = this.companionName; return u ? `${u}, ${c} sees you working hard. Well done!` : `${c} sees you working hard. Well done!`; }, weight: 12 },
      { id: "focus_10", category: "work_streak", template: (u) => (u ? `Momentum is everything, ${u}. Keep moving!` : "Momentum is everything. Keep moving!"), weight: 12 },
      { id: "focus_11", category: "work_streak", template: (_u) => "Heads down, good things happening! 💙", minWorkHours: 1, weight: 12 },
      { id: "focus_12", category: "work_streak", template: (u) => (u ? `${u}, another focused hour in the books 📚` : "Another focused hour in the books 📚"), minWorkHours: 1, weight: 13 },
      { id: "focus_13", category: "work_streak", template: (_u) => "Doing it one step at a time — nice!", weight: 11 },
      { id: "focus_14", category: "work_streak", template: (u) => { const cp = companionPossessive(this.companionName); return u ? `${u}, ${cp} impressed by your consistency!` : `${cp} impressed by your consistency!`; }, minWorkHours: 2, weight: 13 },
      { id: "focus_15", category: "work_streak", template: (_u) => "Brain fully online! Good things ahead ✨", weight: 11 },
      { id: "focus_16", category: "work_streak", template: (u) => (u ? `Staying in the zone, ${u}? Perfect.` : "Staying in the zone? Perfect."), weight: 12 },
      { id: "focus_17", category: "work_streak", template: (_u) => "Tick, tick... progress is building! 🔧", minWorkHours: 1, weight: 11 },
      { id: "focus_18", category: "work_streak", template: (u) => (u ? `${u}, quiet and productive. Love to see it!` : "Quiet and productive. Love to see it!"), weight: 12 },
      { id: "focus_19", category: "work_streak", template: (_u) => "Session looking solid. Keep the pace! 🏃", minWorkHours: 1.5, weight: 11 },
      { id: "focus_20", category: "work_streak", template: (u) => (u ? `Making it happen, ${u}! 🌟` : "Making it happen! 🌟"), weight: 12 },
      { id: "focus_21", category: "work_streak", template: (_u) => "Zero distractions mode — respect! ⚡", weight: 11 },
      { id: "focus_22", category: "work_streak", template: (u) => (u ? `${u}, focused sprints beat marathon multitasking!` : "Focused sprints beat marathon multitasking!"), weight: 12 },
      { id: "focus_23", category: "work_streak", template: (_u) => "Good work takes good focus. You've got both!", weight: 11 },
      { id: "focus_24", category: "work_streak", template: (u) => (u ? `${u}, three hours deep. You're on fire 🔥` : "Three hours deep. You're on fire 🔥"), minWorkHours: 3, weight: 14 },
      { id: "focus_25", category: "work_streak", template: (_u) => `The work is happening. ${companionPossessive(this.companionName)} rooting for you!`, weight: 11 },
      { id: "focus_26", category: "work_streak", template: (u) => (u ? `Crush it, ${u}! Today's a big day 🚀` : "Crush it! Today's a big day 🚀"), weight: 12 },
      { id: "focus_27", category: "work_streak", template: (_u) => "Steady progress beats rushed bursts. Well done!", weight: 11 },
      { id: "focus_28", category: "work_streak", template: (u) => (u ? `${u}, dialled in and delivering!` : "Dialled in and delivering!"), minWorkHours: 1, weight: 12 },
      { id: "focus_29", category: "work_streak", template: (_u) => "Persistence pays off. Keep pushing forward!", weight: 11 },
      { id: "focus_30", category: "work_streak", template: (u) => (u ? `${u}, another productive minute ticked! ⏱️` : "Another productive minute ticked! ⏱️"), minWorkHours: 2, weight: 11 },

      // ── Coding & Development (30) ──
      { id: "code_01", category: "work_streak", template: (u) => (u ? `Shipping code today, ${u}? Nice! 🚀` : "Shipping code today? Nice! 🚀"), weight: 14 },
      { id: "code_02", category: "work_streak", template: (_u) => "Bugs don't stand a chance today! 🐛⚡", weight: 13 },
      { id: "code_03", category: "work_streak", template: (u) => (u ? `${u}, commit early. Commit often!` : "Commit early. Commit often!"), weight: 12 },
      { id: "code_04", category: "work_streak", template: (_u) => "Every line of code is a step forward. Keep going!", weight: 12 },
      { id: "code_05", category: "work_streak", template: (u) => (u ? `${u}, deep in the editor? Don't forget to save!` : "Deep in the editor? Don't forget to save!"), weight: 13 },
      { id: "code_06", category: "work_streak", template: (_u) => "Debug mode active! You'll crack it soon 🔍", weight: 12 },
      { id: "code_07", category: "work_streak", template: (u) => (u ? `${u}, writing great code takes great coffee ☕` : "Writing great code takes great coffee ☕"), weight: 12 },
      { id: "code_08", category: "work_streak", template: (_u) => "Stack traces exist so you can fix them! 💪", weight: 11 },
      { id: "code_09", category: "work_streak", template: (u) => (u ? `${u}, clean code is happy code ✨` : "Clean code is happy code ✨"), weight: 12 },
      { id: "code_10", category: "work_streak", template: (_u) => "PRs merged. Code shipped. Good day ahead!", weight: 11 },
      { id: "code_11", category: "work_streak", template: (u) => (u ? `${u}, great engineers take breaks too!` : "Great engineers take breaks too!"), minWorkHours: 2, weight: 13 },
      { id: "code_12", category: "work_streak", template: (_u) => "Every function you write matters. Build on! 🛠️", weight: 11 },
      { id: "code_13", category: "work_streak", template: (u) => (u ? `${u}, hours of coding? Remember to commit!` : "Hours of coding? Remember to commit!"), minWorkHours: 2, weight: 13 },
      { id: "code_14", category: "work_streak", template: (_u) => "That tricky bug? One more look might do it.", weight: 11 },
      { id: "code_15", category: "work_streak", template: (u) => (u ? `${u}, reading docs? Good engineers always do!` : "Reading docs? Good engineers always do!"), weight: 12 },
      { id: "code_16", category: "work_streak", template: (_u) => "Code review time! Fresh eyes catch everything.", weight: 11 },
      { id: "code_17", category: "work_streak", template: (u) => (u ? `${u}, tests are green means good things ahead 🟢` : "Tests are green means good things ahead 🟢"), weight: 13 },
      { id: "code_18", category: "work_streak", template: (_u) => "Refactoring counts as progress too! ♻️", weight: 11 },
      { id: "code_19", category: "work_streak", template: (u) => (u ? `${u}, your IDE misses you when you're away!` : "Your IDE misses you when you're away!"), weight: 12 },
      { id: "code_20", category: "work_streak", template: (_u) => "If it compiles, it's a win. Keep iterating! 💡", weight: 11 },
      { id: "code_21", category: "work_streak", template: (u) => (u ? `${u}, three hours in VS Code? Time to stretch!` : "Three hours in VS Code? Time to stretch!"), minWorkHours: 3, weight: 14 },
      { id: "code_22", category: "work_streak", template: (_u) => "The terminal is your friend. Use it well!", weight: 11 },
      { id: "code_23", category: "work_streak", template: (u) => (u ? `${u}, one more function and then a quick break!` : "One more function and then a quick break!"), weight: 12 },
      { id: "code_24", category: "work_streak", template: (_u) => "Good architecture starts with good thinking. Take a breath!", weight: 12 },
      { id: "code_25", category: "work_streak", template: (u) => (u ? `${u}, commit your work before the break!` : "Commit your work before the break!"), weight: 12 },
      { id: "code_26", category: "work_streak", template: (_u) => "That feature is almost there. So close! 🎯", weight: 11 },
      { id: "code_27", category: "work_streak", template: (u) => (u ? `${u}, keyboard clicking means things are happening!` : "Keyboard clicking means things are happening!"), weight: 11 },
      { id: "code_28", category: "work_streak", template: (_u) => "Ship it. Iterate. That's how progress works!", weight: 11 },
      { id: "code_29", category: "work_streak", template: (u) => (u ? `${u}, error messages are just puzzles. Solve them!` : "Error messages are just puzzles. Solve them!"), weight: 12 },
      { id: "code_30", category: "work_streak", template: (_u) => "Every commit is a small victory. Well done! 🏆", weight: 12 },

      // ── Break & Wellness (25) ──
      { id: "break_01", category: "posture", template: (u) => (u ? `${u}, five minute walk? Your legs will thank you!` : "Five minute walk? Your legs will thank you!"), weight: 14 },
      { id: "break_02", category: "posture", template: (_u) => "Quick stretch — shoulders, neck, wrists. Go!", weight: 13 },
      { id: "break_03", category: "posture", template: (u) => (u ? `${u}, blink slowly a few times. Screen dryness is real!` : "Blink slowly a few times. Screen dryness is real!"), weight: 13 },
      { id: "break_04", category: "posture", template: (u) => { const c = this.companionName; return u ? `Still working, ${u}? ${c} recommends a quick stretch 🧘` : `Still working? ${c} recommends a quick stretch 🧘`; }, minWorkHours: 1.5, weight: 14 },
      { id: "break_05", category: "posture", template: (u) => (u ? `${u}, chin up, shoulders back. Quick posture reset!` : "Chin up, shoulders back. Quick posture reset!"), weight: 13 },
      { id: "break_06", category: "posture", template: (_u) => "Look out the window for 20 seconds. Eyes need rest!", weight: 13 },
      { id: "break_07", category: "posture", template: (u) => (u ? `${u}, wrist roll time! 10 seconds each side 🤲` : "Wrist roll time! 10 seconds each side 🤲"), minWorkHours: 2, weight: 13 },
      { id: "break_08", category: "posture", template: (_u) => "Neck tilt left, neck tilt right. Gentle stretch!", weight: 12 },
      { id: "break_09", category: "posture", template: (u) => (u ? `${u}, breathe in for 4, hold for 4, out for 4 🌿` : "Breathe in for 4, hold for 4, out for 4 🌿"), weight: 13 },
      { id: "break_10", category: "posture", template: (_u) => "Quick eye massage. Close them, gentle circles!", minWorkHours: 2, weight: 12 },
      { id: "break_11", category: "posture", template: (u) => (u ? `${u}, arms above your head! Big stretch time 🙌` : "Arms above your head! Big stretch time 🙌"), weight: 13 },
      { id: "break_12", category: "posture", template: (_u) => `Ten slow shoulder rolls. ${companionPossessive(this.companionName)} counting!`, weight: 12 },
      { id: "break_13", category: "posture", template: (u) => (u ? `${u}, feet flat on the floor. Grounded and focused!` : "Feet flat on the floor. Grounded and focused!"), weight: 11 },
      { id: "break_14", category: "posture", template: (_u) => "Jaw unclenched? Check your face tension!", weight: 12 },
      { id: "break_15", category: "posture", template: (u) => (u ? `${u}, take three slow breaths before diving back in 🌿` : "Take three slow breaths before diving back in 🌿"), weight: 12 },
      { id: "break_16", category: "posture", template: (_u) => "Raise your arms, roll your neck. Quick reset!", weight: 12 },
      { id: "break_17", category: "posture", template: (u) => (u ? `${u}, short break now means longer focus later!` : "Short break now means longer focus later!"), minWorkHours: 1.5, weight: 13 },
      { id: "break_18", category: "posture", template: (_u) => "Rest your eyes on something green. Nature heals!", weight: 11 },
      { id: "break_19", category: "posture", template: (u) => (u ? `${u}, palm your eyes gently. Warm and dark for 10 seconds!` : "Palm your eyes gently. Warm and dark for 10 seconds!"), weight: 12 },
      { id: "break_20", category: "posture", template: (_u) => "Scroll less, think more. Rest those thumbs!", weight: 11 },
      { id: "break_21", category: "posture", template: (u) => (u ? `${u}, move your fingers, flex your hands. Type better after!` : "Move your fingers, flex your hands. Type better after!"), weight: 12 },
      { id: "break_22", category: "posture", template: (_u) => "Even 90 seconds of movement resets your brain!", minWorkHours: 1, weight: 12 },
      { id: "break_23", category: "posture", template: (u) => (u ? `${u}, step away from the screen. Even two minutes helps!` : "Step away from the screen. Even two minutes helps!"), minWorkHours: 2, weight: 13 },
      { id: "break_24", category: "posture", template: (_u) => "You can't pour from an empty cup. Rest up!", minWorkHours: 3, weight: 14 },
      { id: "break_25", category: "posture", template: (u) => { const c = this.companionName; return u ? `${u}, ${c} orders: one genuine rest break. Now!` : `${c} orders: one genuine rest break. Now!`; }, minWorkHours: 4, weight: 15 },

      // ── Hydration Reminders (20) ──
      { id: "hydro_01", category: "hydration", template: (u) => (u ? `${u}, sip some water. Right now!` : "Sip some water. Right now!"), minWaterMinutes: 45, weight: 20 },
      { id: "hydro_02", category: "hydration", template: (_u) => `${this.companionName} thinks it's a good time for a glass of water 💧`, minWaterMinutes: 50, weight: 19 },
      { id: "hydro_03", category: "hydration", template: (u) => { const c = this.companionName; return u ? `${u}, time to hydrate. ${c} insists!` : `Time to hydrate. ${c} insists!`; }, minWaterMinutes: 55, weight: 20 },
      { id: "hydro_04", category: "hydration", template: (_u) => "Thirsty yet? Pour yourself a glass of water! 🥛", minWaterMinutes: 45, weight: 18 },
      { id: "hydro_05", category: "hydration", template: (u) => (u ? `${u}, water first. Then code!` : "Water first. Then code!"), minWaterMinutes: 60, weight: 19 },
      { id: "hydro_06", category: "hydration", template: (_u) => "Coffee's great, but water is greater. Balance it out!", minWaterMinutes: 50, weight: 17 },
      { id: "hydro_07", category: "hydration", template: (u) => (u ? `${u}, stay hydrated. Your focus depends on it 💧` : "Stay hydrated. Your focus depends on it 💧"), minWaterMinutes: 60, weight: 18 },
      { id: "hydro_08", category: "hydration", template: (_u) => `Quick hydration check! ${this.companionName} wants to see you drink up!`, minWaterMinutes: 45, weight: 17 },
      { id: "hydro_09", category: "hydration", template: (u) => (u ? `${u}, three sips of water. Go!` : "Three sips of water. Go!"), minWaterMinutes: 50, weight: 19 },
      { id: "hydro_10", category: "hydration", template: (_u) => "Dehydration is sneaky. Grab your water bottle now!", minWaterMinutes: 55, weight: 18 },
      { id: "hydro_11", category: "hydration", template: (u) => (u ? `${u}, best performance needs best hydration 💧` : "Best performance needs best hydration 💧"), minWaterMinutes: 60, weight: 17 },
      { id: "hydro_12", category: "hydration", template: (_u) => "Water o'clock! Don't forget while you work ⏰", minWaterMinutes: 45, weight: 16 },
      { id: "hydro_13", category: "hydration", template: (u) => { const cp = companionPossessive(this.companionName); return u ? `${u}, ${cp} counting your water breaks. Have one!` : `${cp} counting your water breaks. Have one!`; }, minWaterMinutes: 50, weight: 17 },
      { id: "hydro_14", category: "hydration", template: (_u) => "Refill that bottle. One step and a sip!", minWaterMinutes: 45, weight: 16 },
      { id: "hydro_15", category: "hydration", template: (u) => (u ? `${u}, still no water? That changes now 💧` : "Still no water? That changes now 💧"), minWaterMinutes: 70, weight: 20 },
      { id: "hydro_16", category: "hydration", template: (_u) => "Water does what coffee can't. Drink up!", minWaterMinutes: 60, weight: 17 },
      { id: "hydro_17", category: "hydration", template: (u) => (u ? `${u}, quick water break before the next task!` : "Quick water break before the next task!"), minWaterMinutes: 50, weight: 17 },
      { id: "hydro_18", category: "hydration", template: (_u) => "Glass half empty? Fill it up and drink it! 💧", minWaterMinutes: 45, weight: 16 },
      { id: "hydro_19", category: "hydration", template: (u) => (u ? `${u}, that headache? Probably needs water!` : "That headache? Probably needs water!"), minWaterMinutes: 65, weight: 18 },
      { id: "hydro_20", category: "hydration", template: (_u) => "No snacks without water. Grab both! 🥤", minWaterMinutes: 50, weight: 16 },

      // ── Workflow Awareness (25) ──
      { id: "workflow_01", category: "work_streak", template: (_u) => "Tab chaos? One window, one task. Try it!", weight: 12 },
      { id: "workflow_02", category: "work_streak", template: (u) => (u ? `${u}, context switching is expensive. Batch your tasks!` : "Context switching is expensive. Batch your tasks!"), weight: 13 },
      { id: "workflow_03", category: "work_streak", template: (_u) => "15-minute sprint. One thing. No distractions. Go!", weight: 12 },
      { id: "workflow_04", category: "work_streak", template: (u) => (u ? `${u}, app-hopping? Pick one and finish it!` : "App-hopping? Pick one and finish it!"), weight: 12 },
      { id: "workflow_05", category: "work_streak", template: (_u) => "Notifications off. Focus on. Let's build!", weight: 11 },
      { id: "workflow_06", category: "work_streak", template: (u) => (u ? `${u}, close unused tabs. Clear screen, clear mind!` : "Close unused tabs. Clear screen, clear mind!"), weight: 12 },
      { id: "workflow_07", category: "work_streak", template: (_u) => "What's the one thing that moves you forward today?", weight: 11 },
      { id: "workflow_08", category: "work_streak", template: (u) => (u ? `${u}, prioritise ruthlessly. Not everything is urgent!` : "Prioritise ruthlessly. Not everything is urgent!"), weight: 12 },
      { id: "workflow_09", category: "work_streak", template: (_u) => "Done is better than perfect. Ship it! 🚀", weight: 11 },
      { id: "workflow_10", category: "work_streak", template: (u) => (u ? `${u}, write it down before you forget it!` : "Write it down before you forget it!"), weight: 12 },
      { id: "workflow_11", category: "work_streak", template: (_u) => "Switching apps too often? Pick one and stick with it!", weight: 12 },
      { id: "workflow_12", category: "work_streak", template: (u) => (u ? `${u}, block out 30 minutes for deep work. Worth it!` : "Block out 30 minutes for deep work. Worth it!"), weight: 12 },
      { id: "workflow_13", category: "work_streak", template: (_u) => "Big task? Break it down. Start with step one!", weight: 11 },
      { id: "workflow_14", category: "work_streak", template: (u) => (u ? `${u}, Pomodoro it — 25 minutes focus, 5 minutes break!` : "Pomodoro it — 25 minutes focus, 5 minutes break!"), weight: 12 },
      { id: "workflow_15", category: "work_streak", template: (_u) => "Start with the hardest thing. Rest gets easier!", weight: 11 },
      { id: "workflow_16", category: "work_streak", template: (u) => (u ? `${u}, single tasking beats multitasking every time!` : "Single tasking beats multitasking every time!"), weight: 12 },
      { id: "workflow_17", category: "work_streak", template: (_u) => "Inbox can wait. The work in front of you can't!", weight: 11 },
      { id: "workflow_18", category: "work_streak", template: (u) => (u ? `${u}, time blocking is your friend today!` : "Time blocking is your friend today!"), weight: 11 },
      { id: "workflow_19", category: "work_streak", template: (_u) => "Make the next ten minutes count. What's the task?", weight: 11 },
      { id: "workflow_20", category: "work_streak", template: (u) => (u ? `${u}, three priorities. That's all you need today!` : "Three priorities. That's all you need today!"), weight: 12 },
      { id: "workflow_21", category: "work_streak", template: (_u) => "A tidy desktop means a tidy mind. Quick declutter?", weight: 11 },
      { id: "workflow_22", category: "work_streak", template: (u) => (u ? `${u}, kill that background music if it's distracting!` : "Kill that background music if it's distracting!"), weight: 11 },
      { id: "workflow_23", category: "work_streak", template: (_u) => "Quick task list review. Are your priorities right?", weight: 11 },
      { id: "workflow_24", category: "work_streak", template: (u) => (u ? `${u}, if a task takes under 2 minutes, do it now!` : "If a task takes under 2 minutes, do it now!"), weight: 12 },
      { id: "workflow_25", category: "work_streak", template: (_u) => "Energy dipping? Switch to an easier task for 10 minutes!", weight: 12 },

      // ── Positive Reinforcement (25) ──
      { id: "praise_01", category: "work_streak", template: (u) => (u ? `${u}, look at that progress! Genuinely impressive!` : "Look at that progress! Genuinely impressive!"), minWorkHours: 2, weight: 13 },
      { id: "praise_02", category: "work_streak", template: (_u) => "Session goal hit! You should feel good about that!", weight: 12 },
      { id: "praise_03", category: "work_streak", template: (u) => { const c = this.companionName; return u ? `${u}, ${c} is genuinely proud of you today!` : `${c} is genuinely proud of you today!`; }, weight: 12 },
      { id: "praise_04", category: "work_streak", template: (_u) => "Great things are built brick by brick. Keep stacking! 🧱", weight: 12 },
      { id: "praise_05", category: "work_streak", template: (u) => (u ? `${u}, hard work beats talent when talent doesn't work hard!` : "Hard work beats talent when talent doesn't work hard!"), minWorkHours: 3, weight: 13 },
      { id: "praise_06", category: "work_streak", template: (_u) => "You showed up today. That already counts for a lot!", weight: 11 },
      { id: "praise_07", category: "work_streak", template: (u) => (u ? `${u}, solid output today. Genuinely!` : "Solid output today. Genuinely!"), minWorkHours: 2, weight: 12 },
      { id: "praise_08", category: "work_streak", template: (_u) => "Every great project starts with great days like this!", weight: 11 },
      { id: "praise_09", category: "work_streak", template: (u) => (u ? `${u}, you're building something that matters. Keep going!` : "You're building something that matters. Keep going!"), weight: 12 },
      { id: "praise_10", category: "work_streak", template: (_u) => "Discipline today, results tomorrow. Nicely done! 🎯", minWorkHours: 2, weight: 12 },
      { id: "praise_11", category: "work_streak", template: (u) => (u ? `${u}, quiet consistency beats loud sprints every time!` : "Quiet consistency beats loud sprints every time!"), weight: 11 },
      { id: "praise_12", category: "work_streak", template: (_u) => `${companionPossessive(this.companionName)} impressed. You've been at it for a while now!`, minWorkHours: 2, weight: 13 },
      { id: "praise_13", category: "work_streak", template: (u) => (u ? `${u}, future you will thank today you for this!` : "Future you will thank today you for this!"), weight: 12 },
      { id: "praise_14", category: "work_streak", template: (_u) => "Progress is progress, no matter the pace. Well done!", weight: 11 },
      { id: "praise_15", category: "work_streak", template: (u) => (u ? `${u}, you're doing better than you think!` : "You're doing better than you think!"), weight: 12 },
      { id: "praise_16", category: "work_streak", template: (_u) => "Good work deserves good recognition. Take a moment! 🌟", minWorkHours: 3, weight: 13 },
      { id: "praise_17", category: "work_streak", template: (u) => (u ? `${u}, smart and steady always wins the race!` : "Smart and steady always wins the race!"), weight: 11 },
      { id: "praise_18", category: "work_streak", template: (_u) => `Incredible focus today. ${this.companionName} sees everything! ✨`, minWorkHours: 2, weight: 12 },
      { id: "praise_19", category: "work_streak", template: (u) => (u ? `${u}, another great chapter in a great story!` : "Another great chapter in a great story!"), weight: 11 },
      { id: "praise_20", category: "work_streak", template: (_u) => "If effort was currency, you'd be rich today! 💰", minWorkHours: 3, weight: 12 },
      { id: "praise_21", category: "work_streak", template: (u) => (u ? `${u}, keep that energy. It's contagious!` : "Keep that energy. It's contagious!"), weight: 11 },
      { id: "praise_22", category: "work_streak", template: (_u) => "Half the battle is just showing up. You showed up! 🏅", weight: 11 },
      { id: "praise_23", category: "work_streak", template: (u) => { const cp = companionPossessive(this.companionName); return u ? `${u}, ${cp} rooting for you. Always!` : `${cp} rooting for you. Always!`; }, weight: 12 },
      { id: "praise_24", category: "work_streak", template: (_u) => "Look how far you've come! Really impressive work!", minWorkHours: 4, weight: 13 },
      { id: "praise_25", category: "work_streak", template: (u) => (u ? `${u}, top-tier effort today. Absolutely top-tier!` : "Top-tier effort today. Absolutely top-tier!"), minWorkHours: 3, weight: 12 },

      // ── Daily Motivation (20) ──
      { id: "motiv_01", category: "classic", template: (u) => (u ? `${u}, today is a great day to build something new!` : "Today is a great day to build something new!"), weight: 12 },
      { id: "motiv_02", category: "classic", template: (_u) => "Start small. Grow fast. Ship often. That's the formula!", weight: 11 },
      { id: "motiv_03", category: "classic", template: (u) => (u ? `${u}, it doesn't have to be perfect. Ship it!` : "It doesn't have to be perfect. Ship it!"), weight: 11 },
      { id: "motiv_04", category: "classic", template: (_u) => "The best time to start was yesterday. Next best is now!", weight: 12 },
      { id: "motiv_05", category: "classic", template: (u) => (u ? `${u}, small consistent effort beats big irregular bursts!` : "Small consistent effort beats big irregular bursts!"), weight: 12 },
      { id: "motiv_06", category: "classic", template: (_u) => "Make today count. Even one task done well matters!", weight: 11 },
      { id: "motiv_07", category: "classic", template: (u) => (u ? `${u}, clarity comes from doing, not from planning!` : "Clarity comes from doing, not from planning!"), weight: 11 },
      { id: "motiv_08", category: "classic", template: (_u) => "Every expert was once a beginner. Keep learning! 📚", weight: 11 },
      { id: "motiv_09", category: "classic", template: (u) => (u ? `${u}, the work is the reward. Enjoy it!` : "The work is the reward. Enjoy it!"), weight: 11 },
      { id: "motiv_10", category: "classic", template: (_u) => "Energy flows where attention goes. Direct it well! ⚡", weight: 11 },
      { id: "motiv_11", category: "classic", template: (u) => (u ? `${u}, what's the one thing that will move the needle today?` : "What's the one thing that will move the needle today?"), weight: 12 },
      { id: "motiv_12", category: "classic", template: (_u) => "Creative problems need creative minds. You've got one! 🧠", weight: 11 },
      { id: "motiv_13", category: "classic", template: (u) => (u ? `${u}, hard days make great stories later!` : "Hard days make great stories later!"), weight: 11 },
      { id: "motiv_14", category: "classic", template: (_u) => "Excellence is a habit. Keep building yours! 🏅", weight: 11 },
      { id: "motiv_15", category: "classic", template: (u) => (u ? `${u}, some days you build. Some days you plan. Both count!` : "Some days you build. Some days you plan. Both count!"), weight: 12 },
      { id: "motiv_16", category: "classic", template: (_u) => `${this.companionName} believes today is going to be a good one! 🌟`, weight: 11 },
      { id: "motiv_17", category: "classic", template: (u) => (u ? `${u}, curiosity is your superpower. Use it!` : "Curiosity is your superpower. Use it!"), weight: 11 },
      { id: "motiv_18", category: "classic", template: (_u) => "Take it one task, one hour, one win at a time!", weight: 11 },
      { id: "motiv_19", category: "classic", template: (u) => (u ? `${u}, better than yesterday. That's all that matters!` : "Better than yesterday. That's all that matters!"), weight: 12 },
      { id: "motiv_20", category: "classic", template: (_u) => "Every day that you try is a day you grow. Keep going!", weight: 11 },

      // ── Welcome-Back Messages (15) ──
      { id: "return_01", category: "classic", template: (u) => (u ? `Welcome back, ${u}! Ready to pick up where you left off?` : "Welcome back! Ready to pick up where you left off?"), minAwayMinutes: 5, weight: 16 },
      { id: "return_02", category: "classic", template: (u) => { const cp = companionPossessive(this.companionName); return u ? `${u}'s back! ${cp} been keeping the screen warm 🌟` : `You're back! ${cp} been keeping the screen warm 🌟`; }, minAwayMinutes: 10, weight: 15 },
      { id: "return_03", category: "classic", template: (u) => (u ? `Hey ${u}, good break? Let's finish what we started!` : "Good break? Let's finish what we started!"), minAwayMinutes: 5, weight: 14 },
      { id: "return_04", category: "classic", template: (_u) => `Welcome back! ${this.companionName} kept things running smoothly ✨`, minAwayMinutes: 5, weight: 13 },
      { id: "return_05", category: "classic", template: (u) => (u ? `${u}, refreshed and ready? Let's keep the momentum!` : "Refreshed and ready? Let's keep the momentum!"), minAwayMinutes: 10, weight: 14 },
      { id: "return_06", category: "classic", template: (_u) => "Welcome back to your corner of the internet! 💙", minAwayMinutes: 15, weight: 14 },
      { id: "return_07", category: "classic", template: (u) => { const c = this.companionName; return u ? `${u}, ${c} saved your place. Right here, ready to go!` : `${c} saved your place. Right here, ready to go!`; }, minAwayMinutes: 10, weight: 14 },
      { id: "return_08", category: "classic", template: (_u) => "Back at the desk! Time to make it count ✨", minAwayMinutes: 5, weight: 13 },
      { id: "return_09", category: "classic", template: (u) => (u ? `${u}, break over! On to the next great thing!` : "Break over! On to the next great thing!"), minAwayMinutes: 5, weight: 13 },
      { id: "return_10", category: "classic", template: (_u) => "Session resuming. Let's pick that thought back up!", minAwayMinutes: 10, weight: 13 },
      { id: "return_11", category: "classic", template: (u) => (u ? `${u}, the desk called and you answered!` : "The desk called and you answered!"), minAwayMinutes: 10, weight: 12 },
      { id: "return_12", category: "classic", template: (_u) => `${companionPossessive(this.companionName)} glad you're back. Now, what's the plan?`, minAwayMinutes: 15, weight: 13 },
      { id: "return_13", category: "classic", template: (u) => (u ? `${u}, stepping back into it. Just like that!` : "Stepping back into it. Just like that!"), minAwayMinutes: 5, weight: 12 },
      { id: "return_14", category: "classic", template: (_u) => "Back at the helm! What needs attention right now?", minAwayMinutes: 10, weight: 12 },
      { id: "return_15", category: "classic", template: (u) => (u ? `Hey ${u}! Good to have you back at the controls 🎮` : "Good to have you back at the controls 🎮"), minAwayMinutes: 15, weight: 14 },

      // ── Context-Switching Awareness (20) ──
      { id: "switch_01", category: "work_streak", template: (_u) => "Lots of windows? Pick the most important one!", weight: 12 },
      { id: "switch_02", category: "work_streak", template: (u) => (u ? `${u}, app-switching a lot? One thing at a time helps!` : "App-switching a lot? One thing at a time helps!"), weight: 12 },
      { id: "switch_03", category: "work_streak", template: (_u) => "Every switch costs focus. Make each one count!", weight: 11 },
      { id: "switch_04", category: "work_streak", template: (u) => (u ? `${u}, juggling too much? Narrow it down to one task!` : "Juggling too much? Narrow it down to one task!"), weight: 12 },
      { id: "switch_05", category: "work_streak", template: (_u) => "Research mode? Stay in one tab until you have your answer!", weight: 12 },
      { id: "switch_06", category: "work_streak", template: (u) => (u ? `${u}, Slack and code at once? That's context tax!` : "Slack and code at once? That's context tax!"), weight: 11 },
      { id: "switch_07", category: "work_streak", template: (_u) => "Open tabs are open loops. Close what you don't need!", weight: 12 },
      { id: "switch_08", category: "work_streak", template: (u) => (u ? `${u}, multitasking myth alert! Sequential focus wins!` : "Multitasking myth alert! Sequential focus wins!"), weight: 12 },
      { id: "switch_09", category: "work_streak", template: (_u) => "Back and forth? Pick a direction and go for it!", weight: 11 },
      { id: "switch_10", category: "work_streak", template: (u) => (u ? `${u}, the browser can wait. Finish that code first!` : "The browser can wait. Finish that code first!"), weight: 12 },
      { id: "switch_11", category: "work_streak", template: (_u) => "Twitter, Slack, IDE, repeat? Break the cycle!", weight: 12 },
      { id: "switch_12", category: "work_streak", template: (u) => (u ? `${u}, focused context means less context-switching tax!` : "Focused context means less context-switching tax!"), weight: 11 },
      { id: "switch_13", category: "work_streak", template: (_u) => "Every open app is a mental thread. Reduce the count!", weight: 12 },
      { id: "switch_14", category: "work_streak", template: (u) => (u ? `${u}, notifications off for the next hour. Try it!` : "Notifications off for the next hour. Try it!"), weight: 12 },
      { id: "switch_15", category: "work_streak", template: (_u) => "The deepest work happens in the longest sessions!", weight: 11 },
      { id: "switch_16", category: "work_streak", template: (u) => (u ? `${u}, research done? Time to execute what you found!` : "Research done? Time to execute what you found!"), weight: 12 },
      { id: "switch_17", category: "work_streak", template: (_u) => "Less switching, more shipping. That's the mantra!", weight: 11 },
      { id: "switch_18", category: "work_streak", template: (u) => (u ? `${u}, mind scattered? A five-minute journal clears it!` : "Mind scattered? A five-minute journal clears it!"), weight: 12 },
      { id: "switch_19", category: "work_streak", template: (_u) => "Chaos mode? Pick ONE task and do just that!", weight: 12 },
      { id: "switch_20", category: "work_streak", template: (u) => (u ? `${u}, app rotation slows you down. Settle in!` : "App rotation slows you down. Settle in!"), weight: 11 },

      // ── General Personalized Interactions (10) ──
      { id: "personal_01", category: "classic", template: (u) => { const cp = companionPossessive(this.companionName); return u ? `${u}, ${cp} happy you're here! Let's make it a great session!` : `${cp} happy you're here! Let's make it a great session!`; }, weight: 13 },
      { id: "personal_02", category: "classic", template: (_u) => `Every session with you is ${companionPossessive(this.companionName)} favourite! 💙`, weight: 12 },
      { id: "personal_03", category: "classic", template: (u) => { const c = this.companionName; return u ? `${u}, you and ${c} are a team. Best team!` : `You and ${c} are a team. Best team!`; }, weight: 12 },
      { id: "personal_04", category: "classic", template: (_u) => `${this.companionName} noticed you've been building a lot. Impressive stuff!`, weight: 12 },
      { id: "personal_05", category: "classic", template: (u) => { const cp = companionPossessive(this.companionName); return u ? `${u}, whatever you're working on, ${cp} cheering you on!` : `Whatever you're working on, ${cp} cheering you on!`; }, weight: 12 },
      { id: "personal_06", category: "classic", template: (_u) => `Together we work better! ${companionPossessive(this.companionName)} right here 🤝`, weight: 11 },
      { id: "personal_07", category: "classic", template: (u) => { const cp = companionPossessive(this.companionName); return u ? `${u}, ${cp} here if you need a little nudge!` : `${cp} here if you need a little nudge!`; }, weight: 12 },
      { id: "personal_08", category: "classic", template: (_u) => "Good vibes only. Good work always. That's the way! ✨", weight: 11 },
      { id: "personal_09", category: "classic", template: (u) => { const cp = companionPossessive(this.companionName); return u ? `${u}, ${cp} rooting for you. Every single day!` : `${cp} rooting for you. Every single day!`; }, weight: 12 },
      { id: "personal_10", category: "classic", template: (_u) => `You + ${this.companionName} = unstoppable. Let's prove it today! 🚀`, weight: 12 },

      // ── Additional Day-of-Week variants ──
      { id: "day_tuesday", category: "day_of_week", dayOfWeek: 2, template: (u) => (u ? `Happy Tuesday, ${u}! Week's warming up nicely!` : "Happy Tuesday! Week's warming up nicely!"), weight: 15 },
      { id: "day_wednesday", category: "day_of_week", dayOfWeek: 3, template: (u) => (u ? `Midweek check-in, ${u}! Halfway there 💪` : "Midweek check-in! Halfway there 💪"), weight: 16 },
      { id: "day_thursday", category: "day_of_week", dayOfWeek: 4, template: (u) => (u ? `${u}, Friday's almost here. One more strong day!` : "Friday's almost here. One more strong day!"), weight: 16 },
      { id: "day_sunday", category: "day_of_week", dayOfWeek: 0, template: (u) => (u ? `Sunday session, ${u}? Respect the hustle 🛠️` : "Sunday session? Respect the hustle 🛠️"), weight: 15 },

      // ── Additional Circadian ──
      { id: "time_dawn_silent", category: "circadian", phase: "dawn", template: (_u) => "Pre-dawn hustle! The world is still asleep. Use it! 🌅", weight: 17 },
      { id: "time_morning_sharp", category: "circadian", phase: "morning_peak", template: (u) => (u ? `${u}, mind is freshest in the morning. Use it well!` : "Mind is freshest in the morning. Use it well!"), weight: 17 },
      { id: "time_lunch_rest", category: "circadian", phase: "midday_lunch", template: (_u) => "Midday fuel break! Eat well for an energised afternoon 🥗", weight: 20 },
      { id: "time_slump_tea", category: "circadian", phase: "afternoon_slump", template: (u) => (u ? `${u}, 3 PM? Perfect time for tea and a quick reset ☕` : "3 PM? Perfect time for tea and a quick reset ☕"), weight: 19 },
      { id: "time_golden_wrap", category: "circadian", phase: "golden_hour", template: (_u) => "Golden hour! What one thing can you close out before evening?", weight: 18 },
      { id: "time_evening_save", category: "circadian", phase: "evening_wrapup", template: (u) => (u ? `${u}, save your work and log off when you're ready!` : "Save your work and log off when you're ready!"), weight: 18 },
      { id: "time_night_stars", category: "circadian", phase: "deep_night", template: (u) => (u ? `${u}, late nights are magic. But sleep is too 💙` : "Late nights are magic. But sleep is too 💙"), weight: 22 },

      // ── Additional Wardrobe ──
      { id: "wardrobe_witch", category: "wardrobe", wardrobe: "witch", template: (u) => (u ? `${u}, spooky season vibes! Welcome back 🎃` : "Spooky season vibes! Welcome back 🎃"), weight: 13 },
      { id: "wardrobe_bunny", category: "wardrobe", wardrobe: "bunny", template: (u) => (u ? `Hoppy to see you, ${u}! Back to work we go 🐰` : "Hoppy to see you! Back to work we go 🐰"), weight: 13 },
      { id: "wardrobe_party", category: "wardrobe", wardrobe: "party", template: (u) => (u ? `Party hat on, ${u}! Let's make today a celebration! 🎉` : "Party hat on! Let's make today a celebration! 🎉"), weight: 13 },
    ];
  }
}

export const GlobalWelcomeMessages = WelcomeMessageManager.shared;
