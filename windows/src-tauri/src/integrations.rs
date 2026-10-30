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

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::Notify;

use crate::github::{self, CiState, ContributionDay, GitHubActivity, GitHubPr, GitHubPulse, GitHubRepoCi, ReviewState};
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
    spawn(app.clone(), "integration_gitea", 7, 300, poll_gitea);
    spawn_github_loops(app.clone());
    spawn(app.clone(), "integration_calcom", 8, 300, poll_calcom);
    spawn(app, "integration_notion", 9, 300, poll_notion);
}

/// The GitLab projects the user follows (Settings → Integrations → GitLab);
/// empty means every project.
fn gitlab_followed(app: &AppHandle) -> Vec<i64> {
    app.try_state::<crate::Shared>()
        .map(|shared| shared.settings.lock().unwrap().gitlab_projects.clone())
        .unwrap_or_default()
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
        "integration_github" => {
            wake_github_pulse();
            github_refresh_if_stale("activity");
            poll_github(app).await
        }
        "integration_gitlab" => {
            gitlab_wake_pulse();
            poll_gitlab(app).await
        }
        "integration_gitea" => poll_gitea(app).await,
        "integration_vercel" => poll_vercel(app).await,
        "integration_n8n" => poll_n8n(app).await,
        "integration_resend" => poll_resend(app).await,
        "integration_notion" => poll_notion(app).await,
        "integration_calcom" => poll_calcom(app).await,
        "integration_youtrack" => poll_youtrack(app).await,
        _ => {}
    }
}

// ── GitLab ───────────────────────────────────────────────────────────────────
fn gitea_api_base() -> Option<String> {
    let url = secrets::get("gitea-url")?;
    let parsed = reqwest::Url::parse(url.trim()).ok()?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
        return None;
    }
    Some(format!("{}/api/v1", parsed.as_str().trim_end_matches('/')))
}

async fn poll_gitea(app: AppHandle) {
    if PAUSED.load(Ordering::Relaxed) || !enabled(&app, "integration_gitea") { return; }
    let (Some(token), Some(base)) = (secrets::get("gitea-token"), gitea_api_base()) else { return };
    let Ok(http) = reqwest::Client::builder().timeout(TIMEOUT)
        .redirect(reqwest::redirect::Policy::none()).build() else { return };
    let user = http.get(format!("{base}/user")).header("Authorization", format!("token {token}")).send().await;
    let Ok(response) = user else { return };
    if !response.status().is_success() {
        emit(&app, IntegrationUpdate { id: "integration_gitea", data: json!({}),
            error: Some(status_error(response.status().as_u16(), &crate::i18n::t("Token lacks the needed scope"))), event: None });
        return;
    }
    let user: Value = response.json().await.unwrap_or(json!({}));
    let repos_response = http.get(format!("{base}/user/repos?limit=100&sort=updated"))
        .header("Authorization", format!("token {token}")).send().await;
    let repos: Vec<Value> = match repos_response {
        Ok(r) if r.status().is_success() => r.json().await.unwrap_or_default(),
        _ => Vec::new(),
    };
    let stars: i64 = repos.iter().filter_map(|r| r.get("stars_count").and_then(Value::as_i64)).sum();
    let open_prs: i64 = repos.iter().filter_map(|r| r.get("open_pr_counter").and_then(Value::as_i64)).sum();
    let profile_url = user.get("html_url").and_then(Value::as_str).unwrap_or("");
    // Gitea's heatmap API is the equivalent of GitHub's contribution calendar.
    // The full year supplies the compact card and detail grid. This is optional
    // on older/self-hosted instances, so a missing one never hides the stats.
    let login = user.get("login").and_then(Value::as_str).unwrap_or("");
    let heatmap: Vec<Value> = if login.is_empty() {
        Vec::new()
    } else {
        match http.get(format!("{base}/users/{login}/heatmap"))
            .header("Authorization", format!("token {token}")).send().await {
            Ok(r) if r.status().is_success() => r.json().await.unwrap_or_default(),
            _ => Vec::new(),
        }
    };
    let activity = gitea_activity(&heatmap, now_ms());
    let my_raw = gitea_get(&http, &token, format!("{base}/repos/issues/search?state=open&type=pulls&created=true&limit=20")).await;
    let review_raw = gitea_get(&http, &token, format!("{base}/repos/issues/search?state=open&type=pulls&review_requested=true&limit=20")).await;
    let my_prs = gitea_prs(&my_raw);
    let to_review = gitea_prs(&review_raw);
    let main_ci = gitea_main_ci(&http, &token, &base, &repos).await;
    let pulse = GitHubPulse { login: login.to_string(), my_prs, to_review, main_ci, fetched_at: now_ms() };
    emit(&app, IntegrationUpdate { id: "integration_gitea", data: json!({
        "totalRepos": repos.len(), "totalStars": stars, "openPRs": open_prs,
        "profileUrl": profile_url, "pulse": pulse, "activity": activity,
    }), error: None, event: None });
}

async fn gitea_get(http: &reqwest::Client, token: &str, url: String) -> Vec<Value> {
    match http.get(url).header("Authorization", format!("token {token}")).send().await {
        Ok(r) if r.status().is_success() => r.json().await.unwrap_or_default(),
        _ => Vec::new(),
    }
}

fn gitea_prs(raw: &[Value]) -> Vec<GitHubPr> {
    raw.iter().filter_map(|pr| {
        let repo = pr.get("repository")?.get("full_name")?.as_str()?.to_string();
        let number = pr.get("number")?.as_i64()?;
        Some(GitHubPr { id: format!("{repo}#{number}"), title: pr.get("title").and_then(Value::as_str).unwrap_or("").to_string(),
            url: pr.get("html_url").and_then(Value::as_str).unwrap_or("").to_string(), repo, number,
            is_draft: pr.get("is_draft").and_then(Value::as_bool).unwrap_or(false), ci: CiState::Unknown,
            review: ReviewState::Unknown, head_sha: None })
    }).collect()
}

fn gitea_ci(state: Option<&str>) -> CiState {
    match state.map(str::to_ascii_lowercase).as_deref() {
        Some("success") => CiState::Success,
        Some("pending") => CiState::Pending,
        Some("failure") | Some("error") => CiState::Failure,
        _ => CiState::Unknown,
    }
}

async fn gitea_main_ci(http: &reqwest::Client, token: &str, base: &str, repos: &[Value]) -> Vec<GitHubRepoCi> {
    let mut out = Vec::new();
    for repo in repos.iter().take(20) {
        let Some(name) = repo.get("full_name").and_then(Value::as_str) else { continue };
        let branch = repo.get("default_branch").and_then(Value::as_str).unwrap_or("main");
        let statuses = gitea_get(http, token, format!("{base}/repos/{name}/commits/{branch}/statuses?limit=1&sort=recentupdate")).await;
        out.push(GitHubRepoCi { repo: name.to_string(), url: repo.get("html_url").and_then(Value::as_str).unwrap_or("").to_string(),
            branch: branch.to_string(), ci: gitea_ci(statuses.first().and_then(|s| s.get("state")).and_then(Value::as_str)), head_sha: None });
    }
    out
}

fn gitea_activity(heatmap: &[Value], fetched_at: u64) -> GitHubActivity {
    let today = (fetched_at / 86_400_000) as i64;
    let mut start = today - 364;
    start -= i64::from(civil_day(start).3);
    let mut weeks: Vec<Vec<ContributionDay>> = Vec::new();
    for day in start..=today {
        let (y, m, d, weekday) = civil_day(day);
        if weekday == 0 || weeks.is_empty() { weeks.push(Vec::new()); }
        let count = heatmap.iter().find_map(|entry| {
            let ts = entry.get("timestamp")?.as_i64()?;
            let entry_day = if ts > 10_000_000_000 { ts / 86_400_000 } else { ts / 86_400 };
            (entry_day == day).then(|| entry.get("contributions").and_then(Value::as_i64).unwrap_or(0).max(0))
        }).unwrap_or(0);
        weeks.last_mut().unwrap().push(ContributionDay {
            date: format!("{y:04}-{m:02}-{d:02}"), count, weekday,
            level: if count == 0 { 0 } else if count == 1 { 1 } else if count < 4 { 2 } else if count < 8 { 3 } else { 4 },
        });
    }
    let total = weeks.iter().flatten().map(|d| d.count).sum(); GitHubActivity { total, weeks, fetched_at }
}

/// A Gitea address or token changed: old totals belong to the previous account
/// and must not remain on the card while the new credentials are checked.
pub fn gitea_credentials_changed(app: &AppHandle) {
    emit(app, IntegrationUpdate { id: "integration_gitea", data: json!({}), error: None, event: None });
    if !PAUSED.load(Ordering::Relaxed) && enabled(app, "integration_gitea") {
        tauri::async_runtime::spawn(poll_gitea(app.clone()));
    }
}

fn gitlab_ci(raw: Option<&str>) -> CiState {
    match raw {
        Some("success") => CiState::Success,
        Some("failed") | Some("canceled") | Some("skipped") => CiState::Failure,
        Some("running") | Some("pending") | Some("created") | Some("preparing") | Some("waiting_for_resource") => CiState::Pending,
        _ => CiState::Unknown,
    }
}

/// Gregorian date and Sunday-based weekday for a day counted from 1970-01-01.
fn civil_day(day: i64) -> (i32, u32, u32, u8) {
    let z = day + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = mp + if mp < 10 { 3 } else { -9 };
    let year = y + i64::from(m <= 2);
    (year as i32, m as u32, d as u32, (day + 4).rem_euclid(7) as u8)
}

fn gitlab_activity(events: &[Value], fetched_at: u64) -> GitHubActivity {
    let mut counts: std::collections::HashMap<String, i64> = std::collections::HashMap::new();
    for event in events {
        if let Some(date) = event.get("created_at").and_then(Value::as_str).and_then(|s| s.get(..10)) {
            *counts.entry(date.to_string()).or_default() += 1;
        }
    }
    let today = (fetched_at / 86_400_000) as i64;
    let mut start = today - 364;
    start -= i64::from(civil_day(start).3); // start the first column on Sunday
    let mut weeks: Vec<Vec<ContributionDay>> = Vec::new();
    for day in start..=today {
        let (year, month, date, weekday) = civil_day(day);
        if weekday == 0 || weeks.is_empty() { weeks.push(Vec::new()); }
        let key = format!("{year:04}-{month:02}-{date:02}");
        let count = counts.get(&key).copied().unwrap_or(0);
        let level = if count == 0 { 0 } else if count == 1 { 1 } else if count <= 3 { 2 } else if count <= 7 { 3 } else { 4 };
        weeks.last_mut().unwrap().push(ContributionDay { date: key, count, level, weekday });
    }
    let total = weeks.iter().flatten().map(|day| day.count).sum();
    GitHubActivity { total, weeks, fetched_at }
}

/// The card's pulse, as GitHub's: the open MRs with their CI, the reviews
/// asked of the user, the default branch's CI and a year of activity, with the
/// totals. Heavier than the minute's news, so `poll_gitlab` asks for it every
/// five minutes. With projects followed, the MRs and the default-branch CI are
/// theirs only; the activity stays the user's whole year.
async fn gitlab_pulse(http: &reqwest::Client, base: &str, token: &str, user: &Value, followed: &[i64]) -> Value {
    let headers = |request: reqwest::RequestBuilder| request.header("PRIVATE-TOKEN", token);
    let login = user.get("username").and_then(Value::as_str).unwrap_or("GitLab").to_string();
    let profile_url = user.get("web_url").and_then(Value::as_str).map(str::to_string);

    // GitHub's overview counts repositories owned by the user, so GitLab does
    // the same. Walk the pages for accurate repository and star totals; the
    // first ten (ordered by recent activity) also drive default-branch CI.
    let mut projects = Vec::new();
    for page in 1..=10 {
        let response = headers(http.get(format!("{base}/api/v4/projects")).query(&[
            ("owned", "true"),
            ("simple", "true"),
            ("order_by", "last_activity_at"),
            ("per_page", "100"),
            ("page", &page.to_string()),
        ])).send().await;
        let batch: Vec<Value> = match response {
            Ok(r) if r.status().is_success() => r.json().await.unwrap_or_default(),
            _ => Vec::new(),
        };
        let done = batch.len() < 100;
        projects.extend(batch);
        if done { break; }
    }
    let list = |url: String| async { match headers(http.get(url)).send().await { Ok(v) if v.status().is_success() => v.json::<Vec<Value>>().await.unwrap_or_default(), _ => Vec::new() } };
    let keep = |mrs: Vec<Value>| gitlab_keep_followed(Some(mrs), followed).unwrap_or_default();
    let mine = keep(list(format!("{base}/api/v4/merge_requests?scope=created_by_me&state=opened&per_page=20")).await);
    let review = keep(list(format!("{base}/api/v4/merge_requests?scope=reviews_for_me&state=opened&per_page=20")).await);
    let mut events = Vec::new();
    let today = (now_ms() / 86_400_000) as i64;
    let (year, month, day, _) = civil_day(today - 364);
    let after = format!("{year:04}-{month:02}-{day:02}");
    for page in 1..=10 {
        let batch = list(format!("{base}/api/v4/events?scope=all&after={after}&per_page=100&page={page}")).await;
        let done = batch.len() < 100;
        events.extend(batch);
        if done { break; }
    }
    let to_pr = |v: &Value| -> Option<GitHubPr> { let repo = v.get("references")?.get("full")?.as_str()?.split('!').next()?.to_string(); let n = v.get("iid")?.as_i64()?; Some(GitHubPr { id: format!("{repo}#{n}"), title: v.get("title")?.as_str()?.to_string(), url: v.get("web_url")?.as_str()?.to_string(), repo, number: n, is_draft: v.get("draft").and_then(Value::as_bool).unwrap_or(false), ci: gitlab_ci(v.get("head_pipeline").and_then(|p| p.get("status")).and_then(Value::as_str)), review: ReviewState::Unknown, head_sha: v.get("sha").and_then(Value::as_str).map(str::to_string) }) };
    // The followed projects' default branches when there are some, each asked
    // for itself as they need not be the user's own.
    let ci_projects: Vec<Value> = if followed.is_empty() {
        projects.iter().take(10).cloned().collect()
    } else {
        let mut out = Vec::new();
        for id in followed.iter().take(10) {
            if let Ok(r) = headers(http.get(format!("{base}/api/v4/projects/{id}"))).send().await {
                if r.status().is_success() {
                    if let Ok(project) = r.json::<Value>().await {
                        out.push(project);
                    }
                }
            }
        }
        out
    };
    let mut main_ci = Vec::new();
    for project in &ci_projects {
        let (Some(id), Some(repo), Some(url)) = (project.get("id").and_then(Value::as_i64), project.get("path_with_namespace").and_then(Value::as_str), project.get("web_url").and_then(Value::as_str)) else { continue };
        let branch = project.get("default_branch").and_then(Value::as_str).unwrap_or("main");
        let pipelines: Vec<Value> = match http.get(format!("{base}/api/v4/projects/{id}/pipelines")).query(&[("ref", branch), ("per_page", "1")]).header("PRIVATE-TOKEN", token).send().await { Ok(r) if r.status().is_success() => r.json().await.unwrap_or_default(), _ => Vec::new() };
        let ci = gitlab_ci(pipelines.first().and_then(|p| p.get("status")).and_then(Value::as_str));
        main_ci.push(GitHubRepoCi { repo: repo.into(), url: url.into(), branch: branch.into(), ci, head_sha: None });
    }
    let fetched_at = now_ms();
    let pulse = GitHubPulse { login, my_prs: mine.iter().filter_map(to_pr).collect(), to_review: review.iter().filter_map(to_pr).collect(), main_ci, fetched_at };
    let activity = gitlab_activity(&events, fetched_at);
    let stars: i64 = projects.iter().filter_map(|p| p.get("star_count").and_then(Value::as_i64)).sum();
    json!({ "projects": projects.len(), "totalRepos": projects.len(), "totalStars": stars, "profileUrl": profile_url, "pulse": pulse, "activity": activity })
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

/// The card's error line, in the interface language (i18n.rs);
/// `unauthorised_hint` comes translated.
fn status_error(code: u16, unauthorised_hint: &str) -> String {
    match code {
        401 => crate::i18n::t("Invalid API key (401)"),
        403 => unauthorised_hint.to_string(),
        _ => crate::i18n::tf("API error {code}", &[("code", &code.to_string())]),
    }
}

// ── Stripe ────────────────────────────────────────────────────────────────────

fn parse_stripe_balance(json: &Value) -> (i64, String) {
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
        .filter(|b| b.get("currency").and_then(Value::as_str) == Some(&currency))
        .filter_map(|b| b.get("amount").and_then(Value::as_i64))
        .sum();
    (amount, currency)
}

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
            parse_stripe_balance(&json)
        }
        Ok(r) => {
            let code = r.status().as_u16();
            emit(&app, IntegrationUpdate {
                id: "integration_stripe",
                data: json!({}),
                error: Some(status_error(code, &crate::i18n::t("Use a secret key (sk_live_… not pk_live_…)"))),
                event: None,
            });
            return;
        }
        Err(e) => {
            emit(&app, IntegrationUpdate {
                id: "integration_stripe",
                data: json!({}),
                error: Some(crate::i18n::tf("No connection: {error}", &[("error", &e.to_string())])),
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
            error: Some(status_error(response.status().as_u16(), &crate::i18n::t("Token lacks the needed scope"))),
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

    let total_repos = public + private;
    let max_pages = calculate_repo_pages(total_repos);
    let mut stars: i64 = 0;

    for page in 1..=max_pages {
        let url = format!(
            "https://api.github.com/user/repos?per_page=100&affiliation=owner&sort=pushed&page={page}"
        );
        let resp = http
            .get(&url)
            .header("Authorization", format!("Bearer {token}"))
            .header("Accept", "application/vnd.github+json")
            .header("User-Agent", "Coucou")
            .send()
            .await;
        match resp {
            Ok(r) if r.status().is_success() => {
                let Ok(list) = r.json::<Vec<Value>>().await else { break };
                let count = list.len();
                stars += sum_repo_stars(&list);
                if count < 100 {
                    break;
                }
            }
            _ => break,
        }
    }

    GITHUB.cache.lock().unwrap().stats = Some((total_repos, stars));
    emit_github(&app);
}

pub(crate) fn calculate_repo_pages(total_repos: i64) -> usize {
    if total_repos <= 0 {
        1
    } else {
        usize::try_from((total_repos + 99) / 100).unwrap_or(1).clamp(1, 50)
    }
}

pub(crate) fn sum_repo_stars(repos: &[Value]) -> i64 {
    repos
        .iter()
        .filter_map(|r| r.get("stargazers_count").and_then(Value::as_i64))
        .sum()
}

// ── GitHub pulse and activity (GithubPoller.swift) ────────────────────────────
//
// Two more loops next to the stats above, with the Mac cadence: the pulse (my
// pull requests and their CI, reviews waiting for me, default-branch CI) 10 s
// after launch, then every 60 s while some CI is running and every 5 min
// otherwise; the contribution calendar 15 s after launch, then every 30 min.
// Neither touches the network while the pill is off or Coucou is paused, and
// the island wakes them when the card is opened on stale data.
//
// All three results are kept here and always sent together, so one poll never
// wipes what another one reported.

const GITHUB_ID: &str = "integration_github";

#[derive(Default)]
struct GitHubCache {
    /// (repositories, stars)
    stats: Option<(i64, i64)>,
    pulse: Option<GitHubPulse>,
    activity: Option<GitHubActivity>,
}

struct GitHubLoops {
    cache: Mutex<GitHubCache>,
    /// Bumped when the token changes: a response for the old token is dropped.
    generation: AtomicU64,
    pulse_wake: Notify,
    activity_wake: Notify,
    pulse_busy: AtomicBool,
    activity_busy: AtomicBool,
}

static GITHUB: std::sync::LazyLock<GitHubLoops> = std::sync::LazyLock::new(|| GitHubLoops {
    cache: Mutex::new(GitHubCache::default()),
    generation: AtomicU64::new(0),
    pulse_wake: Notify::new(),
    activity_wake: Notify::new(),
    pulse_busy: AtomicBool::new(false),
    activity_busy: AtomicBool::new(false),
});

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// What the island's GitHub card receives: whichever of the three is known.
fn github_card_data(cache: &GitHubCache) -> Value {
    let mut data = serde_json::Map::new();
    if let Some((repos, stars)) = cache.stats {
        data.insert("totalRepos".into(), json!(repos));
        data.insert("totalStars".into(), json!(stars));
    }
    if let Some(pulse) = &cache.pulse {
        data.insert("pulse".into(), serde_json::to_value(pulse).unwrap_or(Value::Null));
    }
    if let Some(activity) = &cache.activity {
        data.insert("activity".into(), serde_json::to_value(activity).unwrap_or(Value::Null));
    }
    Value::Object(data)
}

fn emit_github(app: &AppHandle) {
    let data = github_card_data(&GITHUB.cache.lock().unwrap());
    emit(app, IntegrationUpdate { id: GITHUB_ID, data, error: None, event: None });
}

fn spawn_github_loops(app: AppHandle) {
    let pulse_app = app.clone();
    tauri::async_runtime::spawn(async move {
        let mut wait = Duration::from_secs(10);
        loop {
            // Sleeps for `wait`, or less when the island asks for fresh data.
            let _ = tokio::time::timeout(wait, GITHUB.pulse_wake.notified()).await;
            let pending = run_github_pulse(&pulse_app).await;
            wait = Duration::from_secs(if pending { 60 } else { 300 });
        }
    });
    tauri::async_runtime::spawn(async move {
        let mut wait = Duration::from_secs(15);
        loop {
            let _ = tokio::time::timeout(wait, GITHUB.activity_wake.notified()).await;
            run_github_activity(&app).await;
            wait = Duration::from_secs(1800);
        }
    });
}

/// One authenticated GraphQL call. Partial errors are logged (as a count) and the
/// data parsed anyway; only a response without `data` is dropped.
async fn github_graphql(token: &str, query: &str, what: &str) -> Option<Value> {
    let response = client()
        .post("https://api.github.com/graphql")
        .header("Authorization", format!("Bearer {token}"))
        .header("Content-Type", "application/json")
        .header("User-Agent", "Coucou")
        .json(&json!({ "query": query }))
        .send()
        .await;
    let Ok(response) = response else {
        log::line(format!("github {what}: no connection"));
        return None;
    };
    if !response.status().is_success() {
        log::line(format!("github {what} HTTP {}", response.status().as_u16()));
        return None;
    }
    let root: Value = response.json().await.ok()?;
    let errors = github::graphql_error_count(&root);
    if errors > 0 {
        log::line(format!("github {what} GraphQL errors: {errors}"));
    }
    root.get("data").filter(|d| d.is_object())?;
    Some(root)
}

/// Returns whether some CI is still running, which sets the next interval.
async fn run_github_pulse(app: &AppHandle) -> bool {
    if PAUSED.load(Ordering::Relaxed) || !enabled(app, GITHUB_ID) {
        return false;
    }
    let Some(token) = secrets::get("github-token") else { return false };
    let generation = GITHUB.generation.load(Ordering::SeqCst);
    GITHUB.pulse_busy.store(true, Ordering::SeqCst);
    let root = github_graphql(&token, github::PULSE_QUERY, "pulse").await;
    GITHUB.pulse_busy.store(false, Ordering::SeqCst);
    let Some(pulse) = root.and_then(|r| GitHubPulse::parse(&r, now_ms())) else { return false };
    let pending = pulse.has_pending();

    let events = {
        let mut cache = GITHUB.cache.lock().unwrap();
        // The token changed while this was in flight: it answers for someone else.
        if GITHUB.generation.load(Ordering::SeqCst) != generation {
            return pending;
        }
        let events = GitHubPulse::events(cache.pulse.as_ref(), &pulse);
        cache.pulse = Some(pulse);
        events
    };
    emit_github(app);
    if !events.is_empty() {
        let _ = app.emit_to(WINDOW_LABEL, "github-alerts", &events);
    }
    pending
}

async fn run_github_activity(app: &AppHandle) {
    if PAUSED.load(Ordering::Relaxed) || !enabled(app, GITHUB_ID) {
        return;
    }
    let Some(token) = secrets::get("github-token") else { return };
    let generation = GITHUB.generation.load(Ordering::SeqCst);
    GITHUB.activity_busy.store(true, Ordering::SeqCst);
    let root = github_graphql(&token, github::ACTIVITY_QUERY, "activity").await;
    GITHUB.activity_busy.store(false, Ordering::SeqCst);
    let Some(activity) = root.and_then(|r| GitHubActivity::parse(&r, now_ms())) else { return };
    {
        let mut cache = GITHUB.cache.lock().unwrap();
        if GITHUB.generation.load(Ordering::SeqCst) != generation {
            return;
        }
        cache.activity = Some(activity);
    }
    emit_github(app);
}

fn wake_github_pulse() {
    if !GITHUB.pulse_busy.load(Ordering::SeqCst) {
        GITHUB.pulse_wake.notify_one();
    }
}

/// The card was opened: fetch now if what it shows is older than the Mac's
/// limits (1 min for the pulse, 5 min for the activity grid). No-op while a
/// request is already in flight.
pub fn github_refresh_if_stale(section: &str) {
    let now = now_ms();
    let cache = GITHUB.cache.lock().unwrap();
    match section {
        "pulse" => {
            let fetched = cache.pulse.as_ref().map(|p| p.fetched_at);
            if !GITHUB.pulse_busy.load(Ordering::SeqCst) && github::is_stale(fetched, now, 60) {
                GITHUB.pulse_wake.notify_one();
            }
        }
        "activity" => {
            let fetched = cache.activity.as_ref().map(|a| a.fetched_at);
            if !GITHUB.activity_busy.load(Ordering::SeqCst) && github::is_stale(fetched, now, 300) {
                GITHUB.activity_wake.notify_one();
            }
        }
        _ => {}
    }
}

/// The GitHub token was saved or removed: forget what the old one fetched, drop
/// its requests still in flight, and fetch again right away.
pub fn github_token_changed(app: &AppHandle) {
    GITHUB.generation.fetch_add(1, Ordering::SeqCst);
    let has_token = secrets::get("github-token").is_some();
    {
        let mut cache = GITHUB.cache.lock().unwrap();
        cache.pulse = None;
        cache.activity = None;
        if !has_token {
            cache.stats = None;
        }
    }
    emit_github(app);
    GITHUB.pulse_wake.notify_one();
    GITHUB.activity_wake.notify_one();
    if has_token && !PAUSED.load(Ordering::Relaxed) && enabled(app, GITHUB_ID) {
        tauri::async_runtime::spawn(poll_github(app.clone()));
    }
}

/// Switching the pill off forgets the pulse, so switching it back on starts
/// silent instead of alerting on everything that changed in between.
pub fn settings_saved(app: &AppHandle, active_integrations: &[String]) {
    if active_integrations.iter().any(|id| id == GITHUB_ID) {
        return;
    }
    let had_data = {
        let mut cache = GITHUB.cache.lock().unwrap();
        let had = cache.pulse.is_some() || cache.activity.is_some();
        cache.pulse = None;
        cache.activity = None;
        had
    };
    if had_data {
        emit_github(app);
    }
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
            error: Some(status_error(response.status().as_u16(), &crate::i18n::t("Token lacks access"))),
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
            error: Some(status_error(response.status().as_u16(), &crate::i18n::t("Key lacks access"))),
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
            error: Some(status_error(response.status().as_u16(), &crate::i18n::t("Integration lacks access"))),
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
            error: Some(status_error(response.status().as_u16(), &crate::i18n::t("Key lacks access"))),
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
// that has the `read_api` and `read_user` scopes. The card is GitHub's: the
// pulse (`gitlab_pulse`, every five minutes). On top of it, the news, from four
// sources every minute:
// - the To-Do list, GitLab's own inbox for the user: review requests,
//   assignments, mentions, a pipeline failing on their MR, an MR that can't be
//   merged, a review submitted… Every new to-do is news;
// - the merge requests the user authored: approved (and by whom), merged;
// - every open MR the user is involved in — authored, assigned, to review: one
//   updated since the last poll has its discussion read, and what someone else
//   did there (a comment, commits, an approval, a status change) is news;
// - the pipelines the user started in the projects of their week (or in the
//   projects they follow).
// Everything new in one poll becomes one notification — one sound, one badge —
// that lists all of it, so nothing landing in the same minute is lost. The
// card's Inbox keeps that news on top of the pending to-dos and the MRs.

pub const GITLAB_DEFAULT_URL: &str = "https://gitlab.com";

/// The configured instance, without a trailing slash. Only http(s): the value
/// ends up in requests and in the browser.
pub fn gitlab_base() -> Result<String, String> {
    let raw = secrets::get("gitlab-url").unwrap_or_else(|| GITLAB_DEFAULT_URL.to_string());
    let base = raw.trim().trim_end_matches('/').to_string();
    if base.starts_with("https://") || base.starts_with("http://") {
        Ok(base)
    } else {
        Err(crate::i18n::t("The GitLab URL must start with https://"))
    }
}

/// Approvals are asked for this many of the user's open MRs, the most recently
/// updated: one request each, every minute.
const GITLAB_APPROVAL_CHECKS: usize = 5;
/// The discussion is read for at most this many updated MRs a minute.
const GITLAB_ACTIVITY_CHECKS: usize = 5;
/// The user's pipelines are looked for in the projects of their activity over
/// this many days, at most this many projects: one request each, every minute.
const GITLAB_PIPELINE_DAYS: i64 = 7;
const GITLAB_PIPELINE_PROJECTS: usize = 10;
/// Followed projects asked for their pipelines each minute, at most.
const GITLAB_FOLLOWED_MAX: usize = 20;
/// Pages of 100 read when listing the user's projects for Settings.
const GITLAB_PROJECT_PAGES: u32 = 5;
/// Pipelines updated in this window are read each minute; one seen is
/// remembered this long, so it is never told twice.
const GITLAB_PIPELINE_WINDOW_MS: i64 = 15 * 60 * 1000;
const GITLAB_PIPELINE_MEMORY_MS: i64 = 60 * 60 * 1000;
/// The pulse is asked again after this long, or after a minute when the island
/// asks for fresh data (a list opened on the card).
const GITLAB_PULSE_EVERY_MS: i64 = 5 * 60 * 1000;
const GITLAB_PULSE_WAKE_MS: i64 = 60 * 1000;

/// One notification for the lot: the label says it, the detail lists it.
/// `many` names the lot, from its count, when there is more than one.
fn news_event(fresh: &[Value], many: impl Fn(u64) -> String) -> Option<IntegrationEvent> {
    (!fresh.is_empty()).then(|| {
        let labels: Vec<String> = fresh.iter().filter_map(|n| n["label"].as_str().map(str::to_string)).collect();
        IntegrationEvent {
            success: fresh.iter().all(|n| n["success"].as_bool().unwrap_or(true)),
            label: if labels.len() == 1 { labels[0].clone() } else { many(labels.len() as u64) },
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
    /// The user's recent pipelines as last seen: id → (status, when seen).
    pipelines: Option<std::collections::HashMap<i64, (String, i64)>>,
    /// The user's own MRs as last seen: id → (state, approvers).
    authored: Option<std::collections::HashMap<i64, (String, Vec<String>)>>,
    /// The open MRs the user is involved in, as last seen: id → updated_at.
    involved: Option<std::collections::HashMap<i64, String>>,
    /// The latest news, newest first: { label, url, success, at, todoId?, mrId?, changes? }.
    news: Vec<Value>,
    /// Whose news `news` is (the instance and the user), once read from disk.
    news_owner: Option<String>,
    /// The last pulse: when, for whom and which projects, and what it said.
    pulse: Option<(i64, String, Value)>,
}

/// GitLab's client: PRIVATE-TOKEN must never follow an instance redirect to
/// another server.
fn gitlab_client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(TIMEOUT)
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap_or_default()
}

/// The island wants fresh lists: a pulse older than a minute is asked again.
fn gitlab_wake_pulse() {
    if let Some(pulse) = GITLAB.lock().unwrap().pulse.as_mut() {
        if now_ms() as i64 - pulse.0 > GITLAB_PULSE_WAKE_MS {
            pulse.0 = 0;
        }
    }
}

static GITLAB: std::sync::LazyLock<Mutex<GitlabMemory>> = std::sync::LazyLock::new(Default::default);

/// What a to-do is about, in words, and whether it is bad news.
fn gitlab_todo_kind(action: &str) -> (String, bool) {
    use crate::i18n::n_;
    let (kind, ok) = match action {
        "review_requested" => (n_("Review requested"), true),
        "assigned" => (n_("Assigned to you"), true),
        "mentioned" | "directly_addressed" => (n_("Mentioned"), true),
        "build_failed" => (n_("Pipeline failed"), false),
        "unmergeable" => (n_("Can't be merged"), false),
        "merge_train_removed" => (n_("Out of the merge train"), false),
        "approval_required" => (n_("Approval needed"), true),
        "review_submitted" => (n_("Reviewed"), true),
        "member_access_requested" => (n_("Access requested"), true),
        _ => (n_("To-do"), true),
    };
    (crate::i18n::t(kind), ok)
}

// ── News kept across restarts ──

/// News stays on its card, through restarts too, until this many newer pieces
/// push it out.
const NEWS_KEEP: usize = 10;

/// This poll's news first, then what came before, `NEWS_KEEP` at most.
fn recent_news(fresh: &[Value], before: &[Value]) -> Vec<Value> {
    fresh.iter().chain(before).take(NEWS_KEEP).cloned().collect()
}

/// Where a service's news is kept: next to the log, never sent anywhere.
fn news_file(service: &str) -> std::path::PathBuf {
    crate::settings::local_dir().join(format!("news-{service}.json"))
}

/// The news kept for `owner` — the account or the search it came from. None
/// when the file is missing, unreadable, or someone else's.
fn load_news(service: &str, owner: &str) -> Vec<Value> {
    std::fs::read_to_string(news_file(service))
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .filter(|saved| saved["owner"] == owner)
        .and_then(|saved| saved["news"].as_array().cloned())
        .unwrap_or_default()
}

fn save_news(service: &str, owner: &str, news: &[Value]) {
    let written = crate::platform::ensure_private_dir(&crate::settings::local_dir())
        .and_then(|_| std::fs::write(news_file(service), json!({ "owner": owner, "news": news }).to_string()));
    if let Err(e) = written {
        log::line(format!("{service} news not saved: {e}"));
    }
}

fn s(v: &Value, key: &str) -> String {
    v.get(key).and_then(Value::as_str).unwrap_or("").to_string()
}

/// The open MRs the user is involved in, once each, most recently updated
/// first, with what the user is on each: author, assignee, reviewer.
fn gitlab_involved(authored: &[Value], assigned: &[Value], reviewing: &[Value]) -> Vec<Value> {
    let mut items: Vec<Value> = Vec::new();
    // English keys: the card shows them in the interface language.
    let sources = [(authored, crate::i18n::n_("Yours")), (assigned, crate::i18n::n_("Assigned")), (reviewing, crate::i18n::n_("Review"))];
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

/// Lines of detail kept per piece of news: a burst of activity is not worth more.
const GITLAB_CHANGES_KEEP: usize = 8;

/// Markdown and HTML as one plain line: tags gone, `[text](url)` as its text,
/// the emphasis marks dropped, whitespace squeezed, cut at 80 characters.
fn gitlab_plain(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while !rest.is_empty() {
        if let Some(tag) = rest.strip_prefix('<').and_then(|r| r.find('>').map(|end| end + 2)) {
            // A tag: replaced by a space, so <li>a</li><li>b</li> doesn't glue.
            out.push(' ');
            rest = &rest[tag..];
        } else if let Some(link) = rest.strip_prefix('[').and_then(|r| {
            let close = r.find("](")?;
            let end = r[close..].find(')')? + close;
            Some((&r[..close], end + 2))
        }) {
            out.push_str(link.0);
            rest = &rest[link.1..];
        } else {
            let c = rest.chars().next().unwrap();
            if !matches!(c, '*' | '`' | '~') {
                out.push(c);
            }
            rest = &rest[c.len_utf8()..];
        }
    }
    let line = out.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.chars().count() > 80 { format!("{}…", line.chars().take(79).collect::<String>()) } else { line }
}

/// What a note on an MR says happened, as one line. A comment gives its first
/// words; a system note says it itself ("approved this merge request", "changed
/// title from A to B"), and commits pushed read as their messages, not hashes.
fn gitlab_note_text(note: &Value) -> Option<String> {
    let body = s(note, "body");
    if body.trim().is_empty() {
        return None;
    }
    if !note["system"].as_bool().unwrap_or(false) {
        return Some(crate::i18n::tf("Comment: “{text}”", &[("text", &gitlab_plain(&body))]));
    }
    // "added 2 commits\n\n<ul><li>abc1234 - Fix login</li>…</ul>\n\n[Compare…](…)"
    if body.starts_with("added ") && body.contains("<li>") {
        let head = body.lines().next().unwrap_or("");
        let messages: Vec<String> = body
            .split("<li>")
            .skip(1)
            .filter_map(|li| li.split("</li>").next())
            .map(|li| gitlab_plain(li.split_once(" - ").map(|(_, m)| m).unwrap_or(li)))
            .filter(|m| !m.is_empty())
            .collect();
        let more = if messages.len() > 3 { ", …" } else { "" };
        let shown = messages.iter().take(3).cloned().collect::<Vec<_>>().join(", ");
        return Some(gitlab_plain(&format!("{head}: {shown}{more}")));
    }
    Some(gitlab_plain(body.lines().next().unwrap_or("")))
}

/// A failed pipeline's failed jobs, as the lines under its news: "test: unit
/// failed". The stage is left out when the job is named after it.
fn gitlab_failed_jobs(jobs: &[Value]) -> Vec<Value> {
    jobs.iter()
        .filter(|j| s(j, "status") == "failed" || s(j, "status").is_empty())
        .map(|j| {
            let (name, stage) = (s(j, "name"), s(j, "stage"));
            let text = if stage.is_empty() || stage == name {
                crate::i18n::tf("{name} failed", &[("name", &name)])
            } else {
                crate::i18n::tf("{stage}: {name} failed", &[("stage", &stage), ("name", &name)])
            };
            json!({ "text": text, "by": "" })
        })
        .take(GITLAB_CHANGES_KEEP)
        .collect()
}

/// An MR list kept to the followed projects (all of it when none is followed).
/// A source that failed stays failed: None is not an empty list.
fn gitlab_keep_followed(answer: Option<Vec<Value>>, followed: &[i64]) -> Option<Vec<Value>> {
    if followed.is_empty() {
        return answer;
    }
    answer.map(|list| {
        list.into_iter()
            .filter(|mr| mr.get("project_id").and_then(Value::as_i64).is_some_and(|p| followed.contains(&p)))
            .collect()
    })
}

/// One project for Settings: its id, its name, and the group it sits in as
/// GitLab names it ("Team / Backend"), or the user's own namespace.
#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GitlabProject {
    pub id: i64,
    pub name: String,
    pub group: String,
}

/// The projects of an answer to `/projects`, sorted by group then name.
fn gitlab_project_list(answer: &[Value]) -> Vec<GitlabProject> {
    let mut out: Vec<GitlabProject> = answer
        .iter()
        .filter_map(|p| {
            let id = p.get("id").and_then(Value::as_i64)?;
            let name = s(p, "name");
            // "Team / Backend / api" → "Team / Backend".
            let full = s(p, "name_with_namespace");
            let group = full
                .strip_suffix(&name)
                .map(|g| g.trim_end().trim_end_matches('/').trim_end().to_string())
                .filter(|g| !g.is_empty())
                .unwrap_or_else(|| p.get("namespace").map(|n| s(n, "name")).unwrap_or_default());
            Some(GitlabProject { id, name, group })
        })
        .collect();
    out.sort_by(|a, b| {
        a.group.to_lowercase().cmp(&b.group.to_lowercase()).then(a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    out
}

/// The projects the user is a member of, not archived, for Settings →
/// Integrations → GitLab. Asked only from there.
pub async fn gitlab_projects() -> Result<Vec<GitlabProject>, String> {
    let token = secrets::get("gitlab-token").ok_or_else(|| crate::i18n::t("Save the URL and the token first"))?;
    let base = gitlab_base()?;
    let http = gitlab_client();
    let mut all: Vec<Value> = Vec::new();
    for page in 1..=GITLAB_PROJECT_PAGES {
        let response = http
            .get(format!(
                "{base}/api/v4/projects?membership=true&archived=false&simple=true&order_by=path&sort=asc&per_page=100&page={page}"
            ))
            .header("PRIVATE-TOKEN", &token)
            .header("Accept", "application/json")
            .send()
            .await
            .map_err(|e| crate::i18n::tf("No connection: {error}", &[("error", &e.without_url().to_string())]))?;
        if !response.status().is_success() {
            return Err(status_error(response.status().as_u16(), &crate::i18n::t("Token lacks the needed scope")));
        }
        let more = response.json::<Vec<Value>>().await.map_err(|_| crate::i18n::t("Unexpected answer from GitLab — check the URL"))?;
        let full = more.len() == 100;
        all.extend(more);
        if !full {
            break;
        }
    }
    Ok(gitlab_project_list(&all))
}

/// "https://gl/group/sub/api/-/pipelines/12" → "api".
fn gitlab_project_of(url: &str) -> String {
    url.split("/-/").next().unwrap_or("").rsplit('/').next().unwrap_or("").to_string()
}

/// What started a pipeline, in words.
fn gitlab_pipeline_source(source: &str) -> String {
    use crate::i18n::t;
    match source {
        "push" => t("Push"),
        "web" => t("Run from GitLab"),
        "merge_request_event" => t("Merge request"),
        "schedule" => t("Scheduled"),
        "api" => "API".into(),
        "trigger" => t("Trigger"),
        "parent_pipeline" | "pipeline" => t("Parent pipeline"),
        "" => t("Pipeline"),
        other => other.replace('_', " "),
    }
}

/// A pipeline's duration in seconds, as "4 min 12 s".
fn gitlab_took(secs: i64) -> String {
    use crate::i18n::tf;
    let (h, m, s) = ((secs / 3600).to_string(), (secs % 3600 / 60).to_string(), (secs % 60).to_string());
    match secs {
        x if x < 60 => tf("{seconds} s", &[("seconds", &s)]),
        x if x < 3600 => tf("{minutes} min {seconds} s", &[("minutes", &m), ("seconds", &s)]),
        _ => tf("{hours} h {minutes} min", &[("hours", &h), ("minutes", &m)]),
    }
}

/// Milliseconds since the epoch as ISO-8601 in UTC, as GitLab takes it.
fn iso_utc(ms: i64) -> String {
    let secs = ms.div_euclid(1000);
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Days to a civil date (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
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

    // Pipelines: one that finished since it was last seen — running then, or
    // not started yet, or retried since. Canceled is no news.
    let mut failed_projects: Vec<String> = Vec::new();
    let primed = memory.pipelines.is_some();
    let known = memory.pipelines.clone().unwrap_or_default();
    for p in pipelines {
        let id = p["id"].as_i64().unwrap_or(0);
        let status = p["status"].as_str().unwrap_or("");
        let was = known.get(&id).map(|k| k.0.as_str());
        if !primed || !matches!(status, "success" | "failed") || was == Some(status) {
            continue;
        }
        let ok = status == "success";
        let project = p["project"].as_str().unwrap_or("");
        if !ok {
            failed_projects.push(project.to_string());
        }
        let reference = p["ref"].as_str().unwrap_or("");
        let vars = [("project", project), ("ref", reference)];
        let label = if ok {
            crate::i18n::tf("Pipeline passed: {project} · {ref}", &vars)
        } else {
            crate::i18n::tf("Pipeline failed: {project} · {ref}", &vars)
        };
        let url = p["url"].as_str().unwrap_or("").to_string();
        let mut item = news(label, url, ok, None, None);
        let sha: String = p["sha"].as_str().unwrap_or("").chars().take(8).collect();
        let source = gitlab_pipeline_source(p["source"].as_str().unwrap_or(""));
        let started = crate::i18n::tf("{source} on {ref}", &[("source", &source), ("ref", reference)]);
        let started = if sha.is_empty() { started } else { format!("{started} · {sha}") };
        item["changes"] = json!([{ "text": started, "by": "" }]);
        // How long it took, and which jobs failed, are asked for afterwards
        // (`poll_gitlab`): this says which pipeline to ask about.
        item["pipeline"] = json!({ "id": id, "projectId": p["projectId"] });
        fresh.push(item);
    }
    if projects_answer.is_some() {
        let now = now_ms() as i64;
        let mut seen: std::collections::HashMap<i64, (String, i64)> =
            known.into_iter().filter(|(_, (_, at))| now - at < GITLAB_PIPELINE_MEMORY_MS).collect();
        for p in pipelines {
            if let Some(id) = p["id"].as_i64() {
                seen.insert(id, (p["status"].as_str().unwrap_or("").to_string(), now));
            }
        }
        memory.pipelines = Some(seen);
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
            let mut item = news(format!("{kind}: {title}"), url.clone(), ok, Some(id), mr);
            let by = t.get("author").map(|a| s(a, "name")).unwrap_or_default();
            let mut changes: Vec<Value> = Vec::new();
            // A mention or a review carries what was written; an assignment's
            // body is only the title again.
            let body = gitlab_plain(&s(t, "body"));
            if !body.is_empty() && body != gitlab_plain(&title) {
                changes.push(json!({ "text": format!("“{body}”"), "by": by }));
            }
            // Where, and from whom.
            let from = if by.is_empty() { String::new() } else { crate::i18n::tf("from {name}", &[("name", &by)]) };
            let place: Vec<&str> = [project.as_str(), from.as_str()].into_iter().filter(|x| !x.is_empty()).collect();
            if !place.is_empty() {
                changes.push(json!({ "text": place.join(" · "), "by": "" }));
            }
            item["changes"] = json!(changes);
            fresh.push(item);
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
                let branches = format!("{} → {}", s(mr, "source_branch"), s(mr, "target_branch"));
                if state == "merged" && was != "merged" {
                    let mut item = news(crate::i18n::tf("Merged: {title}", &[("title", &title)]), url.clone(), true, None, Some(id));
                    let by = mr.get("merged_by").map(|a| s(a, "name")).unwrap_or_default();
                    let text = if by.is_empty() {
                        branches.clone()
                    } else {
                        crate::i18n::tf("Merged by {name} · {branches}", &[("name", &by), ("branches", &branches)])
                    };
                    item["changes"] = json!([{ "text": text, "by": by }]);
                    fresh.push(item);
                }
                for name in now_approvers.iter().filter(|n| !had.contains(n)) {
                    let label = crate::i18n::tf("Approved by {name}: {title}", &[("name", name), ("title", &title)]);
                    let mut item = news(label, url.clone(), true, None, Some(id));
                    item["changes"] = json!([
                        { "text": crate::i18n::tf("Approvals so far: {names}", &[("names", &now_approvers.join(", "))]), "by": "" },
                        { "text": branches.clone(), "by": "" },
                    ]);
                    fresh.push(item);
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

            let title = mr["title"].as_str().unwrap_or("");
            let url = mr["url"].as_str().unwrap_or("").to_string();
            // What they did, oldest first (the notes come newest first).
            let mut changes: Vec<Value> = Vec::new();
            for n in others.iter().rev() {
                let Some(text) = gitlab_note_text(n) else { continue };
                if changes.len() < GITLAB_CHANGES_KEEP && !changes.iter().any(|c| c["text"] == text.as_str()) {
                    let by = n.get("author").map(|a| s(a, "name")).unwrap_or_default();
                    changes.push(json!({ "text": text, "by": by }));
                }
            }
            let vars = [("name", name.as_str()), ("title", title)];
            let label = if commented {
                crate::i18n::tf("Comment by {name}: {title}", &vars)
            } else {
                crate::i18n::tf("Updated by {name}: {title}", &vars)
            };
            let mut item = news(label, url, true, None, Some(id));
            item["changes"] = json!(changes);
            fresh.push(item);
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
    if PAUSED.load(Ordering::Relaxed) || !enabled(&app, "integration_gitlab") {
        return;
    }
    let Some(token) = secrets::get("gitlab-token") else { return };
    let fail = |error: String| {
        emit(&app, IntegrationUpdate { id: "integration_gitlab", data: json!({}), error: Some(error), event: None });
    };
    let base = match gitlab_base() {
        Ok(b) => b,
        Err(e) => return fail(e),
    };
    let http = gitlab_client();
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
        Ok(r) => return fail(status_error(r.status().as_u16(), &crate::i18n::t("Token lacks the needed scope"))),
        // Without the URL: a self-hosted address is the user's business, not the log's.
        Err(e) => return fail(crate::i18n::tf("No connection: {error}", &[("error", &e.without_url().to_string())])),
    };
    let Some(username) = user.get("username").and_then(Value::as_str).map(str::to_string) else {
        return fail(crate::i18n::t("Unexpected answer from GitLab — check the URL"));
    };

    // ── The To-Do list ──
    let todos_answer = list("todos?state=pending&per_page=20".into()).await;
    let todos = todos_answer.clone().unwrap_or_default();

    // ── The user's own merge requests, and who approved the open ones ──
    let followed = gitlab_followed(&app);
    let authored_answer = gitlab_keep_followed(
        list("merge_requests?scope=created_by_me&state=all&order_by=updated_at&sort=desc&per_page=20".into()).await,
        &followed,
    );
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
    let assigned_answer = gitlab_keep_followed(mrs("scope=assigned_to_me".into()).await, &followed);
    let reviewing_answer = gitlab_keep_followed(mrs(format!("scope=all&reviewer_username={username}")).await, &followed);
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

    // ── The user's recent pipelines, in every project of their recent activity ──
    // GitLab has no list of a user's pipelines across projects: the projects
    // come from the user's own events, newest first, and each is asked for the
    // pipelines the user started that moved in the last minutes.
    // With projects followed, those are the ones asked (GITLAB_FOLLOWED_MAX at most).
    let (projects_answer, project_ids) = if followed.is_empty() {
        let since_day = iso_utc(now_ms() as i64 - (GITLAB_PIPELINE_DAYS + 1) * 86_400_000);
        let answer = list(format!("events?after={}&per_page=100", &since_day[..10])).await;
        let mut ids: Vec<i64> = Vec::new();
        for event in answer.iter().flatten() {
            if let Some(pid) = event.get("project_id").and_then(Value::as_i64) {
                if !ids.contains(&pid) && ids.len() < GITLAB_PIPELINE_PROJECTS {
                    ids.push(pid);
                }
            }
        }
        (answer, ids)
    } else {
        (Some(Vec::new()), followed.iter().copied().take(GITLAB_FOLLOWED_MAX).collect())
    };
    let updated_after = iso_utc(now_ms() as i64 - GITLAB_PIPELINE_WINDOW_MS);
    let mut pipelines: Vec<Value> = Vec::new();
    for pid in project_ids {
        let path = format!("projects/{pid}/pipelines?username={username}&updated_after={updated_after}&per_page=20");
        for p in list(path).await.unwrap_or_default() {
            pipelines.push(json!({
                "id": p.get("id").and_then(Value::as_i64).unwrap_or(0),
                "projectId": pid,
                "project": gitlab_project_of(&s(&p, "web_url")),
                "ref": s(&p, "ref"),
                "sha": s(&p, "sha"),
                "source": s(&p, "source"),
                "status": s(&p, "status"),
                "url": s(&p, "web_url"),
                "updatedAt": s(&p, "updated_at"),
            }));
        }
    }
    // ISO-8601 in UTC sorts as text.
    pipelines.sort_by(|a, b| b["updatedAt"].as_str().cmp(&a["updatedAt"].as_str()));

    // In a block of its own: the lock must be gone before the requests below.
    let (mut fresh, todo_items) = {
        let mut memory = GITLAB.lock().unwrap();
        gitlab_fresh(
            &mut memory, &projects_answer, &pipelines, &todos_answer, &authored_answer, &approvers,
            &involved_answer, &activity, &username,
        )
    };

    // For each pipeline in the news, how long it took and, when it failed,
    // which jobs did: asked only then. Without them the news still goes out.
    for item in &mut fresh {
        let (Some(pipeline), Some(project)) = (item["pipeline"]["id"].as_i64(), item["pipeline"]["projectId"].as_i64())
        else {
            continue;
        };
        let mut lines: Vec<Value> = Vec::new();
        if item["success"] == false {
            if let Some(jobs) = list(format!("projects/{project}/pipelines/{pipeline}/jobs?scope=failed&per_page=20")).await {
                lines = gitlab_failed_jobs(&jobs);
            }
        }
        lines.extend(item["changes"].as_array().cloned().unwrap_or_default());
        if let Ok(r) = get(format!("projects/{project}/pipelines/{pipeline}")).await {
            if let Some(secs) = r.json::<Value>().await.ok().and_then(|p| p["duration"].as_i64()) {
                lines.push(json!({ "text": crate::i18n::tf("Took {duration}", &[("duration", &gitlab_took(secs))]), "by": "" }));
            }
        }
        item["changes"] = json!(lines);
    }

    // News for the card: the fresh items first, then the earlier ones — read
    // back from disk after a restart, unless they were another account's.
    let kept = {
        let mut memory = GITLAB.lock().unwrap();
        let owner = format!("{username}@{base}");
        if memory.news_owner.as_deref() != Some(owner.as_str()) {
            memory.news = load_news("gitlab", &owner);
            memory.news_owner = Some(owner.clone());
        }
        let kept = recent_news(&fresh, &memory.news);
        if !fresh.is_empty() {
            save_news("gitlab", &owner, &kept);
        }
        memory.news = kept.clone();
        kept
    };

    let event = news_event(&fresh, |n| crate::i18n::tn("{count} GitLab update", "{count} GitLab updates", n, &[]));

    // The pulse, every five minutes, or at once for another account or other
    // followed projects.
    let pulse_key = format!("{username}@{base}|{followed:?}");
    let cached = GITLAB.lock().unwrap().pulse.as_ref()
        .filter(|(at, key, _)| *key == pulse_key && now_ms() as i64 - at < GITLAB_PULSE_EVERY_MS)
        .map(|(_, _, pulse)| pulse.clone());
    let pulse = match cached {
        Some(pulse) => pulse,
        None => {
            let pulse = gitlab_pulse(&http, &base, &token, &user, &followed).await;
            GITLAB.lock().unwrap().pulse = Some((now_ms() as i64, pulse_key, pulse.clone()));
            pulse
        }
    };

    let mut data = json!({
        "username": username,
        "todoCount": todos.len(),
        "todosCapped": todos.len() >= 20,
        "todos": todo_items,
        "mergeRequests": involved,
        "news": kept,
        // This poll's news alone: what the notification card shows.
        "fresh": fresh,
    });
    if let (Some(data), Some(pulse)) = (data.as_object_mut(), pulse.as_object()) {
        data.extend(pulse.clone());
    }
    emit(&app, IntegrationUpdate { id: "integration_gitlab", data, error: None, event });
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
    let raw = secrets::get("youtrack-url").ok_or_else(|| crate::i18n::t("Set the YouTrack URL in Settings → Integrations"))?;
    let base = raw.trim().trim_end_matches('/').to_string();
    if base.starts_with("https://") || base.starts_with("http://") {
        Ok(base)
    } else {
        Err(crate::i18n::t("The YouTrack URL must start with https://"))
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
    /// The latest news, newest first: { label, url, success, at, issue }.
    news: Vec<Value>,
    /// Whose news `news` is (the instance and the search), once read from disk.
    news_owner: Option<String>,
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
            let who = if created > seen { "reporter" } else { "updater" };
            let (login, name) = youtrack_who(issue, who);
            if me.is_empty() || login != me {
                let title = format!("{id} {summary}");
                let vars = [("name", name.as_str()), ("title", title.as_str())];
                let label = match (created > seen, name.is_empty()) {
                    (true, true) => crate::i18n::tf("Created: {title}", &vars),
                    (true, false) => crate::i18n::tf("Created by {name}: {title}", &vars),
                    (false, true) => crate::i18n::tf("Updated: {title}", &vars),
                    (false, false) => crate::i18n::tf("Updated by {name}: {title}", &vars),
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

/// The activity categories read for a piece of news: a field, a comment, the
/// title, the description, an attachment, a link.
const YOUTRACK_CHANGE_CATEGORIES: &str =
    "CustomFieldCategory,CommentsCategory,SummaryCategory,DescriptionCategory,AttachmentsCategory,LinksCategory";
const YOUTRACK_CHANGE_FIELDS: &str = "timestamp,target(idReadable,issue(idReadable)),author(login,fullName),\
    category(id),field(name,customField(fieldType(id))),added(name,fullName,login,text,presentation,idReadable),\
    removed(name,fullName,login,text,presentation,idReadable)";
/// Lines kept per issue: the card has room for a few, and a burst of edits is
/// not worth more.
const YOUTRACK_CHANGES_KEEP: usize = 8;

/// What happened to issues, in words, from YouTrack's activity stream (oldest
/// first): a field's old and new value, a comment's first words, an edit. One
/// list per issue; the user's own changes, and repeats, left out.
fn youtrack_changes(activities: &[Value], me: &str) -> std::collections::HashMap<String, Vec<Value>> {
    let mut out: std::collections::HashMap<String, Vec<Value>> = Default::default();
    for a in activities {
        // A field change targets the issue; a comment or an attachment targets
        // itself, and names its issue.
        let target = a.get("target").cloned().unwrap_or(Value::Null);
        let issue = Some(s(&target, "idReadable"))
            .filter(|i| !i.is_empty())
            .or_else(|| target.get("issue").map(|i| s(i, "idReadable")))
            .unwrap_or_default();
        let (login, name) = youtrack_who(a, "author");
        if issue.is_empty() || (!me.is_empty() && login == me) {
            continue;
        }
        let field = a.get("field").map(|f| s(f, "name")).unwrap_or_default();
        let kind = a["field"]["customField"]["fieldType"].get("id").and_then(Value::as_str).unwrap_or("");
        let period = youtrack_is_period(kind, &field);
        let added = youtrack_value(&a["added"], period);
        let removed = youtrack_value(&a["removed"], period);
        let category = a.get("category").map(|c| s(c, "id")).unwrap_or_default();
        let text = match category.as_str() {
            "CustomFieldCategory" => match (removed.is_empty(), added.is_empty()) {
                (false, false) => format!("{field}: {removed} → {added}"),
                (true, false) => format!("{field}: {added}"),
                (false, true) => crate::i18n::tf("{field}: {old} → none", &[("field", &field), ("old", &removed)]),
                (true, true) => continue,
            },
            "CommentsCategory" => match (removed.is_empty(), added.is_empty()) {
                (true, false) => crate::i18n::tf("Comment: “{text}”", &[("text", &added)]),
                (false, true) => crate::i18n::t("Comment deleted"),
                _ => crate::i18n::t("Comment edited"),
            },
            "SummaryCategory" => crate::i18n::t("Title changed"),
            "DescriptionCategory" => crate::i18n::t("Description edited"),
            "AttachmentsCategory" if !added.is_empty() => crate::i18n::tf("Attached {name}", &[("name", &added)]),
            "AttachmentsCategory" => crate::i18n::tf("Attachment removed: {name}", &[("name", &removed)]),
            "LinksCategory" if !added.is_empty() => crate::i18n::tf("Linked to {issue}", &[("issue", &added)]),
            "LinksCategory" => crate::i18n::tf("Unlinked from {issue}", &[("issue", &removed)]),
            _ => continue,
        };
        let lines = out.entry(issue).or_default();
        if lines.len() < YOUTRACK_CHANGES_KEEP && !lines.iter().any(|l| l["text"] == text.as_str()) {
            lines.push(json!({ "text": text, "by": name }));
        }
    }
    out
}

/// Whether a field holds a duration — spent time, an estimation — which the
/// stream gives as a number of minutes. Its type says so (`period`); where the
/// type isn't given, the usual names do.
fn youtrack_is_period(kind: &str, field: &str) -> bool {
    if !kind.is_empty() {
        return kind == "period";
    }
    let name = field.to_lowercase();
    ["spent time", "estimation", "remaining time", "temps passé", "temps restant", "temps estimé"]
        .iter()
        .any(|n| name == *n)
}

/// A value from the activity stream as one short line: named things (a state,
/// users, versions) joined, a comment's text, a date, a duration, a plain value.
fn youtrack_value(v: &Value, period: bool) -> String {
    let one = |x: &Value| -> String {
        match x {
            Value::String(t) => t.clone(),
            Value::Number(n) => match n.as_i64() {
                Some(minutes) if period => youtrack_duration(minutes),
                // Dates come as milliseconds since the epoch.
                Some(ms) if ms > 100_000_000_000 => youtrack_date(ms),
                _ => n.to_string(),
            },
            Value::Bool(b) => b.to_string(),
            Value::Object(_) => ["name", "fullName", "presentation", "idReadable", "text"]
                .iter()
                .map(|k| s(x, k))
                .find(|t| !t.is_empty())
                .unwrap_or_default(),
            _ => String::new(),
        }
    };
    let text = match v {
        Value::Array(items) => items.iter().map(one).filter(|t| !t.is_empty()).collect::<Vec<_>>().join(", "),
        other => one(other),
    };
    let line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.chars().count() > 80 { format!("{}…", line.chars().take(79).collect::<String>()) } else { line }
}

/// Minutes as hours and minutes: "45 min", "2 h", "1 h 30 min". Not in days: how many
/// hours a day makes is the instance's own setting, which a token can't read.
fn youtrack_duration(minutes: i64) -> String {
    use crate::i18n::tf;
    let (h, m) = ((minutes / 60).to_string(), (minutes % 60).to_string());
    match (minutes / 60, minutes % 60) {
        (0, _) => tf("{minutes} min", &[("minutes", &m)]),
        (_, 0) => tf("{hours} h", &[("hours", &h)]),
        _ => tf("{hours} h {minutes} min", &[("hours", &h), ("minutes", &m)]),
    }
}

/// `ms` since the epoch as YYYY-MM-DD (UTC): YouTrack's date fields are days.
fn youtrack_date(ms: i64) -> String {
    // Howard Hinnant's civil-from-days.
    let z = ms.div_euclid(86_400_000) + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}")
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
        .map_err(|e| (0, crate::i18n::tf("No connection: {error}", &[("error", &e.without_url().to_string())])))?;
    let code = response.status().as_u16();
    if !response.status().is_success() {
        return Err((code, status_error(code, &crate::i18n::t("This token can't read YouTrack (403)"))));
    }
    // A wrong path often lands on an HTML page with a 200.
    response
        .json::<Value>()
        .await
        .map_err(|_| (code, crate::i18n::t("Unexpected answer from YouTrack — check the URL")))
}

/// The first request's error: a 404 there means the URL is not YouTrack's.
fn youtrack_error((code, error): (u16, String)) -> String {
    if code == 404 { crate::i18n::t("Not a YouTrack address (404) — check the URL") } else { error }
}

/// The signed-in user's login, which also proves the URL and the token.
async fn youtrack_me(http: &reqwest::Client, base: &str, token: &str) -> Result<String, String> {
    let me = youtrack_get(http, base, token, "users/me", &[("fields", "login")]).await.map_err(youtrack_error)?;
    Some(s(&me, "login"))
        .filter(|l| !l.is_empty())
        .ok_or_else(|| crate::i18n::t("Unexpected answer from YouTrack — check the URL"))
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
        return fail(crate::i18n::t("Choose a saved search in Settings → Integrations"));
    };
    let http = client();
    let me = match youtrack_me(&http, &base, &token).await {
        Ok(me) => me,
        Err(e) => return fail(e),
    };

    let saved = match youtrack_get(&http, &base, &token, &format!("savedQueries/{query_id}"), &[("fields", "name,query")]).await {
        Ok(v) => v,
        Err((404, _)) => return fail(crate::i18n::t("The saved search is gone — choose another in Settings")),
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
        Err((400, _)) => return fail(crate::i18n::t("YouTrack can't run this saved search (400)")),
        Err((_, e)) => return fail(e),
    };

    // In a block of its own: the lock must be gone before the request below.
    let (since, mut fresh, items) = {
        let mut memory = YOUTRACK.lock().unwrap();
        // Where the last poll left off, for the activity below.
        let since = memory.seen_until.filter(|_| memory.query_id == query_id);
        let (fresh, items) = youtrack_fresh(&mut memory, &query_id, &issues, &me, &base);
        (since, fresh, items)
    };

    // What changed on the issues in the news, read only when there is some: one
    // request over the same search, from where the last poll left off. Without
    // it the news still goes out, just without the detail.
    if let (Some(since), false) = (since, fresh.is_empty()) {
        let start = (since + 1).to_string();
        let issue_query = youtrack_unsorted(&query);
        let mut params = vec![
            ("categories", YOUTRACK_CHANGE_CATEGORIES),
            ("start", start.as_str()),
            ("fields", YOUTRACK_CHANGE_FIELDS),
            ("$top", "200"),
        ];
        if !issue_query.is_empty() {
            params.push(("issueQuery", issue_query));
        }
        if let Ok(activities) = youtrack_get(&http, &base, &token, "activities", &params).await {
            let changes = youtrack_changes(activities.as_array().map(Vec::as_slice).unwrap_or_default(), &me);
            for news in &mut fresh {
                if let Some(lines) = news["issue"].as_str().and_then(|id| changes.get(id)) {
                    news["changes"] = json!(lines);
                }
            }
        }
    }

    // The earlier news, read back from disk after a restart, unless it came
    // from another search.
    let kept = {
        let mut memory = YOUTRACK.lock().unwrap();
        let owner = format!("{query_id}@{base}");
        if memory.news_owner.as_deref() != Some(owner.as_str()) {
            memory.news = load_news("youtrack", &owner);
            memory.news_owner = Some(owner.clone());
        }
        let kept = recent_news(&fresh, &memory.news);
        if !fresh.is_empty() {
            save_news("youtrack", &owner, &kept);
        }
        memory.news = kept.clone();
        kept
    };

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
        event: news_event(&fresh, |n| crate::i18n::tn("{count} YouTrack update", "{count} YouTrack updates", n, &[])),
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
    let token = secrets::get("youtrack-token").ok_or_else(|| crate::i18n::t("Save the token first"))?;
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
        format!("{base}/api/v1/executions?limit=10&includeData=false"),
        format!("{base}/rest/executions?limit=10&includeData=false"),
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

    let Some(first) = items.as_deref().and_then(find_terminal_execution) else { return };
    let Some(id) = parse_execution_id(first) else { return };

    let status = first.get("status").and_then(Value::as_str).unwrap_or("");
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
    let mut name = crate::i18n::t("Workflow");
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
            .map(str::to_string)
            .unwrap_or_else(|| crate::i18n::t("Workflow"));
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

pub(crate) fn find_terminal_execution(list: &[Value]) -> Option<&Value> {
    const TERMINAL: [&str; 5] = ["success", "error", "crashed", "canceled", "failed"];
    list.iter().find(|item| {
        item.get("status")
            .and_then(Value::as_str)
            .map(|s| TERMINAL.contains(&s))
            .unwrap_or(false)
    })
}

pub(crate) fn parse_execution_id(item: &Value) -> Option<String> {
    match item.get("id") {
        Some(Value::String(s)) => Some(s.clone()),
        Some(Value::Number(n)) => Some(n.to_string()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gitea_calendar_keeps_full_weeks_and_yearly_totals() {
        let today = 20_000_i64;
        let activity = gitea_activity(&[
            json!({ "timestamp": (today - 300) * 86_400, "contributions": 5 }),
            json!({ "timestamp": today * 86_400_000, "contributions": 2 }),
        ], today as u64 * 86_400_000);
        assert_eq!(activity.total, 7);
        assert!(activity.weeks.iter().flatten().count() >= 365);
        for week in &activity.weeks {
            assert_eq!(week[0].weekday, 0);
            for (index, day) in week.iter().enumerate() {
                assert_eq!(day.weekday as usize, index);
            }
        }
        let last = activity.weeks.last().unwrap().last().unwrap();
        assert_eq!(last.count, 2);
    }




    #[test]
    fn gitlab_activity_builds_a_full_calendar_and_counts_events() {
        let events = vec![
            json!({ "created_at": "1970-01-01T12:00:00Z" }),
            json!({ "created_at": "1970-01-01T18:00:00Z" }),
        ];
        let activity = gitlab_activity(&events, 0);
        let days: Vec<_> = activity.weeks.iter().flatten().collect();
        assert!(days.len() >= 365);
        let first_day = days.iter().find(|day| day.date == "1970-01-01").unwrap();
        assert_eq!((first_day.count, first_day.level, first_day.weekday), (2, 2, 4));
        assert_eq!(activity.total, 2);
    }

    #[test]
    fn gitlab_ci_maps_pipeline_states() {
        assert_eq!(gitlab_ci(Some("success")), CiState::Success);
        assert_eq!(gitlab_ci(Some("running")), CiState::Pending);
        assert_eq!(gitlab_ci(Some("failed")), CiState::Failure);
        assert_eq!(gitlab_ci(None), CiState::Unknown);
    }

    #[test]
    fn github_card_data_sends_only_what_is_known() {
        let mut cache = GitHubCache::default();
        assert_eq!(github_card_data(&cache), json!({}));
        cache.stats = Some((12, 3400));
        assert_eq!(github_card_data(&cache), json!({ "totalRepos": 12, "totalStars": 3400 }));
        cache.activity = Some(GitHubActivity { total: 5, weeks: vec![], fetched_at: 9 });
        let data = github_card_data(&cache);
        assert_eq!(data["totalRepos"], json!(12));
        assert_eq!(data["activity"], json!({ "total": 5, "weeks": [], "fetchedAt": 9 }));
        assert!(data.get("pulse").is_none());
    }

    #[test]
    fn stripe_balance_does_not_mix_different_currencies() {
        let payload = json!({
            "available": [
                { "amount": 10000, "currency": "eur" },
                { "amount": 5000, "currency": "usd" }
            ],
            "pending": [
                { "amount": 2000, "currency": "eur" },
                { "amount": 3000, "currency": "usd" }
            ]
        });
        let (amount, currency) = parse_stripe_balance(&payload);
        assert_eq!(currency, "eur");
        assert_eq!(amount, 12000);
    }

    #[test]
    fn calculate_repo_pages_bounds_correctly() {
        assert_eq!(calculate_repo_pages(0), 1);
        assert_eq!(calculate_repo_pages(1), 1);
        assert_eq!(calculate_repo_pages(100), 1);
        assert_eq!(calculate_repo_pages(101), 2);
        assert_eq!(calculate_repo_pages(200), 2);
        assert_eq!(calculate_repo_pages(500), 5);
        assert_eq!(calculate_repo_pages(5000), 50);
        assert_eq!(calculate_repo_pages(9999), 50);
    }

    #[test]
    fn sum_repo_stars_sums_stargazers_count() {
        let repos = vec![
            json!({ "name": "repo1", "stargazers_count": 42 }),
            json!({ "name": "repo2", "stargazers_count": 10 }),
            json!({ "name": "repo3" }),
            json!({ "name": "repo4", "stargazers_count": 0 }),
        ];
        assert_eq!(sum_repo_stars(&repos), 52);
    }

    #[test]
    fn find_terminal_execution_skips_running_and_finds_terminal() {
        let list = vec![
            json!({ "id": "1", "status": "running" }),
            json!({ "id": "2", "status": "waiting" }),
            json!({ "id": "3", "status": "error" }),
            json!({ "id": "4", "status": "success" }),
        ];
        let term = find_terminal_execution(&list).unwrap();
        assert_eq!(term["id"], "3");
    }

    #[test]
    fn parse_execution_id_handles_string_and_number() {
        assert_eq!(parse_execution_id(&json!({ "id": "abc-123" })), Some("abc-123".to_string()));
        assert_eq!(parse_execution_id(&json!({ "id": 42 })), Some("42".to_string()));
        assert_eq!(parse_execution_id(&json!({ "foo": "bar" })), None);
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

    fn texts(item: &Value) -> Vec<String> {
        item["changes"].as_array().unwrap().iter().map(|c| c["text"].as_str().unwrap().to_string()).collect()
    }

    #[test]
    fn notes_read_as_what_was_done() {
        let note = |body: &str, system: bool| json!({ "body": body, "system": system });
        let text = |n: Value| gitlab_note_text(&n).unwrap();
        assert_eq!(text(note("Looks **good**, see [the doc](https://x/y).\n\nThanks!", false)),
            "Comment: “Looks good, see the doc. Thanks!”");
        assert_eq!(text(note("approved this merge request", true)), "approved this merge request");
        assert_eq!(text(note("changed title from **Fix login** to **Fix the login loop**", true)),
            "changed title from Fix login to Fix the login loop");
        let commits = "added 2 commits\n\n<ul><li>3f2a1b9c - Fix the redirect</li><li>9c8b7a6d - Update the tests</li></ul>\n\n[Compare with previous version](/g/p/-/merge_requests/3/diffs?diff_id=1)";
        assert_eq!(text(note(commits, true)), "added 2 commits: Fix the redirect, Update the tests");
        assert!(gitlab_note_text(&note("  ", false)).is_none());
    }

    #[test]
    fn an_updated_mr_lists_what_others_did_oldest_first() {
        let mut m = GitlabMemory::default();
        let none = std::collections::HashMap::new();
        let at = |t: &str| format!("2026-10-07T{t}:00Z");
        let note = |by: &str, at: &str, body: &str, system: bool| {
            json!({ "author": { "username": by, "name": by.to_uppercase() }, "created_at": at, "body": body, "system": system })
        };
        let first = gitlab_involved(&[], &[], &[open_mr(1, "Login", &at("10:00"))]);
        gitlab_fresh(&mut m, &None, &[], &None, &None, &none, &Some(first), &Default::default(), "me");
        let later = gitlab_involved(&[], &[], &[open_mr(1, "Login", &at("10:05"))]);
        let activity = [(1, vec![
            note("bob", &at("10:05"), "Ship it", false),
            note("me", &at("10:04"), "Done", false),
            note("ada", &at("10:03"), "approved this merge request", true),
            note("ada", &at("10:02"), "approved this merge request", true),
        ])].into();
        let (fresh, _) = gitlab_fresh(&mut m, &None, &[], &None, &None, &none, &Some(later), &activity, "me");
        assert_eq!(texts(&fresh[0]), vec!["approved this merge request", "Comment: “Ship it”"],
            "oldest first, told once, the user's own comment left out");
        assert_eq!(fresh[0]["changes"][1]["by"], "BOB");
    }

    #[test]
    fn a_mention_carries_what_was_written() {
        let mut m = GitlabMemory::default();
        let none = Default::default();
        let with_body = |id: i64, action: &str, body: &str| {
            let mut t = todo(id, action, "web");
            t["body"] = json!(body);
            t["author"] = json!({ "name": "Ada" });
            t
        };
        without_involved(&mut m, &None, &[], &Some(vec![]), &None, &none);
        let (fresh, _) = without_involved(&mut m, &None, &[], &Some(vec![
            with_body(1, "mentioned", "@me could you look at the **cache** part?"),
            with_body(2, "assigned", "MR 2"),
        ]), &None, &none);
        assert_eq!(texts(&fresh[0]), vec!["“@me could you look at the cache part?”", "web · from Ada"]);
        assert_eq!(texts(&fresh[1]), vec!["web · from Ada"], "an assignment's body is the title again");
    }

    #[test]
    fn a_pipeline_is_told_once_it_finishes_whenever_it_started() {
        let mut m = GitlabMemory::default();
        let none = Default::default();
        let projects = Some(vec![]);
        let pipe = |id: i64, status: &str| json!({ "id": id, "projectId": 4, "status": status, "project": "api",
            "ref": "main", "sha": "3f2a1b9c0d", "source": "push", "url": "p" });
        let run = |m: &mut GitlabMemory, pipes: Vec<Value>| without_involved(m, &projects, &pipes, &None, &None, &none).0;

        assert!(run(&mut m, vec![pipe(1, "success"), pipe(2, "running")]).is_empty(), "launch only remembers");
        // 2 finishes after 3, which started later and was never seen running.
        let fresh = run(&mut m, vec![pipe(1, "success"), pipe(2, "running"), pipe(3, "failed")]);
        assert_eq!(labels(&fresh), vec!["Pipeline failed: api · main"]);
        assert_eq!(texts(&fresh[0]), vec!["Push on main · 3f2a1b9c"]);
        assert_eq!(fresh[0]["pipeline"]["id"], 3);
        let fresh = run(&mut m, vec![pipe(2, "success"), pipe(3, "failed")]);
        assert_eq!(labels(&fresh), vec!["Pipeline passed: api · main"], "told once each");
        // 3 retried, and passing this time.
        assert!(run(&mut m, vec![pipe(3, "running")]).is_empty());
        assert_eq!(labels(&run(&mut m, vec![pipe(3, "success")])), vec!["Pipeline passed: api · main"]);
        assert!(run(&mut m, vec![pipe(4, "canceled")]).is_empty(), "canceled is no news");
    }

    #[test]
    fn projects_are_grouped_and_sorted_for_settings() {
        let p = |id: i64, name: &str, full: &str| json!({ "id": id, "name": name, "name_with_namespace": full, "namespace": { "name": "me" } });
        let list = gitlab_project_list(&[
            p(1, "web", "Team / Front / web"),
            p(2, "api", "Team / Backend / api"),
            p(3, "notes", "notes"),
            p(4, "Admin", "Team / Backend / Admin"),
        ]);
        let shown: Vec<(&str, &str)> = list.iter().map(|x| (x.group.as_str(), x.name.as_str())).collect();
        assert_eq!(shown, vec![("me", "notes"), ("Team / Backend", "Admin"), ("Team / Backend", "api"), ("Team / Front", "web")]);
    }

    #[test]
    fn only_the_followed_projects_merge_requests_are_kept() {
        let mr = |id: i64, project: i64| json!({ "id": id, "project_id": project });
        let all = Some(vec![mr(1, 7), mr(2, 8), mr(3, 7)]);
        let ids = |a: Option<Vec<Value>>| a.unwrap().iter().map(|m| m["id"].as_i64().unwrap()).collect::<Vec<_>>();
        assert_eq!(ids(gitlab_keep_followed(all.clone(), &[])), vec![1, 2, 3], "none followed: every project");
        assert_eq!(ids(gitlab_keep_followed(all, &[7])), vec![1, 3]);
        assert!(gitlab_keep_followed(None, &[7]).is_none(), "a failed source stays failed");
    }

    #[test]
    fn pipeline_words() {
        assert_eq!(gitlab_project_of("https://gl/team/sub/api/-/pipelines/12"), "api");
        assert_eq!(gitlab_pipeline_source("merge_request_event"), "Merge request");
        assert_eq!(gitlab_took(42), "42 s");
        assert_eq!(gitlab_took(252), "4 min 12 s");
        assert_eq!(gitlab_took(3_780), "1 h 3 min");
        assert_eq!(iso_utc(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso_utc(951_868_800_000), "2000-03-01T00:00:00Z");
        assert_eq!(iso_utc(1_791_383_045_000), "2026-10-07T14:24:05Z");
    }

    #[test]
    fn a_failed_pipeline_names_its_failed_jobs() {
        let jobs = vec![
            json!({ "name": "unit", "stage": "test", "status": "failed" }),
            json!({ "name": "lint", "stage": "lint", "status": "failed" }),
        ];
        let lines: Vec<String> = gitlab_failed_jobs(&jobs).iter().map(|l| l["text"].as_str().unwrap().to_string()).collect();
        assert_eq!(lines, vec!["test: unit failed", "lint failed"]);
        let long = format!("<p>{}</p>", "word ".repeat(30));
        assert_eq!(gitlab_plain(&long).chars().count(), 80);
    }

    #[test]
    fn news_keeps_the_ten_latest_however_old() {
        let piece = |i: i64| json!({ "label": format!("n{i}"), "at": i });
        let before: Vec<Value> = (0..9).rev().map(piece).collect();
        let kept = recent_news(&[piece(10), piece(9)], &before);
        assert_eq!(kept.len(), NEWS_KEEP);
        assert_eq!(kept[0]["label"], "n10", "this poll's news first");
        assert_eq!(kept[9]["label"], "n1", "the oldest pushed out, not timed out");
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

    fn activity(category: &str, target: Value, by: &str, field: &str, added: Value, removed: Value) -> Value {
        json!({ "category": { "id": category }, "target": target, "field": { "name": field },
                "author": { "login": by, "fullName": by.to_uppercase() }, "added": added, "removed": removed })
    }

    #[test]
    fn the_activity_stream_reads_as_lines_per_issue() {
        let issue = |id: &str| json!({ "idReadable": id });
        let on = |id: &str| json!({ "issue": { "idReadable": id } });
        let stream = vec![
            activity("CustomFieldCategory", issue("P-1"), "ada", "State",
                json!([{ "name": "Fixed" }]), json!([{ "name": "In Progress" }])),
            activity("CustomFieldCategory", issue("P-1"), "ada", "Assignee",
                json!([{ "login": "cy", "fullName": "Cy Young", "name": "Cy Young" }]), json!([])),
            activity("CommentsCategory", on("P-1"), "bob", "comments",
                json!([{ "text": "Looks good,\n  shipping   it" }]), json!([])),
            activity("DescriptionCategory", issue("P-1"), "ada", "description", json!("new"), json!("old")),
            activity("DescriptionCategory", issue("P-1"), "ada", "description", json!("newer"), json!("new")),
            activity("CustomFieldCategory", issue("P-1"), "me", "Priority",
                json!([{ "name": "Major" }]), json!([{ "name": "Normal" }])),
            activity("AttachmentsCategory", on("P-2"), "bob", "attachments", json!([{ "name": "log.txt" }]), json!([])),
            activity("CustomFieldCategory", issue("P-2"), "bob", "Due Date", json!(1791331200000_i64), Value::Null),
        ];
        let changes = youtrack_changes(&stream, "me");
        let texts = |id: &str| changes[id].iter().map(|l| l["text"].as_str().unwrap().to_string()).collect::<Vec<_>>();
        assert_eq!(texts("P-1"), vec![
            "State: In Progress → Fixed",
            "Assignee: Cy Young",
            "Comment: “Looks good, shipping it”",
            "Description edited",
        ], "the user's own change left out, the repeated edit told once");
        assert_eq!(changes["P-1"][2]["by"], "BOB");
        assert_eq!(texts("P-2"), vec!["Attached log.txt", "Due Date: 2026-10-07"]);
    }

    #[test]
    fn a_long_value_is_cut_to_one_line() {
        let long = "word ".repeat(40);
        let line = youtrack_value(&json!(long), false);
        assert_eq!(line.chars().count(), 80);
        assert!(line.ends_with('…'));
        assert_eq!(youtrack_date(0), "1970-01-01");
    }

    #[test]
    fn spent_time_reads_as_hours_and_minutes() {
        let typed = |id: &str| json!({ "name": "Spent time", "customField": { "fieldType": { "id": id } } });
        let mut change = activity("CustomFieldCategory", json!({ "idReadable": "P-1" }), "ada", "",
            json!(90), json!(45));
        change["field"] = typed("period");
        let mut estimate = activity("CustomFieldCategory", json!({ "idReadable": "P-1" }), "ada", "Estimation",
            json!(480), Value::Null);
        estimate["field"] = json!({ "name": "Estimation" }); // no type given: the name says it
        let mut points = activity("CustomFieldCategory", json!({ "idReadable": "P-1" }), "ada", "",
            json!(5), json!(3));
        points["field"] = json!({ "name": "Story points", "customField": { "fieldType": { "id": "integer" } } });
        let changes = youtrack_changes(&[change, estimate, points], "me");
        let texts: Vec<&str> = changes["P-1"].iter().map(|l| l["text"].as_str().unwrap()).collect();
        assert_eq!(texts, vec!["Spent time: 45 min → 1 h 30 min", "Estimation: 8 h", "Story points: 3 → 5"]);
        assert_eq!(youtrack_duration(120), "2 h");
    }
}
