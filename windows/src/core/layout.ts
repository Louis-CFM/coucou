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
// drawn inside it, glued to the right edge and vertically centred (the window
// itself sits in the middle of the display's right edge, like CodeNotch).
export const PANEL_W = 300;
export const PANEL_H = 560;

// No notch on a PC: these are the hidden/compact sizes from docs/SPEC.md.
export const NOTCH_W = 184;
export const NOTCH_H = 32;
export const COMPACT_W = 288; // NOTCH_W + 104
/** The open island is an upright card on the right edge. */
export const EXPANDED_W = 300;
/** Mochi sits centred at the top of each card, under the 42 pt header. */
export const BOT_TOP_Y = 84;
/** The drop sequence is drawn in its 640x176 macOS space, scaled into the card. */
export const UPLOAD_SCALE = EXPANDED_W / 640;
export const UPLOAD_H = 176 * UPLOAD_SCALE;
export const UPLOAD_VIEW_H = 220;
export const UPLOAD_TOP = (UPLOAD_VIEW_H - UPLOAD_H) / 2;
/** Launch greeting space (see src/mochi/greeting.ts). */
export const GREET_W = 240;
export const GREET_H = 260;

/** Compact island on the right edge: an upright tab, like CodeNotch's. */
export const TAB_W = 56;
export const TAB_H = 104;
/** Concave "ears" joining the tab to the screen edge, above and below it. */
export const EAR = 38.7;

export const ROUNDED_CORNER = 14; // hidden / compact
export const EXPANDED_CORNER = 28;

/** Invisible hover strip that wakes the island when hidden. */
export const WAKE_STRIP_W = 240;
export const WAKE_STRIP_H = 6;

export const VIEW_LAYOUTS: Record<IslandViewName, ViewLayout> = {
  // The three drop views keep their macOS coordinates; botPosition scales them.
  overview: { height: 480, botX: EXPANDED_W / 2, botY: BOT_TOP_Y, botDiameter: 58, agentMode: "pills" },
  empty: { height: 270, botX: EXPANDED_W / 2, botY: BOT_TOP_Y, botDiameter: 62, agentMode: "none" },
  approval: { height: 290, botX: EXPANDED_W / 2, botY: BOT_TOP_Y, botDiameter: 56, agentMode: "column" },
  question: { height: 440, botX: EXPANDED_W / 2, botY: BOT_TOP_Y, botDiameter: 56, agentMode: "column" },
  error: { height: 300, botX: EXPANDED_W / 2, botY: BOT_TOP_Y, botDiameter: 58, agentMode: "column" },
  finished: { height: 280, botX: EXPANDED_W / 2, botY: BOT_TOP_Y, botDiameter: 58, agentMode: "column" },
  confused: { height: 250, botX: EXPANDED_W / 2, botY: BOT_TOP_Y, botDiameter: 66, agentMode: "column" },
  upload: { height: UPLOAD_VIEW_H, botX: 140, botY: 104, botDiameter: 62, agentMode: "column" },
  uploading: { height: UPLOAD_VIEW_H, botX: 46, botY: 103, botDiameter: 20, agentMode: "none" },
  choose: { height: UPLOAD_VIEW_H, botX: 60, botY: 101, botDiameter: 52, agentMode: "column" },
  mail: { height: 420, botX: EXPANDED_W / 2, botY: BOT_TOP_Y, botDiameter: 46, agentMode: "column" },
  prompt: { height: 300, botX: EXPANDED_W / 2, botY: 66, botDiameter: 36, agentMode: "column" },
  searching: { height: 280, botX: EXPANDED_W / 2, botY: BOT_TOP_Y, botDiameter: 44, agentMode: "column" },
  result: { height: 280, botX: EXPANDED_W / 2, botY: BOT_TOP_Y, botDiameter: 44, agentMode: "column" },
  note: { height: 250, botX: EXPANDED_W / 2, botY: BOT_TOP_Y, botDiameter: 50, agentMode: "column" },
  settings: { height: 300, botX: EXPANDED_W / 2, botY: 66, botDiameter: 36, agentMode: "none" },
  greeting: { height: GREET_H, botX: GREET_W / 2, botY: 120, botDiameter: 0, agentMode: "none" },
};

// The upload views above are only the fallback geometry. Once a file is actually
// dropped the whole sequence — Mochi included — is drawn by src/upload, which
// owns its own constants (USC) straight from UploadSequenceEngine.swift.

/** Chat view grows with the conversation — IslandContainer.chatPromptHeight. */
export function chatPromptHeight(messageCount: number): number {
  return Math.min(520, 300 + messageCount * 44);
}

export function islandSize(
  mode: IslandMode,
  view: IslandViewName,
  chatCount = 0,
): { w: number; h: number } {
  switch (mode) {
    case "hidden":
      // No notch to hide inside on a PC: the tab retracts to zero width and
      // slides into the right edge of the screen.
      return { w: 0, h: TAB_H };
    case "compact":
      return { w: TAB_W, h: TAB_H };
    case "expanded": {
      const h = view === "prompt" ? chatPromptHeight(chatCount) : VIEW_LAYOUTS[view].height;
      return { w: view === "greeting" ? GREET_W : EXPANDED_W, h };
    }
  }
}

export interface BotPlacement {
  cx: number;
  cy: number;
  diameter: number;
  opacity: number;
}

/** IslandRootView.botPosition — cy is measured from the island's top edge. */
export function botPosition(
  mode: IslandMode,
  view: IslandViewName,
  islandH: number,
  uploadProgress = 0,
): BotPlacement {
  switch (mode) {
    case "hidden":
      return { cx: TAB_W / 2, cy: 36, diameter: 6, opacity: 0 };
    case "compact":
      // Mochi on top, the 2×2 mini grid under it.
      return { cx: TAB_W / 2, cy: 36, diameter: 30, opacity: 1 };
    case "expanded": {
      const layout = VIEW_LAYOUTS[view];
      if (view === "upload" || view === "uploading" || view === "choose") {
        const cx = view === "uploading" ? 36 + uploadProgress * 526 : layout.botX;
        return {
          cx: cx * UPLOAD_SCALE,
          cy: UPLOAD_TOP + (layout.botY ?? 103) * UPLOAD_SCALE,
          diameter: layout.botDiameter * UPLOAD_SCALE,
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
