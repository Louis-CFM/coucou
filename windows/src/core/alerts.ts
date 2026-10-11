// Which alerts open the island instead of only peeking (Settings → General).
// Keys are these two or an integration's pill ID, the same as the Mac's
// "expandOnAlert" (AlertExpansion in AppState.swift).

import type { IslandViewName } from "./layout";
import { State } from "./state";

export const AGENT_FINISHED = "agentFinished";
export const AGENT_ERROR = "agentError";

/** The integration pills whose alerts can open the island. */
export const ALERT_PILLS: readonly string[] = [
  "integration_n8n", "integration_vercel", "integration_github", "integration_stripe",
  "integration_music", "integration_spotify",
];

export interface AlertHost {
  alert(view: IslandViewName): void;
}

/** Settings asks this alert to open the island, and nothing paused, open or waiting stands in the way. */
export function opensOnAlert(key: string): boolean {
  return State.settings.expandOnAlert.includes(key) &&
    !State.paused && State.mode !== "expanded" && !State.pendingApproval;
}

/** Opens the island on the pill's card when Settings asks for it; false when it did not. */
export function openForAlert(host: AlertHost, key: string, pill: string, view: IslandViewName): boolean {
  if (!opensOnAlert(key) || !State.tasks.some((t) => t.id === pill)) {
    return false;
  }
  State.setFocus(pill);
  host.alert(view);
  return true;
}
