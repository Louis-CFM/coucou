// Slack: unread direct messages and recent mentions — the Rust side of
// SlackPoller.swift and SlackParsing.swift, same calls and same parsing.
// Calls and rate limits: docs/INTEGRATIONS.md, section Slack.

use std::collections::{HashMap, HashSet};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::AppHandle;

use crate::integrations::{client, emit, IntegrationEvent, IntegrationUpdate};
use crate::{platform, secrets};

const ID: &str = "integration_slack";
const TOKEN_KEY: &str = "slack-token";
const IM_LIST_MAX_AGE: Duration = Duration::from_secs(600);
const IMS_PER_POLL: usize = 15;
/// Mentions older than this are not "recent" any more.
const MENTION_WINDOW_SECS: f64 = 24.0 * 3600.0;
const SHOWN: usize = 3;

#[derive(Clone, Debug, PartialEq)]
pub struct Identity {
    pub user_id: String,
    pub team_id: String,
    pub url: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Im {
    pub channel_id: String,
    pub user_id: String,
    pub priority: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Message {
    pub dm: bool,
    pub channel_id: String,
    pub channel_name: Option<String>,
    pub user_id: String,
    pub author: String,
    pub text: String,
    pub ts: String,
    pub unread: i64,
    pub permalink: Option<String>,
}

#[derive(Default)]
struct Cache {
    token: Option<String>,
    identity: Option<Identity>,
    ims: Vec<Im>,
    ims_at: Option<Instant>,
    unread: HashSet<String>,
    names: HashMap<String, String>,
    /// Newest message already announced; None until the first poll fills the card.
    last_ts: Option<String>,
    /// Set from a 429's Retry-After: no request before then.
    quiet_until: Option<Instant>,
}

static CACHE: LazyLock<Mutex<Cache>> = LazyLock::new(|| Mutex::new(Cache::default()));

// ── Parsing ───────────────────────────────────────────────────────────────────

/// The Web API answers HTTP 200 with `ok: false` and an error code.
pub fn api_error(json: &Value) -> Option<String> {
    if json.get("ok").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let code = json.get("error").and_then(Value::as_str).unwrap_or("unknown_error");
    if code == "missing_scope" {
        if let Some(needed) = json.get("needed").and_then(Value::as_str) {
            return Some(format!("Missing scope: {needed}"));
        }
    }
    Some(match code {
        "invalid_auth" | "not_authed" | "token_revoked" | "token_expired" | "account_inactive" => {
            "Invalid token".to_string()
        }
        "not_allowed_token_type" => "Use a user token (xoxp-…)".to_string(),
        _ => format!("Slack error: {code}"),
    })
}

/// Errors about one conversation or person, not the token.
const MISSING: [&str; 3] = ["channel_not_found", "channel_is_limited_access", "user_not_found"];

/// One conversation or person Slack no longer finds: skip it, keep polling.
pub fn is_missing(json: &Value) -> bool {
    json.get("ok").and_then(Value::as_bool) != Some(true)
        && json.get("error").and_then(Value::as_str).is_some_and(|c| MISSING.contains(&c))
}

/// auth.test
pub fn parse_identity(json: &Value) -> Option<Identity> {
    if json.get("ok").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    Some(Identity {
        user_id: json.get("user_id")?.as_str()?.to_string(),
        team_id: json.get("team_id")?.as_str()?.to_string(),
        url: json.get("url").and_then(Value::as_str).unwrap_or("").to_string(),
    })
}

/// conversations.list?types=im — skips conversations with deactivated people.
pub fn parse_ims(json: &Value) -> Vec<Im> {
    let Some(list) = json.get("channels").and_then(Value::as_array) else { return vec![] };
    list.iter()
        .filter_map(|c| {
            if c.get("is_im").and_then(Value::as_bool) != Some(true)
                || c.get("is_user_deleted").and_then(Value::as_bool) == Some(true)
            {
                return None;
            }
            Some(Im {
                channel_id: c.get("id")?.as_str()?.to_string(),
                user_id: c.get("user")?.as_str()?.to_string(),
                priority: c.get("priority").and_then(Value::as_f64).unwrap_or(0.0),
            })
        })
        .collect()
}

/// The closest people (Slack's `priority`), plus any conversation unread last time.
pub fn ims_to_check(ims: &[Im], unread: &HashSet<String>, limit: usize) -> Vec<Im> {
    let mut ranked = ims.to_vec();
    ranked.sort_by(|a, b| b.priority.partial_cmp(&a.priority).unwrap_or(std::cmp::Ordering::Equal));
    let mut picked: Vec<Im> = ranked.iter().take(limit).cloned().collect();
    picked.extend(ranked.iter().skip(limit).filter(|im| unread.contains(&im.channel_id)).cloned());
    picked
}

/// conversations.info for a direct message: its latest message when it is unread
/// and someone else sent it.
pub fn parse_unread_dm(json: &Value, me: &str) -> Option<Message> {
    let channel = json.get("channel")?;
    let id = channel.get("id")?.as_str()?;
    let unread = channel.get("unread_count_display").and_then(Value::as_i64).unwrap_or(0);
    if unread <= 0 {
        return None;
    }
    let partner = channel.get("user").and_then(Value::as_str).unwrap_or("");
    let latest = channel.get("latest");
    let author = latest.and_then(|l| l.get("user")).and_then(Value::as_str).unwrap_or(partner);
    if author == me {
        return None;
    }
    let ts = latest
        .and_then(|l| l.get("ts"))
        .or_else(|| channel.get("last_read"))
        .and_then(Value::as_str)
        .unwrap_or("0");
    Some(Message {
        dm: true,
        channel_id: id.to_string(),
        channel_name: None,
        user_id: author.to_string(),
        author: author.to_string(),
        text: latest.and_then(|l| l.get("text")).and_then(Value::as_str).unwrap_or("").to_string(),
        ts: ts.to_string(),
        unread,
        permalink: None,
    })
}

/// search.messages for "<@me>": the recent ones written by someone else.
pub fn parse_mentions(json: &Value, me: &str, now_secs: f64) -> Vec<Message> {
    let Some(matches) = json.pointer("/messages/matches").and_then(Value::as_array) else { return vec![] };
    matches
        .iter()
        .filter_map(|m| {
            let ts = m.get("ts")?.as_str()?;
            let channel = m.get("channel")?;
            let user = m.get("user").and_then(Value::as_str).unwrap_or("");
            if user == me {
                return None;
            }
            let secs: f64 = ts.parse().unwrap_or(0.0);
            if now_secs - secs > MENTION_WINDOW_SECS {
                return None;
            }
            let author = m
                .get("username")
                .and_then(Value::as_str)
                .filter(|u| !u.is_empty())
                .unwrap_or(user);
            Some(Message {
                dm: false,
                channel_id: channel.get("id")?.as_str()?.to_string(),
                channel_name: channel.get("name").and_then(Value::as_str).map(str::to_string),
                user_id: user.to_string(),
                author: author.to_string(),
                text: m.get("text").and_then(Value::as_str).unwrap_or("").to_string(),
                ts: ts.to_string(),
                unread: 0,
                permalink: m.get("permalink").and_then(Value::as_str).map(str::to_string),
            })
        })
        .collect()
}

/// conversations.info: the newest message the user has read there; None without access.
pub fn parse_last_read(json: &Value) -> Option<String> {
    if json.get("ok").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    json.pointer("/channel/last_read").and_then(Value::as_str).map(str::to_string)
}

/// Mentions newer than what the user has read in their channel; kept when that is unknown.
pub fn unread_mentions(mentions: Vec<Message>, last_read: &HashMap<String, String>) -> Vec<Message> {
    mentions
        .into_iter()
        .filter(|m| last_read.get(&m.channel_id).is_none_or(|read| ts_less(read, &m.ts)))
        .collect()
}

/// users.info: the display name, else the real name, else the username.
pub fn parse_user_name(json: &Value) -> Option<String> {
    let user = json.get("user")?;
    [
        json.pointer("/user/profile/display_name"),
        json.pointer("/user/profile/real_name"),
        user.get("real_name"),
        user.get("name"),
    ]
    .into_iter()
    .flatten()
    .filter_map(Value::as_str)
    .find(|s| !s.is_empty())
    .map(str::to_string)
}

/// Slack timestamps ("1513718191.000038") carry more digits than an f64 keeps:
/// compare the seconds and the fraction as integers.
pub fn ts_less(a: &str, b: &str) -> bool {
    fn parts(ts: &str) -> (i64, i64) {
        let (secs, frac) = ts.split_once('.').unwrap_or((ts, ""));
        let frac: String = frac.chars().chain(std::iter::repeat('0')).take(6).collect();
        (secs.parse().unwrap_or(0), frac.parse().unwrap_or(0))
    }
    parts(a) < parts(b)
}

/// Unread direct messages first, then mentions, each newest first.
pub fn merged(mut dms: Vec<Message>, mut mentions: Vec<Message>) -> Vec<Message> {
    let newest_first = |a: &Message, b: &Message| {
        if ts_less(&b.ts, &a.ts) {
            std::cmp::Ordering::Less
        } else if ts_less(&a.ts, &b.ts) {
            std::cmp::Ordering::Greater
        } else {
            std::cmp::Ordering::Equal
        }
    };
    dms.sort_by(newest_first);
    mentions.sort_by(newest_first);
    dms.extend(mentions);
    dms
}

/// Message text as one readable line: Slack's `<@U123>`, `<#C123|general>` and
/// `<https://…|label>` markup resolved, entities unescaped.
pub fn snippet(text: &str, names: &HashMap<String, String>) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(open) = rest.find('<') {
        let Some(len) = rest[open..].find('>') else { break };
        out.push_str(&rest[..open]);
        let inner = &rest[open + 1..open + len];
        let (target, label) = match inner.split_once('|') {
            Some((t, l)) => (t, Some(l)),
            None => (inner, None),
        };
        if let Some(id) = target.strip_prefix('@') {
            out.push('@');
            out.push_str(label.or(names.get(id).map(String::as_str)).unwrap_or(id));
        } else if let Some(name) = target.strip_prefix('#') {
            out.push('#');
            out.push_str(label.unwrap_or(name));
        } else if let Some(special) = target.strip_prefix('!') {
            out.push('@');
            out.push_str(label.unwrap_or(special));
        } else {
            out.push_str(label.unwrap_or(target));
        }
        rest = &rest[open + len + 1..];
    }
    out.push_str(rest);
    let unescaped = out.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&");
    unescaped.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The Slack app's link to a conversation (docs.slack.dev/interactivity/deep-linking).
pub fn app_link(team: &str, channel: &str) -> String {
    format!("slack://channel?team={team}&id={channel}")
}

/// The same conversation in a browser: the message's permalink when there is one.
pub fn web_link(team: &str, channel: &str, permalink: Option<&str>) -> String {
    match permalink {
        Some(p) if p.starts_with("https://") => p.to_string(),
        _ => format!("https://slack.com/app_redirect?channel={channel}&team={team}"),
    }
}

/// Slack IDs are upper-case letters and digits; anything else never reaches a URL.
fn is_slack_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 24 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

// ── Polling ───────────────────────────────────────────────────────────────────

struct Failure(String);

const DEFAULT_RETRY: Duration = Duration::from_secs(60);
const MAX_RETRY: Duration = Duration::from_secs(3600);

/// The wait after a 429: Retry-After, bounded so no value stops the poller for good.
fn retry_after(header: Option<&str>) -> Duration {
    header.and_then(|v| v.trim().parse().ok()).map_or(DEFAULT_RETRY, |s| Duration::from_secs(s).min(MAX_RETRY))
}

async fn send(token: &str, method: &str, params: &[(&str, &str)]) -> Result<Value, Failure> {
    let response = client()
        .get(format!("https://slack.com/api/{method}"))
        .header("Authorization", format!("Bearer {token}"))
        .query(params)
        .send()
        .await
        .map_err(|e| Failure(e.to_string()))?;
    let status = response.status().as_u16();
    if status == 429 {
        let wait = retry_after(response.headers().get("Retry-After").and_then(|v| v.to_str().ok()));
        CACHE.lock().unwrap().quiet_until = Some(Instant::now() + wait);
        return Err(Failure("Slack error: ratelimited".into()));
    }
    if status != 200 {
        return Err(Failure(format!("API error {status}")));
    }
    response.json().await.map_err(|e| Failure(e.to_string()))
}

async fn call(token: &str, method: &str, params: &[(&str, &str)]) -> Result<Value, Failure> {
    let json = send(token, method, params).await?;
    match api_error(&json) {
        Some(e) => Err(Failure(e)),
        None => Ok(json),
    }
}

/// A call about one conversation or person: None when Slack no longer finds it.
async fn call_item(token: &str, method: &str, params: &[(&str, &str)]) -> Result<Option<Value>, Failure> {
    let json = send(token, method, params).await?;
    if is_missing(&json) {
        return Ok(None);
    }
    match api_error(&json) {
        Some(e) => Err(Failure(e)),
        None => Ok(Some(json)),
    }
}

fn reset(cache: &mut Cache, token: Option<String>) {
    *cache = Cache { token, ..Cache::default() };
}

pub async fn poll(app: AppHandle) {
    let token = secrets::get(TOKEN_KEY);
    {
        let mut cache = CACHE.lock().unwrap();
        if cache.token != token {
            reset(&mut cache, token.clone());
        }
        if cache.quiet_until.is_some_and(|t| Instant::now() < t) {
            return;
        }
    }
    let Some(token) = token else { return };

    match fetch(&token).await {
        Ok((identity, messages, unread_dms, mention_count)) => {
            let event = new_message_event(&messages);
            let shown: Vec<Value> = messages.iter().take(SHOWN).map(card_row).collect();
            emit(&app, IntegrationUpdate {
                id: ID,
                data: json!({
                    "messages": shown,
                    "unreadDms": unread_dms,
                    "mentions": mention_count,
                    "workspaceUrl": identity.url,
                }),
                error: None,
                event,
            });
        }
        Err(Failure(message)) => emit(&app, IntegrationUpdate {
            id: ID,
            data: json!({}),
            error: Some(message),
            event: None,
        }),
    }
}

async fn fetch(token: &str) -> Result<(Identity, Vec<Message>, i64, usize), Failure> {
    // Read apart from the match: its lock would otherwise be held across the await.
    let cached = CACHE.lock().unwrap().identity.clone();
    let identity = match cached {
        Some(i) => i,
        None => {
            let json = call(token, "auth.test", &[]).await?;
            let i = parse_identity(&json).ok_or_else(|| Failure("Slack error: auth.test".into()))?;
            CACHE.lock().unwrap().identity = Some(i.clone());
            i
        }
    };
    let me = identity.user_id.as_str();

    let stale = CACHE.lock().unwrap().ims_at.is_none_or(|t| t.elapsed() > IM_LIST_MAX_AGE);
    if stale {
        let json = call(token, "conversations.list", &[("types", "im"), ("exclude_archived", "true"), ("limit", "200")]).await?;
        let mut cache = CACHE.lock().unwrap();
        cache.ims = parse_ims(&json);
        cache.ims_at = Some(Instant::now());
    }
    let to_check = {
        let cache = CACHE.lock().unwrap();
        ims_to_check(&cache.ims, &cache.unread, IMS_PER_POLL)
    };
    let mut dms = Vec::new();
    let mut gone = HashSet::new();
    for im in to_check {
        let Some(json) = call_item(token, "conversations.info", &[("channel", &im.channel_id)]).await? else {
            gone.insert(im.channel_id);
            continue;
        };
        if let Some(dm) = parse_unread_dm(&json, me) {
            dms.push(dm);
        }
    }
    {
        let mut cache = CACHE.lock().unwrap();
        cache.ims.retain(|im| !gone.contains(&im.channel_id));
        cache.unread = dms.iter().map(|d| d.channel_id.clone()).collect();
    }

    let query = format!("<@{me}>");
    let json = call(token, "search.messages", &[("query", &query), ("sort", "timestamp"), ("sort_dir", "desc"), ("count", "20")]).await?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    let found = parse_mentions(&json, me, now);
    let mut last_read = HashMap::new();
    for channel in found.iter().map(|m| m.channel_id.clone()).collect::<HashSet<_>>() {
        if let Some(read) = parse_last_read(&send(token, "conversations.info", &[("channel", &channel)]).await?) {
            last_read.insert(channel, read);
        }
    }
    let mentions = unread_mentions(found, &last_read);

    let mut wanted: HashSet<String> = dms.iter().chain(&mentions).map(|m| m.user_id.clone()).collect();
    wanted.insert(identity.user_id.clone());
    for id in wanted {
        if id.is_empty() || CACHE.lock().unwrap().names.contains_key(&id) {
            continue;
        }
        let json = call_item(token, "users.info", &[("user", &id)]).await?;
        let name = json.as_ref().and_then(parse_user_name).unwrap_or_else(|| id.clone());
        CACHE.lock().unwrap().names.insert(id, name);
    }

    let names = CACHE.lock().unwrap().names.clone();
    let unread_dms: i64 = dms.iter().map(|d| d.unread).sum();
    let mention_count = mentions.len();
    let mut all = merged(dms, mentions);
    for m in &mut all {
        if m.dm {
            if let Some(name) = names.get(&m.user_id) {
                m.author = name.clone();
            }
        }
        m.text = snippet(&m.text, &names);
    }
    Ok((identity, all, unread_dms, mention_count))
}

fn card_row(m: &Message) -> Value {
    let secs: f64 = m.ts.parse().unwrap_or(0.0);
    json!({
        "kind": if m.dm { "dm" } else { "mention" },
        "channelId": m.channel_id,
        "channelName": m.channel_name,
        "author": m.author,
        "text": m.text,
        "date": (secs * 1000.0) as i64,
        "unread": m.unread,
        "permalink": m.permalink,
    })
}

/// A message newer than the last one announced; the first poll only fills the card.
fn new_message_event(messages: &[Message]) -> Option<IntegrationEvent> {
    let newest = messages.iter().reduce(|a, b| if ts_less(&a.ts, &b.ts) { b } else { a })?;
    let mut cache = CACHE.lock().unwrap();
    let previous = cache.last_ts.replace(newest.ts.clone());
    let last = previous?;
    if !ts_less(&last, &newest.ts) {
        return None;
    }
    Some(IntegrationEvent { success: true, label: newest.author.clone(), detail: Some(newest.text.clone()) })
}

// ── Opening ───────────────────────────────────────────────────────────────────

/// Whether something on this system handles slack:// links (the Slack app).
fn app_installed() -> bool {
    #[cfg(target_os = "linux")]
    {
        std::process::Command::new("xdg-mime")
            .args(["query", "default", "x-scheme-handler/slack"])
            .output()
            .map(|o| o.status.success() && !String::from_utf8_lossy(&o.stdout).trim().is_empty())
            .unwrap_or(false)
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        std::process::Command::new("reg")
            .args(["query", r"HKCR\slack", "/v", "URL Protocol"])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }
    #[cfg(not(any(target_os = "linux", windows)))]
    {
        false
    }
}

/// A row of the card: the conversation in the Slack app, else in the browser.
#[tauri::command]
pub async fn slack_open(channel: String, permalink: Option<String>) {
    let Some(team) = CACHE.lock().unwrap().identity.as_ref().map(|i| i.team_id.clone()) else { return };
    if !is_slack_id(&channel) || !is_slack_id(&team) {
        return;
    }
    let installed = tauri::async_runtime::spawn_blocking(app_installed).await.unwrap_or(false);
    let url = if installed { app_link(&team, &channel) } else { web_link(&team, &channel, permalink.as_deref()) };
    platform::open_url(&url);
}

/// The ↗ button: the Slack app, else the workspace in a browser.
#[tauri::command]
pub async fn slack_open_workspace() {
    let installed = tauri::async_runtime::spawn_blocking(app_installed).await.unwrap_or(false);
    if installed {
        platform::open_url("slack://open");
        return;
    }
    let url = CACHE.lock().unwrap().identity.as_ref().map(|i| i.url.clone()).unwrap_or_default();
    platform::open_url(if url.starts_with("https://") { &url } else { "https://app.slack.com" });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retry_after_is_bounded() {
        assert_eq!(retry_after(Some("30")), Duration::from_secs(30));
        assert_eq!(retry_after(None), Duration::from_secs(60));
        assert_eq!(retry_after(Some("soon")), Duration::from_secs(60));
        // A huge value would overflow Instant and end the poller for good.
        assert_eq!(retry_after(Some("18446744073709551615")), Duration::from_secs(3600));
        assert!(Instant::now().checked_add(retry_after(Some("9223372036854775807"))).is_some());
    }

    #[test]
    fn errors_name_the_problem() {
        assert_eq!(api_error(&json!({ "ok": true })), None);
        assert_eq!(api_error(&json!({ "ok": false, "error": "invalid_auth" })).as_deref(), Some("Invalid token"));
        assert_eq!(
            api_error(&json!({ "ok": false, "error": "not_allowed_token_type" })).as_deref(),
            Some("Use a user token (xoxp-…)"),
        );
        assert_eq!(
            api_error(&json!({ "ok": false, "error": "missing_scope", "needed": "search:read" })).as_deref(),
            Some("Missing scope: search:read"),
        );
        assert_eq!(api_error(&json!({ "ok": false, "error": "ratelimited" })).as_deref(), Some("Slack error: ratelimited"));
    }

    #[test]
    fn a_missing_conversation_or_person_is_skipped() {
        assert!(is_missing(&json!({ "ok": false, "error": "channel_not_found" })));
        assert!(is_missing(&json!({ "ok": false, "error": "user_not_found" })));
        assert!(!is_missing(&json!({ "ok": false, "error": "invalid_auth" })));
        assert!(!is_missing(&json!({ "ok": true })));
    }

    #[test]
    fn auth_test_gives_me_and_the_workspace() {
        let me = parse_identity(&json!({
            "ok": true, "url": "https://subarachnoid.slack.com/", "team": "Subarachnoid Workspace",
            "user": "grace", "team_id": "T12345678", "user_id": "W12345678"
        }));
        assert_eq!(me, Some(Identity {
            user_id: "W12345678".into(), team_id: "T12345678".into(), url: "https://subarachnoid.slack.com/".into(),
        }));
        assert_eq!(parse_identity(&json!({ "ok": false, "error": "invalid_auth" })), None);
    }

    #[test]
    fn ims_skip_deactivated_people_and_rank_by_priority() {
        let ims = parse_ims(&json!({ "ok": true, "channels": [
            { "id": "D0C0F7S8Y", "is_im": true, "user": "U0BS9U4SV", "is_user_deleted": false, "priority": 0 },
            { "id": "D0BSHH4AD", "is_im": true, "user": "U0C0NS9HN", "is_user_deleted": true, "priority": 0.9 },
            { "id": "D0BSHH4AE", "is_im": true, "user": "U0C0NS9HP", "priority": 0.5 }
        ]}));
        assert_eq!(ims.iter().map(|i| i.channel_id.as_str()).collect::<Vec<_>>(), ["D0C0F7S8Y", "D0BSHH4AE"]);

        let pool: Vec<Im> = (0..5)
            .map(|n| Im { channel_id: format!("D{n}"), user_id: format!("U{n}"), priority: n as f64 })
            .collect();
        let unread: HashSet<String> = ["D0".to_string()].into();
        let picked: Vec<String> = ims_to_check(&pool, &unread, 2).into_iter().map(|i| i.channel_id).collect();
        assert_eq!(picked, ["D4", "D3", "D0"]);
    }

    #[test]
    fn an_unread_dm_from_someone_else_shows() {
        let dm = parse_unread_dm(&json!({ "ok": true, "channel": {
            "id": "D0BSHH4AD", "is_im": true, "user": "U27FFLNF4", "last_read": "1513718191.000038",
            "latest": { "type": "message", "user": "U27FFLNF4", "text": "Psssst!", "ts": "1513718191.000038" },
            "unread_count": 2, "unread_count_display": 2
        }}), "W1").unwrap();
        assert!(dm.dm);
        assert_eq!((dm.unread, dm.text.as_str(), dm.ts.as_str()), (2, "Psssst!", "1513718191.000038"));

        let read = json!({ "ok": true, "channel": { "id": "D1", "is_im": true, "user": "U2", "unread_count_display": 0 } });
        assert_eq!(parse_unread_dm(&read, "W1"), None);
        let mine = json!({ "ok": true, "channel": { "id": "D1", "is_im": true, "user": "U2", "unread_count_display": 1,
            "latest": { "user": "W1", "text": "done", "ts": "1.0" } } });
        assert_eq!(parse_unread_dm(&mine, "W1"), None);
    }

    #[test]
    fn mentions_are_recent_and_from_others() {
        let mentions = parse_mentions(&json!({ "ok": true, "messages": { "matches": [
            { "user": "U2", "username": "egon", "ts": "1699999000.000100", "text": "<@W1> look",
              "channel": { "id": "C12345678", "name": "general" },
              "permalink": "https://hitchhikers.slack.com/archives/C12345678/p1699999000000100" },
            { "user": "W1", "username": "me", "ts": "1699999500.000000", "text": "note to self",
              "channel": { "id": "C12345678", "name": "general" } },
            { "user": "U3", "username": "ray", "ts": "1600000000.000000", "text": "old",
              "channel": { "id": "C2", "name": "random" } }
        ]}}), "W1", 1_700_000_000.0);
        assert_eq!(mentions.len(), 1);
        assert_eq!(mentions[0].author, "egon");
        assert_eq!(mentions[0].channel_name.as_deref(), Some("general"));

        let read = parse_last_read(&json!({ "ok": true, "channel": { "id": "C12345678", "last_read": "1699999000.000100" } }));
        assert_eq!(read.as_deref(), Some("1699999000.000100"));
        assert_eq!(parse_last_read(&json!({ "ok": false, "error": "missing_scope" })), None);
        let at = |ts: &str| HashMap::from([("C12345678".to_string(), ts.to_string())]);
        assert!(unread_mentions(mentions.clone(), &at("1699999000.000100")).is_empty());
        assert_eq!(unread_mentions(mentions.clone(), &at("1699999000.000099")).len(), 1);
        assert_eq!(unread_mentions(mentions, &HashMap::new()).len(), 1);
    }

    #[test]
    fn user_names_prefer_the_display_name() {
        let real = json!({ "ok": true, "user": { "name": "spengler", "real_name": "Egon Spengler",
            "profile": { "display_name": "", "real_name": "Egon Spengler" } } });
        assert_eq!(parse_user_name(&real).as_deref(), Some("Egon Spengler"));
        let display = json!({ "ok": true, "user": { "name": "spengler", "profile": { "display_name": "egon" } } });
        assert_eq!(parse_user_name(&display).as_deref(), Some("egon"));
    }

    #[test]
    fn timestamps_compare_exactly() {
        assert!(ts_less("1513718191.000038", "1513718191.000039"));
        assert!(!ts_less("1513718191.000039", "1513718191.000038"));
        assert!(ts_less("999999999.9", "1000000000.0"));
    }

    #[test]
    fn snippets_read_like_slack() {
        let names: HashMap<String, String> = [("U2".to_string(), "egon".to_string())].into();
        assert_eq!(
            snippet("<@U2> see <#C1|general>\n<https://x.dev|the doc> &amp; <https://y.dev>", &names),
            "@egon see #general the doc & https://y.dev",
        );
        assert_eq!(snippet("<!here> 3 &lt; 4", &HashMap::new()), "@here 3 < 4");
        assert_eq!(snippet("<@U9>", &HashMap::new()), "@U9");
        assert_eq!(snippet("unclosed < bracket", &HashMap::new()), "unclosed < bracket");
    }

    #[test]
    fn links_open_the_app_or_the_browser() {
        assert_eq!(app_link("T1", "D1"), "slack://channel?team=T1&id=D1");
        assert_eq!(web_link("T1", "C1", Some("https://a.slack.com/archives/C1/p1")), "https://a.slack.com/archives/C1/p1");
        assert_eq!(web_link("T1", "D1", None), "https://slack.com/app_redirect?channel=D1&team=T1");
        assert_eq!(web_link("T1", "D1", Some("javascript:alert(1)")), "https://slack.com/app_redirect?channel=D1&team=T1");
        assert!(is_slack_id("D0BSHH4AD") && !is_slack_id("D1&x=y") && !is_slack_id(""));
    }

    #[test]
    fn only_a_newer_message_is_announced() {
        let msg = |ts: &str| Message {
            dm: true, channel_id: "D1".into(), channel_name: None, user_id: "U1".into(), author: "a".into(),
            text: "hi".into(), ts: ts.into(), unread: 1, permalink: None,
        };
        reset(&mut CACHE.lock().unwrap(), None);
        assert!(new_message_event(&[msg("100.000001")]).is_none()); // first poll: silent
        assert!(new_message_event(&[msg("100.000001")]).is_none()); // same one again
        let event = new_message_event(&[msg("100.000001"), msg("100.000002")]).unwrap();
        assert_eq!((event.label.as_str(), event.detail.as_deref()), ("a", Some("hi")));
        assert_eq!(merged(vec![msg("1.0"), msg("2.0")], vec![]).iter().map(|m| m.ts.as_str()).collect::<Vec<_>>(), ["2.0", "1.0"]);
    }
}
