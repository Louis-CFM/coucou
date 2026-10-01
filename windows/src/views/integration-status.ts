const CODE_HOOK_IDS = new Set(["integration_claude", "integration_codex"]);

/** Hook cards are event-driven and have no initial data poll to finish loading. */
export function idleIntegrationStatusLabel(id: string, configured: boolean, error: string | null): string {
  if (error) return error;
  if (!configured) return CODE_HOOK_IDS.has(id) ? "Hooks not installed" : "Key not configured";
  return CODE_HOOK_IDS.has(id) ? "Hooks installed" : "Connected · loading…";
}
