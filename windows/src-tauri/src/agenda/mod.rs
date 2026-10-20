// The Agenda pill: the day's events from the calendars the user declared, merged in one list.
//
// A calendar is an ICS link: the one Outlook on the web publishes ("Publish a calendar"), iCloud's
// public calendar, Google's secret address, any other. Microsoft Graph would be richer for Outlook,
// but it needs the organisation to approve an app, which a managed tenant can refuse; a link needs
// nobody's approval. The user adds as many as they like (name, link, on or off); the name, the
// colour and the switch are in settings.json, each link is a secret of its own in the keystore.
//
// This file is the part that touches neither the network nor the UI: the shape of an event and of
// a calendar, the window we read, and what the merged list says about itself (conflicts). ics.rs
// reads a calendar file, link.rs fetches one, tz.rs turns Outlook's Windows time zone names into
// the ones chrono knows.

pub mod chat;
pub mod ics;
pub mod link;
mod tz;

use chrono::{DateTime, Local, NaiveDate, TimeZone, Utc};
use serde::{Deserialize, Serialize};

use crate::secrets;

/// Calendars the user may add. Each is read every five minutes, so this is also the most requests
/// one read makes.
pub const MAX_CALENDARS: usize = 10;

/// What every calendar link's key in the keystore starts with (secrets.rs allows exactly this prefix
/// followed by a valid id).
pub const LINK_PREFIX: &str = "agenda-link-";

/// A calendar the user added, as settings.json keeps it. Its link is not here: it is a secret, in the
/// keystore under `link_key(id)`.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct AgendaCalendar {
    /// Lower case letters and digits, made by the settings page; names the calendar's keystore entry.
    pub id: String,
    pub name: String,
    /// The calendar's dot next to its events (`#RRGGBB`).
    pub color: String,
    /// Off keeps the calendar and its link but reads nothing from it.
    pub enabled: bool,
}

impl Default for AgendaCalendar {
    fn default() -> Self {
        AgendaCalendar { id: String::new(), name: String::new(), color: String::new(), enabled: true }
    }
}

/// An id the keystore entry can be named after: short, lower case letters and digits. Anything else
/// is refused, since the id comes from a settings file and ends up in a key name.
pub fn valid_id(id: &str) -> bool {
    (4..=24).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
}

/// The keystore entry of a calendar's link.
pub fn link_key(id: &str) -> String {
    format!("{LINK_PREFIX}{id}")
}

/// What the island receives for one event. Times are Unix seconds. An all-day event has no time of
/// its own: `startDay` and `endDay` (the day after the last, exclusive) are `YYYY-MM-DD`, so it
/// lands on the right day in whatever zone the user is in; its `start` and `end` are those days'
/// midnights in UTC, only there to keep the list in order.
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AgendaEvent {
    pub id: String,
    pub title: String,
    pub start: i64,
    pub end: i64,
    pub all_day: bool,
    pub start_day: Option<String>,
    pub end_day: Option<String>,
    pub location: Option<String>,
    pub join_url: Option<String>,
    /// The id of the calendar it comes from.
    pub source: String,
    /// That calendar's name, as the user gave it.
    pub calendar: String,
    /// That calendar's dot (`#RRGGBB`).
    pub color: String,
    /// False for an event the calendar marks as free (it does not block the time).
    pub busy: bool,
    /// True when another busy event of the day overlaps this one.
    pub conflict: bool,
}

/// What we read: from `from` to `to`, and the same two instants as local dates for all-day events.
#[derive(Clone, Copy, Debug)]
pub struct Window {
    pub from: DateTime<Utc>,
    pub to: DateTime<Utc>,
    pub from_day: NaiveDate,
    pub to_day: NaiveDate,
}

/// Days ahead of today that the list covers.
pub const DAYS_AHEAD: i64 = 7;

impl Window {
    /// Today (from the start of the local day) to `DAYS_AHEAD` days later.
    pub fn from_today(today: NaiveDate, start_of_today: DateTime<Utc>) -> Window {
        let to_day = today + chrono::Duration::days(DAYS_AHEAD);
        Window {
            from: start_of_today,
            to: start_of_today + chrono::Duration::days(DAYS_AHEAD),
            from_day: today,
            to_day,
        }
    }

    /// Whether an event, timed or all-day, touches the window.
    pub fn touches(&self, event: &AgendaEvent) -> bool {
        if event.all_day {
            let (Some(start), Some(end)) = (&event.start_day, &event.end_day) else { return false };
            let (Ok(start), Ok(end)) = (parse_day(start), parse_day(end)) else { return false };
            return end > self.from_day && start < self.to_day;
        }
        let from = self.from.timestamp();
        let to = self.to.timestamp();
        if event.end > event.start {
            event.end > from && event.start < to
        } else {
            event.start >= from && event.start < to
        }
    }
}

/// Today (from midnight, local time) and the days after it.
pub fn window_now() -> Window {
    let today = Local::now().date_naive();
    let midnight = today.and_hms_opt(0, 0, 0).expect("midnight exists");
    let start = Local
        .from_local_datetime(&midnight)
        .earliest()
        .map(|d| d.with_timezone(&Utc))
        .unwrap_or_else(|| midnight.and_utc());
    Window::from_today(today, start)
}

fn parse_day(s: &str) -> Result<NaiveDate, chrono::ParseError> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d")
}

/// Merges the events of every source, in time order, conflicts marked. The island groups them by
/// local day and puts the all-day ones first within a day, so the order here only has to be stable.
pub fn merge(mut events: Vec<AgendaEvent>) -> Vec<AgendaEvent> {
    events.sort_by(|a, b| (a.start, a.end, &a.title, &a.id).cmp(&(b.start, b.end, &b.title, &b.id)));
    mark_conflicts(&mut events);
    events
}

/// Marks the timed, busy events that overlap another timed, busy one. Two events that only touch
/// (one ends when the next starts) do not conflict.
pub fn mark_conflicts(events: &mut [AgendaEvent]) {
    let busy: Vec<usize> = events
        .iter()
        .enumerate()
        .filter(|(_, e)| !e.all_day && e.busy && e.end > e.start)
        .map(|(i, _)| i)
        .collect();
    for &i in &busy {
        events[i].conflict = false;
    }
    for (n, &i) in busy.iter().enumerate() {
        for &j in &busy[n + 1..] {
            if events[i].start < events[j].end && events[j].start < events[i].end {
                events[i].conflict = true;
                events[j].conflict = true;
            }
        }
    }
}

/// Why a calendar gave nothing.
#[derive(Serialize, Clone, Debug)]
pub struct CalendarError {
    pub id: String,
    pub calendar: String,
    pub message: String,
}

/// What a read of the declared calendars brings back.
pub struct Loaded {
    pub events: Vec<AgendaEvent>,
    /// One failing calendar never hides the others' events.
    pub errors: Vec<CalendarError>,
    /// The calendars that were read (on, and with a link in the keystore), for the Check button.
    pub read: Vec<AgendaCalendar>,
}

/// Reads every calendar that is on and has its link, all at once, for the window.
pub async fn load(calendars: &[AgendaCalendar], window: &Window) -> Loaded {
    let mut read = Vec::new();
    let mut tasks = tokio::task::JoinSet::new();
    for calendar in calendars.iter().filter(|c| c.enabled && valid_id(&c.id)).take(MAX_CALENDARS) {
        let Some(url) = secrets::get(&link_key(&calendar.id)) else { continue };
        let (position, calendar, window) = (read.len(), calendar.clone(), *window);
        read.push(calendar.clone());
        tasks.spawn(async move {
            let found = link::fetch(&url)
                .await
                .and_then(|text| ics::events(&text, &calendar.id, &calendar.name, &window));
            (position, found)
        });
    }

    let mut answers: Vec<Option<Result<Vec<AgendaEvent>, String>>> = (0..read.len()).map(|_| None).collect();
    while let Some(done) = tasks.join_next().await {
        if let Ok((position, found)) = done {
            answers[position] = Some(found);
        }
    }

    let mut events = Vec::new();
    let mut errors = Vec::new();
    for (calendar, answer) in read.iter().zip(answers) {
        match answer {
            Some(Ok(found)) => events.extend(found.into_iter().map(|mut e| {
                e.color = calendar.color.clone();
                e
            })),
            Some(Err(message)) => errors.push(CalendarError {
                id: calendar.id.clone(),
                calendar: calendar.name.clone(),
                message,
            }),
            None => {}
        }
    }
    Loaded { events: merge(events), errors, read }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(title: &str, start: i64, end: i64) -> AgendaEvent {
        AgendaEvent {
            id: title.into(),
            title: title.into(),
            start,
            end,
            all_day: false,
            start_day: None,
            end_day: None,
            location: None,
            join_url: None,
            source: "work".into(),
            calendar: "Calendar".into(),
            color: "#7B83EB".into(),
            busy: true,
            conflict: false,
        }
    }

    #[test]
    fn a_calendar_id_is_short_letters_and_digits() {
        assert!(valid_id("a1b2c3d4"));
        assert!(valid_id("abcd"));
        assert!(!valid_id("abc"), "too short");
        assert!(!valid_id(&"a".repeat(25)), "too long");
        assert!(!valid_id("A1B2C3D4"), "lower case only");
        assert!(!valid_id("a1b2-c3d4"));
        assert!(!valid_id("../secret"));
        assert!(!valid_id(""));
        assert_eq!(link_key("a1b2c3d4"), "agenda-link-a1b2c3d4");
    }

    #[test]
    fn overlapping_busy_events_conflict_and_touching_ones_do_not() {
        let merged = merge(vec![
            event("c", 7_200, 10_800),   // touches b only
            event("a", 0, 3_700),        // overlaps b
            event("b", 3_600, 7_200),
        ]);
        let by = |t: &str| merged.iter().find(|e| e.title == t).unwrap().conflict;
        assert!(by("a") && by("b"));
        assert!(!by("c"), "an event that starts when another ends is not a conflict");
    }

    #[test]
    fn a_free_or_all_day_event_never_conflicts() {
        let mut free = event("free", 0, 7_200);
        free.busy = false;
        let mut day = event("day", 0, 86_400);
        day.all_day = true;
        let merged = merge(vec![event("work", 3_600, 5_400), free, day]);
        assert!(merged.iter().all(|e| !e.conflict));
    }

    #[test]
    fn events_come_out_in_time_order() {
        let merged = merge(vec![event("late", 9_000, 9_900), event("early", 100, 200)]);
        assert_eq!(merged[0].title, "early");
    }

    #[test]
    fn the_window_keeps_what_overlaps_it() {
        let from = DateTime::from_timestamp(1_000, 0).unwrap();
        let w = Window {
            from,
            to: DateTime::from_timestamp(2_000, 0).unwrap(),
            from_day: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
            to_day: NaiveDate::from_ymd_opt(2026, 1, 8).unwrap(),
        };
        assert!(w.touches(&event("inside", 1_200, 1_300)));
        assert!(w.touches(&event("running", 500, 1_500)), "started before, still on");
        assert!(!w.touches(&event("ended", 500, 1_000)), "ended exactly when the window opens");
        assert!(!w.touches(&event("after", 2_000, 2_100)));
        let mut day = event("day", 0, 0);
        day.all_day = true;
        day.start_day = Some("2026-01-07".into());
        day.end_day = Some("2026-01-08".into());
        assert!(w.touches(&day), "the last day of the window");
        day.start_day = Some("2026-01-08".into());
        day.end_day = Some("2026-01-09".into());
        assert!(!w.touches(&day));
    }
}
