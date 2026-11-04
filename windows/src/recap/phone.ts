// The weekly recap as the phone gets it (cap `recap`, docs/ANDROID_LINK.md): the numbers of the last completed week and the busiest agent's
// name. Pure: no DOM, no Tauri; tests/phone-recap.test.mjs runs it as it is. The week is the same one the recap card on the island shows.

import type { PhoneLinkRecap } from "../core/bridge";
import { dayKey, previousWeekStart, summarize, type RecapHistory } from "./summary";

/**
 * Last week's numbers for the phone, or null when the week had no session (the phone then shows no recap). `hideProjects` (the recap's own
 * privacy choice) keeps the project out; Rust adds it for a phone only if that phone may see session details.
 */
export function recapForPhone(history: RecapHistory | null | undefined, now: Date): PhoneLinkRecap | null {
  if (!history) return null;
  const start = previousWeekStart(now);
  const week = summarize(history, start);
  if (!week) return null;
  const recap: PhoneLinkRecap = {
    week: dayKey(start),
    minutes: week.totalMinutes,
    sessions: week.sessionCount,
    files: week.filesChanged,
    linesAdded: week.linesAdded,
    linesRemoved: week.linesRemoved,
    commands: week.commandsRun,
    allowed: week.permissionsAllowed,
    denied: week.permissionsDenied,
  };
  if (week.topAgent) recap.topAgent = week.topAgent;
  if (week.topProject && !history.prefs?.hideProjects) recap.topProject = week.topProject;
  return recap;
}

/** The key of the week the phone is told about: it changes on Monday, and only then is a new recap worth computing. */
export function recapWeekKey(now: Date): string {
  return dayKey(previousWeekStart(now));
}
