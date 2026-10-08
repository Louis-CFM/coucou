// What a Claude Code session runs with — permission mode, effort, model — as
// its hooks and status line report it, and the short labels its pill shows.

/**
 * Every permission mode Claude Code takes from a hook's `setMode`, in the order
 * the approval card cycles through them: Shift+Tab's own order first, then the
 * two that turn the prompts off. Same list as hook/src/reply.rs.
 */
export const PERMISSION_MODES = ["default", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"] as const;
export type PermissionMode = (typeof PERMISSION_MODES)[number];

const MODE_LABELS: Record<PermissionMode, string> = {
  default: "Manual",
  acceptEdits: "Accept edits",
  plan: "Plan",
  auto: "Auto",
  dontAsk: "Don't ask",
  bypassPermissions: "Bypass",
};

export function isPermissionMode(mode: unknown): mode is PermissionMode {
  return typeof mode === "string" && (PERMISSION_MODES as readonly string[]).includes(mode);
}

/** "Plan", "Accept edits"… — Claude Code's own names; "manual" is its alias for default. */
export function modeLabel(mode: string): string {
  if (mode === "manual") return MODE_LABELS.default;
  return isPermissionMode(mode) ? MODE_LABELS[mode] : mode;
}

/** The mode after `mode` on the approval card. */
export function nextMode(mode: PermissionMode): PermissionMode {
  return PERMISSION_MODES[(PERMISSION_MODES.indexOf(mode) + 1) % PERMISSION_MODES.length];
}

/** Modes that stop Claude Code asking before it acts: shown in red. */
export function modeSkipsPrompts(mode: string): boolean {
  return mode === "dontAsk" || mode === "bypassPermissions";
}

/**
 * "claude-opus-5-5" → "Opus 5.5", "claude-haiku-4-5-20251001" → "Haiku 4.5",
 * "claude-sonnet-5-5[1m]" → "Sonnet 5.5 1M". Anything else — an alias, a
 * display name, another provider's id — is shown as it came.
 */
export function modelLabel(model: string): string {
  const m = /^claude-([a-z]+)((?:-\d{1,2})*)(?:-\d{8})?(\[1m\])?$/i.exec(model.trim());
  if (!m) return model.trim();
  const family = m[1].charAt(0).toUpperCase() + m[1].slice(1).toLowerCase();
  const version = m[2].split("-").filter(Boolean).join(".");
  return [family, version, m[3] ? "1M" : ""].filter(Boolean).join(" ");
}

/** The level out of an `effort` field: `{ level: "high" }`, or the bare level. */
export function effortLevel(effort: unknown): string | null {
  const level = typeof effort === "string" ? effort : (effort as { level?: unknown } | null)?.level;
  return typeof level === "string" && /^[a-z]{1,12}$/.test(level) ? level : null;
}
