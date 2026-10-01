// Google Calendar — the next few events on your primary calendar, and a nudge
// five minutes before a meeting starts.
//
// There is no Coucou server, so there is no shared "Sign in with Google": the
// user creates a Desktop OAuth client in their own Google Cloud project and
// pastes its ID and secret in Settings. Connecting then runs the installed-app
// flow Google documents for desktop apps — PKCE, a one-shot listener on
// 127.0.0.1, the browser for consent — and keeps only the refresh token, in the
// Credential Manager. Access tokens live in memory for their hour.
//
// Read-only scope. Nothing is ever written to the calendar.

use std::collections::HashSet;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::AppHandle;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use crate::integrations::{client, emit, IntegrationEvent, IntegrationUpdate};
use crate::log;
use crate::secrets;
use crate::time::{now_secs, parse_rfc3339, rfc3339_utc};

const ID: &str = "integration_gcal";
/// Read-only: events, and the list of calendars to read them from.
const SCOPE: &str = concat!(
    "https://www.googleapis.com/auth/calendar.events.readonly ",
    "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
);
const AUTH_URL: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
const REVOKE_URL: &str = "https://oauth2.googleapis.com/revoke";

/// Minutes before an event Mochi speaks up when neither the event, its
/// calendar nor your primary calendar sets any reminder.
const FALLBACK_LEAD: i64 = 5;
/// How long the browser has to come back with a code.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5 * 60);

const EXPIRED: &str = "Google sign-in expired — reconnect in Settings";

// ── Connecting ────────────────────────────────────────────────────────────────

/// Bumped by every Connect and Cancel click, so a newer attempt (or a cancel)
/// retires an older listener still waiting on a browser tab the user closed.
/// Google's own error pages — "access blocked" for an app in Testing whose user
/// isn't on the test list — never redirect back, so without this the wait could
/// only end at the timeout.
static ATTEMPT: AtomicU64 = AtomicU64::new(0);

/// Settings → Cancel: stops waiting for Google within a second.
pub fn cancel() {
    ATTEMPT.fetch_add(1, Ordering::SeqCst);
}

pub async fn connect(app: AppHandle) -> Result<(), String> {
    let (Some(client_id), Some(client_secret)) =
        (secrets::get("gcal-client-id"), secrets::get("gcal-client-secret"))
    else {
        return Err("Save the client ID and client secret first.".into());
    };
    let attempt = ATTEMPT.fetch_add(1, Ordering::SeqCst) + 1;

    let listener = TcpListener::bind("127.0.0.1:0").await.map_err(|e| e.to_string())?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let redirect = format!("http://127.0.0.1:{port}");

    let verifier = b64url(&random_bytes(32)?);
    let challenge = b64url(&sha256(verifier.as_bytes())?);
    let state = b64url(&random_bytes(16)?);

    let url = format!(
        "{AUTH_URL}?{}",
        form(&[
            ("client_id", &client_id),
            ("redirect_uri", &redirect),
            ("response_type", "code"),
            ("scope", SCOPE),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("state", &state),
            // A refresh token, every time — Google only hands one out on consent.
            ("access_type", "offline"),
            ("prompt", "consent"),
        ])
    );
    crate::open_url(url);
    log::line("gcal: waiting for the browser");

    let code = wait_for_code(&listener, &state, attempt).await?;
    drop(listener);

    let response = client()
        .post(TOKEN_URL)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(form(&[
            ("code", &code),
            ("client_id", &client_id),
            ("client_secret", &client_secret),
            ("redirect_uri", &redirect),
            ("grant_type", "authorization_code"),
            ("code_verifier", &verifier),
        ]))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = response.status();
    let body: Value = response.json().await.unwrap_or(json!({}));
    if !status.is_success() {
        return Err(google_error(&body).unwrap_or_else(|| format!("Google answered {status}")));
    }
    let refresh = body["refresh_token"]
        .as_str()
        .ok_or("Google didn't return a refresh token.")?;
    secrets::set("gcal-refresh-token", refresh)?;
    remember_access(&body);
    REMINDED.lock().unwrap().clear();
    *CALENDARS.lock().unwrap() = None;
    log::line("gcal: connected");

    poll(app).await;
    Ok(())
}

/// Serves the one redirect Google sends back, checking `state`, and answers the
/// browser with a page saying it can be closed. Stray requests (a favicon, a
/// stale tab) get a 404 and the wait goes on.
async fn wait_for_code(listener: &TcpListener, state: &str, attempt: u64) -> Result<String, String> {
    let deadline = Instant::now() + CONNECT_TIMEOUT;
    loop {
        if ATTEMPT.load(Ordering::SeqCst) != attempt {
            return Err("Sign-in cancelled.".into());
        }
        if Instant::now() >= deadline {
            return Err("Timed out waiting for Google.".into());
        }
        let Ok(Ok((mut stream, _))) =
            tokio::time::timeout(Duration::from_secs(1), listener.accept()).await
        else {
            continue;
        };

        let mut buf = Vec::with_capacity(2048);
        let mut chunk = [0u8; 2048];
        while buf.len() < 16 * 1024 && !buf.windows(4).any(|w| w == b"\r\n\r\n") {
            match tokio::time::timeout(Duration::from_secs(5), stream.read(&mut chunk)).await {
                Ok(Ok(n)) if n > 0 => buf.extend_from_slice(&chunk[..n]),
                _ => break,
            }
        }
        let request = String::from_utf8_lossy(&buf);
        let target = request
            .lines()
            .next()
            .and_then(|l| l.strip_prefix("GET "))
            .and_then(|l| l.split(' ').next())
            .unwrap_or("");
        let (path, query) = target.split_once('?').unwrap_or((target, ""));
        let params = parse_query(query);
        let param = |k: &str| params.iter().find(|(key, _)| key == k).map(|(_, v)| v.as_str());

        if path != "/" || param("state") != Some(state) {
            let _ = respond(&mut stream, "404 Not Found", "Nothing here.").await;
            continue;
        }
        if let Some(error) = param("error") {
            let _ = respond(&mut stream, "200 OK", "Coucou wasn't given access. You can close this tab.").await;
            return Err(format!("Google sign-in cancelled ({error})."));
        }
        if let Some(code) = param("code") {
            let _ = respond(
                &mut stream,
                "200 OK",
                "Coucou is connected to Google Calendar. You can close this tab.",
            )
            .await;
            return Ok(code.to_string());
        }
        let _ = respond(&mut stream, "400 Bad Request", "Missing code.").await;
    }
}

async fn respond(stream: &mut tokio::net::TcpStream, status: &str, message: &str) -> std::io::Result<()> {
    let html = format!(
        "<!doctype html><meta charset=utf-8><title>Coucou</title>\
         <body style=\"font:15px system-ui;background:#0b0b0c;color:#e8e8ea;\
         display:grid;place-items:center;height:100vh;margin:0\"><p>{message}</p>"
    );
    let reply = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\n\
         Content-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n{html}",
        html.len()
    );
    stream.write_all(reply.as_bytes()).await?;
    stream.shutdown().await
}

/// Revokes the grant at Google (best effort) and forgets the token.
pub async fn disconnect(app: AppHandle) -> Result<(), String> {
    ATTEMPT.fetch_add(1, Ordering::SeqCst);
    if let Some(refresh) = secrets::get("gcal-refresh-token") {
        let _ = client()
            .post(REVOKE_URL)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(form(&[("token", &refresh)]))
            .send()
            .await;
    }
    secrets::clear("gcal-refresh-token")?;
    *ACCESS.lock().unwrap() = None;
    REMINDED.lock().unwrap().clear();
    *CALENDARS.lock().unwrap() = None;
    emit(&app, IntegrationUpdate { id: ID, data: json!({}), error: None, event: None });
    Ok(())
}

// ── Access tokens ─────────────────────────────────────────────────────────────

static ACCESS: Mutex<Option<(String, Instant)>> = Mutex::new(None);

fn remember_access(body: &Value) {
    if let Some(token) = body["access_token"].as_str() {
        let ttl = body["expires_in"].as_u64().unwrap_or(3600);
        // A minute early, so a token never expires between check and use.
        let until = Instant::now() + Duration::from_secs(ttl.saturating_sub(60));
        *ACCESS.lock().unwrap() = Some((token.to_string(), until));
    }
}

async fn access_token(refresh: &str) -> Result<String, String> {
    if let Some((token, until)) = ACCESS.lock().unwrap().clone() {
        if Instant::now() < until {
            return Ok(token);
        }
    }
    let (Some(client_id), Some(client_secret)) =
        (secrets::get("gcal-client-id"), secrets::get("gcal-client-secret"))
    else {
        return Err("Client ID or secret missing".into());
    };
    let response = client()
        .post(TOKEN_URL)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(form(&[
            ("client_id", &client_id),
            ("client_secret", &client_secret),
            ("refresh_token", refresh),
            ("grant_type", "refresh_token"),
        ]))
        .send()
        .await
        .map_err(|_| String::new())?; // offline: say nothing, try again next poll
    let status = response.status();
    let body: Value = response.json().await.unwrap_or(json!({}));
    if !status.is_success() {
        // invalid_grant: revoked, or the 7-day expiry of an OAuth app left in
        // "Testing" — either way only a new sign-in fixes it.
        if body["error"].as_str() == Some("invalid_grant") {
            return Err(EXPIRED.into());
        }
        return Err(google_error(&body).unwrap_or_else(|| format!("Google answered {status}")));
    }
    remember_access(&body);
    body["access_token"].as_str().map(str::to_string).ok_or_else(|| "No access token".into())
}

fn google_error(body: &Value) -> Option<String> {
    body.pointer("/error/message")
        .or_else(|| body.get("error_description"))
        .or_else(|| body.get("error"))
        .and_then(Value::as_str)
        .map(|s| s.chars().take(90).collect())
}

// ── Polling ───────────────────────────────────────────────────────────────────

/// "id@start" of every meeting already announced, so each is announced once
/// (and again if it is moved).
static REMINDED: LazyLock<Mutex<HashSet<String>>> = LazyLock::new(|| Mutex::new(HashSet::new()));

/// A calendar to read: the ones ticked in Google Calendar's sidebar.
#[derive(Clone, Debug)]
struct Calendar {
    id: String,
    name: String,
    color: Option<String>,
    primary: bool,
}

/// The calendar list barely changes: fetched every ten minutes, not every poll.
static CALENDARS: Mutex<Option<(Vec<Calendar>, Instant)>> = Mutex::new(None);
const CALENDARS_TTL: Duration = Duration::from_secs(10 * 60);

/// GET with the cached access token, retrying once with a fresh one when it
/// turns out to have been revoked. `Err(None)`: offline, say nothing and try
/// again next poll. `Err(Some(_))`: a sign-in problem worth showing.
async fn get_json(refresh: &str, url: &str) -> Result<(u16, Value), Option<String>> {
    for _ in 0..2 {
        let token = access_token(refresh).await.map_err(|e| Some(e).filter(|e| !e.is_empty()))?;
        let response = client().get(url).bearer_auth(token).send().await.map_err(|_| None)?;
        let status = response.status().as_u16();
        let json: Value = response.json().await.unwrap_or(json!({}));
        if status == 401 {
            *ACCESS.lock().unwrap() = None;
            continue;
        }
        return Ok((status, json));
    }
    Err(Some(EXPIRED.into()))
}

/// Every calendar shown in Google Calendar — your own, shared and subscribed
/// ones alike — not just the primary one, which is often the emptiest.
async fn calendars(refresh: &str) -> Result<Vec<Calendar>, Option<String>> {
    if let Some((list, at)) = CALENDARS.lock().unwrap().clone() {
        if at.elapsed() < CALENDARS_TTL {
            return Ok(list);
        }
    }
    let url = "https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=reader&maxResults=50";
    let (status, json) = get_json(refresh, url).await?;
    let list = if status == 403 {
        // A token from before Coucou asked for the calendar list: the primary
        // calendar is all it may read until the next Connect.
        log::line("gcal: no calendar-list access, reading the primary calendar only");
        vec![Calendar { id: "primary".into(), name: String::new(), color: None, primary: true }]
    } else if !(200..300).contains(&status) {
        return Err(Some(google_error(&json).unwrap_or_else(|| format!("API error {status}"))));
    } else {
        json["items"]
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .filter(|c| {
                        let shown = c["selected"].as_bool() == Some(true) || c["primary"].as_bool() == Some(true);
                        shown && c["hidden"].as_bool() != Some(true)
                    })
                    .filter_map(|c| {
                        Some(Calendar {
                            id: c["id"].as_str()?.to_string(),
                            // What you renamed it to, else its own name.
                            name: c["summaryOverride"]
                                .as_str()
                                .or_else(|| c["summary"].as_str())
                                .unwrap_or_default()
                                .to_string(),
                            color: c["backgroundColor"].as_str().map(str::to_string),
                            primary: c["primary"].as_bool() == Some(true),
                        })
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    };
    let mut list = list;
    // The primary calendar first: its default reminders stand in for calendars
    // that have none (an imported calendar never does).
    list.sort_by_key(|c| !c.primary);
    *CALENDARS.lock().unwrap() = Some((list.clone(), Instant::now()));
    Ok(list)
}

pub async fn poll(app: AppHandle) {
    let Some(refresh) = secrets::get("gcal-refresh-token") else { return };
    let report = |error: String| {
        emit(&app, IntegrationUpdate { id: ID, data: json!({}), error: Some(error), event: None });
    };

    let list = match calendars(&refresh).await {
        Ok(list) => list,
        Err(None) => return,
        Err(Some(e)) => return report(e),
    };

    let now = now_secs();
    let query = form(&[
        // Events ending after now: what's on right now counts.
        ("timeMin", &rfc3339_utc(now)),
        ("timeMax", &rfc3339_utc(now + 7 * 86_400)),
        ("singleEvents", "true"),
        ("orderBy", "startTime"),
        ("maxResults", "10"),
    ]);

    let mut events: Vec<Event> = Vec::new();
    let mut read_any = false;
    let mut first_error = None;
    // Your main calendar's default reminders; the last resort is FALLBACK_LEAD.
    let mut primary_defaults: Vec<i64> = Vec::new();
    for cal in &list {
        let url = format!("https://www.googleapis.com/calendar/v3/calendars/{}/events?{query}", pct(&cal.id));
        match get_json(&refresh, &url).await {
            Ok((status, json)) if (200..300).contains(&status) => {
                read_any = true;
                let mut defaults = reminder_minutes(&json["defaultReminders"]);
                if cal.primary {
                    primary_defaults = defaults.clone();
                }
                if defaults.is_empty() {
                    defaults = if primary_defaults.is_empty() { vec![FALLBACK_LEAD] } else { primary_defaults.clone() };
                }
                // The events response knows the calendar's real name even when
                // the list was a fallback.
                let mut cal = cal.clone();
                if cal.name.is_empty() {
                    cal.name = json["summary"].as_str().unwrap_or_default().to_string();
                }
                if let Some(items) = json["items"].as_array() {
                    events.extend(items.iter().filter_map(|i| Event::parse(i, &cal, &defaults)));
                }
            }
            Ok((status, json)) => {
                // One unreadable calendar (an import gone stale) shouldn't hide
                // the others. Typically "Google Calendar API has not been used…".
                log::line(format!("gcal: calendar HTTP {status}"));
                first_error.get_or_insert_with(|| google_error(&json).unwrap_or_else(|| format!("API error {status}")));
            }
            Err(None) => return,
            Err(Some(e)) => return report(e),
        }
    }
    if !read_any {
        if let Some(e) = first_error {
            return report(e);
        }
    }

    // An invitation can sit in two calendars at once.
    let mut seen = HashSet::new();
    events.retain(|e| seen.insert(e.id.clone()));
    events.sort_by_key(Event::sort_key);

    let event = reminder(&events, now);
    emit(&app, IntegrationUpdate {
        id: ID,
        data: json!({ "events": events.iter().take(8).map(Event::to_json).collect::<Vec<_>>() }),
        error: None,
        event,
    });
}

/// Minutes from a Calendar `reminders` list (`[{method, minutes}]`), ascending.
/// Email and pop-up alike: either way you asked to be told then.
fn reminder_minutes(list: &Value) -> Vec<i64> {
    let mut out: Vec<i64> = list
        .as_array()
        .map(|l| l.iter().filter_map(|r| r["minutes"].as_i64()).filter(|m| *m >= 0).collect())
        .unwrap_or_default();
    out.sort_unstable();
    out.dedup();
    out
}

/// The reminder that has just come due, the way Google Calendar itself would
/// ring it: at each of the event's reminder times.
///
/// Only the latest reminder due is ever shown — after a restart, a meeting in
/// 20 minutes says "in 20 min" once, not its day-before and its 30-minute
/// reminders back to back. One per poll; a second meeting due at the same
/// moment comes a minute later.
fn reminder(events: &[Event], now: i64) -> Option<IntegrationEvent> {
    let mut reminded = REMINDED.lock().unwrap();
    // Forget events that have dropped off the list, so the set stays small.
    let live: HashSet<String> = events.iter().map(Event::key).collect();
    reminded.retain(|k| live.iter().any(|l| k.starts_with(l.as_str())));

    for e in events {
        let Some(start) = e.start_secs else { continue };
        // A reminder "at the time of the event" still gets its minute.
        if now >= start + 60 {
            continue;
        }
        let due: Vec<i64> = e.reminders.iter().copied().filter(|m| start - m * 60 <= now).collect();
        let Some(latest) = due.iter().min().copied() else { continue };
        if reminded.contains(&format!("{}#{latest}", e.key())) {
            continue;
        }
        for m in &due {
            reminded.insert(format!("{}#{m}", e.key()));
        }
        let minutes = (start - now + 59).div_euclid(60).max(0);
        let mut item = e.to_json();
        item["minutes"] = json!(minutes);
        return Some(IntegrationEvent {
            success: true,
            label: e.title.clone(),
            detail: Some(starts_in(minutes)),
            attention: true,
            item: Some(item),
        });
    }
    None
}

fn starts_in(minutes: i64) -> String {
    match minutes {
        ..=0 => "Starting now".into(),
        1 => "Starts in a minute".into(),
        2..=59 => format!("Starts in {minutes} min"),
        60..=1439 => match (minutes / 60, minutes % 60) {
            (h, 0) => format!("Starts in {h} h"),
            (h, m) => format!("Starts in {h} h {m} min"),
        },
        _ => match minutes / 1440 {
            1 => "Starts in a day".into(),
            d => format!("Starts in {d} days"),
        },
    }
}

#[derive(Debug)]
struct Event {
    id: String,
    title: String,
    /// RFC 3339 for timed events, YYYY-MM-DD for all-day ones.
    start: String,
    end: String,
    start_secs: Option<i64>,
    end_secs: Option<i64>,
    all_day: bool,
    meet_url: Option<String>,
    url: String,
    /// The calendar's colour in Google Calendar, for the row's dot.
    color: Option<String>,
    calendar: String,
    location: Option<String>,
    /// Minutes before the start at which to speak up, ascending. Empty when the
    /// event says "no notification".
    reminders: Vec<i64>,
}

impl Event {
    /// `defaults`: the calendar's default reminders, already resolved to the
    /// primary calendar's (or FALLBACK_LEAD) when it has none.
    fn parse(item: &Value, calendar: &Calendar, defaults: &[i64]) -> Option<Self> {
        if item["status"].as_str() == Some("cancelled") || item["eventType"].as_str() == Some("workingLocation") {
            return None;
        }
        // Declined meetings aren't yours to go to.
        let declined = item["attendees"].as_array().is_some_and(|a| {
            a.iter().any(|p| p["self"].as_bool() == Some(true) && p["responseStatus"].as_str() == Some("declined"))
        });
        if declined {
            return None;
        }
        let when = |k: &str| -> (String, bool) {
            match item[k]["dateTime"].as_str() {
                Some(t) => (t.to_string(), false),
                None => (item[k]["date"].as_str().unwrap_or_default().to_string(), true),
            }
        };
        let (start, all_day) = when("start");
        let (end, _) = when("end");
        if start.is_empty() {
            return None;
        }
        let meet_url = item["hangoutLink"]
            .as_str()
            .map(str::to_string)
            .or_else(|| {
                item.pointer("/conferenceData/entryPoints")?
                    .as_array()?
                    .iter()
                    .find(|p| p["entryPointType"].as_str() == Some("video"))?["uri"]
                    .as_str()
                    .map(str::to_string)
            })
            // Zoom and Teams links pasted into the location field.
            .or_else(|| item["location"].as_str().filter(|l| l.starts_with("https://")).map(str::to_string));
        Some(Event {
            id: item["id"].as_str().unwrap_or_default().to_string(),
            title: item["summary"].as_str().filter(|s| !s.is_empty()).unwrap_or("(No title)").to_string(),
            start_secs: if all_day { None } else { parse_rfc3339(&start) },
            end_secs: if all_day { None } else { parse_rfc3339(&end) },
            start,
            end,
            all_day,
            meet_url,
            url: item["htmlLink"].as_str().unwrap_or_default().to_string(),
            color: calendar.color.clone(),
            calendar: calendar.name.clone(),
            location: item["location"].as_str().filter(|l| !l.is_empty()).map(str::to_string),
            // Your own overrides on this event win — including "none at all".
            reminders: if item["reminders"]["useDefault"].as_bool() == Some(false) {
                reminder_minutes(&item["reminders"]["overrides"])
            } else {
                defaults.to_vec()
            },
        })
    }

    fn key(&self) -> String {
        format!("{}@{}", self.id, self.start)
    }

    /// Chronological across calendars; an all-day event counts from midnight UTC.
    fn sort_key(&self) -> i64 {
        self.start_secs
            .or_else(|| parse_rfc3339(&format!("{}T00:00:00Z", self.start)))
            .unwrap_or(i64::MAX)
    }

    fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "title": self.title,
            "start": self.start,
            "end": self.end,
            "startMs": self.start_secs.map(|s| s * 1000),
            "endMs": self.end_secs.map(|s| s * 1000),
            "allDay": self.all_day,
            "meetUrl": self.meet_url,
            "url": self.url,
            "color": self.color,
            "calendar": self.calendar,
            "location": self.location,
        })
    }
}

// ── Small things std doesn't have ─────────────────────────────────────────────

/// application/x-www-form-urlencoded, also good for query strings.
fn form(pairs: &[(&str, &str)]) -> String {
    pairs.iter().map(|(k, v)| format!("{}={}", pct(k), pct(v))).collect::<Vec<_>>().join("&")
}

fn pct(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn parse_query(q: &str) -> Vec<(String, String)> {
    q.split('&')
        .filter(|p| !p.is_empty())
        .map(|p| {
            let (k, v) = p.split_once('=').unwrap_or((p, ""));
            (pct_decode(k), pct_decode(v))
        })
        .collect()
}

fn pct_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < bytes.len() => {
                let hex = |b: u8| (b as char).to_digit(16);
                match (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                    (Some(hi), Some(lo)) => {
                        out.push((hi * 16 + lo) as u8);
                        i += 2;
                    }
                    _ => out.push(b'%'),
                }
            }
            b => out.push(b),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn b64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        let chars = chunk.len() + 1;
        for i in 0..chars {
            out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
        }
    }
    out
}

/// Windows' own CSPRNG (CNG), so PKCE needs no extra crate.
fn random_bytes(n: usize) -> Result<Vec<u8>, String> {
    use windows::Win32::Security::Cryptography::{BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG};
    let mut buf = vec![0u8; n];
    unsafe { BCryptGenRandom(None, &mut buf, BCRYPT_USE_SYSTEM_PREFERRED_RNG) }
        .ok()
        .map_err(|e| e.to_string())?;
    Ok(buf)
}

fn sha256(data: &[u8]) -> Result<Vec<u8>, String> {
    use windows::Win32::Security::Cryptography::{BCryptHash, BCRYPT_SHA256_ALG_HANDLE};
    let mut out = vec![0u8; 32];
    unsafe { BCryptHash(BCRYPT_SHA256_ALG_HANDLE, None, data, &mut out) }
        .ok()
        .map_err(|e| e.to_string())?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodings() {
        assert_eq!(b64url(b""), "");
        assert_eq!(b64url(b"f"), "Zg");
        assert_eq!(b64url(b"fo"), "Zm8");
        assert_eq!(b64url(b"foo"), "Zm9v");
        assert_eq!(b64url(&[0xfb, 0xff]), "-_8");
        assert_eq!(pct("a b/c:d"), "a%20b%2Fc%3Ad");
        assert_eq!(pct_decode("4%2F0Ab+x%zz%4"), "4/0Ab x%zz%4");
        let q = parse_query("state=abc&code=4%2F0AX&scope=x");
        assert_eq!(q[1], ("code".to_string(), "4/0AX".to_string()));
    }

    #[test]
    fn pkce_primitives() {
        // FIPS 180-2's "abc" vector.
        let hex: String = sha256(b"abc").unwrap().iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        let a = random_bytes(32).unwrap();
        assert_eq!(a.len(), 32);
        assert_ne!(a, random_bytes(32).unwrap());
        // 32 bytes → the 43-character verifier RFC 7636 asks for.
        assert_eq!(b64url(&a).len(), 43);
    }

    /// The loopback listener: strays are ignored, the right redirect yields
    /// its code, and Cancel ends the wait even though Google never came back.
    #[test]
    fn loopback_listener() {
        use std::io::{Read, Write};
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        rt.block_on(async {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            // One after the other, like a browser: the listener stops at the
            // redirect it wants, so anything sent after it would go unanswered.
            let browser = std::thread::spawn(move || {
                ["/favicon.ico", "/?state=wrong&code=evil", "/?state=s3cr3t&code=4%2F0Abc&scope=x"]
                    .map(|path| {
                        let mut s = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
                        write!(s, "GET {path} HTTP/1.1\r\nHost: x\r\n\r\n").unwrap();
                        let mut reply = String::new();
                        let _ = s.read_to_string(&mut reply);
                        reply
                    })
            });

            let attempt = ATTEMPT.fetch_add(1, Ordering::SeqCst) + 1;
            let code = wait_for_code(&listener, "s3cr3t", attempt).await;
            assert_eq!(code.as_deref(), Ok("4/0Abc"));
            let [favicon, forged, real] = browser.join().unwrap();
            assert!(favicon.starts_with("HTTP/1.1 404"));
            assert!(forged.starts_with("HTTP/1.1 404"));
            assert!(real.contains("connected to Google Calendar"));

            // Google's "access blocked" page: no redirect ever arrives.
            let attempt = ATTEMPT.fetch_add(1, Ordering::SeqCst) + 1;
            std::thread::spawn(|| {
                std::thread::sleep(Duration::from_millis(300));
                cancel();
            });
            let started = Instant::now();
            let result = wait_for_code(&listener, "s3cr3t", attempt).await;
            assert_eq!(result, Err("Sign-in cancelled.".to_string()));
            assert!(started.elapsed() < Duration::from_secs(3));
        });
    }

    fn cal() -> Calendar {
        Calendar { id: "primary".into(), name: "Main".into(), color: Some("#16a765".into()), primary: true }
    }

    #[test]
    fn all_day_events_sort_among_timed_ones() {
        let parse = |v: Value| Event::parse(&v, &cal(), &[5]).unwrap();
        let mut events = [
            parse(json!({ "id": "poker", "start": { "dateTime": "2026-10-02T17:30:00Z" }, "end": { "dateTime": "2026-10-02T21:30:00Z" } })),
            parse(json!({ "id": "holiday", "start": { "date": "2026-10-02" }, "end": { "date": "2026-10-03" } })),
            parse(json!({ "id": "today", "start": { "dateTime": "2026-10-01T19:00:00+02:00" }, "end": { "dateTime": "2026-10-01T20:00:00+02:00" } })),
        ];
        events.sort_by_key(Event::sort_key);
        assert_eq!(events.map(|e| e.id), ["today", "holiday", "poker"]);
    }

    fn event(id: &str, start: &str) -> Value {
        json!({ "id": id, "summary": id, "start": { "dateTime": start }, "end": { "dateTime": start } })
    }

    #[test]
    fn events_are_filtered_and_parsed() {
        let declined = json!({
            "id": "d", "start": { "dateTime": "2026-10-01T10:00:00Z" }, "end": { "dateTime": "2026-10-01T11:00:00Z" },
            "attendees": [{ "self": true, "responseStatus": "declined" }],
        });
        assert!(Event::parse(&declined, &cal(), &[5]).is_none());
        let all_day = json!({ "id": "a", "start": { "date": "2026-10-02" }, "end": { "date": "2026-10-03" } });
        let e = Event::parse(&all_day, &cal(), &[5]).unwrap();
        assert!(e.all_day && e.start_secs.is_none());
        let meet = json!({
            "id": "m", "summary": "Standup", "start": { "dateTime": "2026-10-01T10:00:00Z" },
            "end": { "dateTime": "2026-10-01T10:15:00Z" },
            "conferenceData": { "entryPoints": [
                { "entryPointType": "phone", "uri": "tel:+1" },
                { "entryPointType": "video", "uri": "https://meet.google.com/abc" },
            ] },
        });
        assert_eq!(Event::parse(&meet, &cal(), &[5]).unwrap().meet_url.as_deref(), Some("https://meet.google.com/abc"));
    }

    #[test]
    fn reminder_minutes_are_read_and_sorted() {
        let list = json!([{ "method": "popup", "minutes": 30 }, { "method": "email", "minutes": 1440 }, { "method": "popup", "minutes": 30 }]);
        assert_eq!(reminder_minutes(&list), vec![30, 1440]);
        assert_eq!(reminder_minutes(&Value::Null), Vec::<i64>::new());
        let mut e = event("x", "2026-10-02T17:30:00Z");
        e["reminders"] = json!({ "useDefault": false, "overrides": [] });
        // "No notification" on the event beats the calendar's defaults.
        assert!(Event::parse(&e, &cal(), &[30]).unwrap().reminders.is_empty());
        e["reminders"] = json!({ "useDefault": false, "overrides": [{ "method": "popup", "minutes": 10 }] });
        assert_eq!(Event::parse(&e, &cal(), &[30]).unwrap().reminders, vec![10]);
        e["reminders"] = json!({ "useDefault": true });
        assert_eq!(Event::parse(&e, &cal(), &[30, 1440]).unwrap().reminders, vec![30, 1440]);
    }

    /// One test, run in order: REMINDED is shared.
    #[test]
    fn reminders_ring_like_google_calendar() {
        let t = parse_rfc3339("2026-10-02T17:30:00Z").unwrap();
        let min = 60;
        let poker = || vec![Event::parse(&event("poker", "2026-10-02T17:30:00Z"), &cal(), &[30, 1440]).unwrap()];

        // A day ahead, then 30 minutes ahead; once each.
        REMINDED.lock().unwrap().clear();
        let events = poker();
        assert!(reminder(&events, t - 25 * 60 * min).is_none());
        let e = reminder(&events, t - 1440 * min + 30).unwrap();
        assert_eq!(e.detail.as_deref(), Some("Starts in a day"));
        assert!(reminder(&events, t - 1439 * min).is_none());
        assert!(reminder(&events, t - 31 * min).is_none());
        let e = reminder(&events, t - 30 * min).unwrap();
        assert_eq!((e.label.as_str(), e.detail.as_deref()), ("poker", Some("Starts in 30 min")));
        assert!(e.attention);
        let item = e.item.unwrap();
        assert_eq!((item["minutes"].as_i64(), item["calendar"].as_str()), (Some(30), Some("Main")));
        assert!(reminder(&events, t - 29 * min).is_none());

        // Started 20 minutes before the meeting: one reminder, not both.
        REMINDED.lock().unwrap().clear();
        let events = poker();
        assert_eq!(reminder(&events, t - 20 * min).unwrap().detail.as_deref(), Some("Starts in 20 min"));
        assert!(reminder(&events, t - 19 * min).is_none());

        // "At the time of the event" still rings, within its minute.
        REMINDED.lock().unwrap().clear();
        let events = vec![Event::parse(&event("standup", "2026-10-02T17:30:00Z"), &cal(), &[0]).unwrap()];
        assert!(reminder(&events, t - 30).is_none());
        assert_eq!(reminder(&events, t + 10).unwrap().detail.as_deref(), Some("Starting now"));
        REMINDED.lock().unwrap().clear();
        assert!(reminder(&events, t + 90).is_none());

        // Two due at once: the earlier one now, the other on the next poll.
        REMINDED.lock().unwrap().clear();
        let events = vec![
            Event::parse(&event("a", "2026-10-02T17:30:00Z"), &cal(), &[30]).unwrap(),
            Event::parse(&event("b", "2026-10-02T17:40:00Z"), &cal(), &[30]).unwrap(),
        ];
        assert_eq!(reminder(&events, t - 5 * min).unwrap().label, "a");
        assert_eq!(reminder(&events, t - 4 * min).unwrap().label, "b");
        assert!(reminder(&events, t - 3 * min).is_none());
    }

    #[test]
    fn starts_in_reads_naturally() {
        assert_eq!(starts_in(1), "Starts in a minute");
        assert_eq!(starts_in(90), "Starts in 1 h 30 min");
        assert_eq!(starts_in(120), "Starts in 2 h");
        assert_eq!(starts_in(3000), "Starts in 2 days");
    }
}
