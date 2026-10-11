// Timely — the pure half of TimelyAPI.swift: URLs, OAuth request bodies,
// response parsing and the refresh-once rule, away from the network so they
// can be tested. The poller that uses them is in integrations.rs.

use serde_json::{json, Value};

pub const BASE: &str = "https://api.timelyapp.com/1.1";
/// Out-of-band redirect: Timely shows the code on its own page for the user to paste back.
pub const REDIRECT_URI: &str = "urn:ietf:wg:oauth:2.0:oob";
pub const HTTP_UNAUTHORIZED: u16 = 401;

const SECONDS_PER_DAY: i64 = 86_400;

pub fn authorize_url(client_id: &str) -> String {
    format!(
        "{BASE}/oauth/authorize?response_type=code&redirect_uri={}&client_id={}",
        encode(REDIRECT_URI),
        encode(client_id)
    )
}

/// Percent-encodes everything but RFC 3986's unreserved characters and ':', as URLComponents does.
fn encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b':' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

pub fn code_body(client_id: &str, client_secret: &str, code: &str) -> Value {
    json!({
        "grant_type": "authorization_code",
        "client_id": client_id,
        "client_secret": client_secret,
        "code": code,
        "redirect_uri": REDIRECT_URI,
    })
}

pub fn refresh_body(client_id: &str, client_secret: &str, refresh_token: &str) -> Value {
    json!({
        "grant_type": "refresh_token",
        "client_id": client_id,
        "client_secret": client_secret,
        "refresh_token": refresh_token,
    })
}

#[derive(Debug, PartialEq, Eq)]
pub struct Tokens {
    pub access: String,
    pub refresh: Option<String>,
}

/// A refresh answer may leave out the refresh token: the old one then stays valid.
pub fn parse_tokens(json: &Value, old_refresh: Option<&str>) -> Option<Tokens> {
    let access = json.get("access_token")?.as_str().filter(|s| !s.is_empty())?;
    let refresh = json
        .get("refresh_token")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .or(old_refresh)
        .map(str::to_string);
    Some(Tokens { access: access.to_string(), refresh })
}

/// One entry as the island needs it. `timerStartedOn` is set only while the timer runs.
pub fn parse_entry(e: &Value) -> Option<Value> {
    let id = e.get("id")?.as_i64()?;
    let project = e.get("project");
    let started_on = e.get("timer_started_on").and_then(Value::as_i64).unwrap_or(0);
    let stopped = e.get("timer_state").and_then(Value::as_str) == Some("stop");
    let running = !stopped && started_on > 0;
    let color = project
        .and_then(|p| p.get("color"))
        .and_then(Value::as_str)
        .map(|c| if c.starts_with('#') { c.to_string() } else { format!("#{c}") })
        .unwrap_or_else(|| "#F5A524".into());
    Some(json!({
        "id": id,
        "day": e.get("day").and_then(Value::as_str).unwrap_or(""),
        "project": project.and_then(|p| p.get("name")).and_then(Value::as_str).unwrap_or("Timely"),
        "client": project.and_then(|p| p.get("client")).and_then(|c| c.get("name")).and_then(Value::as_str),
        "color": color,
        "note": e.get("note").and_then(Value::as_str).unwrap_or("").trim(),
        "loggedSeconds": e.get("duration").and_then(|d| d.get("total_seconds")).and_then(Value::as_i64).unwrap_or(0),
        "timerStartedOn": if running { Some(started_on) } else { None },
    }))
}

pub fn parse_entries(json: &Value) -> Option<Vec<Value>> {
    Some(json.as_array()?.iter().filter_map(parse_entry).collect())
}

/// The first account the token reaches (GET /accounts).
pub fn first_account_id(json: &Value) -> Option<i64> {
    json.as_array()?.first()?.get("id")?.as_i64()
}

/// GET /{account}/users/current.
pub fn user_id(json: &Value) -> Option<i64> {
    json.get("id")?.as_i64()
}

/// GET /{account}/users/{id}/capacities: the current period's daily hours.
pub fn daily_capacity(json: &Value) -> Option<f64> {
    let list = json.as_array()?;
    let current = list
        .iter()
        .find(|c| c.get("current").and_then(Value::as_bool) == Some(true))
        .or_else(|| list.first())?;
    current.get("daily_capacity")?.as_f64().filter(|h| *h > 0.0)
}

/// "YYYY-MM-DD" in UTC for a Unix time (Howard Hinnant's civil-from-days).
pub fn utc_day(unix_secs: i64) -> String {
    let days = unix_secs.div_euclid(SECONDS_PER_DAY);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}")
}

/// The days to ask for: wide enough to hold "today" in any time zone. The
/// island keeps the entries of its own local day.
pub fn day_window(now_unix: i64) -> (String, String) {
    (utc_day(now_unix - SECONDS_PER_DAY), utc_day(now_unix + SECONDS_PER_DAY))
}

/// Calls `send` with the access token; on a 401, refreshes once and calls it again.
/// A refresh that fails returns the first 401.
pub async fn with_refresh<S, SF, R, RF>(access: String, send: S, refresh: R) -> (u16, Option<Value>)
where
    S: Fn(String) -> SF,
    SF: std::future::Future<Output = (u16, Option<Value>)>,
    R: FnOnce() -> RF,
    RF: std::future::Future<Output = Option<String>>,
{
    let first = send(access).await;
    if first.0 != HTTP_UNAUTHORIZED {
        return first;
    }
    match refresh().await {
        Some(fresh) => send(fresh).await,
        None => first,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    fn block<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread().build().unwrap().block_on(f)
    }

    // Field names and shapes as Timely returns them (trimmed).
    fn stopped() -> Value {
        json!({
            "id": 1, "day": "2026-10-09", "note": "  Review  ",
            "project": { "name": "Website", "color": "7b00ff", "client": { "name": "Acme" } },
            "duration": { "formatted": "00:09", "total_seconds": 591 },
            "timer_state": "stop", "timer_started_on": 0, "timer_stopped_on": 1791567705
        })
    }

    fn running() -> Value {
        json!({
            "id": 2, "day": "2026-10-09", "note": "",
            "project": { "name": "Support", "color": "#22C55E" },
            "duration": { "total_seconds": 600 },
            "timer_state": "start", "timer_started_on": 1000, "timer_stopped_on": 0
        })
    }

    #[test]
    fn authorize_url_carries_the_out_of_band_redirect() {
        assert_eq!(
            authorize_url("ab c"),
            "https://api.timelyapp.com/1.1/oauth/authorize?response_type=code\
             &redirect_uri=urn:ietf:wg:oauth:2.0:oob&client_id=ab%20c"
        );
    }

    #[test]
    fn request_bodies() {
        let code = code_body("i", "s", "c");
        assert_eq!(code["grant_type"], "authorization_code");
        assert_eq!(code["code"], "c");
        assert_eq!(code["redirect_uri"], REDIRECT_URI);
        let refresh = refresh_body("i", "s", "r");
        assert_eq!(refresh["grant_type"], "refresh_token");
        assert_eq!(refresh["refresh_token"], "r");
    }

    #[test]
    fn tokens_keep_the_old_refresh_token_when_left_out() {
        let pair = json!({ "access_token": "a1", "refresh_token": "r1", "created_at": 1 });
        assert_eq!(parse_tokens(&pair, None), Some(Tokens { access: "a1".into(), refresh: Some("r1".into()) }));
        let access_only = json!({ "access_token": "a2" });
        assert_eq!(
            parse_tokens(&access_only, Some("r1")),
            Some(Tokens { access: "a2".into(), refresh: Some("r1".into()) })
        );
        assert_eq!(parse_tokens(&json!({ "error": "invalid_grant" }), None), None);
    }

    #[test]
    fn entries_stopped_and_running() {
        let list = parse_entries(&json!([stopped(), running(), { "no": "id" }])).unwrap();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["project"], "Website");
        assert_eq!(list[0]["client"], "Acme");
        assert_eq!(list[0]["color"], "#7b00ff");
        assert_eq!(list[0]["note"], "Review");
        assert_eq!(list[0]["loggedSeconds"], 591);
        assert_eq!(list[0]["timerStartedOn"], Value::Null);
        assert_eq!(list[1]["timerStartedOn"], 1000);
        assert_eq!(list[1]["color"], "#22C55E");
        assert_eq!(list[1]["client"], Value::Null);
        assert_eq!(parse_entries(&json!({})), None);
    }

    #[test]
    fn account_user_and_capacity() {
        assert_eq!(first_account_id(&json!([{ "id": 21 }, { "id": 22 }])), Some(21));
        assert_eq!(first_account_id(&json!([])), None);
        assert_eq!(user_id(&json!({ "id": 7 })), Some(7));
        let caps = json!([{ "daily_capacity": 6, "current": false }, { "daily_capacity": 7.5, "current": true }]);
        assert_eq!(daily_capacity(&caps), Some(7.5));
        assert_eq!(daily_capacity(&json!([{ "daily_capacity": 0 }])), None);
    }

    #[test]
    fn days_in_utc() {
        assert_eq!(utc_day(0), "1970-01-01");
        assert_eq!(utc_day(951_782_400), "2000-02-29");
        assert_eq!(utc_day(1_791_567_705), "2026-10-09");
        assert_eq!(day_window(1_791_567_705), ("2026-10-08".into(), "2026-10-10".into()));
    }

    #[test]
    fn refreshes_once_on_401_then_retries() {
        let sent = Mutex::new(Vec::new());
        let result = block(with_refresh(
            "old".into(),
            |token: String| {
                sent.lock().unwrap().push(token.clone());
                async move { (if token == "new" { 200 } else { 401 }, None) }
            },
            || async { Some("new".to_string()) },
        ));
        assert_eq!(result.0, 200);
        assert_eq!(*sent.lock().unwrap(), vec!["old", "new"]);
    }

    #[test]
    fn no_refresh_when_the_first_call_works() {
        let refreshed = Mutex::new(false);
        let result = block(with_refresh(
            "good".into(),
            |_token: String| async { (200, None) },
            || {
                *refreshed.lock().unwrap() = true;
                async { Some("x".to_string()) }
            },
        ));
        assert_eq!(result.0, 200);
        assert!(!*refreshed.lock().unwrap());
    }

    #[test]
    fn a_failed_refresh_returns_the_first_401() {
        let sent = Mutex::new(0);
        let result = block(with_refresh(
            "old".into(),
            |_token: String| {
                *sent.lock().unwrap() += 1;
                async { (401, None) }
            },
            || async { None },
        ));
        assert_eq!(result.0, 401);
        assert_eq!(*sent.lock().unwrap(), 1);
    }
}
