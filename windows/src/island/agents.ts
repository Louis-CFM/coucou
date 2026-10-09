// Agents other than Claude Code, as the island shows them. Ids, names and colours
// are PillCatalog.swift's (pill `agent_<id>`), so a pill looks the same on every
// platform.

export interface KnownAgent {
  name: string;
  color: string;
}

export const KNOWN_AGENTS: Record<string, KnownAgent> = {
  cursor: { name: "Cursor", color: "#C0C4CC" },
  antigravity: { name: "Antigravity", color: "#E879F9" },
  codex: { name: "Codex", color: "#2DD4BF" },
  gemini: { name: "Gemini CLI", color: "#8AB4F8" },
  copilot: { name: "Copilot CLI", color: "#818CF8" },
  muse: { name: "Muse Code", color: "#38BDF8" },
  opencode: { name: "OpenCode", color: "#4ADE80" },
  amp: { name: "Amp", color: "#F59E0B" },
  hermes: { name: "Hermes", color: "#C084FC" },
  "claude-desktop": { name: "Claude Desktop", color: "#D97757" },
};

/**
 * Agents whose permission requests get an Allow / Deny card, as on the Mac.
 * Must match `takes_decisions` in the relay (hook/src/reply.rs): any other
 * agent's request is handed straight back to its terminal.
 */
export const APPROVAL_AGENTS = new Set(["codex", "copilot", "muse"]);

/** Same rule as HookServer.validateAgent on macOS. "claude" is reserved. */
export function validateAgent(raw: string | undefined): string | null {
  if (!raw || raw.length > 24 || raw === "claude") return null;
  if (!/^[a-z0-9-]+$/.test(raw)) return null;
  return raw;
}

const FALLBACK_COLORS = ["#22C55E", "#EAB308", "#60A5FA", "#E879F9"];

export function agentColor(id: string): string {
  const known = KNOWN_AGENTS[id];
  if (known) return known.color;
  let h = 0;
  for (let i = 0; i < id.length; i++) {
    h = (Math.imul(31, h) + id.charCodeAt(i)) | 0;
  }
  return FALLBACK_COLORS[Math.abs(h) % FALLBACK_COLORS.length];
}

/** The pill label: the agent's own name when Nova knows it, else its id. */
export function agentName(id: string): string {
  return KNOWN_AGENTS[id]?.name ?? id;
}
