// ── Dynamic Island Core Types (islandcn registry specification) ────────────

export type IslandPresentation = "idle" | "compact" | "split" | "expanded";

export interface ActivityContent {
  leading?: string | HTMLElement;
  trailing?: string | HTMLElement;
  center?: string | HTMLElement;
  bottom?: string | HTMLElement;
}

export interface IslandActivity {
  id: string;
  label: string;
  priority?: number;
  timestamp?: number;
  compact?: ActivityContent;
  split?: ActivityContent;
  expanded?: ActivityContent;
  onSelect?: () => void;
}

export interface IslandPhysicsConfig {
  stiffness: number;
  damping: number;
  mass: number;
}
