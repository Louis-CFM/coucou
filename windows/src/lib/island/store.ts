import type { IslandClock } from "./clock";
import type { IslandMotion } from "./motion";
import type {
  Activity,
  ActivityContent,
  ActivityHandle,
  ActivityUpdate,
  ExpandReason,
  IslandApi,
  IslandPresentation,
  PresentationKind,
} from "./types";

export interface IslandSnapshot {
  /** Running activities, primary first. */
  activities: readonly Activity[];
  expanded: { id: string; reason: ExpandReason } | null;
  /** Counts changes to what the island shows, so two changes at the same clock time stay distinct. */
  changeId: number;
  /** Clock time (ms) of the last change to what the island shows. Springs start from here. */
  changedAt: number;
  /** The last change snaps into place instead of animating (devtools resets use this). */
  instant: boolean;
  /** Which part is swelling under a press (from touch-down until it expands or springs back). */
  pressed: PressTarget | null;
  /**
   * Clock time (ms) a long-pressed bubble will join the pill (its expansion), known from the moment
   * the press is decided; null otherwise. The renderer cuts the bubble's content a little before.
   */
  joining: number | null;
  /** Per group, the activity brought forward by an alert or `expand()`; else the first started shows. */
  front: Readonly<Record<string, string>>;
  /** A group handing over to a hidden activity: none of its activities shows until the expansion. */
  handoff: string | null;
}

/** The pill (primary activity) or the detached bubble (second activity). */
export type PressTarget = "pill" | "bubble";

/** What the island draws for a snapshot, plus the identity that decides when content crossfades. */
export interface IslandScene {
  presentation: IslandPresentation;
  /** Same key means the content updates in place; a new key crossfades. */
  contentKey: string;
  /** Spoken summary of what is showing. */
  label: string;
  /** Activity under the pill (the attached one when split). */
  primary: Activity | null;
  /** Activity in the detached bubble. */
  detached: Activity | null;
}

const byPriority = (a: Activity, b: Activity) => b.priority - a.priority || a.order - b.order;

/** Content identity of an activity: a crossfade update bumps its revision, so its layer is replaced. */
const keyOf = (activity: Activity) => (activity.revision > 0 ? `${activity.id}#${activity.revision}` : activity.id);

/** The activity of `group` on show: the one brought forward, else the first started. */
const shownOf = (snapshot: Pick<IslandSnapshot, "activities" | "front">, group: string) => {
  const members = snapshot.activities.filter((a) => a.group === group);
  const forward = snapshot.front[group];
  if (forward !== undefined && members.some((a) => a.id === forward)) return forward;
  return members.reduce<Activity | null>((first, a) => (first === null || a.order < first.order ? a : first), null)?.id ?? null;
};

/** Whether an activity shows: ungrouped ones always, grouped ones in turn and never mid-handoff. */
export const isShown = (snapshot: Pick<IslandSnapshot, "activities" | "front" | "handoff">, activity: Activity) =>
  activity.group === null || (snapshot.handoff !== activity.group && shownOf(snapshot, activity.group) === activity.id);

export const deriveScene = (snapshot: IslandSnapshot): IslandScene => {
  const [first, second] = snapshot.activities.filter((a) => isShown(snapshot, a));
  const expanded = snapshot.expanded ? snapshot.activities.find((a) => a.id === snapshot.expanded?.id) : undefined;
  if (expanded) {
    return {
      presentation: { kind: "expanded", ...expanded.content.expanded },
      contentKey: `expanded:${keyOf(expanded)}`,
      label: expanded.label,
      primary: expanded,
      detached: null,
    };
  }
  if (!first) {
    return { presentation: { kind: "idle" }, contentKey: "idle", label: "", primary: null, detached: null };
  }
  if (!second) {
    return {
      presentation: { kind: "compact", ...first.content.compact },
      contentKey: `compact:${keyOf(first)}`,
      label: first.label,
      primary: first,
      detached: null,
    };
  }
  // iOS 27 shows both activities' compact content in the split; `minimal` is the fallback the
  // renderer switches to when that doesn't fit.
  return {
    presentation: {
      kind: "minimal",
      attached: minimalOf(first.content),
      detached: minimalOf(second.content),
      split: { attached: first.content.compact ?? {}, detached: second.content.compact ?? {} },
    },
    contentKey: `minimal:${keyOf(first)}:${keyOf(second)}`,
    label: `${first.label}, ${second.label}`,
    primary: first,
    detached: second,
  };
};

const minimalOf = (content: ActivityContent) => content.minimal ?? content.compact?.leading ?? null;

const mergeContent = (content: ActivityContent, update: ActivityUpdate): ActivityContent => ({
  compact: update.compact ? { ...content.compact, ...update.compact } : content.compact,
  minimal: "minimal" in update ? update.minimal : content.minimal,
  expanded: update.expanded ? { ...content.expanded, ...update.expanded } : content.expanded,
});

export interface IslandStore {
  getSnapshot(): IslandSnapshot;
  subscribe(listener: () => void): () => void;
  api: IslandApi;
  /** Runs `change` so the resulting state snaps into place with no animation. */
  instantly(change: () => void): void;
  /** Ends every activity and clears pending timers, without animation. */
  reset(): void;
  /**
   * Starts a press: the pill swells from touch-down. Still held at `press.decide`, it expands that
   * activity at `longPress`; an island with nothing to expand swells and springs back.
   */
  press(target: PressTarget): void;
  /** Ends a press. A release before `press.decide` is a tap: it calls `onPress` and the swell springs back. */
  release(options?: { cancel?: boolean }): void;
}

export const createIslandStore = (options: { clock: IslandClock; motion: () => IslandMotion }): IslandStore => {
  const { clock } = options;
  let snapshot: IslandSnapshot = {
    activities: [],
    expanded: null,
    changeId: 0,
    changedAt: clock.now(),
    instant: false,
    pressed: null,
    joining: null,
    front: {},
    handoff: null,
  };
  /** Timers of the press in progress (decide, expand, spring back). */
  let pressTimers: (() => void)[] = [];
  /** The press in progress: what is held, when it went down, and whether it became a long-press. */
  let holding: { target: PressTarget; at: number; long: boolean; activityId: string | null } | null = null;
  const cancelHold = () => {
    for (const cancel of pressTimers) cancel();
    pressTimers = [];
  };
  /** Content an alerting update applies once the island has expanded with the old content. */
  const pendingContent = new Map<string, () => void>();
  const flushPending = (id: string) => {
    const apply = pendingContent.get(id);
    if (apply) apply();
  };
  let nextOrder = 0;
  let instant = false;
  /** Timers of the alert under way: its return, and a group's handoff before it expands. */
  let alertTimers: (() => void)[] = [];
  const listeners = new Set<() => void>();

  // `at` lets timers stamp the exact time they were due, so stepped captures stay exact.
  const commit = (next: Omit<IslandSnapshot, "changeId" | "changedAt" | "instant">, at = clock.now()) => {
    const before = deriveScene(snapshot);
    const draft: IslandSnapshot = { ...next, changeId: snapshot.changeId, changedAt: snapshot.changedAt, instant: snapshot.instant };
    const after = deriveScene(draft);
    const shown = before.contentKey !== after.contentKey;
    snapshot = shown || instant ? { ...draft, changeId: snapshot.changeId + 1, changedAt: at, instant } : draft;
    for (const listener of [...listeners]) listener();
  };

  /** Cancels the alert's timers. Callers that commit next end any handoff with `handoff: null`. */
  const clearAlert = () => {
    for (const cancel of alertTimers) cancel();
    alertTimers = [];
  };

  /** Collapses the alert on `id` at `at`, unless something else took over first. */
  const returnAt = (id: string, at: number) => {
    alertTimers.push(
      clock.at(at, (due) => {
        if (snapshot.expanded?.id === id && snapshot.expanded.reason === "alert") {
          commit({ ...snapshot, expanded: null }, due);
        }
      }),
    );
  };

  /**
   * Expands `id` as an alert and schedules its return. Returns the clock time (ms) the expansion
   * starts: now, or after the handoff when `id` waits hidden behind another activity of its group.
   */
  const alert = (id: string, fromIdle = false): number => {
    clearAlert();
    const m = options.motion();
    const now = clock.now();
    const activity = snapshot.activities.find((a) => a.id === id);
    const group = activity?.group ?? null;
    if (!activity || group === null || isShown(snapshot, activity)) {
      commit({ ...snapshot, expanded: { id, reason: "alert" }, handoff: null });
      // An alert that appears on an idle island returns a little sooner (`alertHoldIdle`).
      const hold = fromIdle ? (m.alertHoldIdle ?? m.alertHold) : m.alertHold;
      returnAt(id, now + hold * 1000);
      return now;
    }
    // Held-out swap-t2: the shown activity leaves to idle (the dismiss motion), the island stays
    // empty, then the alerting one expands from idle; the alert window counts from the departure,
    // and the one that left does not come back.
    commit({ ...snapshot, expanded: null, handoff: group, front: { ...snapshot.front, [group]: id } });
    const expandAt = now + m.group.handoff * 1000;
    alertTimers.push(
      clock.at(expandAt, (due) => {
        if (snapshot.handoff !== group || !snapshot.activities.some((a) => a.id === id)) return;
        commit({ ...snapshot, handoff: null, expanded: { id, reason: "alert" } }, due);
      }),
    );
    returnAt(id, now + m.group.window * 1000);
    return expandAt;
  };

  const handle = (id: string): ActivityHandle => ({
    id,
    update: (update) => api.update(id, update),
    end: () => api.end(id),
  });

  const api: IslandApi = {
    start(start) {
      const existing = snapshot.activities.find((a) => a.id === start.id);
      if (existing) {
        api.update(start.id, start);
        return handle(start.id);
      }
      const activity: Activity = {
        id: start.id,
        label: start.label ?? start.id,
        priority: start.priority ?? 0,
        order: nextOrder++,
        content: { compact: start.compact, minimal: start.minimal, expanded: start.expanded },
        onPress: start.onPress ?? null,
        revision: 0,
        group: start.group ?? null,
      };
      const idle = snapshot.activities.length === 0;
      commit({ ...snapshot, activities: [...snapshot.activities, activity].sort(byPriority) });
      if (start.alert) alert(start.id, idle);
      return handle(start.id);
    },
    update(id, update) {
      flushPending(id);
      const found = snapshot.activities.find((a) => a.id === id);
      if (!found) return;
      const next: Activity = {
        ...found,
        label: update.label ?? found.label,
        priority: update.priority ?? found.priority,
        onPress: "onPress" in update ? (update.onPress ?? null) : found.onPress,
        content: mergeContent(found.content, update),
        revision: update.transition === "crossfade" ? found.revision + 1 : found.revision,
      };
      const replace = (activity: Activity) =>
        commit({ ...snapshot, activities: snapshot.activities.map((a) => (a.id === id ? activity : a)).sort(byPriority) });
      const changesContent = update.compact !== undefined || update.expanded !== undefined || "minimal" in update;
      const delay = options.motion().alertContentDelay;
      // Only an activity on show has content to keep: one waiting hidden in its group expands with
      // the update already applied (held-out swap-t2: B comes in showing "8" and its bar at 0.8).
      if (update.alert && changesContent && delay > 0 && snapshot.expanded?.id !== id && isShown(snapshot, found)) {
        // iOS expands with the content it had, then changes it in place (alert-t1: "42" turns into
        // "43" and the bar moves once the expanded view is in).
        replace({ ...next, content: found.content, revision: found.revision });
        const expandAt = alert(id);
        const cancel = clock.at(expandAt + delay * 1000, (due) => {
          pendingContent.delete(id);
          const current = snapshot.activities.find((a) => a.id === id);
          if (!current) return;
          const content = mergeContent(current.content, update);
          commit({ ...snapshot, activities: snapshot.activities.map((a) => (a.id === id ? { ...current, content, revision: next.revision } : a)) }, due);
        });
        pendingContent.set(id, () => {
          cancel();
          pendingContent.delete(id);
          const current = snapshot.activities.find((a) => a.id === id);
          if (current) commit({ ...snapshot, activities: snapshot.activities.map((a) => (a.id === id ? { ...current, content: mergeContent(current.content, update), revision: next.revision } : a)) });
        });
        return;
      }
      replace(next);
      if (update.alert) alert(id);
    },
    end(id) {
      pendingContent.get(id)?.();
      if (!snapshot.activities.some((a) => a.id === id)) return;
      const ending = snapshot.activities.find((a) => a.id === id);
      const expanded = snapshot.expanded?.id === id ? null : snapshot.expanded;
      // An activity handed to mid-handoff that ends calls the handoff off.
      const handingTo = ending !== undefined && ending.group !== null && snapshot.handoff === ending.group && snapshot.front[ending.group] === id;
      if (!expanded || handingTo) clearAlert();
      const front = Object.fromEntries(Object.entries(snapshot.front).filter(([, forward]) => forward !== id));
      commit({ ...snapshot, activities: snapshot.activities.filter((a) => a.id !== id), expanded, front, handoff: handingTo ? null : snapshot.handoff });
    },
    expand(id) {
      // Default: the primary activity among those on show.
      const target = id ?? snapshot.activities.find((a) => isShown(snapshot, a))?.id;
      const activity = snapshot.activities.find((a) => a.id === target);
      if (!target || !activity) return;
      clearAlert();
      // Expanding a hidden activity of a group brings it forward.
      const front = activity.group === null ? snapshot.front : { ...snapshot.front, [activity.group]: activity.id };
      commit({ ...snapshot, expanded: { id: target, reason: "user" }, front, handoff: null });
    },
    collapse() {
      if (!snapshot.expanded) return;
      clearAlert();
      commit({ ...snapshot, expanded: null });
    },
    get activities() {
      return snapshot.activities;
    },
    get presentation(): PresentationKind {
      return deriveScene(snapshot).presentation.kind;
    },
  };

  return {
    getSnapshot: () => snapshot,
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    api,
    instantly(change) {
      instant = true;
      try {
        change();
      } finally {
        instant = false;
      }
    },
    press(target) {
      const scene = deriveScene(snapshot);
      const activity = target === "bubble" ? scene.detached : scene.primary;
      if (target === "bubble" && !activity) return;
      cancelHold();
      const m = options.motion();
      const at = clock.now();
      const expanded = scene.presentation.kind === "expanded";
      holding = { target, at, long: false, activityId: activity?.id ?? null };
      // An expanded island doesn't swell; a press on it is a tap.
      if (expanded) return;
      // Every press swells from touch-down, however short (reference round 2, 30 takes).
      commit({ ...snapshot, pressed: target, joining: null });
      const springBack = (due: number) => {
        if (snapshot.pressed) commit({ ...snapshot, pressed: null }, due);
      };
      if (!activity) {
        // Nothing to expand: a fixed bump that springs back even with the finger down (idlehold-t1).
        pressTimers.push(clock.at(at + m.press.holdReturn * 1000, springBack));
        return;
      }
      // The bubble joins the pill before it opens, on its own time (`longPressBubble`).
      const longPress = target === "bubble" ? (m.longPressBubble ?? m.longPress) : m.longPress;
      pressTimers.push(
        clock.at(at + m.press.decide * 1000, () => {
          // Still down: a long-press. It expands even if released before the expansion shows.
          if (holding?.target !== target || holding.at !== at) return;
          holding.long = true;
          // A held bubble's join is now certain, so its content can go ahead of it (split-expand-b-t1).
          if (target === "bubble") commit({ ...snapshot, joining: at + longPress * 1000 });
        }),
      );
      pressTimers.push(
        clock.at(at + longPress * 1000, (due) => {
          if (!holding || holding.at !== at || !holding.long) return;
          holding = null;
          pressTimers = [];
          clearAlert();
          commit({ ...snapshot, pressed: null, joining: null, expanded: { id: activity.id, reason: "user" } }, due);
        }),
      );
    },
    release(release) {
      const press = holding;
      if (!press) return;
      const m = options.motion();
      const now = clock.now();
      // A long-press is already decided: it expands at `longPress` from touch-down, released or not.
      if (press.long && !release?.cancel) return;
      holding = null;
      cancelHold();
      // A cancelled long-press on the bubble doesn't join: its content stays.
      if (snapshot.joining !== null) commit({ ...snapshot, joining: null });
      // A tap: the swell keeps its short run, then springs back with no bounce (idletap-t1). On an
      // activity it waits at least `releaseReturn` after the release, growing (hold200).
      if (snapshot.pressed) {
        const back = press.activityId
          ? Math.max(press.at + m.press.tapReturn * 1000, now + (m.press.releaseReturn ?? 0) * 1000)
          : press.at + (m.press.idleTapReturn ?? m.press.tapReturn) * 1000;
        if (back > now) {
          pressTimers.push(
            clock.at(back, (due) => {
              if (snapshot.pressed && !holding) commit({ ...snapshot, pressed: null }, due);
            }),
          );
        } else {
          commit({ ...snapshot, pressed: null });
        }
      }
      if (release?.cancel || !press.activityId) return;
      const activity = snapshot.activities.find((a) => a.id === press.activityId);
      activity?.onPress?.();
    },
    reset() {
      clearAlert();
      instant = true;
      try {
        cancelHold();
        holding = null;
        for (const apply of [...pendingContent.values()]) apply();
        pendingContent.clear();
        commit({ activities: [], expanded: null, pressed: null, joining: null, front: {}, handoff: null });
      } finally {
        instant = false;
      }
    },
  };
};
