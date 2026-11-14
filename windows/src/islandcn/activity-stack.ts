// ── Activity Stack Engine for Dynamic Island ──────────────────────────────
// Manages live activities, priority ordering, and computes layout presentations.

import type { IslandActivity, IslandPresentation } from "./types";

export class ActivityStack {
  private activities = new Map<string, IslandActivity>();
  private listeners = new Set<(presentation: IslandPresentation, active: IslandActivity[]) => void>();

  public start(activity: IslandActivity): {
    update: (patch: Partial<IslandActivity>) => void;
    end: () => void;
  } {
    const act: IslandActivity = {
      ...activity,
      timestamp: activity.timestamp ?? Date.now(),
      priority: activity.priority ?? 0,
    };
    this.activities.set(act.id, act);
    this.notify();

    return {
      update: (patch: Partial<IslandActivity>) => {
        const existing = this.activities.get(act.id);
        if (existing) {
          this.activities.set(act.id, { ...existing, ...patch });
          this.notify();
        }
      },
      end: () => {
        this.activities.delete(act.id);
        this.notify();
      },
    };
  }

  public getActivities(): IslandActivity[] {
    return Array.from(this.activities.values()).sort(
      (a, b) => (b.priority ?? 0) - (a.priority ?? 0) || (b.timestamp ?? 0) - (a.timestamp ?? 0)
    );
  }

  public getPresentation(): IslandPresentation {
    const count = this.activities.size;
    if (count === 0) return "idle";
    if (count === 1) return "compact";
    return "split";
  }

  public subscribe(listener: (presentation: IslandPresentation, active: IslandActivity[]) => void): () => void {
    this.listeners.add(listener);
    listener(this.getPresentation(), this.getActivities());
    return () => this.listeners.delete(listener);
  }

  private notify(): void {
    const pres = this.getPresentation();
    const list = this.getActivities();
    for (const l of this.listeners) {
      try {
        l(pres, list);
      } catch (e) {
        console.error("ActivityStack listener error:", e);
      }
    }
  }
}

export const globalActivityStack = new ActivityStack();
