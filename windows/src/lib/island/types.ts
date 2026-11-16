import type { ReactNode } from "react";

/**
 * What the island shows, following ActivityKit's presentations.
 *
 * - `idle`: the resting pill, no activity.
 * - `compact`: one activity, content on either side of the sensor area.
 * - `minimal`: two activities. One sits attached to the pill, the other in a detached bubble.
 *   With `split`, both pills show their activity's compact leading and trailing content, as on
 *   iOS 27; `attached` and `detached` are the fallback when that content is too wide.
 * - `expanded`: one activity, full width, with four regions.
 */
export type IslandPresentation =
  | { kind: "idle" }
  | { kind: "compact"; leading?: ReactNode; trailing?: ReactNode }
  | { kind: "minimal"; attached: ReactNode; detached?: ReactNode; split?: { attached: CompactContent; detached: CompactContent } }
  | { kind: "expanded"; leading?: ReactNode; trailing?: ReactNode; center?: ReactNode; bottom?: ReactNode };

export type PresentationKind = IslandPresentation["kind"];

/** Content for the compact presentation. */
export interface CompactContent {
  /** Left of the sensor. Defaults to nothing. */
  leading?: ReactNode;
  /** Right of the sensor. Defaults to nothing. */
  trailing?: ReactNode;
}

/** Content for the expanded presentation. */
export interface ExpandedContent {
  /** Top left, beside the sensor. Defaults to nothing. */
  leading?: ReactNode;
  /** Top right, beside the sensor. Defaults to nothing. */
  trailing?: ReactNode;
  /** Between leading and trailing, below the sensor. Defaults to nothing. */
  center?: ReactNode;
  /** Full width under the top row. Defaults to nothing. */
  bottom?: ReactNode;
}

/** Everything an activity can show. Each presentation falls back to empty slots. */
export interface ActivityContent {
  /** Shown when this is the only activity. Defaults to empty slots. */
  compact?: CompactContent;
  /**
   * Shown when two activities run and their compact content doesn't fit side by side (attached or
   * in the detached bubble). Defaults to the compact leading content.
   */
  minimal?: ReactNode;
  /** Shown on long-press, `expand()`, or an alerting update. Defaults to empty regions. */
  expanded?: ExpandedContent;
}

export interface ActivityOptions extends ActivityContent {
  /** Unique id. Starting an id that already runs updates it instead. */
  id: string;
  /** Spoken by screen readers when the activity starts or changes. Defaults to the id. */
  label?: string;
  /** Higher priority takes the primary slot. Ties go to the activity that started first. Defaults to 0. */
  priority?: number;
  /** Called on a tap (a press shorter than the long-press). Defaults to none. */
  onPress?: () => void;
  /** Start with an alert: expand briefly, then settle to compact. Defaults to false. */
  alert?: boolean;
  /**
   * Activities that share a group show one at a time, as one app's Live Activities do on iOS: the
   * first started shows and the others wait hidden. An alert on a hidden one hands over: the shown
   * one leaves to idle, the island waits `motion.group.handoff`, expands the alerting one, and comes
   * back to it compact; the one that left stays hidden. Defaults to none (always shown).
   */
  group?: string;
}

/** A partial update. Nested content merges, so `{ compact: { trailing } }` keeps the leading slot. */
export interface ActivityUpdate {
  /** Replaces the compact slots given. Defaults to keeping them. */
  compact?: CompactContent;
  /** Replaces the minimal content. Defaults to keeping it. */
  minimal?: ReactNode;
  /** Replaces the expanded regions given. Defaults to keeping them. */
  expanded?: ExpandedContent;
  /** Replaces the screen reader label. Defaults to keeping it. */
  label?: string;
  /** Replaces the priority. Defaults to keeping it. */
  priority?: number;
  /** Replaces the tap handler. Defaults to keeping it. */
  onPress?: () => void;
  /**
   * Expand briefly to draw attention, like an alerting ActivityKit update. The island expands with
   * the content it had and applies this update in place `motion.alertContentDelay` later, as iOS
   * does. Defaults to false.
   */
  alert?: boolean;
  /**
   * "update" changes content in place (a number ticking, a bar moving); "crossfade" replaces the
   * layer with a blur-and-fade, for content that is different, not just newer. Defaults to "update".
   */
  transition?: "update" | "crossfade";
}

export interface ActivityHandle {
  readonly id: string;
  update(update: ActivityUpdate): void;
  /** Removes the activity with the system dismiss motion. */
  end(): void;
}

/** An activity as the island holds it. */
export interface Activity {
  id: string;
  label: string;
  priority: number;
  /** Start order, used to break priority ties. */
  order: number;
  content: ActivityContent;
  onPress: (() => void) | null;
  /** Bumped by crossfade updates: a new revision replaces the content layer instead of updating it. */
  revision: number;
  /** The group it shows in turn with (`ActivityOptions.group`), or null. */
  group: string | null;
}

/** Why the island is expanded. Alerts collapse by themselves; user expansions wait for a press outside. */
export type ExpandReason = "user" | "alert";

export interface IslandApi {
  /** Starts an activity, or updates it if the id already runs. */
  start(options: ActivityOptions): ActivityHandle;
  update(id: string, update: ActivityUpdate): void;
  end(id: string): void;
  /** Expands an activity (what a long-press does). Defaults to the primary activity. */
  expand(id?: string): void;
  collapse(): void;
  /** Running activities, primary first, including grouped ones waiting hidden. */
  readonly activities: readonly Activity[];
  /** What the island shows right now. */
  readonly presentation: PresentationKind;
}

/** Whether the system's reduced-motion setting applies. */
export type ReducedMotionSetting = "user" | "always" | "never";

/**
 * A scripted run for captures: build the starting state instantly, then fire events at fixed
 * times. `/lab` registers these and `window.__islandcn.play(name)` runs them.
 */
export interface IslandSequence {
  /** Builds the starting state with no animation, before time 0. Defaults to idle. */
  setup?: (island: SequenceIsland) => void;
  /** Events in ms from the start. */
  events: readonly { at: number; run: (island: SequenceIsland) => void }[];
  /** Total length in ms, so a capture knows when to stop. */
  duration: number;
}

/** What sequence events can drive: the public API plus presses, so a capture can include the long-press squish. */
export interface SequenceIsland extends IslandApi {
  /** Holds the pill (or the detached bubble) down. Held for the long-press time, it expands. */
  press(target?: "pill" | "bubble"): void;
  release(): void;
}
