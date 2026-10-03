// Integration pollers — the Rust side of StripePoller / GithubPoller /
// VercelPoller / N8nPoller / ResendPoller / NotionPoller / CalcomPoller, plus
// GitLab and YouTrack, which only exist on Windows.
//
// Same endpoints, same first-run delays and intervals as the Swift pollers. Each
// one emits an `integration` event; the island owns the badge, the sound and the
// 60 s auto-clear, exactly as the Swift handlers do.
//
// Nothing is polled until its key exists in the Credential Manager, and no
// request goes anywhere the user has not configured.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use crate::island::WINDOW_LABEL;
use crate::log;
use crate::secrets;

const TIMEOUT: Duration = Duration::from_secs(10);

/// What the island receives. `event` is only set when something actually changed,
/// which is what drives the pill badge and the sound.
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct IntegrationUpdate {
    pub id: &'static str,
    pub data: Value,
    pub error: Option<String>,
    pub event: Option<IntegrationEvent>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct IntegrationEvent {
    pub success: bool,
    pub label: String,
    pub detail: Option<String>,
}

fn emit(app: &AppHandle, update: IntegrationUpdate) {
    let _ = app.emit_to(WINDOW_LABEL, "integration", update);
}

fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(TIMEOUT)
        .build()
        .unwrap_or_default()
}

/// Set from the tray's Pause item. While it is on, nothing reaches the network:
/// pausing Coucou has to mean pausing Coucou, not just hiding the island.
pub static PAUSED: AtomicBool = AtomicBool::new(false);

pub fn set_paused(on: bool) {
    PAUSED.store(on, Ordering::Relaxed);
}

/// Spawns every poller with the macOS delays and intervals.
pub fn start(app: AppHandle) {
    spawn(app.clone(), "integration_n8n", 3, 15, poll_n8n);
    spawn(app.clone(), "integration_gitlab", 4, 60, poll_gitlab);
    spawn(app.clone(), "integration_youtrack", 5, 60, poll_youtrack);
    spawn(app.clone(), "integration_vercel", 5, 30, poll_vercel);
    spawn(app.clone(), "integration_stripe", 6, 30, poll_stripe);
    spawn(app.clone(), "integration_resend", 6, 60, poll_resend);
    spawn(app.clone(), "integration_github", 7, 300, poll_github);
    spawn(app.clone(), "integration_calcom", 8, 300, poll_calcom);
    spawn(app, "integration_notion", 9, 300, poll_notion);
}

/// True when the user has this integration switched on in settings.
fn enabled(app: &AppHandle, id: &str) -> bool {
    app.try_state::<crate::Shared>()
        .map(|shared| {
            let settings = shared.settings.lock().unwrap();
            settings.active_integrations.iter().any(|x| x == id)
        })
        .unwrap_or(false)
}

fn spawn<F, Fut>(app: AppHandle, id: &'static str, delay_secs: u64, every_secs: u64, poll: F)
where
    F: Fn(AppHandle) -> Fut + Send + 'static,
    Fut: std::future::Future<Output = ()> + Send,
{
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(delay_secs)).await;
        let mut ticker = tokio::time::interval(Duration::from_secs(every_secs));
        loop {
            ticker.tick().await;
            // The ticker keeps its cadence; we just decline to do the work. An
            // integration the user switched off, or a paused app, must make no
            // network calls at all — CLAUDE.md allows talking only to services
            // the user configured, and a disabled one is not configured.
            if PAUSED.load(Ordering::Relaxed) || !enabled(&app, id) {
                continue;
            }
            poll(app.clone()).await;
        }
    });
}

/// One-shot refresh from the Refresh buttons in the island.
pub async fn poll_once(app: AppHandle, id: &str) {
    match id {
        "integration_stripe" => poll_stripe(app).await,
        "integration_github" => poll_github(app).await,
        "integration_vercel" => poll_vercel(app).await,
        "integration_n8n" => poll_n8n(app).await,
        "integration_resend" => poll_resend(app).await,
        "integration_notion" => poll_notion(app).await,
        "integration_calcom" => poll_calcom(app).await,
        "integration_gitlab" => poll_gitlab(app).await,
        "integration_youtrack" => poll_youtrack(app).await,
        _ => {}
    }
}

/// Remembers the newest id per integration so an event fires once, not on every poll.
struct Seen(Mutex<std::collections::HashMap<&'static str, String>>);

static SEEN: std::sync::LazyLock<Seen> =
    std::sync::LazyLock::new(|| Seen(Mutex::new(std::collections::HashMap::new())));

/// Returns true the first time a given id is seen (and false on the very first
/// load, which only fills the card).
fn is_new(key: &'static str, id: &str) -> bool {
    let mut map = SEEN.0.lock().unwrap();
    match map.insert(key, id.to_string()) {
        Some(previous) => previous != id,
        None => false, // first poll: populate silently, like the Swift pollers
    }
}

fn status_error(code: u16, unauthorised_hint: &str) -> String {
    match code {
        401 => "Invalid API key (401)".into(),
        403 => unauthorised_hint.into(),
        _ => format!("API error {code}"),
    }
}

// ── Stripe ────────────────────────────────────────────────────────────────────

async fn poll_stripe(app: AppHandle) {
    let Some(key) = secrets::get("stripe-api-key") else { return };
    let auth = format!("Basic {}", crate::claude::base64_for(format!("{key}:").as_bytes()));
    let http = client();

    let balance = http
        .get("https://api.stripe.com/v1/balance")
        .header("Authorization", &auth)
        .send()
        .await;

    let (amount, currency) = match balance {
        Ok(r) if r.status().is_success() => {
            let json: Value = r.json().await.unwrap_or(json!({}));
            let mut buckets: Vec<Value> = Vec::new();
            for k in ["available", "pending"] {
                if let Some(arr) = json.get(k).and_then(Value::as_array) {
                    buckets.extend(arr.iter().cloned());
                }
            }
            let currency = buckets
                .first()
                .and_then(|b| b.get("currency"))
                .and_then(Value::as_str)
                .unwrap_or("eur")
                .to_string();
            let amount: i64 = buckets
                .iter()
                .filter_map(|b| b.get("amount").and_then(Value::as_i64))
                .sum();
            (amount, currency)
        }
        Ok(r) => {
            let code = r.status().as_u16();
            emit(&app, IntegrationUpdate {
                id: "integration_stripe",
                data: json!({}),
                error: Some(status_error(code, "Use a secret key (sk_live_… not pk_live_…)")),
                event: None,
            });
            return;
        }
        Err(e) => {
            emit(&app, IntegrationUpdate {
                id: "integration_stripe",
                data: json!({}),
                error: Some(format!("No connection: {e}")),
                event: None,
            });
            return;
        }
    };

    let charges = http
        .get("https://api.stripe.com/v1/charges?limit=3")
        .header("Authorization", &auth)
        .send()
        .await;
    let Ok(response) = charges else { return };
    if !response.status().is_success() {
        return;
    }
    let json: Value = response.json().await.unwrap_or(json!({}));
    let payments: Vec<Value> = json
        .get("data")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(|c| {
                    let description = c
                        .get("description")
                        .and_then(Value::as_str)
                        .or_else(|| {
                            c.get("billing_details")
                                .and_then(|b| b.get("name"))
                                .and_then(Value::as_str)
                        })
                        .map(str::to_string);
                    Some(json!({
                        "id": c.get("id")?.as_str()?,
                        "amount": c.get("amount")?.as_i64()?,
                        "currency": c.get("currency")?.as_str()?,
                        "description": description,
                        "createdAt": c.get("created").and_then(Value::as_i64).unwrap_or(0) * 1000,
                        "status": c.get("status").and_then(Value::as_str).unwrap_or("succeeded"),
                    }))
                })
                .collect()
        })
        .unwrap_or_default();

    let newest = payments
        .first()
        .and_then(|p| p.get("id"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let event = if !newest.is_empty() && is_new("stripe", &newest) {
        let label = payments[0]
            .get("description")
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or_else(|| {
                let cents = payments[0].get("amount").and_then(Value::as_i64).unwrap_or(0);
                format!("{:.2}", cents as f64 / 100.0)
            });
        Some(IntegrationEvent { success: true, label, detail: None })
    } else {
        None
    };

    emit(&app, IntegrationUpdate {
        id: "integration_stripe",
        data: json!({ "balance": amount, "currency": currency, "payments": payments }),
        error: None,
        event,
    });
}

// ── GitHub ────────────────────────────────────────────────────────────────────

async fn poll_github(app: AppHandle) {
    let Some(token) = secrets::get("github-token") else { return };
    let http = client();

    let user = http
        .get("https://api.github.com/user")
        .header("Authorization", format!("Bearer {token}"))
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", "Coucou")
        .send()
        .await;
    let Ok(response) = user else { return };
    if !response.status().is_success() {
        emit(&app, IntegrationUpdate {
            id: "integration_github",
            data: json!({}),
            error: Some(status_error(response.status().as_u16(), "Token lacks the needed scope")),
            event: None,
        });
        return;
    }
    let json: Value = response.json().await.unwrap_or(json!({}));
    let public = json.get("public_repos").and_then(Value::as_i64).unwrap_or(0);
    let private = json
        .get("owned_private_repos")
        .or_else(|| json.get("total_private_repos"))
        .and_then(Value::as_i64)
        .unwrap_or(0);

    let repos = http
        .get("https://api.github.com/user/repos?per_page=100&affiliation=owner&sort=pushed")
        .header("Authorization", format!("Bearer {token}"))
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", "Coucou")
        .send()
        .await;
    let stars: i64 = match repos {
        Ok(r) if r.status().is_success() => r
            .json::<Value>()
            .await
            .ok()
            .and_then(|v| v.as_array().cloned())
            .map(|list| {
                list.iter()
                    .filter_map(|r| r.get("stargazers_count").and_then(Value::as_i64))
                    .sum()
            })
            .unwrap_or(0),
        _ => 0,
    };

    emit(&app, IntegrationUpdate {
        id: "integration_github",
        data: json!({ "totalRepos": public + private, "totalStars": stars }),
        error: None,
        event: None,
    });
}

// ── Vercel ────────────────────────────────────────────────────────────────────

async fn poll_vercel(app: AppHandle) {
    let Some(token) = secrets::get("vercel-token") else { return };
    let response = client()
        .get("https://api.vercel.com/v6/deployments?limit=5")
        .header("Authorization", format!("Bearer {token}"))
        .header("Accept", "application/json")
        .send()
        .await;
    let Ok(response) = response else { return };
    if !response.status().is_success() {
        emit(&app, IntegrationUpdate {
            id: "integration_vercel",
            data: json!({}),
            error: Some(status_error(response.status().as_u16(), "Token lacks access")),
            event: None,
        });
        return;
    }
    let json: Value = response.json().await.unwrap_or(json!({}));
    let terminal = ["READY", "ERROR", "CANCELED"];
    let deployments: Vec<Value> = json
        .get("deployments")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(|d| {
                    let state = d.get("state")?.as_str()?;
                    if !terminal.contains(&state) {
                        return None;
                    }
                    let meta = d.get("meta");
                    let pick = |keys: [&str; 3]| {
                        meta.and_then(|m| keys.iter().find_map(|k| m.get(*k).and_then(Value::as_str)))
                            .map(str::to_string)
                    };
                    Some(json!({
                        "id": d.get("uid")?.as_str()?,
                        "projectName": d.get("name")?.as_str()?,
                        "url": d.get("url").and_then(Value::as_str).unwrap_or(""),
                        "state": state,
                        "createdAt": d.get("createdAt").and_then(Value::as_f64).unwrap_or(0.0),
                        "commitMessage": pick(["githubCommitMessage", "gitlabCommitMessage", "bitbucketCommitMessage"]),
                        "branch": pick(["githubCommitRef", "gitlabCommitRef", "bitbucketBranch"]),
                    }))
                })
                .collect()
        })
        .unwrap_or_default();

    let event = deployments.first().and_then(|latest| {
        let id = latest.get("id")?.as_str()?;
        if !is_new("vercel", id) {
            return None;
        }
        let success = latest.get("state")?.as_str()? == "READY";
        Some(IntegrationEvent {
            success,
            label: latest.get("projectName")?.as_str()?.to_string(),
            detail: None,
        })
    });

    emit(&app, IntegrationUpdate {
        id: "integration_vercel",
        data: json!({ "deployments": deployments }),
        error: None,
        event,
    });
}

// ── Resend ────────────────────────────────────────────────────────────────────

async fn poll_resend(app: AppHandle) {
    let Some(key) = secrets::get("resend-api-key") else { return };
    let response = client()
        .get("https://api.resend.com/emails?limit=100")
        .header("Authorization", format!("Bearer {key}"))
        .header("Accept", "application/json")
        .send()
        .await;
    let Ok(response) = response else { return };
    if !response.status().is_success() {
        emit(&app, IntegrationUpdate {
            id: "integration_resend",
            data: json!({}),
            error: Some(status_error(response.status().as_u16(), "Key lacks access")),
            event: None,
        });
        return;
    }
    let json: Value = response.json().await.unwrap_or(json!({}));
    let total = json
        .get("total")
        .or_else(|| json.get("count"))
        .and_then(Value::as_i64);
    let emails: Vec<Value> = json
        .get("data")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .take(5)
                .filter_map(|e| {
                    let to = match e.get("to") {
                        Some(Value::Array(a)) => a.clone(),
                        Some(Value::String(s)) => vec![Value::String(s.clone())],
                        _ => vec![],
                    };
                    Some(json!({
                        "id": e.get("id")?.as_str()?,
                        "to": to,
                        "subject": e.get("subject").and_then(Value::as_str).unwrap_or(""),
                        "createdAt": e.get("created_at").and_then(Value::as_str).unwrap_or(""),
                        "lastEvent": e.get("last_event").and_then(Value::as_str).unwrap_or(""),
                    }))
                })
                .collect()
        })
        .unwrap_or_default();

    emit(&app, IntegrationUpdate {
        id: "integration_resend",
        data: json!({ "emails": emails, "total": total }),
        error: None,
        event: None,
    });
}

// ── Notion ────────────────────────────────────────────────────────────────────

async fn poll_notion(app: AppHandle) {
    let Some(token) = secrets::get("notion-api-key") else { return };
    let response = client()
        .post("https://api.notion.com/v1/search")
        .header("Authorization", format!("Bearer {token}"))
        .header("Notion-Version", "2022-06-28")
        .header("Content-Type", "application/json")
        .json(&json!({
            "sort": { "direction": "descending", "timestamp": "last_edited_time" },
            "page_size": 3
        }))
        .send()
        .await;
    let Ok(response) = response else { return };
    if !response.status().is_success() {
        emit(&app, IntegrationUpdate {
            id: "integration_notion",
            data: json!({}),
            error: Some(status_error(response.status().as_u16(), "Integration lacks access")),
            event: None,
        });
        return;
    }
    let json: Value = response.json().await.unwrap_or(json!({}));
    let pages: Vec<Value> = json
        .get("results")
        .and_then(Value::as_array)
        .map(|list| list.iter().filter_map(parse_notion_page).collect())
        .unwrap_or_default();

    emit(&app, IntegrationUpdate {
        id: "integration_notion",
        data: json!({ "pages": pages }),
        error: None,
        event: None,
    });
}

fn parse_notion_page(obj: &Value) -> Option<Value> {
    let id = obj.get("id")?.as_str()?;
    let is_database = obj.get("object").and_then(Value::as_str) == Some("database");

    let mut title = "Untitled".to_string();
    if is_database {
        if let Some(text) = obj
            .get("title")
            .and_then(Value::as_array)
            .and_then(|a| a.first())
            .and_then(|t| t.get("plain_text"))
            .and_then(Value::as_str)
        {
            if !text.is_empty() {
                title = text.to_string();
            }
        }
    } else if let Some(props) = obj.get("properties").and_then(Value::as_object) {
        for prop in props.values() {
            if prop.get("type").and_then(Value::as_str) != Some("title") {
                continue;
            }
            if let Some(text) = prop
                .get("title")
                .and_then(Value::as_array)
                .and_then(|a| a.first())
                .and_then(|t| t.get("plain_text"))
                .and_then(Value::as_str)
            {
                if !text.is_empty() {
                    title = text.to_string();
                    break;
                }
            }
        }
    }

    let emoji = obj
        .get("icon")
        .filter(|i| i.get("type").and_then(Value::as_str) == Some("emoji"))
        .and_then(|i| i.get("emoji"))
        .and_then(Value::as_str);

    Some(json!({
        "id": id,
        "title": title,
        "emoji": emoji,
        "lastEditedAt": obj.get("last_edited_time").and_then(Value::as_str)?,
        "url": obj.get("url").and_then(Value::as_str).unwrap_or("https://notion.so"),
    }))
}

// ── Cal.com ───────────────────────────────────────────────────────────────────

async fn poll_calcom(app: AppHandle) {
    let Some(key) = secrets::get("calcom-api-key") else { return };
    let response = client()
        .get("https://api.cal.com/v2/bookings?status=upcoming")
        .header("Authorization", format!("Bearer {key}"))
        .header("cal-api-version", "2024-08-13")
        .send()
        .await;
    let Ok(response) = response else { return };
    if !response.status().is_success() {
        emit(&app, IntegrationUpdate {
            id: "integration_calcom",
            data: json!({}),
            error: Some(status_error(response.status().as_u16(), "Key lacks access")),
            event: None,
        });
        return;
    }
    let json: Value = response.json().await.unwrap_or(json!({}));
    let bookings: Vec<Value> = json
        .get("data")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(|b| {
                    let start = b
                        .get("start")
                        .or_else(|| b.get("startTime"))
                        .and_then(Value::as_str)?;
                    let attendee = b.get("attendees").and_then(Value::as_array).and_then(|a| a.first());
                    let notes = b
                        .get("responses")
                        .and_then(|r| r.get("notes"))
                        .and_then(|n| n.get("value"))
                        .and_then(Value::as_str)
                        .or_else(|| b.get("description").and_then(Value::as_str))
                        .filter(|s| !s.is_empty());
                    Some(json!({
                        "id": b.get("id").map(|v| v.to_string()).unwrap_or_default(),
                        "title": b.get("title").and_then(Value::as_str).unwrap_or("Meeting"),
                        "start": start,
                        "status": b.get("status").and_then(Value::as_str).unwrap_or("accepted"),
                        "attendeeName": attendee.and_then(|a| a.get("name")).and_then(Value::as_str),
                        "attendeeEmail": attendee.and_then(|a| a.get("email")).and_then(Value::as_str),
                        "attendeeNotes": notes,
                    }))
                })
                .collect()
        })
        .unwrap_or_default();

    emit(&app, IntegrationUpdate {
        id: "integration_calcom",
        data: json!({ "bookings": bookings }),
        error: None,
        event: None,
    });
}

// ── GitLab ────────────────────────────────────────────────────────────────────
// gitlab.com or a self-hosted instance (the URL is configurable), with a token
// that has the `read_api` scope. Four sources, every minute:
// - the To-Do list, GitLab's own inbox for the user: review requests,
//   assignments, mentions, a pipeline failing on their MR, an MR that can't be
//   merged, a review submitted… Every new to-do is news;
// - the merge requests the user authored: approved (and by whom), merged;
// - every open MR the user is involved in — authored, assigned, to review: one
//   updated since the last poll has its discussion read, and what someone else
//   did there (a comment, commits, an approval, a status change) is news;
// - the latest pipeline the user triggered in their three most active projects.
// Everything new in one poll becomes one notification — one sound, one badge —
// that lists all of it, so nothing landing in the same minute is lost. The card
// keeps that news on top of the pending to-dos and the MRs.

pub const GITLAB_DEFAULT_URL: &str = "https://gitlab.com";

/// The configured instance, without a trailing slash. Only http(s): the value
/// ends up in requests and in the browser.
pub fn gitlab_base() -> Result<String, String> {
    let raw = secrets::get("gitlab-url").unwrap_or_else(|| GITLAB_DEFAULT_URL.to_string());
    let base = raw.trim().trim_end_matches('/').to_string();
    if base.starts_with("https://") || base.starts_with("http://") {
        Ok(base)
    } else {
        Err("The GitLab URL must start with https://".into())
    }
}

/// Approvals are asked for this many of the user's open MRs, the most recently
/// updated: one request each, every minute.
const GITLAB_APPROVAL_CHECKS: usize = 5;
/// The discussion is read for at most this many updated MRs a minute.
const GITLAB_ACTIVITY_CHECKS: usize = 5;
/// News stays on a card this long, and at most this many items (GitLab, YouTrack).
const NEWS_FOR_MS: i64 = 30 * 60 * 1000;
const NEWS_KEEP: usize = 5;

/// News for a card: this poll's first, then what is still recent.
fn recent_news(fresh: &[Value], before: &[Value]) -> Vec<Value> {
    let cutoff = now_ms() - NEWS_FOR_MS;
    let mut kept: Vec<Value> = fresh.to_vec();
    kept.extend(before.iter().filter(|n| n["at"].as_i64().unwrap_or(0) >= cutoff).cloned());
    kept.truncate(NEWS_KEEP);
    kept
}

/// One notification for the lot: the label says it, the detail lists it.
fn news_event(fresh: &[Value], service: &str) -> Option<IntegrationEvent> {
    (!fresh.is_empty()).then(|| {
        let labels: Vec<String> = fresh.iter().filter_map(|n| n["label"].as_str().map(str::to_string)).collect();
        IntegrationEvent {
            success: fresh.iter().all(|n| n["success"].as_bool().unwrap_or(true)),
            label: if labels.len() == 1 { labels[0].clone() } else { format!("{} {service} updates", labels.len()) },
            detail: Some(labels.join("\n")),
        }
    })
}

/// What the poller remembers between polls, source by source. `None` until that
/// source has answered once: its first answer only fills it — no news on
/// launch, as with every other poller — and a source that failed then can't
/// pass its whole backlog off as news later.
#[derive(Default)]
struct GitlabMemory {
    todo_max: Option<i64>,
    pipeline_max: Option<i64>,
    /// The user's own MRs as last seen: id → (state, approvers).
    authored: Option<std::collections::HashMap<i64, (String, Vec<String>)>>,
    /// The open MRs the user is involved in, as last seen: id → updated_at.
    involved: Option<std::collections::HashMap<i64, String>>,
    /// Recent news, newest first: { label, url, success, at, todoId?, mrId? }.
    news: Vec<Value>,
}

static GITLAB: std::sync::LazyLock<Mutex<GitlabMemory>> = std::sync::LazyLock::new(Default::default);

/// What a to-do is about, in words, and whether it is bad news.
fn gitlab_todo_kind(action: &str) -> (&'static str, bool) {
    match action {
        "review_requested" => ("Review requested", true),
        "assigned" => ("Assigned to you", true),
        "mentioned" | "directly_addressed" => ("Mentioned", true),
        "build_failed" => ("Pipeline failed", false),
        "unmergeable" => ("Can't be merged", false),
        "merge_train_removed" => ("Out of the merge train", false),
        "approval_required" => ("Approval needed", true),
        "review_submitted" => ("Reviewed", true),
        "member_access_requested" => ("Access requested", true),
        _ => ("To-do", true),
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn s(v: &Value, key: &str) -> String {
    v.get(key).and_then(Value::as_str).unwrap_or("").to_string()
}

/// The open MRs the user is involved in, once each, most recently updated
/// first, with what the user is on each: author, assignee, reviewer.
fn gitlab_involved(authored: &[Value], assigned: &[Value], reviewing: &[Value]) -> Vec<Value> {
    let mut items: Vec<Value> = Vec::new();
    let sources = [(authored, "Yours"), (assigned, "Assigned"), (reviewing, "Review")];
    for (list, role) in sources {
        for mr in list.iter().filter(|m| s(m, "state") == "opened") {
            let Some(id) = mr.get("id").and_then(Value::as_i64) else { continue };
            if let Some(item) = items.iter_mut().find(|i| i["id"].as_i64() == Some(id)) {
                if let Some(roles) = item["roles"].as_array_mut() {
                    roles.push(json!(role));
                }
                continue;
            }
            // "group/sub/project!12" → "project".
            let reference = mr.get("references").map(|r| s(r, "full")).unwrap_or_default();
            let path = reference.split('!').next().unwrap_or("");
            items.push(json!({
                "id": id,
                "iid": mr.get("iid").and_then(Value::as_i64).unwrap_or(0),
                "projectId": mr.get("project_id").and_then(Value::as_i64).unwrap_or(0),
                "title": s(mr, "title"),
                "url": s(mr, "web_url"),
                "project": path.rsplit('/').next().unwrap_or(""),
                "author": mr.get("author").map(|a| s(a, "name")).unwrap_or_default(),
                "draft": mr.get("draft").and_then(Value::as_bool).unwrap_or(false),
                "roles": [role],
                "updatedAt": s(mr, "updated_at"),
            }));
        }
    }
    // ISO-8601 in UTC sorts as text.
    items.sort_by(|a, b| b["updatedAt"].as_str().cmp(&a["updatedAt"].as_str()));
    items
}

/// The involved MRs updated since the last poll: their discussion says what
/// happened. An MR seen for the first time is not one — its to-do tells it —
/// and nothing is before the first answer.
fn gitlab_changed(memory: &GitlabMemory, involved: &[Value]) -> Vec<Value> {
    let Some(known) = &memory.involved else { return Vec::new() };
    involved
        .iter()
        .filter(|mr| {
            let id = mr["id"].as_i64().unwrap_or(0);
            known.get(&id).is_some_and(|seen| mr["updatedAt"].as_str().unwrap_or("") > seen.as_str())
        })
        .take(GITLAB_ACTIVITY_CHECKS)
        .cloned()
        .collect()
}

/// What's new since the last poll, against what `memory` remembers, which it
/// then updates. `None` for a source that failed this time. `activity` holds the
/// latest notes of the MRs `gitlab_changed` picked, newest first. Returns the
/// news (newest sources first) and the pending to-dos as the card shows them.
#[allow(clippy::too_many_arguments)]
fn gitlab_fresh(
    memory: &mut GitlabMemory,
    projects_answer: &Option<Vec<Value>>,
    pipelines: &[Value],
    todos_answer: &Option<Vec<Value>>,
    authored_answer: &Option<Vec<Value>>,
    approvers: &std::collections::HashMap<i64, Vec<String>>,
    involved_answer: &Option<Vec<Value>>,
    activity: &std::collections::HashMap<i64, Vec<Value>>,
    me: &str,
) -> (Vec<Value>, Vec<Value>) {
    let todos = todos_answer.clone().unwrap_or_default();
    let authored = authored_answer.clone().unwrap_or_default();
    let mut fresh: Vec<Value> = Vec::new();
    let news = |label: String, url: String, success: bool, todo: Option<i64>, mr: Option<i64>| {
        json!({ "label": label, "url": url, "success": success, "at": now_ms(), "todoId": todo, "mrId": mr })
    };

    // Pipelines: finished ones above every id seen before. Canceled is no news.
    let mut failed_projects: Vec<String> = Vec::new();
    let seen_pipeline = memory.pipeline_max;
    for p in pipelines {
        let id = p["id"].as_i64().unwrap_or(0);
        let status = p["status"].as_str().unwrap_or("");
        let Some(seen) = seen_pipeline else { break };
        if !matches!(status, "success" | "failed" | "canceled") || id <= seen {
            continue;
        }
        if status != "canceled" {
            let ok = status == "success";
            let project = p["project"].as_str().unwrap_or("");
            if !ok {
                failed_projects.push(project.to_string());
            }
            let verb = if ok { "Pipeline passed" } else { "Pipeline failed" };
            let label = format!("{verb}: {project} · {}", p["ref"].as_str().unwrap_or(""));
            fresh.push(news(label, p["url"].as_str().unwrap_or("").to_string(), ok, None, None));
        }
    }
    if projects_answer.is_some() {
        let top = pipelines
            .iter()
            .filter(|p| matches!(p["status"].as_str(), Some("success" | "failed" | "canceled")))
            .filter_map(|p| p["id"].as_i64())
            .max()
            .unwrap_or(0);
        memory.pipeline_max = Some(seen_pipeline.unwrap_or(0).max(top));
    }

    // To-dos: every one newer than the newest seen. A pipeline failure already
    // told above is not told twice through its to-do.
    let mut todo_items: Vec<Value> = Vec::new();
    for t in &todos {
        let id = t.get("id").and_then(Value::as_i64).unwrap_or(0);
        let action = s(t, "action_name");
        let (kind, ok) = gitlab_todo_kind(&action);
        let target = t.get("target").cloned().unwrap_or(json!({}));
        let title = Some(s(&target, "title")).filter(|x| !x.is_empty()).unwrap_or_else(|| s(t, "body"));
        let project = t.get("project").map(|p| s(p, "name")).unwrap_or_default();
        let url = s(t, "target_url");
        let mr = (s(t, "target_type") == "MergeRequest").then(|| target.get("id").and_then(Value::as_i64)).flatten();
        let is_new = memory.todo_max.is_some_and(|seen| id > seen);
        if is_new && !(action == "build_failed" && failed_projects.contains(&project)) {
            fresh.push(news(format!("{kind}: {title}"), url.clone(), ok, Some(id), mr));
        }
        todo_items.push(json!({
            "id": id,
            "kind": kind,
            "bad": !ok,
            "title": title,
            "project": project,
            "author": t.get("author").map(|a| s(a, "name")).unwrap_or_default(),
            "url": url,
            "createdAt": s(t, "created_at"),
            "mrId": mr,
        }));
    }
    if todos_answer.is_some() {
        let top = todos.iter().filter_map(|t| t.get("id").and_then(Value::as_i64)).max().unwrap_or(0);
        memory.todo_max = Some(memory.todo_max.unwrap_or(0).max(top));
    }

    // The user's MRs: merged since last time, or approved by someone new. An MR
    // seen for the first time is only remembered.
    if authored_answer.is_some() {
        let primed = memory.authored.is_some();
        let known = memory.authored.get_or_insert_with(Default::default);
        for mr in &authored {
            let Some(id) = mr.get("id").and_then(Value::as_i64) else { continue };
            let state = s(mr, "state");
            let title = s(mr, "title");
            let url = s(mr, "web_url");
            let before = known.get(&id).cloned();
            let now_approvers = approvers
                .get(&id)
                .cloned()
                .or_else(|| before.as_ref().map(|b| b.1.clone()))
                .unwrap_or_default();
            if let (true, Some((was, had))) = (primed, &before) {
                if state == "merged" && was != "merged" {
                    fresh.push(news(format!("Merged: {title}"), url.clone(), true, None, Some(id)));
                }
                for name in now_approvers.iter().filter(|n| !had.contains(n)) {
                    fresh.push(news(format!("Approved by {name}: {title}"), url.clone(), true, None, Some(id)));
                }
            }
            known.insert(id, (state, now_approvers));
        }
    }

    // The MRs the user is involved in: what someone else did on an updated one
    // since it was last seen, as its discussion tells — comments, but also the
    // system notes for commits, approvals, status changes. One piece of news per
    // MR, and none for an MR that is already news above.
    if let Some(involved) = involved_answer {
        let told: std::collections::HashSet<i64> = fresh.iter().filter_map(|n| n["mrId"].as_i64()).collect();
        let known = memory.involved.clone().unwrap_or_default();
        for mr in involved {
            let id = mr["id"].as_i64().unwrap_or(0);
            let (Some(notes), Some(since)) = (activity.get(&id), known.get(&id)) else { continue };
            if told.contains(&id) {
                continue;
            }
            let others: Vec<&Value> = notes
                .iter()
                .filter(|n| s(n, "created_at").as_str() > since.as_str())
                .filter(|n| n.get("author").map(|a| s(a, "username")).unwrap_or_default() != me)
                .collect();
            let Some(latest) = others.first() else { continue };
            let name = latest.get("author").map(|a| s(a, "name")).unwrap_or_default();
            let commented = others.iter().any(|n| !n["system"].as_bool().unwrap_or(false));
            let verb = if commented { "Comment by" } else { "Updated by" };
            let title = mr["title"].as_str().unwrap_or("");
            let url = mr["url"].as_str().unwrap_or("").to_string();
            fresh.push(news(format!("{verb} {name}: {title}"), url, true, None, Some(id)));
        }
        // An updated MR whose discussion wasn't read this time (more than
        // GITLAB_ACTIVITY_CHECKS changed, or the request failed) keeps its old
        // mark, so the next poll reads it rather than forgetting it.
        memory.involved = Some(
            involved
                .iter()
                .filter_map(|mr| {
                    let id = mr["id"].as_i64()?;
                    let seen = match known.get(&id) {
                        Some(old) if !activity.contains_key(&id) => old.clone(),
                        _ => mr["updatedAt"].as_str()?.to_string(),
                    };
                    Some((id, seen))
                })
                .collect(),
        );
    }

    (fresh, todo_items)
}

async fn poll_gitlab(app: AppHandle) {
    let Some(token) = secrets::get("gitlab-token") else { return };
    let fail = |error: String| {
        emit(&app, IntegrationUpdate { id: "integration_gitlab", data: json!({}), error: Some(error), event: None });
    };
    let base = match gitlab_base() {
        Ok(b) => b,
        Err(e) => return fail(e),
    };
    let http = client();
    let get = |path: String| {
        http.get(format!("{base}/api/v4/{path}"))
            .header("PRIVATE-TOKEN", &token)
            .header("Accept", "application/json")
            .send()
    };
    // A list endpoint's items, or None when it failed: one source failing must
    // not hide the others, nor be mistaken for an empty list.
    let list = |path: String| {
        let request = get(path);
        async move {
            match request.await {
                Ok(r) if r.status().is_success() => r.json::<Value>().await.ok().and_then(|v| v.as_array().cloned()),
                _ => None,
            }
        }
    };

    let user = match get("user".into()).await {
        Ok(r) if r.status().is_success() => r.json::<Value>().await.unwrap_or(json!({})),
        Ok(r) => return fail(status_error(r.status().as_u16(), "Token lacks the read_api scope")),
        // Without the URL: a self-hosted address is the user's business, not the log's.
        Err(e) => return fail(format!("No connection: {}", e.without_url())),
    };
    let Some(username) = user.get("username").and_then(Value::as_str).map(str::to_string) else {
        return fail("Unexpected answer from GitLab — check the URL".into());
    };

    // ── The To-Do list ──
    let todos_answer = list("todos?state=pending&per_page=20".into()).await;
    let todos = todos_answer.clone().unwrap_or_default();

    // ── The user's own merge requests, and who approved the open ones ──
    let authored_answer =
        list("merge_requests?scope=created_by_me&state=all&order_by=updated_at&sort=desc&per_page=20".into()).await;
    let authored = authored_answer.clone().unwrap_or_default();
    let mut approvers: std::collections::HashMap<i64, Vec<String>> = Default::default();
    for mr in authored.iter().filter(|m| s(m, "state") == "opened").take(GITLAB_APPROVAL_CHECKS) {
        let (Some(id), Some(project), Some(iid)) = (
            mr.get("id").and_then(Value::as_i64),
            mr.get("project_id").and_then(Value::as_i64),
            mr.get("iid").and_then(Value::as_i64),
        ) else {
            continue;
        };
        let Ok(r) = get(format!("projects/{project}/merge_requests/{iid}/approvals")).await else { continue };
        if !r.status().is_success() {
            continue;
        }
        let names = r
            .json::<Value>()
            .await
            .ok()
            .and_then(|v| v.get("approved_by").and_then(Value::as_array).cloned())
            .unwrap_or_default()
            .iter()
            .filter_map(|a| a.get("user").and_then(|u| u.get("name")).and_then(Value::as_str).map(str::to_string))
            .collect();
        approvers.insert(id, names);
    }

    // ── Every open MR the user is involved in, and the discussion of the updated ones ──
    let mrs = |scope: String| list(format!("merge_requests?{scope}&state=opened&order_by=updated_at&sort=desc&per_page=20"));
    let assigned_answer = mrs("scope=assigned_to_me".into()).await;
    let reviewing_answer = mrs(format!("scope=all&reviewer_username={username}")).await;
    // All three or nothing: a source missing would pass its MRs off as new later.
    let involved_answer = match (&authored_answer, &assigned_answer, &reviewing_answer) {
        (Some(a), Some(b), Some(c)) => Some(gitlab_involved(a, b, c)),
        _ => None,
    };
    let involved = involved_answer.clone().unwrap_or_default();
    let changed = gitlab_changed(&GITLAB.lock().unwrap(), &involved);
    let mut activity: std::collections::HashMap<i64, Vec<Value>> = Default::default();
    for mr in &changed {
        let (Some(id), Some(project), Some(iid)) = (mr["id"].as_i64(), mr["projectId"].as_i64(), mr["iid"].as_i64()) else {
            continue;
        };
        let path = format!("projects/{project}/merge_requests/{iid}/notes?sort=desc&order_by=created_at&per_page=20");
        if let Some(notes) = list(path).await {
            activity.insert(id, notes);
        }
    }

    // ── The latest pipeline the user triggered in each of their busiest projects ──
    let projects_answer =
        list("projects?membership=true&archived=false&simple=true&order_by=last_activity_at&sort=desc&per_page=3".into()).await;
    let projects = projects_answer.clone().unwrap_or_default();
    let mut pipelines: Vec<Value> = Vec::new();
    for project in &projects {
        let Some(pid) = project.get("id").and_then(Value::as_i64) else { continue };
        let name = project.get("name").and_then(Value::as_str).unwrap_or("Project");
        let Some(p) = list(format!("projects/{pid}/pipelines?per_page=1&username={username}"))
            .await
            .unwrap_or_default()
            .into_iter()
            .next()
        else {
            continue;
        };
        pipelines.push(json!({
            "id": p.get("id").and_then(Value::as_i64).unwrap_or(0),
            "project": name,
            "ref": s(&p, "ref"),
            "status": s(&p, "status"),
            "url": s(&p, "web_url"),
            "updatedAt": s(&p, "updated_at"),
        }));
    }
    // ISO-8601 in UTC sorts as text.
    pipelines.sort_by(|a, b| b["updatedAt"].as_str().cmp(&a["updatedAt"].as_str()));

    let mut memory = GITLAB.lock().unwrap();
    let (fresh, todo_items) = gitlab_fresh(
        &mut memory, &projects_answer, &pipelines, &todos_answer, &authored_answer, &approvers,
        &involved_answer, &activity, &username,
    );

    let kept = recent_news(&fresh, &memory.news);
    memory.news = kept.clone();
    drop(memory);
    let event = news_event(&fresh, "GitLab");

    emit(&app, IntegrationUpdate {
        id: "integration_gitlab",
        data: json!({
            "base": base,
            "username": username,
            "todoCount": todos.len(),
            "todosCapped": todos.len() >= 20,
            "todos": todo_items,
            "mergeRequests": involved,
            "news": kept,
            // This poll's news alone: what the notification card shows.
            "fresh": fresh,
        }),
        error: None,
        event,
    });
}

// ── YouTrack ──────────────────────────────────────────────────────────────────
// A self-hosted YouTrack (the URL is configurable: `https://host` or
// `https://host/youtrack`), a permanent token, and one saved search the user
// picked in the settings. Every minute, the search's most recently updated
// issues: one created or updated since the last poll, by someone other than the
// user, is news. As with GitLab, everything new in one poll is one notification.
// Read-only: Coucou never changes an issue.

/// The configured instance, without a trailing slash. Only http(s): the value
/// ends up in requests and in the browser.
pub fn youtrack_base() -> Result<String, String> {
    let raw = secrets::get("youtrack-url").ok_or("Set the YouTrack URL in Settings → Integrations")?;
    let base = raw.trim().trim_end_matches('/').to_string();
    if base.starts_with("https://") || base.starts_with("http://") {
        Ok(base)
    } else {
        Err("The YouTrack URL must start with https://".into())
    }
}

/// Issues read each minute, the most recently updated first: far more than
/// changes in a minute.
const YOUTRACK_TOP: usize = 50;

/// What the poller remembers between polls.
#[derive(Default)]
struct YoutrackMemory {
    /// The saved search this memory is about: another one starts afresh.
    query_id: String,
    /// The latest `updated` seen in that search. `None` until it has answered
    /// once: its first answer only fills it — no news on launch.
    seen_until: Option<i64>,
    /// Recent news, newest first: { label, url, success, at, issue }.
    news: Vec<Value>,
}

static YOUTRACK: std::sync::LazyLock<Mutex<YoutrackMemory>> = std::sync::LazyLock::new(Default::default);

/// The followed saved search, as the settings stored it. Its id (`120-3`) goes
/// into a URL path, so nothing else is let through.
fn youtrack_query_id() -> Option<String> {
    secrets::get("youtrack-query")
        .map(|q| q.trim().to_string())
        .filter(|q| !q.is_empty() && q.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.')))
}

/// The search without its own `sort by:` clause, which would otherwise decide
/// which issues make the top of the list instead of the latest update.
fn youtrack_unsorted(query: &str) -> &str {
    // ASCII lowercase keeps byte offsets, so they still cut `query`.
    let lower = query.to_ascii_lowercase();
    let cut = ["sort by:", "order by:"].iter().filter_map(|k| lower.find(k)).min().unwrap_or(query.len());
    query[..cut].trim()
}

/// A user field of an issue: (login, name to show).
fn youtrack_who(issue: &Value, key: &str) -> (String, String) {
    let user = issue.get(key).cloned().unwrap_or(Value::Null);
    let login = s(&user, "login");
    let name = Some(s(&user, "fullName")).filter(|n| !n.is_empty()).unwrap_or_else(|| login.clone());
    (login, name)
}

/// What's new in the saved search since the last poll, against `memory`, which
/// it then updates. `issues` come newest update first. Returns the news and the
/// issues as the card shows them.
fn youtrack_fresh(
    memory: &mut YoutrackMemory,
    query_id: &str,
    issues: &[Value],
    me: &str,
    base: &str,
) -> (Vec<Value>, Vec<Value>) {
    if memory.query_id != query_id {
        *memory = YoutrackMemory { query_id: query_id.to_string(), ..Default::default() };
    }
    let seen = memory.seen_until;
    let mut fresh: Vec<Value> = Vec::new();
    let mut items: Vec<Value> = Vec::new();
    for issue in issues {
        let id = s(issue, "idReadable");
        let summary = s(issue, "summary");
        let created = issue["created"].as_i64().unwrap_or(0);
        let updated = issue["updated"].as_i64().unwrap_or(created);
        let url = format!("{base}/issue/{id}");
        let (_, updater) = youtrack_who(issue, "updater");
        // Anything above the latest update seen before is news: created since
        // then, or changed. Who did it — the reporter or the last to update it —
        // decides whether it is: the user's own doing is not.
        if let Some(seen) = seen.filter(|&seen| updated > seen) {
            let (verb, who) = if created > seen { ("Created", "reporter") } else { ("Updated", "updater") };
            let (login, name) = youtrack_who(issue, who);
            if me.is_empty() || login != me {
                let label = if name.is_empty() {
                    format!("{verb}: {id} {summary}")
                } else {
                    format!("{verb} by {name}: {id} {summary}")
                };
                fresh.push(json!({ "label": label, "url": url, "success": true, "at": now_ms(), "issue": id }));
            }
        }
        items.push(json!({
            "id": id,
            "summary": summary,
            "url": url,
            "updated": updated,
            "resolved": !issue["resolved"].is_null(),
            "by": updater,
        }));
    }
    let top = issues.iter().filter_map(|i| i["updated"].as_i64()).max().unwrap_or(0);
    memory.seen_until = Some(seen.unwrap_or(0).max(top));
    (fresh, items)
}

/// One GET on the YouTrack REST API. The error carries the HTTP status (0 when
/// the server was not reached), so each caller can word it.
async fn youtrack_get(
    http: &reqwest::Client,
    base: &str,
    token: &str,
    path: &str,
    params: &[(&str, &str)],
) -> Result<Value, (u16, String)> {
    let response = http
        .get(format!("{base}/api/{path}"))
        .bearer_auth(token)
        .header("Accept", "application/json")
        .query(params)
        .send()
        .await
        // Without the URL: a self-hosted address is the user's business, not the log's.
        .map_err(|e| (0, format!("No connection: {}", e.without_url())))?;
    let code = response.status().as_u16();
    if !response.status().is_success() {
        return Err((code, status_error(code, "This token can't read YouTrack (403)")));
    }
    // A wrong path often lands on an HTML page with a 200.
    response
        .json::<Value>()
        .await
        .map_err(|_| (code, "Unexpected answer from YouTrack — check the URL".into()))
}

/// The first request's error: a 404 there means the URL is not YouTrack's.
fn youtrack_error((code, error): (u16, String)) -> String {
    if code == 404 { "Not a YouTrack address (404) — check the URL".into() } else { error }
}

/// The signed-in user's login, which also proves the URL and the token.
async fn youtrack_me(http: &reqwest::Client, base: &str, token: &str) -> Result<String, String> {
    let me = youtrack_get(http, base, token, "users/me", &[("fields", "login")]).await.map_err(youtrack_error)?;
    Some(s(&me, "login"))
        .filter(|l| !l.is_empty())
        .ok_or_else(|| "Unexpected answer from YouTrack — check the URL".into())
}

async fn poll_youtrack(app: AppHandle) {
    let Some(token) = secrets::get("youtrack-token") else { return };
    let fail = |error: String| {
        emit(&app, IntegrationUpdate { id: "integration_youtrack", data: json!({}), error: Some(error), event: None });
    };
    let base = match youtrack_base() {
        Ok(b) => b,
        Err(e) => return fail(e),
    };
    let Some(query_id) = youtrack_query_id() else {
        return fail("Choose a saved search in Settings → Integrations".into());
    };
    let http = client();
    let me = match youtrack_me(&http, &base, &token).await {
        Ok(me) => me,
        Err(e) => return fail(e),
    };

    let saved = match youtrack_get(&http, &base, &token, &format!("savedQueries/{query_id}"), &[("fields", "name,query")]).await {
        Ok(v) => v,
        Err((404, _)) => return fail("The saved search is gone — choose another in Settings".into()),
        Err((_, e)) => return fail(e),
    };
    let name = s(&saved, "name");
    let query = s(&saved, "query");
    let search = format!("{} sort by: updated desc", youtrack_unsorted(&query));
    let top = YOUTRACK_TOP.to_string();
    let params = [
        ("query", search.as_str()),
        ("fields", "idReadable,summary,created,updated,resolved,reporter(login,fullName),updater(login,fullName)"),
        ("$top", top.as_str()),
    ];
    let issues = match youtrack_get(&http, &base, &token, "issues", &params).await {
        Ok(v) => v.as_array().cloned().unwrap_or_default(),
        Err((400, _)) => return fail("YouTrack can't run this saved search (400)".into()),
        Err((_, e)) => return fail(e),
    };

    let mut memory = YOUTRACK.lock().unwrap();
    let (fresh, items) = youtrack_fresh(&mut memory, &query_id, &issues, &me, &base);
    let kept = recent_news(&fresh, &memory.news);
    memory.news = kept.clone();
    drop(memory);

    let count = items.len();
    emit(&app, IntegrationUpdate {
        id: "integration_youtrack",
        data: json!({
            "base": base,
            "queryName": name,
            // The search as saved, its own sort included: what "Open" shows.
            "query": query,
            "count": count,
            "capped": count >= YOUTRACK_TOP,
            "issues": items,
            "news": kept,
            // This poll's news alone: what the notification card shows.
            "fresh": fresh,
        }),
        error: None,
        event: news_event(&fresh, "YouTrack"),
    });
}

/// The saved searches the settings offer, the user's own first, and the one
/// followed now. Asked from the settings window only.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct YoutrackSearches {
    pub searches: Vec<Value>,
    pub selected: Option<String>,
}

pub async fn youtrack_saved_searches() -> Result<YoutrackSearches, String> {
    let token = secrets::get("youtrack-token").ok_or("Save the token first")?;
    let base = youtrack_base()?;
    let http = client();
    let me = youtrack_me(&http, &base, &token).await?;
    let list = youtrack_get(&http, &base, &token, "savedQueries", &[("fields", "id,name,query,owner(login)"), ("$top", "500")])
        .await
        .map_err(|(_, e)| e)?;
    let mut searches: Vec<Value> = list
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|q| {
            json!({
                "id": s(q, "id"),
                "name": s(q, "name"),
                "query": s(q, "query"),
                "mine": q.get("owner").is_some_and(|o| s(o, "login") == me),
            })
        })
        .collect();
    let key = |v: &Value| (!v["mine"].as_bool().unwrap_or(false), v["name"].as_str().unwrap_or("").to_lowercase());
    searches.sort_by_key(key);
    Ok(YoutrackSearches { searches, selected: youtrack_query_id() })
}

// ── n8n ───────────────────────────────────────────────────────────────────────

async fn poll_n8n(app: AppHandle) {
    let (Some(key), Some(raw_base)) = (secrets::get("n8n-api-key"), secrets::get("n8n-url")) else {
        return;
    };
    let base = raw_base.trim_end_matches('/').to_string();
    let http = client();

    // Same two shapes as the Swift poller: the public API first, then /rest.
    let list_urls = [
        format!("{base}/api/v1/executions?limit=1&includeData=false"),
        format!("{base}/rest/executions?limit=1&includeData=false"),
    ];

    let mut items: Option<Vec<Value>> = None;
    for url in &list_urls {
        let Ok(response) = http.get(url).header("X-N8N-API-KEY", &key).header("Accept", "application/json").send().await
        else {
            continue;
        };
        if !response.status().is_success() {
            // Only the status: a self-hosted base URL can carry credentials.
            log::line(format!("n8n list HTTP {}", response.status()));
            continue;
        }
        let Ok(json) = response.json::<Value>().await else { continue };
        items = match &json {
            Value::Object(o) => o.get("data").and_then(Value::as_array).cloned(),
            Value::Array(a) => Some(a.clone()),
            _ => None,
        };
        if items.is_some() {
            break;
        }
    }

    let Some(first) = items.and_then(|list| list.into_iter().next()) else { return };
    let id = match first.get("id") {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => return,
    };

    let status = first.get("status").and_then(Value::as_str).unwrap_or("");
    if !["success", "error", "crashed", "canceled", "failed"].contains(&status) {
        return;
    }
    if !is_new("n8n", &id) {
        return;
    }
    let success = status == "success";

    let detail_urls = [
        format!("{base}/api/v1/executions/{id}?includeData=true"),
        format!("{base}/api/v1/executions/{id}"),
        format!("{base}/rest/executions/{id}?includeData=true"),
        format!("{base}/rest/executions/{id}"),
    ];
    let mut name = "Workflow".to_string();
    let mut detail = None;
    for url in &detail_urls {
        let Ok(response) = http.get(url).header("X-N8N-API-KEY", &key).header("Accept", "application/json").send().await
        else {
            continue;
        };
        if !response.status().is_success() {
            continue;
        }
        let Ok(json) = response.json::<Value>().await else { continue };
        name = json
            .get("workflowData")
            .and_then(|w| w.get("name"))
            .and_then(Value::as_str)
            .or_else(|| json.get("name").and_then(Value::as_str))
            .unwrap_or("Workflow")
            .to_string();
        detail = n8n_detail(&json, success);
        break;
    }

    log::line(format!("n8n execution {id} {status} · {name}"));
    emit(&app, IntegrationUpdate {
        id: "integration_n8n",
        data: json!({ "workflow": name, "status": status }),
        error: None,
        event: Some(IntegrationEvent { success, label: name, detail }),
    });
}

fn n8n_detail(json: &Value, success: bool) -> Option<String> {
    let result = json.get("data")?.get("resultData")?;
    if !success {
        if let Some(error) = result.get("error") {
            let message = error.get("message").and_then(Value::as_str).unwrap_or("");
            if let Some(node) = error.get("node").and_then(|n| n.get("name")).and_then(Value::as_str) {
                if !node.is_empty() {
                    return Some(format!("{node}\n{message}"));
                }
            }
            return Some(message.to_string());
        }
        let runs = result.get("runData")?.as_object()?;
        for (node, value) in runs {
            if let Some(message) = value
                .as_array()
                .and_then(|a| a.first())
                .and_then(|r| r.get("error"))
                .and_then(|e| e.get("message"))
                .and_then(Value::as_str)
            {
                return Some(format!("{node}\n{message}"));
            }
        }
        return None;
    }

    let last_node = result.get("lastNodeExecuted")?.as_str()?;
    let items = result
        .get("runData")?
        .get(last_node)?
        .as_array()?
        .first()?
        .get("data")?
        .get("main")?
        .as_array()?
        .first()?
        .as_array()?;
    let count = items.len();
    let header = format!("→ {last_node} · {count} item{}", if count == 1 { "" } else { "s" });

    let fields = items
        .first()
        .and_then(|i| i.get("json"))
        .and_then(Value::as_object)
        .map(|obj| {
            obj.iter()
                .take(4)
                .map(|(k, v)| format!("{k}: {}", fmt_value(v)))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .filter(|s| !s.is_empty());

    Some(match fields {
        Some(f) => format!("{header}\n{f}"),
        None => header,
    })
}

fn fmt_value(v: &Value) -> String {
    match v {
        Value::String(s) => s.chars().take(50).collect(),
        Value::Array(a) => format!("[{}]", a.len()),
        Value::Object(_) => "{…}".into(),
        other => other.to_string(),
    }
}

#[cfg(test)]
mod gitlab_tests {
    use super::*;

    fn todo(id: i64, action: &str, project: &str) -> Value {
        json!({ "id": id, "action_name": action, "target": { "title": format!("MR {id}") },
                "project": { "name": project }, "target_url": format!("https://gl/{id}") })
    }

    fn labels(news: &[Value]) -> Vec<String> {
        news.iter().map(|n| n["label"].as_str().unwrap().to_string()).collect()
    }

    /// The sources before the involved MRs, which these tests leave out.
    fn without_involved(
        m: &mut GitlabMemory,
        projects: &Option<Vec<Value>>,
        pipelines: &[Value],
        todos: &Option<Vec<Value>>,
        authored: &Option<Vec<Value>>,
        approvers: &std::collections::HashMap<i64, Vec<String>>,
    ) -> (Vec<Value>, Vec<Value>) {
        gitlab_fresh(m, projects, pipelines, todos, authored, approvers, &None, &Default::default(), "me")
    }

    fn open_mr(id: i64, title: &str, updated: &str) -> Value {
        json!({ "id": id, "iid": id, "project_id": 1, "state": "opened", "title": title, "web_url": format!("https://gl/mr/{id}"),
                "updated_at": updated, "references": { "full": "team/web!3" }, "author": { "name": "Ada" } })
    }

    fn note(by: &str, at: &str, system: bool) -> Value {
        json!({ "author": { "username": by, "name": by.to_uppercase() }, "created_at": at, "system": system })
    }

    #[test]
    fn involved_mrs_are_listed_once_with_every_role() {
        let a = open_mr(1, "Mine", "2026-10-01T10:00:00Z");
        let b = open_mr(2, "To review", "2026-10-01T11:00:00Z");
        let items = gitlab_involved(&[a.clone()], &[a], &[b]);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["title"], "To review", "most recently updated first");
        assert_eq!(items[1]["roles"], json!(["Yours", "Assigned"]));
        assert_eq!(items[1]["project"], "web");
    }

    #[test]
    fn an_updated_mr_tells_what_someone_else_did_on_it() {
        let mut m = GitlabMemory::default();
        let none = std::collections::HashMap::new();
        let run = |m: &mut GitlabMemory, involved: Vec<Value>, activity: &std::collections::HashMap<i64, Vec<Value>>| {
            gitlab_fresh(m, &None, &[], &None, &None, &none, &Some(involved), activity, "me").0
        };
        let at = |t: &str| format!("2026-10-01T{t}:00Z");

        let first = gitlab_involved(&[], &[], &[open_mr(1, "Login", &at("10:00")), open_mr(2, "Cache", &at("10:00"))]);
        assert!(gitlab_changed(&m, &first).is_empty(), "nothing before the first answer");
        assert!(run(&mut m, first, &Default::default()).is_empty());

        let later = gitlab_involved(&[], &[], &[
            open_mr(1, "Login", &at("10:05")), open_mr(2, "Cache", &at("10:06")), open_mr(3, "New one", &at("10:07")),
        ]);
        let changed: Vec<i64> = gitlab_changed(&m, &later).iter().filter_map(|mr| mr["id"].as_i64()).collect();
        assert_eq!(changed, vec![2, 1], "only the updated ones; a newcomer is its to-do's business");

        let activity = [
            (1, vec![note("ada", &at("10:05"), true), note("me", &at("10:04"), false), note("bob", &at("09:00"), false)]),
            (2, vec![note("me", &at("10:06"), false)]),
        ]
        .into();
        // MR 1: Ada's commits (a system note) count; the user's comment and Bob's
        // old one don't. MR 2: only the user did something.
        assert_eq!(labels(&run(&mut m, later, &activity)), vec!["Updated by ADA: Login"]);

        let again = gitlab_involved(&[], &[], &[open_mr(2, "Cache", &at("10:20")), open_mr(1, "Login", &at("10:30"))]);
        // MR 1's discussion is not read this time: it stays to be read next time.
        let activity = [(2, vec![note("bob", &at("10:20"), false), note("ada", &at("10:19"), true)])].into();
        assert_eq!(labels(&run(&mut m, again.clone(), &activity)), vec!["Comment by BOB: Cache"]);
        let changed: Vec<i64> = gitlab_changed(&m, &again).iter().filter_map(|mr| mr["id"].as_i64()).collect();
        assert_eq!(changed, vec![1]);
    }

    #[test]
    fn the_first_answer_is_silent_and_the_next_one_tells_what_is_new() {
        let mut m = GitlabMemory::default();
        let none = Default::default();
        let mr = |state: &str| Some(vec![json!({ "id": 7, "state": state, "title": "Login fix", "web_url": "u" })]);
        let projects = Some(vec![]);
        let pipe = |id: i64, status: &str| vec![json!({ "id": id, "status": status, "project": "api", "ref": "main", "url": "p" })];

        let (fresh, _) = without_involved(&mut m, &projects, &pipe(10, "success"), &Some(vec![todo(1, "assigned", "api")]), &mr("opened"), &none);
        assert!(fresh.is_empty(), "launch fills the memory without a word");

        let approved: std::collections::HashMap<i64, Vec<String>> = [(7, vec!["Ada".to_string()])].into();
        let (fresh, todos) = without_involved(
            &mut m, &projects, &pipe(11, "failed"),
            &Some(vec![todo(1, "assigned", "api"), todo(2, "review_requested", "web"), todo(3, "build_failed", "api")]),
            &mr("opened"), &approved,
        );
        assert_eq!(todos.len(), 3);
        assert_eq!(
            labels(&fresh),
            vec![
                "Pipeline failed: api · main".to_string(),
                "Review requested: MR 2".to_string(),
                // build_failed on api is the pipeline above: not told twice.
                "Approved by Ada: Login fix".to_string(),
            ]
        );

        let (fresh, _) = without_involved(&mut m, &projects, &pipe(11, "failed"), &Some(vec![]), &mr("merged"), &none);
        assert_eq!(labels(&fresh), vec!["Merged: Login fix".to_string()], "and the approver is remembered");
    }

    #[test]
    fn a_source_that_failed_at_first_does_not_pour_out_its_backlog() {
        let mut m = GitlabMemory::default();
        let none = Default::default();
        let backlog = Some((1..=5).map(|i| todo(i, "mentioned", "x")).collect::<Vec<_>>());
        let (fresh, _) = without_involved(&mut m, &None, &[], &None, &None, &none);
        assert!(fresh.is_empty());
        let (fresh, _) = without_involved(&mut m, &None, &[], &backlog, &None, &none);
        assert!(fresh.is_empty(), "the first answer of a source primes it, whenever it comes");
        let more = Some((1..=6).map(|i| todo(i, "mentioned", "x")).collect::<Vec<_>>());
        let (fresh, _) = without_involved(&mut m, &None, &[], &more, &None, &none);
        assert_eq!(labels(&fresh), vec!["Mentioned: MR 6".to_string()]);
    }
}

#[cfg(test)]
mod youtrack_tests {
    use super::*;

    fn issue(id: &str, created: i64, updated: i64, reporter: &str, updater: &str) -> Value {
        json!({ "idReadable": id, "summary": "Login", "created": created, "updated": updated,
                "reporter": { "login": reporter, "fullName": reporter.to_uppercase() },
                "updater": { "login": updater, "fullName": updater.to_uppercase() } })
    }

    fn labels(news: &[Value]) -> Vec<String> {
        news.iter().map(|n| n["label"].as_str().unwrap().to_string()).collect()
    }

    #[test]
    fn the_first_answer_is_silent_and_the_next_one_tells_what_others_did() {
        let mut m = YoutrackMemory::default();
        let base = "https://yt.example.com/youtrack";
        let (fresh, items) = youtrack_fresh(&mut m, "1-1", &[issue("P-1", 10, 20, "ada", "ada")], "me", base);
        assert!(fresh.is_empty(), "launch fills the memory without a word");
        assert_eq!(items[0]["url"], "https://yt.example.com/youtrack/issue/P-1");

        let (fresh, _) = youtrack_fresh(&mut m, "1-1", &[
            issue("P-3", 30, 30, "bob", "bob"),  // created since
            issue("P-2", 5, 25, "ada", "me"),    // the user's own change
            issue("P-1", 10, 22, "ada", "cy"),   // changed by someone else
            issue("P-0", 1, 15, "ada", "ada"),   // older than what was seen: it only entered the list
        ], "me", base);
        assert_eq!(labels(&fresh), vec!["Created by BOB: P-3 Login", "Updated by CY: P-1 Login"]);

        let (fresh, _) = youtrack_fresh(&mut m, "1-1", &[issue("P-3", 30, 30, "bob", "bob")], "me", base);
        assert!(fresh.is_empty(), "told once");
    }

    #[test]
    fn another_saved_search_starts_afresh() {
        let mut m = YoutrackMemory::default();
        youtrack_fresh(&mut m, "1-1", &[issue("P-1", 10, 20, "ada", "ada")], "me", "b");
        m.news.push(json!({ "label": "old" }));
        let (fresh, _) = youtrack_fresh(&mut m, "1-2", &[issue("Q-1", 50, 60, "ada", "ada")], "me", "b");
        assert!(fresh.is_empty(), "the new search's first answer is silent too");
        assert!(m.news.is_empty(), "and the old search's news goes with it");
    }

    #[test]
    fn the_search_loses_its_own_sort() {
        assert_eq!(youtrack_unsorted("for: me #Unresolved sort by: priority desc"), "for: me #Unresolved");
        assert_eq!(youtrack_unsorted("project: X Order By: created"), "project: X");
        assert_eq!(youtrack_unsorted("été #Unresolved"), "été #Unresolved");
        assert_eq!(youtrack_unsorted(""), "");
    }
}
