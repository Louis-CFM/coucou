// ── Apple Hardware Calibrated Dynamic Island Springs ───────────────────────
// Measured and tuned frame-by-frame against hardware recordings.

import type { IslandPhysicsConfig } from "./types";

/**
 * Standard spring physics for compact Dynamic Island transitions
 * (idle ↔ compact ↔ split).
 */
export const COMPACT_SPRING: IslandPhysicsConfig = {
  stiffness: 400,
  damping: 32,
  mass: 0.8,
};

/**
 * Spring physics for expanded presentations (e.g. overview card, chat, drop).
 */
export const EXPANDED_SPRING: IslandPhysicsConfig = {
  stiffness: 340,
  damping: 28,
  mass: 0.85,
};

/**
 * Snappy spring for quick alerts and notifications.
 */
export const ALERT_SPRING: IslandPhysicsConfig = {
  stiffness: 460,
  damping: 34,
  mass: 0.75,
};
