import { N_ } from "../i18n/i18n";
import type { ModelInfo } from "./bridge";
import type { Settings } from "./state";

/** Normalize against the live CLI catalog whenever the model changes. */
export function codexSelection(settings: Settings, model: ModelInfo): Settings {
  const efforts = model.reasoningEfforts ?? [];
  const effort = efforts.includes(settings.codexReasoningEffort)
    ? settings.codexReasoningEffort : model.defaultEffort ?? efforts[0] ?? "";
  const tier = model.serviceTiers?.some((t) => t.id === settings.codexServiceTier)
    ? settings.codexServiceTier : "";
  return { ...settings, codexReasoningEffort: effort, codexServiceTier: tier,
    chatModels: { ...settings.chatModels, codex: model.id } };
}
export function effortLabel(effort: string): string {
  return ({ none: N_("None"), minimal: N_("Minimal"), low: N_("Low"), medium: N_("Medium"), high: N_("High"),
    xhigh: N_("Extra high"), max: N_("Maximum"), ultra: N_("Ultra") } as Record<string, string>)[effort] ?? effort;
}
export function codexModelLabel(id: string): string {
  return id.replace(/^gpt-/i, "GPT-");
}
