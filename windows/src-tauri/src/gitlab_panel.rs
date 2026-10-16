// The GitLab panel: a small window next to the island with the user's merge
// requests across every project (to review, mine, approved) and the discussion
// threads waiting for an answer, which can be answered from there.
//
// This file is the window (created hidden at launch, as create_settings_window
// explains; moved by the user, snapped to the screen's edges, remembered), the
// loop that reads GitLab (5 min, 60 s while the panel is open) and the commands
// the panel calls. What the data means is in gitlab_dash.rs.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tauri::{AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, WebviewUrl, WebviewWindow, WebviewWindowBuilder};
use tokio::sync::Notify;

use crate::gitlab;
use crate::gitlab_dash::{self, Dashboard, MrEntry, Roles, SnippetLine};
use crate::integrations::{self, GITLAB_ID};
use crate::island::WINDOW_LABEL as ISLAND_LABEL;
use crate::{log, secrets, settings};

pub const LABEL: &str = "gitlab-panel";

const WIDTH: f64 = 340.0;
const START_HEIGHT: f64 = 260.0;
const MIN_HEIGHT: f64 = 160.0;
/// The panel snaps to an edge of the screen from this close (physical pixels).
const SNAP: i32 = 16;
/// Merge requests read at a time.
const PERIMETER: usize = 30;
const EVENT_CANDIDATES: usize = 15;

struct Panel {
    /// (project id, iid) → the update time it was read at, and what was read.
    cache: Mutex<HashMap<(i64, i64), (String, MrEntry)>>,
    dashboard: Mutex<Option<Dashboard>>,
    wake: Notify,
    busy: AtomicBool,
    open: AtomicBool,
    /// Bumped when the token or the instance changes: an answer for the old one is dropped.
    generation: AtomicU64,
    /// When the window was last moved, to save its place once it stops.
    moved_at: Mutex<Option<std::time::Instant>>,
    /// Threads the user opened again himself: coming back is no news to alert on.
    reopened: Mutex<std::collections::HashSet<String>>,
}

static PANEL: LazyLock<Panel> = LazyLock::new(|| Panel {
    cache: Mutex::new(HashMap::new()),
    dashboard: Mutex::new(None),
    wake: Notify::new(),
    busy: AtomicBool::new(false),
    open: AtomicBool::new(false),
    generation: AtomicU64::new(0),
    moved_at: Mutex::new(None),
    reopened: Mutex::new(Default::default()),
});

// ── Window ────────────────────────────────────────────────────────────────────

fn page_url(app: &AppHandle) -> WebviewUrl {
    #[cfg(dev)]
    if let Some(mut base) = app.config().build.dev_url.clone() {
        base.set_path("/gitlab-panel.html");
        return WebviewUrl::External(base);
    }
    let _ = app;
    WebviewUrl::App("gitlab-panel.html".into())
}

fn window(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window(LABEL)
}

#[derive(Serialize, Deserialize, Clone, Copy)]
struct Place {
    x: i32,
    y: i32,
}

fn place_path() -> std::path::PathBuf {
    settings::config_dir().join("gitlab-panel.json")
}

fn load_place() -> Option<Place> {
    serde_json::from_slice(&std::fs::read(place_path()).ok()?).ok()
}

fn save_place(place: Place) {
    let dir = settings::config_dir();
    if crate::platform::ensure_private_dir(&dir).is_err() {
        return;
    }
    if let Ok(json) = serde_json::to_vec(&place) {
        let _ = std::fs::write(place_path(), json);
    }
}

/// Creates the panel's window, hidden. Before the island, for WebView2's sake
/// (see create_settings_window in lib.rs).
pub fn setup(app: &AppHandle) {
    let built = WebviewWindowBuilder::new(app, LABEL, page_url(app))
        .additional_browser_args(crate::BROWSER_ARGS)
        .title("Coucou — GitLab")
        .inner_size(WIDTH, START_HEIGHT)
        // GTK won't size a non-resizable window below its natural size (see
        // island::apply_geometry); the panel is resized by the page's content.
        .resizable(cfg!(target_os = "linux"))
        .decorations(false)
        .shadow(true)
        .always_on_top(true)
        .skip_taskbar(true)
        .maximizable(false)
        .minimizable(false)
        .visible(false)
        .build();
    match built {
        Ok(win) => {
            let handle = app.clone();
            let this = win.clone();
            win.on_window_event(move |event| match event {
                // Closing it must only hide it, or it could never be reopened.
                tauri::WindowEvent::CloseRequested { api, .. } => {
                    api.prevent_close();
                    close(&handle);
                }
                tauri::WindowEvent::Moved(_) => moved(&this),
                _ => {}
            });
        }
        Err(err) => log::line(format!("gitlab panel window failed: {err}")),
    }
}

/// Snaps the window to the screen's edges when it is let go near one, and
/// remembers where it ended once it stops moving.
fn moved(win: &WebviewWindow) {
    if !PANEL.open.load(Ordering::Relaxed) {
        return;
    }
    let (Ok(pos), Ok(size), Ok(Some(monitor))) = (win.outer_position(), win.outer_size(), win.current_monitor()) else {
        return;
    };
    let area = monitor.work_area();
    let (left, top) = (area.position.x, area.position.y);
    let (right, bottom) = (left + area.size.width as i32, top + area.size.height as i32);
    let snap = |value: i32, near: i32| if (value - near).abs() <= SNAP { near } else { value };
    let x = snap(snap(pos.x, left), right - size.width as i32);
    let y = snap(snap(pos.y, top), bottom - size.height as i32);
    if (x, y) != (pos.x, pos.y) {
        let _ = win.set_position(PhysicalPosition::new(x, y));
        return;
    }
    let now = std::time::Instant::now();
    *PANEL.moved_at.lock().unwrap() = Some(now);
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_millis(500)).await;
        if *PANEL.moved_at.lock().unwrap() == Some(now) {
            save_place(Place { x, y });
        }
    });
}

/// Puts the window where it was left, or at the top right of the screen the
/// first time (and whenever the remembered place is no longer on a screen).
fn place(app: &AppHandle, win: &WebviewWindow) {
    let monitors = app.available_monitors().unwrap_or_default();
    if let Some(saved) = load_place() {
        let on_screen = monitors.iter().any(|m| {
            let a = m.work_area();
            saved.x >= a.position.x
                && saved.y >= a.position.y
                && saved.x < a.position.x + a.size.width as i32 - 40
                && saved.y < a.position.y + a.size.height as i32 - 40
        });
        if on_screen {
            let _ = win.set_position(PhysicalPosition::new(saved.x, saved.y));
            return;
        }
    }
    if let Ok(Some(monitor)) = app.primary_monitor() {
        let a = monitor.work_area();
        let scale = monitor.scale_factor();
        let x = a.position.x + a.size.width as i32 - (WIDTH * scale) as i32 - (16.0 * scale) as i32;
        let y = a.position.y + (80.0 * scale) as i32;
        let _ = win.set_position(PhysicalPosition::new(x, y));
    }
}

fn set_open(app: &AppHandle, open: bool) {
    PANEL.open.store(open, Ordering::Relaxed);
    let _ = app.emit_to(ISLAND_LABEL, "gitlab-panel-open", open);
    let _ = app.emit_to(LABEL, "gitlab-panel-open", open);
}

pub fn close(app: &AppHandle) {
    if let Some(win) = window(app) {
        let _ = win.hide();
    }
    set_open(app, false);
}

fn open(app: &AppHandle) {
    let Some(win) = window(app) else {
        log::line("gitlab panel window missing");
        return;
    };
    place(app, &win);
    let _ = win.show();
    let _ = win.set_focus();
    set_open(app, true);
    PANEL.wake.notify_one();
}

/// The "⤢" button of the GitLab card.
#[tauri::command]
pub fn gitlab_panel_toggle(app: AppHandle) {
    if PANEL.open.load(Ordering::Relaxed) {
        close(&app);
    } else if integrations::enabled(&app, GITLAB_ID) && secrets::get("gitlab-token").is_some() {
        open(&app);
    }
}

#[tauri::command]
pub fn gitlab_panel_close(app: AppHandle) {
    close(&app);
}

#[tauri::command]
pub fn gitlab_panel_is_open() -> bool {
    PANEL.open.load(Ordering::Relaxed)
}

/// The page tells how tall its content is; the window follows, within the screen.
#[tauri::command]
pub fn gitlab_panel_resize(app: AppHandle, height: f64) {
    let Some(win) = window(&app) else { return };
    if !height.is_finite() {
        return;
    }
    let mut max = 900.0;
    if let (Ok(pos), Ok(Some(monitor))) = (win.outer_position(), win.current_monitor()) {
        let a = monitor.work_area();
        let scale = monitor.scale_factor();
        let room = f64::from(a.position.y + a.size.height as i32 - pos.y) / scale - 8.0;
        max = room.max(MIN_HEIGHT);
    }
    let _ = win.set_size(LogicalSize::new(WIDTH, height.clamp(MIN_HEIGHT, max)));
}

/// Dragging the header moves the window.
#[tauri::command]
pub fn gitlab_panel_drag(window: WebviewWindow) {
    let _ = window.start_dragging();
}

/// What the panel shows when it opens, before the next poll.
#[tauri::command]
pub fn gitlab_dashboard() -> Option<Dashboard> {
    PANEL.dashboard.lock().unwrap().clone()
}

// ── Credentials and settings ──────────────────────────────────────────────────

/// The token or the instance changed: forget what the old one read.
pub fn credentials_changed(app: &AppHandle) {
    PANEL.generation.fetch_add(1, Ordering::SeqCst);
    PANEL.cache.lock().unwrap().clear();
    *PANEL.dashboard.lock().unwrap() = None;
    emit_dashboard(app, None);
    if secrets::get("gitlab-token").is_none() {
        close(app);
    } else {
        PANEL.wake.notify_one();
    }
}

/// The GitLab pill was switched off: the panel goes with it.
pub fn pill_off(app: &AppHandle) {
    if PANEL.dashboard.lock().unwrap().take().is_some() {
        emit_dashboard(app, None);
    }
    PANEL.cache.lock().unwrap().clear();
    close(app);
}

fn emit_dashboard(app: &AppHandle, dashboard: Option<&Dashboard>) {
    let _ = app.emit_to(LABEL, "gitlab-dashboard", dashboard);
}

// ── Reading GitLab ────────────────────────────────────────────────────────────

pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut wait = Duration::from_secs(12);
        loop {
            // Sleeps for `wait`, or less when the panel opens or something was sent.
            let _ = tokio::time::timeout(wait, PANEL.wake.notified()).await;
            run(&app).await;
            wait = Duration::from_secs(if PANEL.open.load(Ordering::Relaxed) { 60 } else { 300 });
        }
    });
}

async fn run(app: &AppHandle) {
    if integrations::PAUSED.load(Ordering::Relaxed) || !integrations::enabled(app, GITLAB_ID) {
        return;
    }
    let (Some(token), Some(base)) = (secrets::get("gitlab-token"), integrations::gitlab_base()) else { return };
    if PANEL.busy.swap(true, Ordering::SeqCst) {
        return;
    }
    let generation = PANEL.generation.load(Ordering::SeqCst);
    let fresh = fetch(&base, &token).await;
    PANEL.busy.store(false, Ordering::SeqCst);
    let Some(fresh) = fresh else { return };

    let events = {
        let mut current = PANEL.dashboard.lock().unwrap();
        // The token or the instance changed while this was in flight.
        if PANEL.generation.load(Ordering::SeqCst) != generation {
            return;
        }
        let events = Dashboard::events(current.as_ref(), &fresh);
        *current = Some(fresh.clone());
        events
    };
    emit_dashboard(app, Some(&fresh));
    let events: Vec<_> = {
        let mut reopened = PANEL.reopened.lock().unwrap();
        events
            .into_iter()
            .filter(|e| match e {
                crate::github::GitHubEvent::CommentPending { thread_id } => !reopened.remove(thread_id),
                _ => true,
            })
            .collect()
    };
    if !events.is_empty() {
        let _ = app.emit_to(ISLAND_LABEL, "gitlab-alerts", &events);
    }
}

/// A list GitLab returned, and the role it gives its merge requests.
type RoleList = (Result<Value, u16>, fn(&mut Roles));

fn mr_key(item: &Value) -> Option<(i64, i64)> {
    Some((item.get("project_id")?.as_i64()?, item.get("iid")?.as_i64()?))
}

/// One merge request, read whole: its detail (the pipeline), its approvals when
/// they matter, and its discussions.
async fn read_entry(
    http: reqwest::Client,
    base: String,
    token: String,
    key: (i64, i64),
    with_approvals: bool,
    me: String,
) -> Option<(String, MrEntry)> {
    let (pid, iid) = key;
    let path = format!("projects/{pid}/merge_requests/{iid}");
    let detail = integrations::gitlab_get(&http, &base, &token, &path, &[]).await.ok()?;
    let approvals = if with_approvals {
        integrations::gitlab_get(&http, &base, &token, &format!("{path}/approvals"), &[]).await.ok()
    } else {
        None
    };
    // Oldest first: the newest threads are on the last page.
    let mut discussions: Vec<Value> = Vec::new();
    for page in 1..=3 {
        let page_s = page.to_string();
        let q = [("per_page", "100"), ("page", page_s.as_str())];
        let Ok(Value::Array(batch)) =
            integrations::gitlab_get(&http, &base, &token, &format!("{path}/discussions"), &q).await
        else {
            break;
        };
        let full = batch.len() >= 100;
        discussions.extend(batch);
        if !full {
            break;
        }
    }
    let updated = detail.get("updated_at").and_then(Value::as_str)?.to_string();
    let entry = gitlab_dash::build_entry(&detail, approvals.as_ref(), Some(&discussions), &me)?;
    Some((updated, entry))
}

async fn fetch(base: &str, token: &str) -> Option<Dashboard> {
    let http = integrations::client();
    let user = integrations::gitlab_get(&http, base, token, "user", &[]).await.ok()?;
    let me = user.get("username").and_then(Value::as_str)?.to_string();
    let now = integrations::now_ms();
    let approved_after = gitlab::date_days_ago(now, 60);
    let commented_after = gitlab::date_days_ago(now, 14);

    let base_q = [("state", "opened"), ("order_by", "updated_at"), ("per_page", "30")];
    let mine_q = [base_q[0], base_q[1], base_q[2], ("scope", "created_by_me")];
    let reviewer_q = [base_q[0], base_q[1], base_q[2], ("scope", "all"), ("reviewer_username", me.as_str())];
    let assigned_q = [base_q[0], base_q[1], base_q[2], ("scope", "assigned_to_me")];
    let approved_q = [("action", "approved"), ("after", approved_after.as_str()), ("per_page", "100")];
    let commented_q = [("action", "commented"), ("after", commented_after.as_str()), ("per_page", "100")];
    let (mine, reviewer, assigned, approved_ev, commented_ev, scopes) = tokio::join!(
        integrations::gitlab_get(&http, base, token, "merge_requests", &mine_q),
        integrations::gitlab_get(&http, base, token, "merge_requests", &reviewer_q),
        integrations::gitlab_get(&http, base, token, "merge_requests", &assigned_q),
        integrations::gitlab_get(&http, base, token, "events", &approved_q),
        integrations::gitlab_get(&http, base, token, "events", &commented_q),
        integrations::gitlab_get(&http, base, token, "personal_access_tokens/self", &[]),
    );
    // Without my own merge requests there is nothing to build on.
    let mine = mine.ok()?;
    let can_write = scopes
        .ok()
        .and_then(|s| s.get("scopes").and_then(Value::as_array).cloned())
        .map(|list| list.iter().any(|s| s.as_str() == Some("api")));

    // The perimeter: merge requests from the lists (newest first), then those
    // my events point at.
    let mut roles: HashMap<(i64, i64), Roles> = HashMap::new();
    let mut updated: HashMap<(i64, i64), String> = HashMap::new();
    let mut listed: Vec<(String, (i64, i64))> = Vec::new();
    let mut authors: HashMap<(i64, i64), String> = HashMap::new();
    let lists: [RoleList; 3] = [
        (Ok(mine), |_| {}),
        (reviewer, |r| r.reviewer = true),
        (assigned, |r| r.assigned = true),
    ];
    for (list, role) in lists {
        for item in list.ok().as_ref().and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]) {
            let Some(key) = mr_key(item) else { continue };
            gitlab_dash::merge_roles(&mut roles, key, role);
            if let Some(at) = item.get("updated_at").and_then(Value::as_str) {
                if updated.insert(key, at.to_string()).is_none() {
                    listed.push((at.to_string(), key));
                }
            }
            if let Some(a) = item.get("author").and_then(|a| a.get("username")).and_then(Value::as_str) {
                authors.insert(key, a.to_string());
            }
        }
    }
    listed.sort_by(|a, b| b.0.cmp(&a.0));
    let mut order: Vec<(i64, i64)> = listed.into_iter().map(|(_, key)| key).collect();
    let approved_keys = approved_ev.ok().map(|e| gitlab_dash::event_targets(&e, EVENT_CANDIDATES)).unwrap_or_default();
    let commented_keys = commented_ev.ok().map(|e| gitlab_dash::event_targets(&e, EVENT_CANDIDATES)).unwrap_or_default();
    for key in &approved_keys {
        gitlab_dash::merge_roles(&mut roles, *key, |r| r.approved_event = true);
    }
    for key in approved_keys.into_iter().chain(commented_keys) {
        if !order.contains(&key) {
            order.push(key);
        }
    }
    order.truncate(PERIMETER);

    // Read again only what moved since the last time (or still runs a pipeline).
    let generation = PANEL.generation.load(Ordering::SeqCst);
    let mut cache = PANEL.cache.lock().unwrap().clone();
    let mut set = tokio::task::JoinSet::new();
    for key in &order {
        let wanted = updated.get(key).map(String::as_str);
        if gitlab_dash::is_fresh(cache.get(key), wanted) {
            continue;
        }
        let r = roles.get(key).copied().unwrap_or_default();
        // Approvals: for my merge requests ("1/2") and to know if I approved.
        let with_approvals = r.approved_event || authors.get(key).map(String::as_str) == Some(me.as_str());
        let (http, base, token, me, key) = (http.clone(), base.to_string(), token.to_string(), me.clone(), *key);
        set.spawn(async move { (key, read_entry(http, base, token, key, with_approvals, me).await) });
    }
    while let Some(Ok((key, read))) = set.join_next().await {
        match read {
            Some(read) => {
                cache.insert(key, read);
            }
            // A merge request that cannot be read (gone, no access) is not shown.
            None => {
                cache.remove(&key);
            }
        }
    }
    cache.retain(|key, _| order.contains(key));
    if PANEL.generation.load(Ordering::SeqCst) != generation {
        return None;
    }
    *PANEL.cache.lock().unwrap() = cache.clone();

    let entries: Vec<(MrEntry, Roles)> = order
        .iter()
        .filter_map(|key| Some((cache.get(key)?.1.clone(), roles.get(key).copied().unwrap_or_default())))
        .collect();
    Some(gitlab_dash::build_dashboard(&me, base, can_write, &entries, now))
}

// ── Answering ─────────────────────────────────────────────────────────────────

/// The code the panel turns into a message.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Sent {
    pub ok: bool,
    /// "empty", "no_token", "forbidden", "not_found", "network" or "error".
    pub error: Option<&'static str>,
}

fn sent(error: Option<&'static str>) -> Sent {
    Sent { ok: error.is_none(), error }
}

fn code_for(status: u16) -> &'static str {
    match status {
        0 => "network",
        401 | 403 => "forbidden",
        404 => "not_found",
        _ => "error",
    }
}

async fn write(
    method: reqwest::Method,
    path: &str,
    form: &[(&str, &str)],
) -> Result<(), &'static str> {
    let (Some(token), Some(base)) = (secrets::get("gitlab-token"), integrations::gitlab_base()) else {
        return Err("no_token");
    };
    let response = integrations::client()
        .request(method, gitlab::api_url(&base, path))
        .header("PRIVATE-TOKEN", token)
        .header("User-Agent", "Coucou")
        .form(form)
        .send()
        .await
        .map_err(|_| "network")?;
    let status = response.status();
    if status.is_success() {
        Ok(())
    } else {
        log::line(format!("gitlab {path} HTTP {}", status.as_u16()));
        Err(code_for(status.as_u16()))
    }
}

/// What a click on Reply or Resolve changed: the thread leaves the list at once,
/// then the next read confirms it.
fn drop_thread(app: &AppHandle, project_id: i64, mr_iid: i64, discussion: &str) {
    PANEL.cache.lock().unwrap().remove(&(project_id, mr_iid));
    let updated = {
        let mut current = PANEL.dashboard.lock().unwrap();
        if let Some(d) = current.as_mut() {
            d.comments.retain(|t| t.id != discussion);
        }
        current.clone()
    };
    if let Some(d) = updated {
        emit_dashboard(app, Some(&d));
    }
    PANEL.wake.notify_one();
}

/// Answers in a thread. Only on a click in the panel, never by itself.
#[tauri::command]
pub async fn gitlab_reply(app: AppHandle, project_id: i64, mr_iid: i64, discussion: String, body: String) -> Sent {
    let body = body.trim();
    if body.is_empty() {
        return sent(Some("empty"));
    }
    let path = format!("projects/{project_id}/merge_requests/{mr_iid}/discussions/{discussion}/notes");
    match write(reqwest::Method::POST, &path, &[("body", body)]).await {
        Ok(()) => {
            drop_thread(&app, project_id, mr_iid, &discussion);
            sent(None)
        }
        Err(code) => sent(Some(code)),
    }
}

/// Resolves a thread, or opens it again.
#[tauri::command]
pub async fn gitlab_resolve(app: AppHandle, project_id: i64, mr_iid: i64, discussion: String, resolved: bool) -> Sent {
    let path = format!("projects/{project_id}/merge_requests/{mr_iid}/discussions/{discussion}");
    let value = if resolved { "true" } else { "false" };
    match write(reqwest::Method::PUT, &path, &[("resolved", value)]).await {
        Ok(()) => {
            if !resolved {
                PANEL.reopened.lock().unwrap().insert(discussion.clone());
            }
            drop_thread(&app, project_id, mr_iid, &discussion);
            sent(None)
        }
        Err(code) => sent(Some(code)),
    }
}

/// The lines around a code comment, read from the file at the commit it was made on.
#[tauri::command]
pub async fn gitlab_snippet(project_id: i64, file: String, sha: String, line: i64) -> Option<Vec<SnippetLine>> {
    let (token, base) = (secrets::get("gitlab-token")?, integrations::gitlab_base()?);
    let mut url = reqwest::Url::parse(&gitlab::api_url(&base, "projects")).ok()?;
    url.path_segments_mut()
        .ok()?
        .extend([project_id.to_string().as_str(), "repository", "files", file.as_str(), "raw"]);
    let response = integrations::client()
        .get(url)
        .query(&[("ref", sha.as_str())])
        .header("PRIVATE-TOKEN", token)
        .header("User-Agent", "Coucou")
        .send()
        .await
        .ok()?;
    // A huge file is not worth reading for a few lines.
    if !response.status().is_success() || response.content_length().is_some_and(|n| n > 2_000_000) {
        return None;
    }
    let text = response.text().await.ok()?;
    Some(gitlab_dash::snippet(&text, line, 3))
}
