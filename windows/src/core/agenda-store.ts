// Which of the Agenda's calendars have their link in the credential store. Kept apart from
// core/agenda.ts, which is pure and loads without the bridge.

import { Bridge } from "./bridge";
import { linkKey, type AgendaCalendar } from "./agenda";

/** True when a calendar that is on has its link: the Agenda pill is connected. */
export async function hasCalendarLink(calendars: AgendaCalendar[]): Promise<boolean> {
  for (const calendar of calendars) {
    if (calendar.enabled && (await Bridge.secretPresent(linkKey(calendar.id))) === true) return true;
  }
  return false;
}
