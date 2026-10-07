// Devin agent sessions — the Windows/Linux port of the macOS DevinMonitor
// (NotchBuddy/Sources/App/DevinMonitor.swift + DevinAPI.swift). Sessions are
// cloud-hosted, so a poller is the event source: same endpoints, same state
// mapping, same cadences (20 s live, 120 s discovery, exponential backoff,
// Retry-After). See docs/INTEGRATIONS.md § 1quinquies for the design.
//
// Nothing is polled without a token in the Credential Manager / Secret Service,
// and nothing is logged but counts, states and sanitized errors — never the
// token, which only ever travels in the Authorization header.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter};

use crate::integrations::PAUSED;
use crate::island::WINDOW_LABEL;
use crate::log;
use crate::secrets;

const API: &str = "https://api.devin.ai/v3";
const TOKEN_KEY: &str = "devin-api-key";
const TIMEOUT: Duration = Duration::from_secs(15);

/// Cadences and windows — the same values as the macOS monitor.
const ACTIVE_INTERVAL: u64 = 20;
const DISCOVERY_INTERVAL: u64 = 120;
const BACKOFF_FLOOR: u64 = 60;
const BACKOFF_CEILING: u64 = 600;
const TERMINAL_WINDOW: i64 = 60;
const UNKNOWN_WINDOW: i64 = 24 * 3600;
/// Discovery only looks at recent creations; deep history cannot crowd the page.
const HISTORY_WINDOW: i64 = 30 * 24 * 3600;
/// Cap on the by-id refresh so the URL stays comfortably small.
const REFRESH_MAX_IDS: usize = 50;

// ── Model (mirrors DevinSession / DevinPhase in DevinAPI.swift) ────────────────

#[derive(Clone, PartialEq, Eq, Debug)]
enum Phase {
    Starting,
    Working,
    Waiting,
    Finished,
    Failed,
    RateLimited,
    Ended,
    /// Unrecognized status: degrade to a "still active" reading — never
    /// success, never failure — and let the unknown window age it out.
    Unknown,
}

impl Phase {
    fn is_attention(&self) -> bool {
        self == &Phase::Waiting
    }
    fn is_live(&self) -> bool {
        matches!(
            self,
            Phase::Starting | Phase::Working | Phase::Waiting | Phase::RateLimited | Phase::Unknown
        )
    }
    fn is_terminal(&self) -> bool {
        matches!(self, Phase::Finished | Phase::Failed | Phase::Ended)
    }
}

/// The documented status mapping (SessionResponse.status + status_detail).
fn phase(status: &str, detail: Option<&str>) -> Phase {
    let d = detail.unwrap_or_default();
    match status {
        "new" | "claimed" | "resuming" => Phase::Starting,
        "running" => match d {
            "waiting_for_user" | "waiting_for_approval" => Phase::Waiting,
            "finished" => Phase::Finished,
            // working, absent or unrecognized detail
            _ => Phase::Working,
        },
        "exit" => Phase::Finished,
        "error" => Phase::Failed,
        "suspended" => match d {
            "error" | "payment_declined" | "contract_expired" => Phase::Failed,
            "usage_limit_exceeded" | "out_of_credits" | "out_of_quota" | "no_quota_allocation"
            | "org_usage_limit_exceeded" | "user_usage_limit_exceeded"
            | "total_session_limit_exceeded" => Phase::RateLimited,
            // inactivity, user_request, absent or unrecognized detail
            _ => Phase::Ended,
        },
        _ => Phase::Unknown,
    }
}

/// Phase → the island's bot state (DevinMonitor.botState).
fn state_name(phase: Option<Phase>) -> &'static str {
    match phase {
        Some(Phase::Starting) => "thinking",
        Some(Phase::Working) | Some(Phase::Unknown) => "working",
        Some(Phase::Waiting) => "question",
        Some(Phase::Finished) => "finished",
        Some(Phase::Failed) => "error",
        Some(Phase::RateLimited) => "ratelimit",
        Some(Phase::Ended) | None => "idle",
    }
}

#[derive(Clone, Debug)]
struct Session {
    id: String,
    url: String,
    title: String,
    status: String,
    detail: Option<String>,
    updated_at: i64,
    prs: usize,
}

impl Session {
    fn phase(&self) -> Phase {
        phase(&self.status, self.detail.as_deref())
    }

    /// Ticker-friendly name: the session title, else the tail of the id.
    fn display_title(&self) -> String {
        if !self.title.is_empty() {
            return self.title.chars().take(40).collect();
        }
        let tail = self.id.strip_prefix("devin-").unwrap_or(&self.id);
        tail.chars().take(8).collect()
    }
}

/// One transition worth a ticker line / a sound (DevinTracker's DevinEvent).
#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DevinTick {
    pub kind: &'static str,
    pub step: String,
}

/// The full snapshot the island applies idempotently.
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct DevinUpdate {
    pub state: &'static str,
    pub name: String,
    pub url: Option<String>,
    /// Sessions on the pill (live + still-displayed terminal).
    pub tracked: usize,
    /// Live sessions only — the idle card's "N active" line.
    pub active: usize,
    pub user: Option<String>,
    pub error: Option<String>,
    pub events: Vec<DevinTick>,
}

// ── Tracker (pure — unit-tested, the DevinTracker port) ───────────────────────

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn is_stale_unknown(session: &Session, now: i64) -> bool {
    session.phase() == Phase::Unknown && now - session.updated_at >= UNKNOWN_WINDOW
}

/// Whether a session belongs on the pill: live sessions, terminal sessions
/// still inside their display window, fresh unknowns only.
fn trackable(session: &Session, now: i64) -> bool {
    if is_stale_unknown(session, now) {
        return false;
    }
    if session.phase().is_live() {
        return true;
    }
    // A missing timestamp keeps the session: the next poll decides.
    now - session.updated_at < TERMINAL_WINDOW
}

/// Merges one poll's sessions into the tracked set and returns the
/// transitions worth surfacing. The first poll is silent — pre-existing
/// sessions populate the pill without sounds, like the GitHub pulse poller.
/// `first_poll` is true until that first poll has been seen.
fn track(
    tracked: &mut HashMap<String, Session>,
    incoming: Vec<Session>,
    now: i64,
    first_poll: &mut bool,
) -> Vec<DevinTick> {
    // First occurrence wins (by-id refresh + discovery dedupe by session id).
    let mut incoming_map: HashMap<String, Session> = HashMap::new();
    for session in incoming {
        incoming_map.entry(session.id.clone()).or_insert(session);
    }
    incoming_map.retain(|_, session| trackable(session, now));

    if *first_poll {
        *tracked = incoming_map;
        *first_poll = false;
        return Vec::new();
    }

    let mut ticks: Vec<DevinTick> = Vec::new();

    // New and changed sessions, newest first, so events read in order.
    let mut sorted: Vec<&Session> = incoming_map.values().collect();
    sorted.sort_by(|a, b| b.updated_at.cmp(&a.updated_at).then(b.id.cmp(&a.id)));
    for session in sorted {
        let phase = session.phase();
        let title = session.display_title();
        match tracked.get(&session.id) {
            None => {
                // A session that was already terminal before Coucou watched
                // is not news.
                if phase.is_live() {
                    ticks.push(DevinTick { kind: "started", step: title });
                }
            }
            Some(prev) => {
                if session.prs > prev.prs {
                    ticks.push(DevinTick { kind: "pr", step: format!("{title} · PR ready") });
                } else if phase != prev.phase() {
                    ticks.push(match phase {
                        Phase::Starting | Phase::Working | Phase::Unknown => DevinTick {
                            kind: "working",
                            step: format!("{title} · working"),
                        },
                        Phase::Waiting => DevinTick {
                            kind: "waiting",
                            step: format!("{title} · waiting for you"),
                        },
                        Phase::Finished => DevinTick {
                            kind: "finished",
                            step: format!("{title} · finished"),
                        },
                        Phase::Failed => {
                            DevinTick { kind: "failed", step: format!("{title} · failed") }
                        }
                        Phase::RateLimited => DevinTick {
                            kind: "rate",
                            step: format!("{title} · usage limit"),
                        },
                        Phase::Ended => DevinTick {
                            kind: "suspended",
                            step: format!("{title} · suspended"),
                        },
                    });
                }
            }
        }
        tracked.insert(session.id.clone(), session.clone());
    }

    // Sessions gone from the page (archived or deleted). An unresolved
    // unknown leaves silently: "suspended" would claim a state the API
    // never confirmed.
    let gone: Vec<String> = tracked
        .keys()
        .filter(|id| !incoming_map.contains_key(*id))
        .cloned()
        .collect();
    for id in gone {
        if let Some(prev) = tracked.remove(&id) {
            if prev.phase().is_live() && !is_stale_unknown(&prev, now) {
                ticks.push(DevinTick {
                    kind: "suspended",
                    step: format!("{} · suspended", prev.display_title()),
                });
            }
        }
    }

    ticks
}

/// Single phase for the pill, most urgent first:
/// failed > waiting > rate-limited > working > starting > finished.
fn aggregate(tracked: &HashMap<String, Session>) -> Option<Phase> {
    let phases: Vec<Phase> = tracked.values().map(Session::phase).collect();
    if phases.is_empty() {
        return None;
    }
    if phases.contains(&Phase::Failed) {
        return Some(Phase::Failed);
    }
    if phases.contains(&Phase::Waiting) {
        return Some(Phase::Waiting);
    }
    if phases.contains(&Phase::RateLimited) {
        return Some(Phase::RateLimited);
    }
    if phases.contains(&Phase::Working) || phases.contains(&Phase::Unknown) {
        return Some(Phase::Working);
    }
    if phases.contains(&Phase::Starting) {
        return Some(Phase::Starting);
    }
    if phases.contains(&Phase::Finished) {
        return Some(Phase::Finished);
    }
    Some(Phase::Ended)
}

/// The session the pill opens in Devin — deterministic rule: the waiting
/// session that updated last, else the live session that updated last, else
/// the session that updated last. updated_at ties break on session id.
fn best_session(tracked: &HashMap<String, Session>) -> Option<Session> {
    let mut ranked: Vec<&Session> = tracked.values().collect();
    ranked.sort_by(|a, b| b.updated_at.cmp(&a.updated_at).then(b.id.cmp(&a.id)));
    let pick = ranked
        .iter()
        .find(|s| s.phase().is_attention())
        .or_else(|| ranked.iter().find(|s| s.phase().is_live()))
        .or_else(|| ranked.first())
        .copied();
    pick.cloned()
}

/// The session that names the pill: the most recently updated session among
/// the ones driving the aggregate phase (leadSession).
fn lead_session(tracked: &HashMap<String, Session>) -> Option<Session> {
    let agg = aggregate(tracked)?;
    tracked
        .values()
        .filter(|s| s.phase() == agg)
        .max_by(|a, b| a.updated_at.cmp(&b.updated_at).then(b.id.cmp(&a.id)))
        .cloned()
}

fn snapshot(
    tracked: &HashMap<String, Session>,
    error: Option<String>,
    user: Option<String>,
    events: Vec<DevinTick>,
) -> DevinUpdate {
    let active = tracked.values().filter(|s| s.phase().is_live()).count();
    let name = lead_session(tracked)
        .map(|s| s.display_title())
        .unwrap_or_else(|| "Devin".to_string());
    DevinUpdate {
        state: state_name(aggregate(tracked)),
        name,
        url: best_session(tracked).map(|s| s.url),
        tracked: tracked.len(),
        active,
        user,
        error,
        events,
    }
}

// ── Parsing (tolerant: one malformed item never drops the whole page) ─────────

fn parse_session(obj: &Value) -> Option<Session> {
    let id = obj.get("session_id")?.as_str()?;
    let url = obj.get("url")?.as_str()?;
    if id.is_empty() || url.is_empty() {
        return None;
    }
    Some(Session {
        id: id.to_string(),
        url: url.to_string(),
        title: obj
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_string(),
        status: obj
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        detail: obj.get("status_detail").and_then(Value::as_str).map(str::to_string),
        updated_at: obj.get("updated_at").and_then(Value::as_i64).unwrap_or(0),
        prs: obj
            .get("pull_requests")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter(|p| p.get("pr_url").and_then(Value::as_str).is_some())
                    .count()
            })
            .unwrap_or(0),
    })
}

fn parse_sessions(json: &Value) -> Vec<Session> {
    let mut seen = std::collections::HashSet::new();
    json.get("items")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(parse_session)
                .filter(|s| seen.insert(s.id.clone()))
                .collect()
        })
        .unwrap_or_default()
}

/// (sessions org, user id, user name) from GET /v3/self with a PAT. None when
/// the account has no Devin sessions organization — it cannot be watched.
fn parse_identity(json: &Value) -> Option<(String, String, String)> {
    Some((
        json.get("devin_sessions_org_id")?.as_str()?.to_string(),
        json.get("user_id")?.as_str()?.to_string(),
        json.get("user_name")?.as_str()?.to_string(),
    ))
}

// ── Process state ──────────────────────────────────────────────────────────────

#[derive(Clone)]
struct Identity {
    org: String,
    user: String,
    name: String,
}

static TRACKED: LazyLock<Mutex<HashMap<String, Session>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static IDENTITY: LazyLock<Mutex<Option<Identity>>> = LazyLock::new(|| Mutex::new(None));
static FIRST_POLL: AtomicBool = AtomicBool::new(true);
static ERRORS: AtomicU32 = AtomicU32::new(0);
static IN_FLIGHT: AtomicBool = AtomicBool::new(false);

fn backoff_delay() -> u64 {
    let n = ERRORS.load(Ordering::Relaxed).min(10);
    BACKOFF_FLOOR
        .saturating_mul(1u64 << n.saturating_sub(1))
        .min(BACKOFF_CEILING)
}

/// Forgets every session and resets the poll state (disconnect, token removed).
fn clear_state() -> DevinUpdate {
    let mut tracked = TRACKED.lock().unwrap();
    tracked.clear();
    FIRST_POLL.store(true, Ordering::Relaxed);
    ERRORS.store(0, Ordering::Relaxed);
    *IDENTITY.lock().unwrap() = None;
    snapshot(&tracked, None, None, Vec::new())
}

/// A poll failure the loop backs off from. The token is never part of it.
struct PollErr {
    message: String,
    retry_after: Option<u64>,
    refetch_identity: bool,
}

impl PollErr {
    fn message(message: &str) -> Self {
        PollErr { message: message.to_string(), retry_after: None, refetch_identity: false }
    }
}

fn status_error(code: u16, retry_after: Option<u64>) -> PollErr {
    match code {
        401 => PollErr::message("Invalid token (401)."),
        403 => PollErr::message("No access to this organization's sessions (403)."),
        404 => PollErr {
            message: "Devin organization not found (404).".into(),
            retry_after: None,
            // The cached identity may be stale; the next poll refetches it.
            refetch_identity: true,
        },
        429 => PollErr {
            message: "Rate limited (429) — backing off.".into(),
            retry_after,
            refetch_identity: false,
        },
        code => PollErr::message(&format!("Devin API error ({code}).")),
    }
}

// ── Loop ──────────────────────────────────────────────────────────────────────

/// Spawns the poll loop. One loop, adaptive cadence: each poll decides how
/// long to wait (20 s live, 120 s discovery, backoff on errors).
pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(8)).await;
        loop {
            let next = poll(&app).await;
            tokio::time::sleep(Duration::from_secs(next)).await;
        }
    });
}

/// One-shot poll for the island's Refresh button; Connect triggers it too.
pub async fn poll_once(app: AppHandle) {
    poll(&app).await;
}

async fn poll(app: &AppHandle) -> u64 {
    if PAUSED.load(Ordering::Relaxed) {
        return DISCOVERY_INTERVAL;
    }
    let Some(token) = secrets::get(TOKEN_KEY) else {
        // Not configured: forget everything once, then stay idle. The loop
        // stays alive so connecting later just works.
        let had_state = {
            let tracked = TRACKED.lock().unwrap();
            !tracked.is_empty() || !FIRST_POLL.load(Ordering::Relaxed)
        };
        if had_state {
            let update = clear_state();
            let _ = app.emit_to(WINDOW_LABEL, "devin", update);
            log::line("devin: token removed, watching stopped");
        }
        return DISCOVERY_INTERVAL;
    };
    if IN_FLIGHT.swap(true, Ordering::Relaxed) {
        return ACTIVE_INTERVAL;
    }
    let result = cycle(&token).await;
    IN_FLIGHT.store(false, Ordering::Relaxed);
    match result {
        Ok(update) => {
            ERRORS.store(0, Ordering::Relaxed);
            let _ = app.emit_to(WINDOW_LABEL, "devin", update);
            let live = TRACKED.lock().unwrap().values().any(|s| s.phase().is_live());
            if live { ACTIVE_INTERVAL } else { DISCOVERY_INTERVAL }
        }
        Err(err) => {
            ERRORS.fetch_add(1, Ordering::Relaxed);
            if err.refetch_identity {
                *IDENTITY.lock().unwrap() = None;
            }
            let tracked = TRACKED.lock().unwrap();
            let update = snapshot(&tracked, Some(err.message.clone()), None, Vec::new());
            drop(tracked);
            let _ = app.emit_to(WINDOW_LABEL, "devin", update);
            log::line(format!("devin: {}", err.message));
            let delay = err
                .retry_after
                .filter(|r| *r > 0)
                .map(|r| r.min(BACKOFF_CEILING))
                .unwrap_or_else(backoff_delay);
            delay
        }
    }
}

async fn cycle(token: &str) -> Result<DevinUpdate, PollErr> {
    let identity = {
        // Clone the inner Option, not the guard.
        let cached = (*IDENTITY.lock().unwrap()).clone();
        match cached {
            Some(i) => i,
            None => {
                let json = http_get("self", &[], token).await?;
                let (org, user, name) = parse_identity(&json)
                    .ok_or_else(|| PollErr::message("Unexpected response from Devin."))?;
                let identity = Identity { org, user, name };
                *IDENTITY.lock().unwrap() = Some(identity.clone());
                identity
            }
        }
    };
    if identity.org.is_empty() {
        return Err(PollErr::message(
            "This account has no Devin organization to watch.",
        ));
    }

    // Discovery: the user's recent, non-archived sessions. Any recency-based
    // ordering puts new sessions on this page; created_after keeps deep
    // history out of it.
    let discovery_query: Vec<(&str, String)> = vec![
        ("first", "200".to_string()),
        ("is_archived", "false".to_string()),
        ("user_ids", identity.user.clone()),
        ("created_after", (now_unix() - HISTORY_WINDOW).to_string()),
    ];
    let path = format!("organizations/{}/sessions", identity.org);
    let mut items = parse_sessions(&http_get(&path, &discovery_query, token).await?);

    // By-id refresh (only while sessions are watched): the tracked sessions
    // re-queried by session_id. Whatever the server's ordering and however
    // much history the user has, a watched session can never be crowded out
    // of the discovery page; missing from both requests it is genuinely
    // archived or deleted. Refresh entries come first: first occurrence
    // wins in the dedupe.
    let mut ranked: Vec<(u8, i64, String)> = TRACKED
        .lock()
        .unwrap()
        .values()
        .map(|s| {
            let rank = if s.phase().is_attention() {
                0
            } else if s.phase().is_live() {
                1
            } else {
                2
            };
            (rank, s.updated_at, s.id.clone())
        })
        .collect();
    ranked.sort_by(|a, b| a.0.cmp(&b.0).then(b.1.cmp(&a.1)).then(b.2.cmp(&a.2)));
    let ids: Vec<String> = ranked
        .into_iter()
        .take(REFRESH_MAX_IDS)
        .map(|(_, _, id)| id)
        .collect();
    if !ids.is_empty() {
        let mut refresh_query: Vec<(&str, String)> = vec![
            ("first", "200".to_string()),
            ("is_archived", "false".to_string()),
        ];
        for id in &ids {
            refresh_query.push(("session_ids", id.clone()));
        }
        let refresh = parse_sessions(&http_get(&path, &refresh_query, token).await?);
        let mut merged = refresh;
        merged.extend(items);
        items = merged;
    }

    let mut tracked = TRACKED.lock().unwrap();
    let mut first_poll = FIRST_POLL.load(Ordering::Relaxed);
    let ticks = track(&mut tracked, items, now_unix(), &mut first_poll);
    FIRST_POLL.store(first_poll, Ordering::Relaxed);
    let update = snapshot(&tracked, None, Some(identity.name.clone()), ticks);
    drop(tracked);
    log::line(format!(
        "devin: watching {} session(s), {} live",
        update.tracked, update.active
    ));
    Ok(update)
}

async fn http_get(path: &str, query: &[(&str, String)], token: &str) -> Result<Value, PollErr> {
    let url = format!("{API}/{path}");
    let response = reqwest::Client::builder()
        .timeout(TIMEOUT)
        .build()
        .unwrap_or_default()
        .get(&url)
        .query(query)
        .header("Authorization", format!("Bearer {token}"))
        .header("Accept", "application/json")
        .send()
        .await;
    match response {
        Ok(r) if r.status().is_success() => r
            .json::<Value>()
            .await
            .map_err(|_| PollErr::message("Unexpected response from Devin.")),
        Ok(r) => {
            let code = r.status().as_u16();
            let retry_after = if code == 429 {
                r.headers()
                    .get("Retry-After")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|s| s.parse::<u64>().ok())
            } else {
                None
            };
            Err(status_error(code, retry_after))
        }
        Err(_) => Err(PollErr::message("Cannot reach api.devin.ai.")),
    }
}

// ── Commands (Settings → Devin) ────────────────────────────────────────────────

/// Validates the token against the official API *before* saving it, stores
/// it in the Credential Manager / Secret Service and starts watching. The
/// token only ever travels inside the Authorization header.
#[tauri::command]
pub async fn devin_connect(app: AppHandle, token: String) -> Result<String, String> {
    let token = token.trim().to_string();
    if token.is_empty() {
        return Err("Enter an API token first.".into());
    }
    let json = http_get("self", &[], &token).await.map_err(|e| e.message)?;
    let (org, _user, name) = parse_identity(&json)
        .ok_or_else(|| "Unexpected response from Devin.".to_string())?;
    if org.is_empty() {
        return Err("This account has no Devin organization to watch.".into());
    }
    secrets::set(TOKEN_KEY, &token).map_err(|e| format!("Could not store the token: {e}"))?;
    log::line("devin: token saved");
    // Watch right away instead of waiting for the discovery cadence.
    tauri::async_runtime::spawn(async move {
        poll_once(app).await;
    });
    Ok(name)
}

/// Removes the credential, forgets every session and clears the pill.
#[tauri::command]
pub fn devin_disconnect(app: AppHandle) -> Result<(), String> {
    secrets::clear(TOKEN_KEY).map_err(|e| format!("Could not remove the token: {e}"))?;
    let update = clear_state();
    let _ = app.emit_to(WINDOW_LABEL, "devin", update);
    log::line("devin: token removed, watching stopped");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn session(id: &str, status: &str, detail: Option<&str>, title: &str, updated_ago: i64) -> Session {
        Session {
            id: id.to_string(),
            url: format!("https://app.devin.ai/sessions/{id}"),
            title: title.to_string(),
            status: status.to_string(),
            detail: detail.map(str::to_string),
            updated_at: 1_000_000 - updated_ago,
            prs: 0,
        }
    }

    #[test]
    fn phase_mapping() {
        assert_eq!(phase("new", None), Phase::Starting);
        assert_eq!(phase("claimed", None), Phase::Starting);
        assert_eq!(phase("resuming", None), Phase::Starting);
        assert_eq!(phase("running", Some("working")), Phase::Working);
        assert_eq!(phase("running", None), Phase::Working);
        assert_eq!(phase("running", Some("waiting_for_user")), Phase::Waiting);
        assert_eq!(phase("running", Some("waiting_for_approval")), Phase::Waiting);
        assert_eq!(phase("running", Some("finished")), Phase::Finished);
        assert_eq!(phase("exit", None), Phase::Finished);
        assert_eq!(phase("error", None), Phase::Failed);
        assert_eq!(phase("suspended", Some("error")), Phase::Failed);
        assert_eq!(phase("suspended", Some("payment_declined")), Phase::Failed);
        assert_eq!(phase("suspended", Some("usage_limit_exceeded")), Phase::RateLimited);
        assert_eq!(phase("suspended", Some("user_usage_limit_exceeded")), Phase::RateLimited);
        assert_eq!(phase("suspended", Some("inactivity")), Phase::Ended);
        assert_eq!(phase("suspended", Some("user_request")), Phase::Ended);
        assert_eq!(phase("suspended", None), Phase::Ended);
        // Unknown values degrade: never success, never failure.
        assert_eq!(phase("migrated", None), Phase::Unknown);
        assert_eq!(phase("running", Some("brand_new")), Phase::Working);
    }

    #[test]
    fn state_names() {
        assert_eq!(state_name(Some(Phase::Starting)), "thinking");
        assert_eq!(state_name(Some(Phase::Working)), "working");
        assert_eq!(state_name(Some(Phase::Unknown)), "working");
        assert_eq!(state_name(Some(Phase::Waiting)), "question");
        assert_eq!(state_name(Some(Phase::Finished)), "finished");
        assert_eq!(state_name(Some(Phase::Failed)), "error");
        assert_eq!(state_name(Some(Phase::RateLimited)), "ratelimit");
        assert_eq!(state_name(Some(Phase::Ended)), "idle");
        assert_eq!(state_name(None), "idle");
    }

    #[test]
    fn first_poll_is_silent() {
        let mut tracked = HashMap::new();
        let mut first = true;
        let ticks = track(
            &mut tracked,
            vec![session("devin-a", "running", Some("working"), "A", 10)],
            1_000_000,
            &mut first,
        );
        assert!(ticks.is_empty());
        // The first poll has been seen: the next one diffs instead of adopting.
        assert!(!first);
        assert_eq!(tracked.len(), 1);
    }

    #[test]
    fn transitions_fire_once() {
        let mut tracked = HashMap::new();
        let mut first = true;
        let now = 1_000_000;
        track(
            &mut tracked,
            vec![session("devin-t", "running", Some("working"), "T", 100)],
            now,
            &mut first,
        );
        let ticks = track(
            &mut tracked,
            vec![session("devin-t", "running", Some("waiting_for_user"), "T", 5)],
            now,
            &mut first,
        );
        assert_eq!(ticks.len(), 1);
        assert_eq!(ticks[0].kind, "waiting");
        assert!(ticks[0].step.contains("waiting for you"));
        // Same state again → no duplicate event.
        let same = track(
            &mut tracked,
            vec![session("devin-t", "running", Some("waiting_for_user"), "T", 2)],
            now,
            &mut first,
        );
        assert!(same.is_empty());
    }

    #[test]
    fn gone_live_session_reports_suspended() {
        let mut tracked = HashMap::new();
        let mut first = true;
        track(
            &mut tracked,
            vec![session("devin-g", "running", Some("working"), "G", 30)],
            1_000_000,
            &mut first,
        );
        let ticks = track(&mut tracked, vec![], 1_000_000, &mut first);
        assert_eq!(ticks.len(), 1);
        assert_eq!(ticks[0].kind, "suspended");
        assert!(tracked.is_empty());
    }

    #[test]
    fn terminal_sessions_age_out_silently() {
        let mut tracked = HashMap::new();
        let mut first = true;
        let now = 1_000_000;
        track(
            &mut tracked,
            vec![session("devin-t1", "running", Some("working"), "T1", 120)],
            now,
            &mut first,
        );
        let done = track(
            &mut tracked,
            vec![session("devin-t1", "exit", None, "T1", 1)],
            now,
            &mut first,
        );
        assert_eq!(done.len(), 1);
        assert_eq!(done[0].kind, "finished");
        // Aged past the 60 s window, still in the page: dropped, no event.
        let later = now + TERMINAL_WINDOW + 5;
        let aged = track(
            &mut tracked,
            vec![session("devin-t1", "exit", None, "T1", 1)],
            later,
            &mut first,
        );
        assert!(aged.is_empty());
        assert!(tracked.is_empty());
    }

    #[test]
    fn stale_unknown_leaves_silently() {
        let mut tracked = HashMap::new();
        let mut first = true;
        let now = 1_000_000;
        // Never adopted in the first place when stale.
        track(
            &mut tracked,
            vec![session("devin-u", "migrated", None, "U", UNKNOWN_WINDOW + 60)],
            now,
            &mut first,
        );
        assert!(tracked.is_empty());
        // Fresh unknown is watched as active…
        track(
            &mut tracked,
            vec![session("devin-u", "migrated", None, "U", 10)],
            now,
            &mut first,
        );
        assert_eq!(tracked.len(), 1);
        // …and leaves silently after the window, without inventing a state.
        let later = now + UNKNOWN_WINDOW + 60;
        let ticks = track(
            &mut tracked,
            vec![session("devin-u", "migrated", None, "U", 10)],
            later,
            &mut first,
        );
        assert!(ticks.is_empty());
        assert!(tracked.is_empty());
    }

    #[test]
    fn concurrent_sessions_stay_isolated() {
        let mut tracked = HashMap::new();
        let mut first = true;
        let now = 1_000_000;
        track(
            &mut tracked,
            vec![
                session("devin-a", "running", Some("working"), "A", 300),
                session("devin-b", "running", Some("waiting_for_user"), "B", 200),
                session("devin-c", "exit", None, "C", 20),
            ],
            now,
            &mut first,
        );
        // B answers: one event, and A survives C's completion.
        let ticks = track(
            &mut tracked,
            vec![
                session("devin-a", "running", Some("working"), "A", 90),
                session("devin-b", "running", Some("working"), "B", 80),
                session("devin-c", "exit", None, "C", 20),
            ],
            now,
            &mut first,
        );
        assert_eq!(ticks.len(), 1);
        assert_eq!(ticks[0].kind, "working");
        assert!(tracked.contains_key("devin-a"));
        assert!(tracked.contains_key("devin-c"));
        // A fails: the aggregate turns to error, B keeps its own phase.
        track(
            &mut tracked,
            vec![
                session("devin-a", "error", None, "A", 10),
                session("devin-b", "running", Some("working"), "B", 5),
                session("devin-c", "exit", None, "C", 20),
            ],
            now,
            &mut first,
        );
        assert_eq!(aggregate(&tracked), Some(Phase::Failed));
        assert_eq!(tracked.get("devin-b").unwrap().phase(), Phase::Working);
    }

    #[test]
    fn aggregate_priority() {
        let mut tracked = HashMap::new();
        assert_eq!(aggregate(&tracked), None);
        tracked.insert("a".into(), session("a", "running", Some("working"), "A", 1));
        assert_eq!(aggregate(&tracked), Some(Phase::Working));
        tracked.insert(
            "b".into(),
            session("b", "suspended", Some("user_usage_limit_exceeded"), "B", 1),
        );
        assert_eq!(aggregate(&tracked), Some(Phase::RateLimited));
        tracked.insert(
            "c".into(),
            session("c", "running", Some("waiting_for_user"), "C", 1),
        );
        assert_eq!(aggregate(&tracked), Some(Phase::Waiting));
        tracked.insert("d".into(), session("d", "error", None, "D", 1));
        assert_eq!(aggregate(&tracked), Some(Phase::Failed));
    }

    #[test]
    fn best_session_is_deterministic() {
        let mut tracked = HashMap::new();
        tracked.insert("a".into(), session("devin-a", "running", Some("working"), "A", 10));
        tracked.insert(
            "b".into(),
            session("devin-b", "running", Some("waiting_for_user"), "B", 100),
        );
        tracked.insert("c".into(), session("devin-c", "exit", None, "C", 1));
        // Waiting wins even though it is not the most recently updated.
        assert_eq!(best_session(&tracked).unwrap().id, "devin-b");
        // Tie on updated_at: the higher session id wins, so the choice is stable.
        let mut tie = HashMap::new();
        tie.insert(
            "x1".into(),
            session("devin-x1", "running", Some("waiting_for_user"), "X1", 50),
        );
        tie.insert(
            "x2".into(),
            session("devin-x2", "running", Some("waiting_for_user"), "X2", 50),
        );
        assert_eq!(best_session(&tie).unwrap().id, "devin-x2");
        // Nothing live: the newest terminal session.
        let mut done = HashMap::new();
        done.insert("c".into(), session("devin-c", "exit", None, "C", 1));
        done.insert("c2".into(), session("devin-c2", "exit", None, "C2", 30));
        assert_eq!(best_session(&done).unwrap().id, "devin-c");
    }

    #[test]
    fn parse_sessions_is_tolerant() {
        let page = json!({
            "items": [
                { "session_id": "devin-ok", "url": "https://app.devin.ai/sessions/devin-ok",
                  "status": "running", "status_detail": "waiting_for_user", "title": "Fix login",
                  "updated_at": 123, "pull_requests": [{ "pr_url": "https://github.com/o/r/pull/1", "pr_state": "open" }] },
                { "session_id": "", "url": "x", "status": "running" },
                { "url": "https://app.devin.ai/sessions/no-id", "status": "running" },
                { "session_id": "devin-future", "url": "https://app.devin.ai/sessions/devin-future",
                  "status": "queued_v4", "status_detail": "new_thing" }
            ],
            "has_next_page": true,
            "end_cursor": "cur=1"
        });
        let sessions = parse_sessions(&page);
        assert_eq!(sessions.len(), 2);
        assert_eq!(sessions[0].id, "devin-ok");
        assert_eq!(sessions[0].prs, 1);
        assert_eq!(sessions[0].phase(), Phase::Waiting);
        assert_eq!(sessions[1].phase(), Phase::Unknown);
        // Malformed page → empty, never a panic.
        assert!(parse_sessions(&json!({})).is_empty());
        // Duplicates: the first occurrence wins.
        let dup = json!({ "items": [
            { "session_id": "devin-d", "url": "https://a/1", "status": "running", "title": "First" },
            { "session_id": "devin-d", "url": "https://a/1", "status": "exit", "title": "Second" }
        ]});
        let sessions = parse_sessions(&dup);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].title, "First");
    }

    #[test]
    fn parse_identity_needs_the_sessions_org() {
        let me = json!({
            "principal_type": "pat_user", "user_id": "user_1", "user_name": "Test User",
            "api_key_id": "k", "api_key_name": "n",
            "devin_sessions_org_id": "org-abc"
        });
        let (org, user, name) = parse_identity(&me).unwrap();
        assert_eq!(org, "org-abc");
        assert_eq!(user, "user_1");
        assert_eq!(name, "Test User");
        assert!(parse_identity(&json!({})).is_none());
        // No sessions org: it cannot be watched.
        let no_org = json!({
            "principal_type": "pat_user", "user_id": "user_1", "user_name": "T",
            "devin_sessions_org_id": null
        });
        assert!(parse_identity(&no_org).is_none());
    }

    #[test]
    fn snapshot_carries_the_pill_view() {
        let mut tracked = HashMap::new();
        tracked.insert(
            "a".into(),
            session("devin-a", "running", Some("working"), "Fix login", 10),
        );
        let update = snapshot(&tracked, None, Some("Test User".into()), vec![]);
        assert_eq!(update.state, "working");
        assert_eq!(update.name, "Fix login");
        assert_eq!(update.url.as_deref(), Some("https://app.devin.ai/sessions/devin-a"));
        assert_eq!(update.tracked, 1);
        assert_eq!(update.active, 1);
        assert_eq!(update.user.as_deref(), Some("Test User"));
    }

    #[test]
    fn backoff_doubles_and_caps() {
        ERRORS.store(0, Ordering::Relaxed);
        assert_eq!(backoff_delay(), 60);
        ERRORS.store(1, Ordering::Relaxed);
        assert_eq!(backoff_delay(), 60);
        ERRORS.store(3, Ordering::Relaxed);
        assert_eq!(backoff_delay(), 240);
        ERRORS.store(20, Ordering::Relaxed);
        assert_eq!(backoff_delay(), 600);
        ERRORS.store(0, Ordering::Relaxed);
    }
}
