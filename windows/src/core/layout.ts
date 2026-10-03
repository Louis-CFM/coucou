// Island geometry — ported from IslandTypes.swift + IslandWindowController.islandSize
// + IslandRootView.botPosition. All values are logical pixels, identical to the
// macOS app's points.

export type IslandMode = "hidden" | "compact" | "expanded";

export type IslandViewName =
  | "overview"
  | "empty"
  | "approval"
  | "question"
  | "error"
  | "finished"
  | "confused"
  | "upload"
  | "uploading"
  | "choose"
  | "mail"
  | "prompt"
  | "searching"
  | "result"
  | "note"
  | "settings"
  | "greeting";

export type BotStateName =
  | "idle"
  | "working"
  | "thinking"
  | "searching"
  | "approval"
  | "question"
  | "error"
  | "finished"
  | "ratelimit"
  | "sleeping"
  | "dizzy";

export type BotEmoteName = "love" | "surprised" | "proud" | "wink" | "yawn" | "happy" | "annoyed";

export type AgentLayoutMode = "none" | "grid" | "pills" | "column";

export interface ViewLayout {
  height: number;
  botX: number;
  botY: number | null; // null = auto-centred
  botDiameter: number;
  agentMode: AgentLayoutMode;
}

// The window is a fixed 720×320 (largest view) like the macOS panel; the island is
// drawn inside it, glued to the top edge and horizontally centred.
export const PANEL_W = 720;
export const PANEL_H = 320;

// A PC never has a real notch, so the resting sizes follow PR #22's no-notch
// branch: an 80 pt fake notch that Mochi peeks out of, and a 240 pt compact bar
// no taller than the menu bar.
export const FALLBACK_NOTCH_W = 184; // only used when a screen really has a notch
export const NO_NOTCH_W = 80;
export const NO_NOTCH_H = 24;
export const COMPACT_W = 240;
export const EXPANDED_W = 640;

/** The resting island's sizes on a notched-less screen. Mirrors PR #22's
 *  `IslandScreenGeometry` so the mascot and pills shrink with the bar. */
export function restingLayout() {
    return { width: NO_NOTCH_W, height: NO_NOTCH_H };
    }

export const ROUNDED_CORNER = 14; // hidden / compact
export const EXPANDED_CORNER = 22;

/** Invisible hover strip that wakes the island when hidden. */
export const WAKE_STRIP_W = 240;
export const WAKE_STRIP_H = 6;

export const VIEW_LAYOUTS: Record<IslandViewName, ViewLayout> = {
  overview: { height: 160, botX: 68, botY: null, botDiameter: 58, agentMode: "pills" },
  empty: { height: 160, botX: 70, botY: null, botDiameter: 62, agentMode: "none" },
  approval: { height: 160, botX: 62, botY: null, botDiameter: 56, agentMode: "column" },
  question: { height: 160, botX: 62, botY: null, botDiameter: 56, agentMode: "column" },
  error: { height: 160, botX: 62, botY: null, botDiameter: 58, agentMode: "column" },
  finished: { height: 160, botX: 62, botY: null, botDiameter: 58, agentMode: "column" },
  confused: { height: 160, botX: 76, botY: null, botDiameter: 66, agentMode: "column" },
  upload: { height: 176, botX: 140, botY: 104, botDiameter: 62, agentMode: "column" },
  // botY 103 = bar top (42 + 58) + 3, so the dot really rides the bar. The Swift
  // layout says 118 while its own comment says 103; the comment matches the spec.
  uploading: { height: 176, botX: 46, botY: 103, botDiameter: 20, agentMode: "none" },
  choose: { height: 176, botX: 60, botY: 101, botDiameter: 52, agentMode: "column" },
  mail: { height: 240, botX: 56, botY: null, botDiameter: 46, agentMode: "column" },
  prompt: { height: 160, botX: 52, botY: null, botDiameter: 44, agentMode: "column" },
  searching: { height: 160, botX: 52, botY: null, botDiameter: 44, agentMode: "column" },
  result: { height: 160, botX: 52, botY: null, botDiameter: 44, agentMode: "column" },
  note: { height: 160, botX: 60, botY: null, botDiameter: 50, agentMode: "column" },
  // Tall enough for every settings row to sit inside the card. The view height is
  // fixed, so a row added without raising it is clipped off the bottom.
  settings: { height: 288, botX: 54, botY: null, botDiameter: 46, agentMode: "none" },
  greeting: { height: 150, botX: 320, botY: 90, botDiameter: 0, agentMode: "none" },
};

// The upload views above are only the fallback geometry. Once a file is actually
// dropped the whole sequence — Mochi included — is drawn by src/upload, which
// owns its own constants (USC) straight from UploadSequenceEngine.swift.

/** Chat view grows with the conversation — IslandContainer.chatPromptHeight. */
export function chatPromptHeight(messageCount: number): number {
  return Math.min(300, 240 + messageCount * 40);
}

export function islandSize(
  mode: IslandMode,
  view: IslandViewName,
  chatCount = 0,
  offscreen = false,
): { w: number; h: number } {
  switch (mode) {
    case "hidden":
      // Two outcomes, decided by whether auto-close has a delay at all.
      // With auto-close on Never the island is never meant to leave the screen, so
      // fully reduced keeps the draft's small parked bar with Mochi in it. With a
      // delay it goes off-screen instead: zero height, sliding out through the top
      // edge as if the screen's edge were pulling it in. The cursor can still find
      // it either way — the hit rectangle keeps its 14px margin, leaving a band
      // along the top edge at the resting position.
      return offscreen
        ? { w: NO_NOTCH_W, h: 0 }
        : { w: NO_NOTCH_W, h: NO_NOTCH_H };
    case "compact":
      // Regular compact: the docked bar. Wider than the fully-compact bar and the
      // one the island opens into, and where the agent pills would sit.
      return { w: COMPACT_W, h: NO_NOTCH_H };
    case "expanded": {
      const h = view === "prompt" ? chatPromptHeight(chatCount) : VIEW_LAYOUTS[view].height;
      return { w: EXPANDED_W, h };
    }
  }
}

export interface BotPlacement {
  cx: number;
  cy: number;
  diameter: number;
  opacity: number;
}

/** IslandRootView.botPosition — cy is measured from the island's top edge.
 *
 *  `offscreen` no longer changes Mochi's placement: the island slides up past the
 *  top edge to hide, so the bot rides out with the rest of it. The flag still
 *  decides the island's own height, in `islandSize`.
 */
export function botPosition(
  mode: IslandMode,
  view: IslandViewName,
  islandH: number,
  uploadProgress = 0,
  _offscreen = false,
): BotPlacement {
  switch (mode) {
    case "hidden": {
      // Off-screen is the parked bar with the island slid up past the top edge, so
      // Mochi is placed and drawn exactly as it is on screen and the slide is the
      // only thing that takes it away. Fading it here instead is what made Mochi
      // blink out on the first frame of the hide, with no motion at all.
      // Auto-close on Never keeps it parked in the small bar, which is how the
      // island behaved before there was anywhere to go.
      const rest = restingLayout();
      return {
        cx: NO_NOTCH_W / 2,
        cy: rest.height / 2,
        diameter: Math.min(20, Math.max(0, NO_NOTCH_H - 6)),
        opacity: 1,
      };
    }
    case "compact": {
      // Centre Mochi vertically and cap the diameter so a short bar never crops
      // it. cx is the centre of the resting bar, so the single Mochi sits centred
      // in it; the agent pills only ever appear to one side, never on top of it.
      const rest = restingLayout();
      return {
        cx: NO_NOTCH_W / 2,
        cy: rest.height / 2,
        diameter: Math.min(20, Math.max(0, rest.height - 6)),
        opacity: 1,
      };
    }
    case "expanded": {
      const layout = VIEW_LAYOUTS[view];
      if (view === "uploading") {
        return {
          cx: 36 + uploadProgress * 526,
          cy: layout.botY ?? 103,
          diameter: layout.botDiameter,
          opacity: 1,
        };
      }
      if (layout.botY != null) {
        return { cx: layout.botX, cy: layout.botY, diameter: layout.botDiameter, opacity: 1 };
      }
      // Centre of the fixed 84 pt card (8 pt top inset + 34 pt header → content at y = 42)
      const headerBottom = 42;
      const cardH = 84;
      const cy = headerBottom + (islandH - headerBottom - cardH) / 2 + cardH / 2;
      return { cx: layout.botX, cy, diameter: layout.botDiameter, opacity: 1 };
    }
  }
}

export function botGlowColor(s: BotStateName): string {
  switch (s) {
    case "working":
      return "#3B9EFF";
    case "thinking":
      return "#A78BFA";
    case "searching":
      return "#6366F1";
    case "approval":
      return "#F5A524";
    case "error":
      return "#F4505E";
    case "finished":
      return "#34D399";
    case "ratelimit":
      return "#F59E0B";
    default:
      return "#FFFFFF";
  }
}

export function botGlowOpacity(s: BotStateName): number {
  switch (s) {
    case "idle":
    case "sleeping":
      return 0.15;
    case "dizzy":
      return 0;
    default:
      return 0.65;
  }
}

// Project colours (IslandConst.projectColors)
const PROJECT_COLORS: Record<string, string> = {
  korus: "#FF5A4E",
  "sbe hub": "#2EC4A0",
  "morning ai brief": "#F29B38",
  "publication ig": "#7C5CFF",
  "ig post": "#7C5CFF",
  "louisraille.fr": "#38BDF8",
  louisraille: "#38BDF8",
  "notch buddy": "#EC4899",
  "notch-buddy": "#EC4899",
  notchbuddy: "#EC4899",
};

const FALLBACK_COLORS = ["#22C55E", "#EAB308", "#60A5FA", "#E879F9"];

export function colorForProject(name: string): string {
  const key = name.toLowerCase().trim();
  const exact = PROJECT_COLORS[key];
  if (exact) return exact;
  for (const [k, c] of Object.entries(PROJECT_COLORS)) {
    if (key.startsWith(k) || key.includes(k)) return c;
  }
  let hash = 0;
  for (let i = 0; i < name.length; i++) hash = (hash * 31 + name.charCodeAt(i)) | 0;
  return FALLBACK_COLORS[Math.abs(hash) % FALLBACK_COLORS.length];
}

// Card wash colours (CardBackground.washColor)
export type Wash = "red" | "green" | "pink" | "amber" | "cyan" | "indigo" | "soft" | null;

export function washRGBA(wash: Wash): string {
  switch (wash) {
    case "red":
      return "rgba(244,80,94,0.55)";
    case "green":
      return "rgba(52,211,153,0.5)";
    case "pink":
      return "rgba(244,114,182,0.55)";
    case "amber":
      return "rgba(245,165,36,0.42)";
    case "cyan":
      return "rgba(34,211,238,0.38)";
    case "indigo":
      return "rgba(99,102,241,0.5)";
    case "soft":
      return "rgba(255,255,255,0.08)";
    default:
      return "rgba(0,0,0,0)";
  }
}
