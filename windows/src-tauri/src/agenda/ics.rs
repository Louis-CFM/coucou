// Reads an iCalendar file (what Outlook, iCloud and Google publish) into the events of a
// window: recurrences expanded, one-off changes to an occurrence applied, cancelled events left
// out, time zones put right. No network here, so all of it is tested on plain text.

use std::collections::HashMap;

use chrono::{DateTime, Duration, Local, NaiveDate, NaiveDateTime, TimeZone, Utc};
use icalendar::parser::{read_calendar, unfold, Component, Property};

use crate::i18n::t;

use super::{tz, AgendaEvent, Window};

/// The most occurrences one recurring event may add to a window. A week of a daily event is 7; this
/// only stops a runaway rule ("every second").
const MAX_OCCURRENCES: u16 = 500;

/// An instant, or a whole day (an all-day event has no zone).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum When {
    Day(NaiveDate),
    At(DateTime<Utc>),
}

/// An event as written in the file, before any expansion.
struct Raw {
    uid: String,
    title: String,
    start: When,
    end: Option<When>,
    duration: Option<Duration>,
    rrule: Option<String>,
    exdates: Vec<When>,
    recurrence_id: Option<When>,
    cancelled: bool,
    location: Option<String>,
    join_url: Option<String>,
    busy: bool,
    /// The zone DTSTART was written in, so a weekly 09:00 stays 09:00 across a clock change.
    tzid: Option<chrono_tz::Tz>,
}

/// The events of `window` found in `text`, tagged with their source and calendar.
pub fn events(text: &str, source: &str, calendar: &str, window: &Window) -> Result<Vec<AgendaEvent>, String> {
    // An expired or wrong link often answers with a web page: say so, rather than "no events".
    if !text.contains("BEGIN:VCALENDAR") {
        return Err(t("That link did not return a calendar"));
    }
    let unfolded = unfold(text);
    let calendar_file = read_calendar(&unfolded).map_err(|_| t("That link did not return a calendar"))?;

    let raws: Vec<Raw> = calendar_file
        .components
        .iter()
        .filter(|c| c.name == "VEVENT")
        .filter_map(raw_event)
        .collect();

    // A changed occurrence of a recurring event is its own VEVENT with a RECURRENCE-ID; it replaces
    // the occurrence it names (and a cancelled one just removes it).
    let mut replaced: HashMap<(String, When), ()> = HashMap::new();
    for raw in &raws {
        if let Some(id) = raw.recurrence_id {
            replaced.insert((raw.uid.clone(), id), ());
        }
    }

    let mut out = Vec::new();
    for raw in &raws {
        if raw.cancelled {
            continue;
        }
        if raw.rrule.is_some() && raw.recurrence_id.is_none() {
            for start in occurrences(raw, window) {
                if replaced.contains_key(&(raw.uid.clone(), start)) {
                    continue;
                }
                push_if_in_window(&mut out, raw, start, source, calendar, window);
            }
        } else {
            push_if_in_window(&mut out, raw, raw.start, source, calendar, window);
        }
    }
    Ok(out)
}

fn push_if_in_window(
    out: &mut Vec<AgendaEvent>,
    raw: &Raw,
    start: When,
    source: &str,
    calendar: &str,
    window: &Window,
) {
    let event = build(raw, start, source, calendar);
    if window.touches(&event) {
        out.push(event);
    }
}

fn build(raw: &Raw, start: When, source: &str, calendar: &str) -> AgendaEvent {
    let (start_ts, end_ts, all_day, start_day, end_day) = match start {
        When::Day(first) => {
            // A recurrence keeps the length of the first occurrence. DTEND of an all-day event is
            // the day after its last one; with neither DTEND nor DURATION it lasts a day.
            let days = match (raw.end, raw.start, raw.duration) {
                (Some(When::Day(end)), When::Day(first_start), _) => (end - first_start).num_days(),
                (_, _, Some(d)) => d.num_days(),
                _ => 1,
            };
            let end = first + Duration::days(days.max(1));
            let midnight = |d: NaiveDate| d.and_hms_opt(0, 0, 0).unwrap().and_utc().timestamp();
            (midnight(first), midnight(end), true, Some(fmt_day(first)), Some(fmt_day(end)))
        }
        When::At(at) => {
            let end = match (raw.end, raw.duration, raw.start) {
                // A recurrence keeps the length of the first occurrence.
                (Some(When::At(end)), _, When::At(first)) => at + (end - first),
                (_, Some(d), _) => at + d,
                _ => at,
            };
            (at.timestamp(), end.timestamp(), false, None, None)
        }
    };
    AgendaEvent {
        id: format!("{source}:{}:{start_ts}", raw.uid),
        title: raw.title.clone(),
        start: start_ts,
        end: end_ts,
        all_day,
        start_day,
        end_day,
        location: raw.location.clone(),
        join_url: raw.join_url.clone(),
        source: source.into(),
        calendar: calendar.into(),
        // The calendar's colour is not the file's to say: `load` puts it in.
        color: String::new(),
        busy: raw.busy,
        conflict: false,
    }
}

fn fmt_day(d: NaiveDate) -> String {
    d.format("%Y-%m-%d").to_string()
}

// ── One VEVENT ─────────────────────────────────────────────────────────────────────────────────

fn raw_event(component: &Component) -> Option<Raw> {
    let prop = |name: &str| component.properties.iter().find(|p| p.name == name);
    let text = |name: &str| prop(name).map(|p| unescape(p.val.as_ref())).filter(|s| !s.trim().is_empty());

    let start_prop = prop("DTSTART")?;
    let start = parse_when(start_prop)?;
    let tzid = param(start_prop, "TZID").and_then(|t| tz::resolve(&t));

    let location = text("LOCATION");
    let description = text("DESCRIPTION");
    let join_url = ["X-MICROSOFT-SKYPETEAMSMEETINGURL", "X-MICROSOFT-ONLINEMEETINGEXTERNALLINK"]
        .iter()
        .filter_map(|n| text(n))
        .find_map(|v| https_only(&v))
        .or_else(|| {
            [text("URL"), location.clone(), description.clone()]
                .into_iter()
                .flatten()
                .find_map(|v| find_meeting_link(&v))
        });

    let transparent = text("TRANSP").is_some_and(|v| v.eq_ignore_ascii_case("TRANSPARENT"))
        || text("X-MICROSOFT-CDO-BUSYSTATUS").is_some_and(|v| v.eq_ignore_ascii_case("FREE"));

    Some(Raw {
        uid: text("UID").unwrap_or_else(|| format!("{start:?}")),
        title: text("SUMMARY").unwrap_or_else(|| "(no title)".into()),
        start,
        end: prop("DTEND").and_then(parse_when),
        duration: prop("DURATION").and_then(|p| parse_duration(p.val.as_ref())),
        rrule: text("RRULE"),
        exdates: component
            .properties
            .iter()
            .filter(|p| p.name == "EXDATE")
            .flat_map(parse_whens)
            .collect(),
        recurrence_id: prop("RECURRENCE-ID").and_then(parse_when),
        cancelled: text("STATUS").is_some_and(|v| v.eq_ignore_ascii_case("CANCELLED")),
        location,
        join_url,
        busy: !transparent,
        tzid,
    })
}

fn param(p: &Property, key: &str) -> Option<String> {
    p.params
        .iter()
        .find(|q| q.key.as_ref().eq_ignore_ascii_case(key))
        .and_then(|q| q.val.as_ref())
        .map(|v| v.as_ref().trim_matches('"').to_string())
}

fn parse_when(p: &Property) -> Option<When> {
    parse_whens(p).into_iter().next()
}

/// A date or date-time property, which EXDATE may give as a comma separated list.
fn parse_whens(p: &Property) -> Vec<When> {
    let tzid = param(p, "TZID");
    let is_date = param(p, "VALUE").is_some_and(|v| v.eq_ignore_ascii_case("DATE"));
    p.val
        .as_ref()
        .split(',')
        .filter_map(|v| parse_one(v.trim(), tzid.as_deref(), is_date))
        .collect()
}

fn parse_one(value: &str, tzid: Option<&str>, is_date: bool) -> Option<When> {
    if is_date || value.len() == 8 {
        return NaiveDate::parse_from_str(value, "%Y%m%d").ok().map(When::Day);
    }
    if let Some(utc) = value.strip_suffix('Z') {
        let naive = NaiveDateTime::parse_from_str(utc, "%Y%m%dT%H%M%S").ok()?;
        return Some(When::At(naive.and_utc()));
    }
    let naive = NaiveDateTime::parse_from_str(value, "%Y%m%dT%H%M%S").ok()?;
    // A zone we do not know (or none: "floating", which means the reader's own) is read in the
    // user's own zone, which is nearly always the one the calendar was written in.
    let at = match tzid.and_then(tz::resolve) {
        Some(zone) => local_to_utc(&zone, naive),
        None => local_to_utc(&Local, naive),
    }?;
    Some(When::At(at))
}

/// The instant a wall-clock time is in a zone. A time that does not exist (the clock jumped over
/// it) is read an hour later; one that happens twice, the first time.
fn local_to_utc<Z: TimeZone>(zone: &Z, naive: NaiveDateTime) -> Option<DateTime<Utc>> {
    zone.from_local_datetime(&naive)
        .earliest()
        .or_else(|| zone.from_local_datetime(&(naive + Duration::hours(1))).earliest())
        .map(|d| d.with_timezone(&Utc))
}

/// `PT1H30M`, `P1D`, `-PT15M`.
fn parse_duration(v: &str) -> Option<Duration> {
    let (neg, v) = match v.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, v.strip_prefix('+').unwrap_or(v)),
    };
    let v = v.strip_prefix('P')?;
    let (date, time) = v.split_once('T').unwrap_or((v, ""));
    let mut total = 0i64;
    let mut number = String::new();
    for c in date.chars().chain(time.chars()) {
        if c.is_ascii_digit() {
            number.push(c);
            continue;
        }
        let n: i64 = number.parse().ok()?;
        number.clear();
        total += match c {
            'W' => n * 7 * 86_400,
            'D' => n * 86_400,
            'H' => n * 3_600,
            'M' => n * 60,
            'S' => n,
            _ => return None,
        };
    }
    Some(Duration::seconds(if neg { -total } else { total }))
}

/// iCalendar's text escapes: `\n`, `\,`, `\;`, `\\`.
fn unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') | Some('N') => out.push('\n'),
            Some(other) => out.push(other),
            None => out.push('\\'),
        }
    }
    out
}

// ── Meeting links ──────────────────────────────────────────────────────────────────────────────

/// Hosts whose https links we offer as "Join".
const MEETING_HOSTS: &[&str] = &[
    "teams.microsoft.com",
    "teams.live.com",
    "zoom.us",
    "meet.google.com",
    "webex.com",
];

/// A link is only ever offered if it is https: the island opens it in the browser.
fn https_only(v: &str) -> Option<String> {
    let v = v.trim();
    v.starts_with("https://").then(|| v.to_string())
}

/// The first https link to a known meeting host in a block of text (an invitation's body).
fn find_meeting_link(text: &str) -> Option<String> {
    let mut rest = text;
    while let Some(i) = rest.find("https://") {
        let tail = &rest[i..];
        let end = tail
            .find(|c: char| c.is_whitespace() || matches!(c, '<' | '>' | '"' | '\'' | ')' | ']'))
            .unwrap_or(tail.len());
        let url = tail[..end].trim_end_matches(['.', ',', ';']);
        let host = url["https://".len()..].split(['/', '?', '#']).next().unwrap_or("");
        if MEETING_HOSTS.iter().any(|h| host == *h || host.ends_with(&format!(".{h}"))) {
            return Some(url.to_string());
        }
        rest = &tail["https://".len()..];
    }
    None
}

// ── Recurrence ─────────────────────────────────────────────────────────────────────────────────

/// The starts of a recurring event that may touch the window.
fn occurrences(raw: &Raw, window: &Window) -> Vec<When> {
    let Some(rule) = raw.rrule.as_deref() else { return Vec::new() };
    let rule = normalise_until(rule);

    // The rrule crate wants DTSTART as text. A timed event keeps its zone, so a weekly 09:00 is
    // 09:00 on both sides of a clock change; an all-day one is just its dates, read at midnight UTC.
    let (dtstart, all_day) = match raw.start {
        When::Day(d) => (format!("DTSTART:{}T000000Z", d.format("%Y%m%d")), true),
        When::At(at) => match raw.tzid {
            Some(zone) => {
                let local = at.with_timezone(&zone).naive_local();
                (format!("DTSTART;TZID={}:{}", zone.name(), local.format("%Y%m%dT%H%M%S")), false)
            }
            None => (format!("DTSTART:{}", at.format("%Y%m%dT%H%M%SZ")), false),
        },
    };
    let mut text = format!("{dtstart}\nRRULE:{rule}");
    for ex in &raw.exdates {
        match ex {
            When::Day(d) => text.push_str(&format!("\nEXDATE:{}T000000Z", d.format("%Y%m%d"))),
            When::At(at) => text.push_str(&format!("\nEXDATE:{}", at.format("%Y%m%dT%H%M%SZ"))),
        }
    }

    let Ok(set) = text.parse::<rrule::RRuleSet>() else { return Vec::new() };

    // An event that began before the window may still be running in it.
    let length = match (raw.end, raw.start) {
        (Some(When::At(end)), When::At(start)) => end - start,
        (Some(When::Day(end)), When::Day(start)) => end - start,
        _ => raw.duration.unwrap_or_else(Duration::zero),
    };
    let utc = rrule::Tz::UTC;
    let after = (window.from - length - Duration::days(1)).with_timezone(&utc);
    let before = window.to.with_timezone(&utc);
    let result = set.after(after).before(before).all(MAX_OCCURRENCES);

    result
        .dates
        .into_iter()
        .map(|d| {
            if all_day {
                When::Day(d.date_naive())
            } else {
                When::At(d.with_timezone(&Utc))
            }
        })
        .collect()
}

/// `UNTIL=20261231` (a date) next to a date-time DTSTART is refused by the rule engine; read it as
/// the end of that day.
fn normalise_until(rule: &str) -> String {
    rule.split(';')
        .map(|part| match part.strip_prefix("UNTIL=") {
            Some(v) if v.len() == 8 => format!("UNTIL={v}T235959Z"),
            _ => part.to_string(),
        })
        .collect::<Vec<_>>()
        .join(";")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 2026-01-05 (a Monday) to 2026-01-12, in UTC.
    fn week() -> Window {
        let from = Utc.with_ymd_and_hms(2026, 1, 5, 0, 0, 0).unwrap();
        let day = |d| NaiveDate::from_ymd_opt(2026, 1, d).unwrap();
        Window { from, to: from + Duration::days(7), from_day: day(5), to_day: day(12) }
    }

    fn calendar(body: &str) -> String {
        format!("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:test\r\n{body}END:VCALENDAR\r\n")
    }

    fn read(body: &str) -> Vec<AgendaEvent> {
        let mut found = events(&calendar(body), "outlook", "Calendar", &week()).unwrap();
        found.sort_by_key(|e| e.start);
        found
    }

    fn at(h: u32, m: u32, d: u32) -> i64 {
        Utc.with_ymd_and_hms(2026, 1, d, h, m, 0).unwrap().timestamp()
    }

    #[test]
    fn a_plain_event_in_utc() {
        let found = read(
            "BEGIN:VEVENT\r\nUID:a\r\nSUMMARY:Stand-up\r\nDTSTART:20260106T080000Z\r\nDTEND:20260106T083000Z\r\nEND:VEVENT\r\n",
        );
        assert_eq!(found.len(), 1);
        assert_eq!((found[0].start, found[0].end), (at(8, 0, 6), at(8, 30, 6)));
        assert_eq!(found[0].title, "Stand-up");
        assert!(found[0].busy && !found[0].all_day);
    }

    #[test]
    fn outlooks_windows_zone_names_are_understood() {
        // 09:00 in Paris in January is 08:00 UTC.
        let found = read(
            "BEGIN:VEVENT\r\nUID:a\r\nSUMMARY:x\r\nDTSTART;TZID=Romance Standard Time:20260106T090000\r\nDTEND;TZID=Romance Standard Time:20260106T100000\r\nEND:VEVENT\r\n",
        );
        assert_eq!(found[0].start, at(8, 0, 6));
        assert_eq!(found[0].end, at(9, 0, 6));
    }

    #[test]
    fn a_weekly_event_expands_and_skips_its_exdate() {
        let found = read(
            "BEGIN:VEVENT\r\nUID:w\r\nSUMMARY:Weekly\r\nDTSTART;TZID=Europe/Paris:20251222T090000\r\nDTEND;TZID=Europe/Paris:20251222T100000\r\n\
             RRULE:FREQ=WEEKLY;BYDAY=MO,WE\r\nEXDATE;TZID=Europe/Paris:20260107T090000\r\nEND:VEVENT\r\n",
        );
        // Mon 5 is in; Wed 7 is excluded by its EXDATE; Mon 12 is outside the window.
        let days: Vec<i64> = found.iter().map(|e| e.start).collect();
        assert_eq!(days, vec![at(8, 0, 5)]);
        assert_eq!(found[0].end - found[0].start, 3_600, "keeps the length of the first one");
    }

    #[test]
    fn a_weekly_event_keeps_its_wall_clock_time_across_a_clock_change() {
        // Paris is UTC+1 in winter and UTC+2 after the last Sunday of March.
        let spring = Window {
            from: Utc.with_ymd_and_hms(2026, 3, 23, 0, 0, 0).unwrap(),
            to: Utc.with_ymd_and_hms(2026, 4, 6, 0, 0, 0).unwrap(),
            from_day: NaiveDate::from_ymd_opt(2026, 3, 23).unwrap(),
            to_day: NaiveDate::from_ymd_opt(2026, 4, 6).unwrap(),
        };
        let text = calendar(
            "BEGIN:VEVENT\r\nUID:w\r\nSUMMARY:x\r\nDTSTART;TZID=Europe/Paris:20260105T090000\r\nDTEND;TZID=Europe/Paris:20260105T100000\r\nRRULE:FREQ=WEEKLY\r\nEND:VEVENT\r\n",
        );
        let mut found = events(&text, "outlook", "c", &spring).unwrap();
        found.sort_by_key(|e| e.start);
        let hours: Vec<u32> = found
            .iter()
            .map(|e| chrono::DateTime::from_timestamp(e.start, 0).unwrap().format("%H").to_string().parse().unwrap())
            .collect();
        // Mon 23 Mar (still winter): 08:00 UTC. Mon 30 Mar (summer): 07:00 UTC. Mon 6 Apr is out.
        assert_eq!(hours, vec![8, 7]);
    }

    #[test]
    fn a_changed_occurrence_replaces_the_original_and_a_cancelled_one_disappears() {
        let found = read(
            "BEGIN:VEVENT\r\nUID:m\r\nSUMMARY:Sync\r\nDTSTART:20251229T090000Z\r\nDTEND:20251229T100000Z\r\nRRULE:FREQ=WEEKLY;COUNT=4\r\nEND:VEVENT\r\n\
             BEGIN:VEVENT\r\nUID:m\r\nSUMMARY:Sync (moved)\r\nRECURRENCE-ID:20260105T090000Z\r\nDTSTART:20260105T140000Z\r\nDTEND:20260105T150000Z\r\nEND:VEVENT\r\n\
             BEGIN:VEVENT\r\nUID:m\r\nSUMMARY:Sync\r\nRECURRENCE-ID:20260112T090000Z\r\nDTSTART:20260112T090000Z\r\nDTEND:20260112T100000Z\r\nSTATUS:CANCELLED\r\nEND:VEVENT\r\n",
        );
        // The 5th was moved to 14:00; the 12th is outside the window anyway.
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].title, "Sync (moved)");
        assert_eq!(found[0].start, at(14, 0, 5));
    }

    #[test]
    fn a_cancelled_event_is_left_out() {
        let found = read(
            "BEGIN:VEVENT\r\nUID:c\r\nSUMMARY:x\r\nDTSTART:20260106T080000Z\r\nDTEND:20260106T090000Z\r\nSTATUS:CANCELLED\r\nEND:VEVENT\r\n",
        );
        assert!(found.is_empty());
    }

    #[test]
    fn an_all_day_event_keeps_its_dates() {
        let found = read(
            "BEGIN:VEVENT\r\nUID:d\r\nSUMMARY:Holiday\r\nDTSTART;VALUE=DATE:20260107\r\nDTEND;VALUE=DATE:20260109\r\nEND:VEVENT\r\n",
        );
        assert_eq!(found.len(), 1);
        assert!(found[0].all_day);
        assert_eq!(found[0].start_day.as_deref(), Some("2026-01-07"));
        assert_eq!(found[0].end_day.as_deref(), Some("2026-01-09"), "exclusive: the 7th and the 8th");
    }

    #[test]
    fn a_weekly_all_day_event_expands_by_date() {
        let found = read(
            "BEGIN:VEVENT\r\nUID:d\r\nSUMMARY:Remote day\r\nDTSTART;VALUE=DATE:20251229\r\nDTEND;VALUE=DATE:20251230\r\nRRULE:FREQ=WEEKLY\r\nEND:VEVENT\r\n",
        );
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].start_day.as_deref(), Some("2026-01-05"));
        assert_eq!(found[0].end_day.as_deref(), Some("2026-01-06"));
    }

    #[test]
    fn an_all_day_event_without_dtend_lasts_one_day() {
        let found = read("BEGIN:VEVENT\r\nUID:d\r\nSUMMARY:x\r\nDTSTART;VALUE=DATE:20260108\r\nEND:VEVENT\r\n");
        assert_eq!(found[0].end_day.as_deref(), Some("2026-01-09"));
    }

    #[test]
    fn an_event_outside_the_window_is_dropped_and_one_running_into_it_is_kept() {
        let found = read(
            "BEGIN:VEVENT\r\nUID:o\r\nSUMMARY:old\r\nDTSTART:20251201T080000Z\r\nDTEND:20251201T090000Z\r\nEND:VEVENT\r\n\
             BEGIN:VEVENT\r\nUID:n\r\nSUMMARY:night\r\nDTSTART:20260104T230000Z\r\nDTEND:20260105T010000Z\r\nEND:VEVENT\r\n",
        );
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].title, "night");
    }

    #[test]
    fn a_duration_stands_in_for_dtend() {
        let found = read("BEGIN:VEVENT\r\nUID:p\r\nSUMMARY:x\r\nDTSTART:20260106T080000Z\r\nDURATION:PT1H30M\r\nEND:VEVENT\r\n");
        assert_eq!(found[0].end - found[0].start, 5_400);
    }

    #[test]
    fn a_free_event_is_not_busy() {
        let found = read("BEGIN:VEVENT\r\nUID:f\r\nSUMMARY:x\r\nDTSTART:20260106T080000Z\r\nDTEND:20260106T090000Z\r\nTRANSP:TRANSPARENT\r\nEND:VEVENT\r\n");
        assert!(!found[0].busy);
        let found = read("BEGIN:VEVENT\r\nUID:f\r\nSUMMARY:x\r\nDTSTART:20260106T080000Z\r\nDTEND:20260106T090000Z\r\nX-MICROSOFT-CDO-BUSYSTATUS:FREE\r\nEND:VEVENT\r\n");
        assert!(!found[0].busy);
        let found = read("BEGIN:VEVENT\r\nUID:f\r\nSUMMARY:x\r\nDTSTART:20260106T080000Z\r\nDTEND:20260106T090000Z\r\nX-MICROSOFT-CDO-BUSYSTATUS:TENTATIVE\r\nEND:VEVENT\r\n");
        assert!(found[0].busy, "a tentative event still blocks the time");
    }

    #[test]
    fn the_teams_link_comes_from_the_header_or_from_the_invitation_text() {
        let found = read(
            "BEGIN:VEVENT\r\nUID:t\r\nSUMMARY:x\r\nDTSTART:20260106T080000Z\r\nDTEND:20260106T090000Z\r\nX-MICROSOFT-SKYPETEAMSMEETINGURL:https://teams.microsoft.com/l/meetup-join/abc\r\nEND:VEVENT\r\n",
        );
        assert_eq!(found[0].join_url.as_deref(), Some("https://teams.microsoft.com/l/meetup-join/abc"));

        let found = read(
            "BEGIN:VEVENT\r\nUID:t\r\nSUMMARY:x\r\nDTSTART:20260106T080000Z\r\nDTEND:20260106T090000Z\r\n\
             DESCRIPTION:Join the meeting now\\n<https://teams.microsoft.com/l/meetup-join/xyz?context=1>\\nMeeting ID: 1\r\nEND:VEVENT\r\n",
        );
        assert_eq!(found[0].join_url.as_deref(), Some("https://teams.microsoft.com/l/meetup-join/xyz?context=1"));
    }

    #[test]
    fn only_https_links_to_a_known_meeting_host_are_offered() {
        assert_eq!(find_meeting_link("see http://teams.microsoft.com/l/x"), None, "http is not offered");
        assert_eq!(find_meeting_link("https://evil.example/teams.microsoft.com"), None);
        assert_eq!(find_meeting_link("https://teams.microsoft.com.evil.example/x"), None);
        assert_eq!(
            find_meeting_link("Zoom: https://acme.zoom.us/j/123?pwd=a."),
            Some("https://acme.zoom.us/j/123?pwd=a".to_string())
        );
        assert_eq!(https_only("javascript:alert(1)"), None);
        assert_eq!(https_only("file:///etc/passwd"), None);
    }

    #[test]
    fn folded_lines_and_escapes_are_read() {
        let found = read(
            "BEGIN:VEVENT\r\nUID:e\r\nSUMMARY:Review\\, part one\\; and a very long title that the\r\n  server folded\r\nDTSTART:20260106T080000Z\r\nDTEND:20260106T090000Z\r\nLOCATION:Room 4\\nFloor 2\r\nEND:VEVENT\r\n",
        );
        assert_eq!(found[0].title, "Review, part one; and a very long title that the server folded");
        assert_eq!(found[0].location.as_deref(), Some("Room 4\nFloor 2"));
    }

    #[test]
    fn a_web_page_is_an_error_not_an_empty_day() {
        assert!(events("<html>Sign in</html>", "outlook", "c", &week()).is_err());
    }

    #[test]
    fn a_runaway_rule_is_capped() {
        let found = read(
            "BEGIN:VEVENT\r\nUID:r\r\nSUMMARY:x\r\nDTSTART:20260105T000000Z\r\nDTEND:20260105T000001Z\r\nRRULE:FREQ=SECONDLY\r\nEND:VEVENT\r\n",
        );
        assert!(found.len() <= MAX_OCCURRENCES as usize);
    }

    #[test]
    fn durations_parse() {
        assert_eq!(parse_duration("PT1H30M"), Some(Duration::minutes(90)));
        assert_eq!(parse_duration("P1D"), Some(Duration::days(1)));
        assert_eq!(parse_duration("P1W"), Some(Duration::days(7)));
        assert_eq!(parse_duration("-PT15M"), Some(Duration::minutes(-15)));
        assert_eq!(parse_duration("nonsense"), None);
    }

    #[test]
    fn a_date_only_until_is_read_as_the_end_of_that_day() {
        assert_eq!(normalise_until("FREQ=WEEKLY;UNTIL=20261231;BYDAY=MO"), "FREQ=WEEKLY;UNTIL=20261231T235959Z;BYDAY=MO");
        assert_eq!(normalise_until("FREQ=WEEKLY;UNTIL=20261231T100000Z"), "FREQ=WEEKLY;UNTIL=20261231T100000Z");
    }
}
