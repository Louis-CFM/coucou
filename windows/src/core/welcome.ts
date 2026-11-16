// Mochi Contextual Companion & Ambient Messaging Engine (#1055 & Dynamic Island Notch).
// Evaluates a multi-factor live state vector (screen time, hydration intervals,
// circadian rhythm, absence duration, and day-of-week) to select heartwarming,
// personal messages with the user's name ({name}), displayed alongside Mochi in the small notch.

import { State } from "./state";

export type CircadianPhase =
  | "dawn"
  | "morning_peak"
  | "midday_lunch"
  | "afternoon_slump"
  | "golden_hour"
  | "evening_wrapup"
  | "deep_night";

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

  userName = "Madhan";
  enabled = true;
  wellnessEnabled = true;
  hydrationIntervalMinutes = 45; // default 45 min

  static get shared(): WelcomeMessageManager {
    if (!WelcomeMessageManager.instance) {
      WelcomeMessageManager.instance = new WelcomeMessageManager();
    }
    return WelcomeMessageManager.instance;
  }

  private constructor() {
    this.loadState();
    this.startAmbientTicker();
  }

  private loadState() {
    try {
      if (typeof localStorage !== "undefined") {
        const en = localStorage.getItem("coucou_welcome_enabled");
        if (en != null) this.enabled = en === "true";
        const well = localStorage.getItem("coucou_wellness_enabled");
        if (well != null) this.wellnessEnabled = well === "true";
        const u = localStorage.getItem("coucou_user_name");
        if (u && u.trim().length > 0) this.userName = u.trim();
        const water = localStorage.getItem("coucou_last_water_time");
        if (water) this.lastWaterNudgeTime = Number(water) || Date.now();
        const intv = localStorage.getItem("coucou_hydration_interval");
        if (intv) this.hydrationIntervalMinutes = Number(intv) || 45;
      }
    } catch {}
  }

  saveState() {
    try {
      if (typeof localStorage !== "undefined") {
        localStorage.setItem("coucou_welcome_enabled", String(this.enabled));
        localStorage.setItem("coucou_wellness_enabled", String(this.wellnessEnabled));
        localStorage.setItem("coucou_user_name", this.userName);
        localStorage.setItem("coucou_last_water_time", String(this.lastWaterNudgeTime));
        localStorage.setItem("coucou_hydration_interval", String(this.hydrationIntervalMinutes));
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
    const hour = d.getHours() + d.getMinutes() / 60;
    const u = this.userName;

    let text = u ? `Hey ${u}, good to see you! ✨` : "Hey, good to see you! ✨";
    if (hour >= 5 && hour < 11.5) {
      text = u ? `Good morning, ${u}! Ready to crush today? 🚀` : "Good morning! Ready to crush today? 🚀";
    } else if (hour >= 11.5 && hour < 17) {
      text = u ? `Afternoon momentum looking great, ${u} ✨` : "Afternoon momentum looking great! ✨";
    } else if (hour >= 17 && hour < 22) {
      text = u ? `Evening building, ${u}! Let's make it count 🌇` : "Evening building! Let's make it count 🌇";
    } else {
      text = u ? `Night owl mode, ${u}! Mochi's here with you 🌙` : "Night owl mode! Mochi's here with you 🌙";
    }

    this.displayMessage({
      id: "launch_greeting",
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
    if (!this.enabled) return;

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
      const u = this.userName;
      const hydrationTemplates = [
        u ? `Hey ${u}! Grab a glass of water right now 💧` : "Hey! Grab a glass of water right now 💧",
        u ? `${u}, quick water break to keep your energy up! 💧` : "Quick water break to keep your energy up! 💧",
        u ? `Hydration check, ${u}! Take a refreshing sip 🥤` : "Hydration check! Take a refreshing sip 🥤",
      ];
      const text = hydrationTemplates[Math.floor(Math.random() * hydrationTemplates.length)];
      this.lastWaterNudgeTime = now;
      this.saveState();
      this.displayMessage({
        id: "ambient_hydration",
        text,
        bot: true,
        category: "hydration",
        timestamp: now,
      });
      return;
    }

    // 2. Posture & 20-20-20 Eye Relief Nudge
    if (this.wellnessEnabled && minutesSincePosture >= 90 && sessionWorkHours >= 1.5) {
      const u = this.userName;
      const postureTemplates = [
        u ? `${u}, look 20 feet away for 20 seconds ✨` : "Look 20 feet away for 20 seconds ✨",
        u ? `Quick posture check, ${u}! Roll those shoulders back 🧘` : "Quick posture check! Roll those shoulders back 🧘",
        u ? `Deep breath in, ${u}... and exhale 🌿` : "Deep breath in... and exhale 🌿",
      ];
      const text = postureTemplates[Math.floor(Math.random() * postureTemplates.length)];
      this.lastPostureNudgeTime = now;
      this.displayMessage({
        id: "ambient_posture",
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
      const u = this.userName;
      let phaseText = "";
      if (currentPhase === "afternoon_slump") {
        phaseText = u ? `2 PM slump? Not on Mochi's watch, ${u} ⚡` : "2 PM slump? Not on Mochi's watch ⚡";
      } else if (currentPhase === "golden_hour") {
        phaseText = u ? `Golden hour, ${u}! Look at all you built today 🌇` : "Golden hour! Look at all you built today 🌇";
      } else if (currentPhase === "evening_wrapup") {
        phaseText = u ? `Almost wrap-up time, ${u}! You earned your evening ✨` : "Almost wrap-up time! You earned your evening ✨";
      } else if (currentPhase === "deep_night") {
        phaseText = u ? `Still awake, ${u}? Don't forget to rest soon 🌙` : "Still awake? Don't forget to rest soon 🌙";
      }

      this.lastCircadianPhase = currentPhase;
      if (phaseText) {
        this.displayMessage({
          id: `circadian_${currentPhase}`,
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

  /**
   * Called when Win32 GetLastInputInfo reports the user returned after an idle period.
   */
  onUserReturned(awayMinutes: number, resolvedName?: string | null) {
    if (!this.enabled) return;

    const now = Date.now();
    if (now - this.lastTriggerTime < WelcomeMessageManager.RETURN_COOLDOWN_MS) {
      return;
    }

    if (resolvedName && resolvedName.trim().length > 0) {
      this.userName = resolvedName.trim();
    }

    const stateVector = this.computeStateVector(awayMinutes, now);
    const message = this.selectBestMessage(stateVector);

    if (message) {
      if (message.category === "hydration") {
        this.lastWaterNudgeTime = now;
        this.saveState();
      }

      this.recentHistory.push(message.id);
      if (this.recentHistory.length > 8) {
        this.recentHistory.shift();
      }

      const text = message.template(this.userName);
      this.displayMessage({
        id: message.id,
        text,
        bot: true,
        category: message.category,
        timestamp: now,
      });
    }
  }

  /**
   * User clicks or pokes Mochi directly in the Notch.
   */
  poke() {
    const now = Date.now();
    const u = this.userName;
    const thoughts = [
      u ? `Mochi's right here with you, ${u}! 💙` : "Mochi's right here with you! 💙",
      u ? `You're doing awesome work today, ${u}! 🚀` : "You're doing awesome work today! 🚀",
      u ? `Focus mode active! Let's build something great ✨` : "Focus mode active! Let's build something great ✨",
      u ? `Remember to stretch and hydrate, ${u} 🧘` : "Remember to stretch and hydrate! 🧘",
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
   * Immediately triggers a preview message (for Settings or test buttons).
   */
  triggerPreview(sampleText?: string) {
    const text = sampleText || (this.userName ? `Hey ${this.userName}! Mochi companion is active 🌟` : "Hey! Mochi companion is active 🌟");
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
      userName: this.userName,
      wardrobe,
    };
  }

  selectBestMessage(s: WelcomeStateVector): WelcomeMessageItem {
    const candidates = this.getCatalog();
    let bestScore = -Infinity;
    let selected = candidates[0];

    for (const c of candidates) {
      let score = c.weight ?? 10;

      // Recency penalty
      if (this.recentHistory.includes(c.id)) {
        score -= 25;
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
      if (c.phase && c.phase === s.timeOfDay) {
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

      if (score > bestScore) {
        bestScore = score;
        selected = c;
      }
    }

    return selected;
  }

  private getCatalog(): WelcomeMessageItem[] {
    return [
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
        template: (u) => (u ? `Mochi kept your seat warm, ${u}!` : "Mochi kept your seat warm!"),
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
        template: (u) => (u ? `Hey ${u}! 2 PM slump? Not on Mochi's watch ⚡` : "Hey! 2 PM slump? Not on Mochi's watch ⚡"),
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
        template: (u) => (u ? `You're back! Mochi missed you so much, ${u}! 💙` : "You're back! Mochi missed you so much! 💙"),
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
    ];
  }
}

export const GlobalWelcomeMessages = WelcomeMessageManager.shared;
