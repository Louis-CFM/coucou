// Mirror of the provider presets in src-tauri/src/providers.rs — keep both in
// sync. Rust owns the real endpoint resolution; this table only feeds the
// settings window and the island's API badge.

export interface ProviderDef {
  id: string;
  name: string;
  /** Preset base URL; "" for the custom preset. */
  url: string;
  format: "anthropic" | "openai";
  /** Credential Manager key; absent = no key needed (local server). */
  key?: string;
  /** Suggested model, also used as the free-text field placeholder. */
  model?: string;
  /** Placeholder for the key input. */
  keyHint?: string;
}

export const PROVIDERS: ProviderDef[] = [
  { id: "anthropic", name: "Anthropic", url: "https://api.anthropic.com", format: "anthropic",
    key: "anthropic-api-key", model: "claude-opus-5", keyHint: "sk-ant-..." },
  { id: "openai", name: "OpenAI", url: "https://api.openai.com", format: "openai",
    key: "openai-api-key", model: "gpt-5.2", keyHint: "sk-..." },
  { id: "openrouter", name: "OpenRouter", url: "https://openrouter.ai/api/v1", format: "openai",
    key: "openrouter-api-key", model: "anthropic/claude-sonnet-4.5", keyHint: "sk-or-..." },
  { id: "groq", name: "Groq", url: "https://api.groq.com/openai/v1", format: "openai",
    key: "groq-api-key", model: "llama-3.3-70b-versatile", keyHint: "gsk_..." },
  { id: "deepseek", name: "DeepSeek", url: "https://api.deepseek.com", format: "openai",
    key: "deepseek-api-key", model: "deepseek-chat", keyHint: "sk-..." },
  { id: "ollama", name: "Ollama (local)", url: "http://localhost:11434", format: "openai",
    model: "llama3.2" },
  { id: "custom", name: "Custom", url: "", format: "openai", key: "custom-api-key" },
];

/** Unknown or absent provider ids fall back to Anthropic, like Rust does. */
export function providerDef(id: string | undefined): ProviderDef {
  return PROVIDERS.find((p) => p.id === id) ?? PROVIDERS[0];
}
