// Port of NotchBuddy IslandTypes.swift (+ islandSize from IslandWindowController.swift)

export type IslandMode = "hidden" | "compact" | "expanded";

export type IslandView =
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

export type BotState =
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

export type BotEmote =
  | "love"
  | "surprised"
  | "proud"
  | "wink"
  | "yawn"
  | "happy"
  | "annoyed";

export interface ApprovalInfo {
  sessionId: string;
  tool: string;
  command: string;
}

export type PillBadge = "approval" | "finished" | "error";

export type AgentSource = "claudeCode" | "n8n";

export type EyeShape =
  | "pill"
  | "wide"
  | "dot"
  | "line"
  | "flat"
  | "happy"
  | "closed"
  | "spiral"
  | "heart"
  | "star"
  | "tired"
  | "wink";

export interface AgentTask {
  id: string;
  name: string;
  color: string;
  state: BotState;
  stepIndex: number;
  steps: string[];
  source: AgentSource;
  isIntegration: boolean;
  emote?: BotEmote;
  miniEye?: EyeShape;
  pillBadge?: PillBadge;
  sessionCwd?: string;
}

export type AgentLayoutMode = "none" | "grid" | "pills" | "column";

export interface ViewLayout {
  height: number;
  botX: number;
  botY: number | null;
  botDiameter: number;
  agentMode: AgentLayoutMode;
}

export interface IntegrationMeta {
  id: string;
  name: string;
  color: string;
}

const PROMPT_CHAT_BASE = 240;
const PROMPT_CHAT_PER_MSG = 40;
const PROMPT_CHAT_MAX = 300;

function chatPromptHeight(chatCount: number): number {
  return Math.min(PROMPT_CHAT_MAX, PROMPT_CHAT_BASE + chatCount * PROMPT_CHAT_PER_MSG);
}

/** Stable string hash (fallback project colors; not Swift hashValue). */
function hashString(s: string): number {
  let h = 5381;
  for (let i = 0; i < s.length; i++) {
    h = (h * 33) ^ s.charCodeAt(i);
  }
  return Math.abs(h);
}

export const IslandConst = {
  notchWidth: 184,
  notchHeight: 32,
  expandedWidth: 640,
  earRadius: 14,
  roundedCorner: 14,
  expandedCorner: 22,

  viewLayouts: {
    overview: {
      height: 160,
      botX: 68,
      botY: null,
      botDiameter: 58,
      agentMode: "pills",
    },
    empty: {
      height: 160,
      botX: 70,
      botY: null,
      botDiameter: 62,
      agentMode: "none",
    },
    approval: {
      height: 160,
      botX: 62,
      botY: null,
      botDiameter: 56,
      agentMode: "column",
    },
    question: {
      height: 160,
      botX: 62,
      botY: null,
      botDiameter: 56,
      agentMode: "column",
    },
    error: {
      height: 160,
      botX: 62,
      botY: null,
      botDiameter: 58,
      agentMode: "column",
    },
    finished: {
      height: 160,
      botX: 62,
      botY: null,
      botDiameter: 58,
      agentMode: "column",
    },
    confused: {
      height: 160,
      botX: 76,
      botY: null,
      botDiameter: 66,
      agentMode: "column",
    },
    upload: {
      height: 176,
      botX: 140,
      botY: 104,
      botDiameter: 62,
      agentMode: "column",
    },
    uploading: {
      height: 176,
      botX: 46,
      botY: 118,
      botDiameter: 20,
      agentMode: "none",
    },
    choose: {
      height: 176,
      botX: 60,
      botY: 101,
      botDiameter: 52,
      agentMode: "column",
    },
    mail: {
      height: 240,
      botX: 56,
      botY: null,
      botDiameter: 46,
      agentMode: "column",
    },
    prompt: {
      height: 160,
      botX: 52,
      botY: null,
      botDiameter: 44,
      agentMode: "column",
    },
    searching: {
      height: 160,
      botX: 52,
      botY: null,
      botDiameter: 44,
      agentMode: "column",
    },
    result: {
      height: 160,
      botX: 52,
      botY: null,
      botDiameter: 44,
      agentMode: "column",
    },
    note: {
      height: 160,
      botX: 60,
      botY: null,
      botDiameter: 50,
      agentMode: "column",
    },
    settings: {
      height: 260,
      botX: 54,
      botY: null,
      botDiameter: 0,
      agentMode: "none",
    },
    greeting: {
      height: 150,
      botX: 320,
      botY: 90,
      botDiameter: 0,
      agentMode: "none",
    },
  } satisfies Record<IslandView, ViewLayout>,

  projectColors: {
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
  } as Record<string, string>,

  fallbackColors: ["#22C55E", "#EAB308", "#60A5FA", "#E879F9"],

  allIntegrations: [
    { id: "integration_resend", name: "Resend", color: "#22C55E" },
    { id: "integration_n8n", name: "n8n", color: "#F29B38" },
    { id: "integration_vercel", name: "Vercel", color: "#7C5CFF" },
    { id: "integration_github", name: "GitHub", color: "#F4505E" },
    { id: "integration_notion", name: "Notion", color: "#8C8C8C" },
    { id: "integration_calcom", name: "Cal.com", color: "#C9956A" },
    { id: "integration_stripe", name: "Stripe", color: "#0570DE" },
  ] satisfies IntegrationMeta[],

  washColors: {
    approval: "rgba(245,165,36,0.42)",
    question: "rgba(34,211,238,0.38)",
    error: "rgba(244,80,94,0.55)",
    finished: "rgba(52,211,153,0.5)",
    confused: "rgba(244,114,182,0.55)",
    searching: "rgba(99,102,241,0.5)",
    result: "rgba(52,211,153,0.22)",
    prompt: "rgba(99,102,241,0.22)",
  } as Partial<Record<IslandView, string>>,

  colorForProject(name: string): string {
    const key = name.toLowerCase().trim();
    const pc = IslandConst.projectColors;
    if (pc[key]) return pc[key];
    for (const [k, c] of Object.entries(pc)) {
      if (key.startsWith(k) || key.includes(k)) return c;
    }
    const fb = IslandConst.fallbackColors;
    return fb[hashString(name) % fb.length];
  },
} as const;

export interface IslandSize {
  width: number;
  height: number;
}

export function islandSize(
  mode: IslandMode,
  view: IslandView,
  notchW: number = IslandConst.notchWidth,
  notchH: number = IslandConst.notchHeight,
  chatCount?: number,
): IslandSize {
  switch (mode) {
    case "hidden":
      return { width: notchW, height: notchH };
    case "compact":
      return { width: notchW + 160, height: notchH };
    case "expanded": {
      const layout = IslandConst.viewLayouts[view];
      let height = layout.height;
      if (view === "prompt" && chatCount !== undefined) {
        height = chatPromptHeight(chatCount);
      }
      return { width: IslandConst.expandedWidth, height };
    }
  }
}
