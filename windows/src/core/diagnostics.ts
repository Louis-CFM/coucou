/**
 * Startup Lifecycle Diagnostics Logger
 * Records high-resolution timestamps for startup milestones.
 */

export interface StartupMilestone {
  name: string;
  timestamp: number;
  durationSinceStart: number;
}

class StartupDiagnostics {
  private startTime = typeof performance !== "undefined" ? performance.now() : Date.now();
  private milestones: StartupMilestone[] = [];

  record(name: string) {
    const now = typeof performance !== "undefined" ? performance.now() : Date.now();
    const milestone: StartupMilestone = {
      name,
      timestamp: now,
      durationSinceStart: Math.round(now - this.startTime),
    };
    this.milestones.push(milestone);
    if (typeof window !== "undefined" && (window as unknown as { __coucouDebug?: boolean }).__coucouDebug) {
      console.log(`[CouCou Startup] +${milestone.durationSinceStart}ms: ${name}`);
    }
  }

  getMilestones(): readonly StartupMilestone[] {
    return this.milestones;
  }
}

export const Diagnostics = new StartupDiagnostics();
