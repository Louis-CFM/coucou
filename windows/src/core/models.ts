// Chat model choices shared by the island picker and the settings window.

export const ANTHROPIC_MODELS: [string, string][] = [
  ["claude-opus-5", "Claude Opus 5"],
  ["claude-sonnet-5", "Claude Sonnet 5"],
  ["claude-haiku-4-5", "Claude Haiku 4.5"],
];

export const DEFAULT_ANTHROPIC_MODEL = ANTHROPIC_MODELS[0][0];

export function anthropicLabel(id: string): string {
  return ANTHROPIC_MODELS.find(([m]) => m === id)?.[1] ?? id;
}
