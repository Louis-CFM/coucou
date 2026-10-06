export const ROBOT_DEFAULT = "Ctrl+Alt+R";
export function hermesAutoAdvance(question: { multiSelect: boolean }, picks: readonly string[], index: number, total: number): boolean {
  return !question.multiSelect && picks.length === 1 && index < total - 1;
}
export function hermesExpiredEffects() { return { log: true, sound: "blip", returnAfterDelay: true } as const; }
