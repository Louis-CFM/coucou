// Multiple-choice questions an agent asks (Claude AskUserQuestion, Kimi
// AskUserQuestion, Codex request_user_input), as the island shows them.

import type { QuestionInfo, QuestionOption } from "./state";

export interface QuestionCarrier {
  questions?: QuestionInfo[] | null;
  picks?: string[][];
  step?: number;
}

const MAX_QUESTIONS = 8;
const MAX_OPTIONS = 12;

const text = (v: unknown): string | null =>
  typeof v === "string" && v.trim() ? v : null;

/** `tool_input.questions`, or null when there is nothing answerable in it. */
export function parseQuestions(input: Record<string, unknown> | undefined): QuestionInfo[] | null {
  const raw = input?.questions;
  // Answers go back by question index, so every question must be shown.
  if (!Array.isArray(raw) || raw.length > MAX_QUESTIONS) return null;
  const out: QuestionInfo[] = [];
  for (const q of raw) {
    if (!q || typeof q !== "object") return null;
    const item = q as Record<string, unknown>;
    const question = text(item.question);
    if (!question || !Array.isArray(item.options)) return null;
    const options: QuestionOption[] = [];
    for (const o of item.options.slice(0, MAX_OPTIONS)) {
      const label = text((o as Record<string, unknown> | null)?.label);
      if (!label) continue;
      const description = text((o as Record<string, unknown>).description);
      options.push(description ? { label, description } : { label });
    }
    if (options.length === 0) return null;
    const header = text(item.header);
    out.push({ question, ...(header ? { header } : {}), multiSelect: item.multiSelect === true, options });
  }
  return out.length ? out : null;
}

export function sameText(left: string, right: string): boolean {
  return left.trim().replace(/\s+/g, " ").toLocaleLowerCase() === right.trim().replace(/\s+/g, " ").toLocaleLowerCase();
}

export function liveLabels(picks: string[], choices: string[]): string[] | null {
  const selected = new Set(picks);
  const labels = choices.filter((choice) => selected.has(choice));
  return labels.length === selected.size ? labels : null;
}

/** Selects or clears one option; a single-select question keeps one label. */
export function togglePick(approval: QuestionCarrier, index: number, label: string) {
  const q = approval.questions?.[index];
  if (!q || !q.options.some((o) => o.label === label)) return;
  const picks = (approval.picks ??= approval.questions!.map(() => []));
  const current = picks[index] ?? [];
  if (!q.multiSelect) {
    picks[index] = current.length === 1 && current[0] === label ? [] : [label];
    return;
  }
  const next = current.includes(label) ? current.filter((l) => l !== label) : [...current, label];
  picks[index] = q.options.map((o) => o.label).filter((l) => next.includes(l));
}

/** The question shown now: the card asks one at a time. */
export function currentStep(approval: QuestionCarrier | null): number {
  const n = approval?.questions?.length ?? 0;
  if (!n) return 0;
  const s = approval!.step ?? 0;
  return Math.min(Math.max(0, s), n - 1);
}

/** Question `index` has a valid pick. */
export function stepAnswered(approval: QuestionCarrier | null, index: number): boolean {
  const q = approval?.questions?.[index];
  if (!q) return false;
  const p = approval!.picks?.[index] ?? [];
  return p.length > 0 && (q.multiSelect || p.length === 1);
}

/** Moves to the previous (-1) or next (+1) question. Next needs an answer first. */
export function goStep(approval: QuestionCarrier, delta: -1 | 1): boolean {
  const n = approval.questions?.length ?? 0;
  const s = currentStep(approval);
  const to = s + delta;
  if (to < 0 || to >= n) return false;
  if (delta === 1 && !stepAnswered(approval, s)) return false;
  approval.step = to;
  return true;
}

/** Every question has a valid pick: the condition for Submit. */
export function allAnswered(approval: QuestionCarrier | null): boolean {
  const qs = approval?.questions;
  if (!qs?.length) return false;
  return qs.every((q, i) => {
    const p = approval!.picks?.[i] ?? [];
    return p.length > 0 && (q.multiSelect || p.length === 1);
  });
}
