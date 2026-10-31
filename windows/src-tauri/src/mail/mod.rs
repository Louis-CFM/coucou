// The Mail pill on Windows: classic Outlook, driven through its COM objects (outlook.rs).
// Port of MailController / MailTriageStore / MailAgent from the Mac, where Apple Mail plays
// Outlook's part.
//
// - The pill: the latest messages of every inbox, a search and quick filters, and actions
//   on a message (each one the user's click).
// - The Mail section of the Coucou window: automatic sorting (off by default), rules, banned
//   words, VIPs, a journal with Undo, and what Coucou sent.
// - The chat's Mail switch: the AI gets the latest messages and may answer with a plan
//   (plan.rs) that runs only after the user clicks Run on its card.
//
// Outlook is read every 60 s only while the pill is on or the sorting is, and only when
// OUTLOOK.EXE runs: Coucou never starts Outlook, and a closed Outlook costs nothing.
// Coucou never deletes a message.

pub mod outlook;
pub mod pdf;
pub mod plan;
pub mod store;
pub mod triage;

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use outlook::{Message, RunError};
use plan::{Plan, Step};
use store::{JournalEntry, SentEntry, Store};
use triage::{Action, Facts, Filter, Query, Reason, Settings};

pub const PILL: &str = "integration_mail";
const OUTLOOK_EXE: &str = "OUTLOOK.EXE";
const TIMEOUT: Duration = Duration::from_secs(40);
const KEEP: usize = 12;
const MAX_SHOWN: usize = 60;

/// Set around a chat turn sent with the Mail switch on: chat::system_prompt adds the
/// mail instructions while it is.
pub static MAIL_TURN: AtomicBool = AtomicBool::new(false);

static BUSY: AtomicBool = AtomicBool::new(false);
static COUNTER: AtomicU64 = AtomicU64::new(0);

struct BusyGuard<'a>(&'a AtomicBool);

impl<'a> Drop for BusyGuard<'a> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

struct Runtime {
    store: Store,
    shown: usize,
    /// The card's list and unread count, as last read.
    last: Vec<Message>,
    last_unread: i64,
    /// The messages of the last list sent to the AI, by their number.
    numbered: HashMap<usize, Message>,
    accounts: Vec<(String, String)>,
    plans: HashMap<String, PlanRun>,
    cancelled: HashSet<String>,
}

fn rt() -> MutexGuard<'static, Runtime> {
    static RT: OnceLock<Mutex<Runtime>> = OnceLock::new();
    RT.get_or_init(|| {
        Mutex::new(Runtime {
            store: Store::load(crate::platform::config_dir().join("mail")),
            shown: KEEP,
            last: Vec::new(),
            last_unread: 0,
            numbered: HashMap::new(),
            accounts: Vec::new(),
            plans: HashMap::new(),
            cancelled: HashSet::new(),
        })
    })
    .lock()
    .unwrap_or_else(|e| e.into_inner())
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn new_id() -> String {
    format!("{:x}-{:x}", now_ms(), COUNTER.fetch_add(1, Ordering::Relaxed))
}

fn sender_of(m: &Message) -> String {
    if m.sender_name.is_empty() { m.address.clone() } else { format!("{} <{}>", m.sender_name, m.address) }
}

fn pill_on(app: &AppHandle) -> bool {
    app.try_state::<crate::Shared>()
        .map(|shared| shared.settings.lock().unwrap().active_integrations.iter().any(|x| x == PILL))
        .unwrap_or(false)
}

fn outlook_open() -> bool {
    cfg!(windows) && crate::platform::process_running(OUTLOOK_EXE)
}

fn emit_card(app: &AppHandle, running: bool) {
    let data = {
        let r = rt();
        json!({
            "running": running,
            "windows": cfg!(windows),
            "unread": r.last_unread,
            "messages": r.last,
            "shown": r.shown,
            "maxShown": MAX_SHOWN,
        })
    };
    let _ = app.emit_to(crate::island::WINDOW_LABEL, "integration", json!({
        "id": PILL, "data": data, "error": Value::Null, "event": Value::Null,
    }));
}

// ── Polling ──────────────────────────────────────────────────────────────────

pub fn start(app: AppHandle) {
    let _ = std::fs::remove_dir_all(work_dir());
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(8)).await;
        let mut ticker = tokio::time::interval(Duration::from_secs(60));
        loop {
            ticker.tick().await;
            poll(&app).await;
        }
    });
}

/// Reads the inboxes (the card, and the sorting) when the pill or the sorting is on.
pub async fn poll(app: &AppHandle) {
    if crate::integrations::PAUSED.load(Ordering::Relaxed) {
        return;
    }
    let pill = pill_on(app);
    let auto = rt().store.settings.auto_sort;
    if !pill && !auto {
        return;
    }
    if !outlook_open() {
        if pill {
            emit_card(app, false);
        }
        return;
    }
    if BUSY.swap(true, Ordering::AcqRel) {
        return;
    }
    let _busy_guard = BusyGuard(&BUSY);
    let per_inbox = { rt().shown.max(if auto { 30 } else { 0 }) };
    let result = outlook::run(outlook::list_script(per_inbox), TIMEOUT).await;
    drop(_busy_guard);
    match result {
        Ok(v) => {
            let listing: outlook::Listing = serde_json::from_value(v).unwrap_or_default();
            let mut all = listing.messages;
            all.sort_by(|a, b| b.date.cmp(&a.date));
            {
                let mut r = rt();
                r.last_unread = listing.unread;
                r.last = all.iter().take(r.shown).cloned().collect();
            }
            if pill {
                emit_card(app, true);
            }
            triage(app, &all).await;
        }
        Err(RunError::NotRunning) if pill => emit_card(app, false),
        Err(e) => crate::log::line(format!("[mail] Outlook: {e}")),
    }
}

/// The automatic sorting: each message that arrived since it was turned on is looked at once
/// (VIPs, banned words, rules), and what it does goes in the journal.
async fn triage(app: &AppHandle, list: &[Message]) {
    let settings = rt().store.settings.clone();
    let (true, Some(since)) = (settings.auto_sort, settings.auto_sort_since) else { return };
    let mut fresh: Vec<Message> = {
        let r = rt();
        list.iter().filter(|m| m.date >= since && !r.store.is_seen(&m.id())).cloned().collect()
    };
    if fresh.is_empty() {
        return;
    }
    fresh.sort_by_key(|m| m.date);
    rt().store.mark_seen(&fresh.iter().map(Message::id).collect::<Vec<_>>());
    let needs_text = triage::needs_text(&settings);
    let mut changed = false;
    for m in &fresh {
        let mut facts = Facts {
            sender_name: m.sender_name.clone(),
            address: m.address.clone(),
            subject: m.subject.clone(),
            account: m.account.clone(),
            text: None,
        };
        if needs_text {
            facts.text = detail(m, 4000).await.map(|d| d.text);
        }
        if let Some(d) = triage::decide(&facts, &settings) {
            changed |= perform(&d.action, m, d.reason).await.is_ok();
        }
    }
    if changed && pill_on(app) {
        emit_card(app, true);
    }
}

/// Applies `action` to a message in Outlook, writes it in the journal and updates the card.
async fn perform(action: &Action, m: &Message, reason: Reason) -> Result<(), String> {
    let v = outlook::run(outlook::apply_script(&m.entry_id, &m.store_id, action), TIMEOUT)
        .await
        .map_err(|e| e.to_string())?;
    let after = v.get("entryId").and_then(Value::as_str).unwrap_or(&m.entry_id).to_string();
    let mut r = rt();
    r.store.record(JournalEntry {
        id: new_id(),
        date: now_ms(),
        account: m.account.clone(),
        store_id: m.store_id.clone(),
        entry_id: after,
        sender: sender_of(m),
        subject: m.subject.clone(),
        action: action.clone(),
        reason,
        undone: false,
    });
    let id = m.id();
    match action {
        Action::Junk | Action::Move(_) => {
            if r.last.iter().any(|x| x.id() == id && x.unread) {
                r.last_unread = (r.last_unread - 1).max(0);
            }
            r.last.retain(|x| x.id() != id);
        }
        Action::Important => r.last.iter_mut().filter(|x| x.id() == id).for_each(|x| x.flagged = true),
        Action::MarkRead => r.last.iter_mut().filter(|x| x.id() == id).for_each(|x| x.unread = false),
    }
    Ok(())
}

#[derive(Serialize, Deserialize, Default, Clone)]
pub struct Detail {
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub attachments: Vec<String>,
}

async fn detail(m: &Message, limit: usize) -> Option<Detail> {
    let v = outlook::run(outlook::detail_script(&m.entry_id, &m.store_id, limit), TIMEOUT).await.ok()?;
    serde_json::from_value(v).ok()
}

// ── The pill's commands ──────────────────────────────────────────────────────

/// Reads Outlook now (the card opened, Refresh).
#[tauri::command]
pub async fn mail_refresh(app: AppHandle) {
    poll(&app).await;
}

/// The card shows 12 more messages.
#[tauri::command]
pub async fn mail_more(app: AppHandle) {
    {
        let mut r = rt();
        r.shown = (r.shown + KEEP).min(MAX_SHOWN);
    }
    poll(&app).await;
}

/// Searches every inbox; nothing to search: the card's list.
#[tauri::command]
pub async fn mail_search(query: String, filter: Filter) -> Result<Vec<Message>, String> {
    let Some(dasl) = outlook::dasl(&Query::parse(&query), filter) else { return Ok(rt().last.clone()) };
    let v = outlook::run(outlook::search_script(&dasl, MAX_SHOWN), TIMEOUT).await.map_err(|e| e.to_string())?;
    let mut list = serde_json::from_value::<outlook::Listing>(v).unwrap_or_default().messages;
    list.sort_by(|a, b| b.date.cmp(&a.date));
    list.truncate(MAX_SHOWN);
    Ok(list)
}

/// A message's text (1,200 characters) and attachments, for the card.
#[tauri::command]
pub async fn mail_detail(message: Message) -> Result<Detail, String> {
    detail(&message, 1200).await.ok_or_else(|| "Outlook did not answer".to_string())
}

/// Opens the message (or a reply to it) in Outlook's own window. Nothing is sent.
#[tauri::command]
pub async fn mail_open(message: Message, reply: bool) -> Result<(), String> {
    let body = reply.then_some("");
    outlook::run(outlook::open_script(&message.entry_id, &message.store_id, body), TIMEOUT)
        .await
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// An action on a message, from the user's click in the card.
#[tauri::command]
pub async fn mail_act(app: AppHandle, message: Message, kind: String) -> Result<(), String> {
    match kind.as_str() {
        "read" => perform(&Action::MarkRead, &message, Reason::Manual).await?,
        "flag" => perform(&Action::Important, &message, Reason::Manual).await?,
        "unflag" => {
            outlook::run(outlook::unflag_script(&message.entry_id, &message.store_id), TIMEOUT)
                .await
                .map_err(|e| e.to_string())?;
            rt().last.iter_mut().filter(|x| x.id() == message.id()).for_each(|x| x.flagged = false);
        }
        "junk" => perform(&Action::Junk, &message, Reason::Manual).await?,
        "ignore" => {
            rt().store.add_banned(&message.address);
            perform(&Action::Junk, &message, Reason::Manual).await?;
        }
        "vip" => {
            rt().store.add_vip(&message.address);
            if !message.flagged {
                perform(&Action::Important, &message, Reason::Manual).await?;
            }
        }
        other => return Err(format!("unknown action {other}")),
    }
    emit_card(&app, true);
    Ok(())
}

// ── The Mail section's commands ──────────────────────────────────────────────

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TriageView {
    settings: Settings,
    journal: Vec<JournalEntry>,
    sent: Vec<SentEntry>,
    today: Value,
    windows: bool,
    outlook_open: bool,
}

#[tauri::command]
pub fn mail_triage() -> TriageView {
    let r = rt();
    let start_of_day = {
        let t = crate::platform::local_time();
        let secs_today = (t.hour * 3600 + t.minute * 60 + t.second) as i64;
        now_ms() - secs_today * 1000
    };
    let today: Vec<&JournalEntry> = r.store.journal.iter().filter(|e| e.date >= start_of_day && !e.undone).collect();
    TriageView {
        settings: r.store.settings.clone(),
        journal: r.store.journal.iter().take(100).cloned().collect(),
        sent: r.store.sent.iter().take(50).cloned().collect(),
        today: json!({
            "sorted": today.len(),
            "junk": today.iter().filter(|e| e.action == Action::Junk).count(),
            "important": today.iter().filter(|e| e.action == Action::Important).count(),
        }),
        windows: cfg!(windows),
        outlook_open: outlook_open(),
    }
}

#[tauri::command]
pub async fn mail_triage_set(app: AppHandle, settings: Settings) {
    rt().store.set_settings(settings, now_ms());
    poll(&app).await;
}

#[tauri::command]
pub fn mail_journal_clear() {
    rt().store.clear_journal();
}

/// Puts back a message the journal shows as sorted.
#[tauri::command]
pub async fn mail_undo(app: AppHandle, id: String) -> Result<(), String> {
    let entry = rt().store.journal.iter().find(|e| e.id == id && !e.undone).cloned().ok_or("not found")?;
    outlook::run(outlook::undo_script(&entry.entry_id, &entry.store_id, &entry.action), TIMEOUT)
        .await
        .map_err(|e| e.to_string())?;
    rt().store.mark_undone(&id);
    poll(&app).await;
    Ok(())
}

// ── The chat's Mail switch ───────────────────────────────────────────────────

/// The user's request with the latest messages under it, for the AI.
pub async fn decorate(query: &str) -> String {
    if !cfg!(windows) {
        return format!("{query}\n\n<mail>Outlook is only reached on Windows: say so.</mail>");
    }
    if !outlook_open() {
        return format!("{query}\n\n<mail>Outlook is closed: ask the user to open the classic Outlook, then to ask again.</mail>");
    }
    if let Ok(v) = outlook::run(outlook::accounts_script(), TIMEOUT).await {
        let accounts: Vec<(String, String)> = v["accounts"]
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|x| (x["name"].as_str().unwrap_or("").to_string(), x["address"].as_str().unwrap_or("").to_string()))
                    .collect()
            })
            .unwrap_or_default();
        rt().accounts = accounts;
    }
    let mut list = match outlook::run(outlook::list_script(20), TIMEOUT).await {
        Ok(v) => serde_json::from_value::<outlook::Listing>(v).unwrap_or_default().messages,
        Err(e) => return format!("{query}\n\n<mail>Coucou could not read Outlook ({e}).</mail>"),
    };
    list.sort_by(|a, b| b.date.cmp(&a.date));
    list.truncate(40);
    rt().numbered = list.iter().enumerate().map(|(i, m)| (i + 1, m.clone())).collect();
    let senders: Vec<String> = list.iter().map(sender_of).collect();
    let subjects: Vec<String> = list.iter().map(|m| m.subject.clone()).collect();
    let named: HashSet<usize> = plan::mentioned(query, &senders, &subjects, 3).into_iter().collect();
    let mut lines = Vec::new();
    for (i, m) in list.iter().enumerate() {
        let mut line = plan::Line {
            number: i + 1,
            sender: senders[i].clone(),
            subject: m.subject.clone(),
            date: m.local.clone(),
            unread: m.unread,
            account: m.account.clone(),
            attachments: Vec::new(),
            text: None,
        };
        // The messages the request names get their text; the newest ones their attachments.
        if named.contains(&i) || i < 8 {
            if let Some(d) = detail(m, if named.contains(&i) { 3000 } else { 300 }).await {
                line.attachments = d.attachments;
                line.text = Some(d.text);
            }
        }
        lines.push(line);
    }
    let accounts = rt().accounts.clone();
    format!("{query}{}", plan::snapshot(&lines, &accounts))
}

/// One mail a plan will send.
#[derive(Serialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct PreparedMail {
    to: Vec<String>,
    cc: Vec<String>,
    subject: String,
    body: String,
    /// Paths on this computer.
    attachments: Vec<String>,
    /// Why it can't be sent ("noPage", "badAddress"): shown in red, skipped.
    problem: Option<&'static str>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Phase {
    Preparing,
    Ready,
    Countdown { seconds: u32 },
    Running { done: usize, total: usize },
    Done { ok: usize, failed: usize },
    Cancelled,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct SortStep {
    action: Action,
    messages: Vec<Message>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct PlanNote {
    /// "missing" (a message number not in the list), "noPdf", "fileMissing".
    kind: &'static str,
    value: String,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct PlanRun {
    phase: Phase,
    summary: String,
    sorts: Vec<SortStep>,
    replies: Vec<(Message, String)>,
    saves: Vec<(Message, String)>,
    mails: Vec<PreparedMail>,
    notes: Vec<PlanNote>,
    test_sent_to: Option<String>,
    my_address: Option<String>,
    step_count: usize,
}

impl PlanRun {
    fn new(summary: String) -> PlanRun {
        PlanRun {
            phase: Phase::Preparing,
            summary,
            sorts: Vec::new(),
            replies: Vec::new(),
            saves: Vec::new(),
            mails: Vec::new(),
            notes: Vec::new(),
            test_sent_to: None,
            my_address: None,
            step_count: 0,
        }
    }

    fn count(&self) -> usize {
        self.sorts.iter().map(|s| s.messages.len()).sum::<usize>()
            + self.replies.len()
            + self.saves.len()
            + self.mails.iter().filter(|m| m.problem.is_none()).count()
    }
}

fn emit_plan(app: &AppHandle, id: &str) {
    let run = rt().plans.get(id).cloned();
    if let Some(run) = run {
        let _ = app.emit_to(crate::island::WINDOW_LABEL, "mail-plan", json!({ "id": id, "run": run }));
    }
}

fn set_phase(app: &AppHandle, id: &str, phase: Phase) {
    if let Some(run) = rt().plans.get_mut(id) {
        run.phase = phase;
    }
    emit_plan(app, id);
}

fn work_dir() -> std::path::PathBuf {
    std::env::temp_dir().join("coucou-mail-plans")
}

/// The card of a chat answer holding a plan: prepared once, then its state.
#[tauri::command]
pub async fn mail_plan_show(app: AppHandle, id: String, text: String) -> Result<PlanRun, String> {
    if let Some(run) = rt().plans.get(&id).cloned() {
        return Ok(run);
    }
    let (_, plan, error) = plan::extract(&text);
    let plan = plan.ok_or(error.unwrap_or_else(|| "no plan".into()))?;
    let run = PlanRun::new(plan.summary.clone());
    rt().plans.insert(id.clone(), run.clone());
    let app2 = app.clone();
    let id2 = id.clone();
    tauri::async_runtime::spawn(async move {
        let mut run = prepare(plan).await;
        run.phase = Phase::Ready;
        run.step_count = run.count();
        run.my_address = rt().accounts.iter().map(|a| a.1.clone()).find(|a| !a.is_empty());
        rt().plans.insert(id2.clone(), run);
        emit_plan(&app2, &id2);
    });
    Ok(run)
}

async fn save_attachments(m: &Message, only: Option<&str>) -> Vec<String> {
    let dir = work_dir().join(new_id());
    let folder = dir.to_string_lossy().to_string();
    match outlook::run(outlook::save_attachments_script(&m.entry_id, &m.store_id, &folder, only), TIMEOUT).await {
        Ok(v) => v["saved"]
            .as_array()
            .map(|a| a.iter().filter_map(Value::as_str).map(|n| dir.join(n).to_string_lossy().to_string()).collect())
            .unwrap_or_default(),
        Err(_) => Vec::new(),
    }
}

fn expand(path: &str) -> String {
    match path.strip_prefix('~') {
        Some(rest) => format!("{}{}", crate::platform::home_dir().to_string_lossy(), rest),
        None => path.to_string(),
    }
}

async fn prepare(plan: Plan) -> PlanRun {
    let mut run = PlanRun::new(plan.summary.clone());
    let numbered = rt().numbered.clone();
    let message = |n: usize, run: &mut PlanRun| -> Option<Message> {
        let m = numbered.get(&n).cloned();
        if m.is_none() {
            run.notes.push(PlanNote { kind: "missing", value: n.to_string() });
        }
        m
    };
    for step in plan.steps {
        match step {
            Step::Sort(action, numbers) => {
                let messages: Vec<Message> = numbers.into_iter().filter_map(|n| message(n, &mut run)).collect();
                if !messages.is_empty() {
                    run.sorts.push(SortStep { action, messages });
                }
            }
            Step::Reply(n, body) => {
                if let Some(m) = message(n, &mut run) {
                    run.replies.push((m, body));
                }
            }
            Step::SaveAttachments(n, folder) => {
                if let Some(m) = message(n, &mut run) {
                    run.saves.push((m, expand(&folder)));
                }
            }
            Step::Send(out) => {
                let mut files = Vec::new();
                if let Some(m) = out.attachments_from.and_then(|n| message(n, &mut run)) {
                    files.extend(save_attachments(&m, None).await);
                }
                for f in &out.files {
                    let p = expand(f);
                    if std::path::Path::new(&p).is_file() {
                        files.push(p);
                    } else {
                        run.notes.push(PlanNote { kind: "fileMissing", value: f.clone() });
                    }
                }
                let bad = out.to.iter().chain(&out.cc).any(|a| !plan::valid_address(a));
                run.mails.push(PreparedMail {
                    to: out.to,
                    cc: out.cc,
                    subject: out.subject,
                    body: out.body,
                    attachments: files,
                    problem: bad.then_some("badAddress"),
                });
            }
            Step::Merge(merge) => {
                let source = merge.from_message.and_then(|n| message(n, &mut run));
                prepare_merge(merge, source, &mut run).await;
            }
        }
    }
    run
}

async fn prepare_merge(merge: plan::Merge, source: Option<Message>, run: &mut PlanRun) {
    // The PDF: a file on this computer, or one of a message's attachments.
    let mut pdf: Option<String> = None;
    if let Some(file) = &merge.file {
        let p = expand(file);
        if std::path::Path::new(&p).is_file() {
            pdf = Some(p);
        } else {
            run.notes.push(PlanNote { kind: "fileMissing", value: file.clone() });
        }
    } else if let Some(m) = &source {
        let mut name = merge.attachment.clone();
        if name.is_none() {
            name = detail(m, 1).await.and_then(|d| d.attachments.into_iter().find(|a| a.to_lowercase().ends_with(".pdf")));
        }
        if let Some(name) = name {
            pdf = save_attachments(m, Some(&name)).await.into_iter().next();
        }
        if pdf.is_none() {
            run.notes.push(PlanNote { kind: "noPdf", value: String::new() });
        }
    }
    let mut pages = pdf::Pages { files: Vec::new(), texts: Vec::new() };
    if let (Some(path), true) = (&pdf, merge.split_pages) {
        let path = std::path::PathBuf::from(path);
        let dir = work_dir().join(new_id());
        match tauri::async_runtime::spawn_blocking(move || pdf::split(&path, &dir)).await {
            Ok(Ok(p)) => pages = p,
            _ => run.notes.push(PlanNote { kind: "noPdf", value: String::new() }),
        }
    }
    let assignments = if merge.split_pages {
        plan::assign(&pages.texts, &merge.recipients, merge.match_by_key)
    } else {
        merge.recipients.iter().map(|r| plan::Assignment { recipient: r.clone(), page: None, ambiguous: false }).collect()
    };
    let base = pdf
        .as_deref()
        .and_then(|p| std::path::Path::new(p).file_name())
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "Plan.pdf".into());
    for a in assignments {
        let mut files = Vec::new();
        let mut problem = None;
        if merge.split_pages {
            match a.page.and_then(|p| pages.files.get(p).map(|f| (p, f))) {
                Some((p, file)) => {
                    // The recipient gets "Plans - Bordeaux.pdf", not "p3.pdf".
                    let named = file.with_file_name(plan::page_file_name(&base, &a.recipient.key, p));
                    let _ = std::fs::copy(file, &named);
                    files.push(named.to_string_lossy().to_string());
                }
                None => problem = Some("noPage"),
            }
        } else if let Some(p) = &pdf {
            files.push(p.clone());
        }
        if !plan::valid_address(&a.recipient.email) {
            problem = Some("badAddress");
        }
        run.mails.push(PreparedMail {
            to: vec![a.recipient.email.clone()],
            cc: Vec::new(),
            subject: plan::fill(&merge.subject, &a.recipient),
            body: plan::fill(&merge.body, &a.recipient),
            attachments: files,
            problem,
        });
    }
}

/// Sends the plan's first mail to the user's own address, "[Test]" in front.
#[tauri::command]
pub async fn mail_plan_test(app: AppHandle, id: String) -> Result<(), String> {
    let (first, me) = {
        let r = rt();
        let run = r.plans.get(&id).ok_or("no plan")?;
        let first = run.mails.iter().find(|m| m.problem.is_none()).cloned().ok_or("no mail")?;
        (first, run.my_address.clone().ok_or("no address")?)
    };
    let script = outlook::send_script(&[me.clone()], &[], &format!("[Test] {}", first.subject), &first.body, &first.attachments);
    outlook::run(script, TIMEOUT).await.map_err(|e| e.to_string())?;
    if let Some(run) = rt().plans.get_mut(&id) {
        run.test_sent_to = Some(me);
    }
    emit_plan(&app, &id);
    Ok(())
}

/// Run: 5 seconds to change one's mind, then every step in order.
#[tauri::command]
pub async fn mail_plan_start(app: AppHandle, id: String) -> Result<(), String> {
    let run = {
        let mut r = rt();
        r.cancelled.remove(&id);
        r.plans.get(&id).cloned().ok_or("no plan")?
    };
    if !matches!(run.phase, Phase::Ready | Phase::Cancelled) {
        return Ok(());
    }
    tauri::async_runtime::spawn(async move {
        for s in (1..=5).rev() {
            if rt().cancelled.contains(&id) {
                set_phase(&app, &id, Phase::Cancelled);
                return;
            }
            set_phase(&app, &id, Phase::Countdown { seconds: s });
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        if rt().cancelled.contains(&id) {
            set_phase(&app, &id, Phase::Cancelled);
            return;
        }
        execute(&app, &id, run).await;
    });
    Ok(())
}

#[tauri::command]
pub fn mail_plan_cancel(app: AppHandle, id: String) {
    let countdown = {
        let mut r = rt();
        r.cancelled.insert(id.clone());
        matches!(r.plans.get(&id).map(|p| &p.phase), Some(Phase::Countdown { .. }))
    };
    if countdown {
        set_phase(&app, &id, Phase::Cancelled);
    }
}

async fn execute(app: &AppHandle, id: &str, run: PlanRun) {
    let total = run.count();
    let (mut ok, mut failed) = (0, 0);
    let step = |success: bool, ok: &mut usize, failed: &mut usize| {
        if success { *ok += 1 } else { *failed += 1 }
        set_phase(app, id, Phase::Running { done: *ok + *failed, total });
    };
    set_phase(app, id, Phase::Running { done: 0, total });
    let stopped = || rt().cancelled.contains(id);
    for s in &run.sorts {
        for m in &s.messages {
            if stopped() {
                break;
            }
            step(perform(&s.action, m, Reason::Manual).await.is_ok(), &mut ok, &mut failed);
        }
    }
    for (m, body) in &run.replies {
        let r = outlook::run(outlook::open_script(&m.entry_id, &m.store_id, Some(body)), TIMEOUT).await;
        step(r.is_ok(), &mut ok, &mut failed);
    }
    for (m, folder) in &run.saves {
        let r = outlook::run(outlook::save_attachments_script(&m.entry_id, &m.store_id, folder, None), TIMEOUT).await;
        step(r.is_ok(), &mut ok, &mut failed);
    }
    let mails: Vec<&PreparedMail> = run.mails.iter().filter(|m| m.problem.is_none()).collect();
    for (i, mail) in mails.iter().enumerate() {
        if stopped() {
            break;
        }
        let script = outlook::send_script(&mail.to, &mail.cc, &mail.subject, &mail.body, &mail.attachments);
        let sent = outlook::run(script, TIMEOUT).await.is_ok();
        if sent {
            rt().store.record_sent(SentEntry {
                id: new_id(),
                date: now_ms(),
                to: mail.to.clone(),
                subject: mail.subject.clone(),
                attachments: mail
                    .attachments
                    .iter()
                    .filter_map(|p| std::path::Path::new(p).file_name().map(|n| n.to_string_lossy().to_string()))
                    .collect(),
            });
        }
        step(sent, &mut ok, &mut failed);
        // A pause between mails: the provider sees a person, not a burst.
        if i + 1 < mails.len() {
            tokio::time::sleep(Duration::from_millis(1200)).await;
        }
    }
    set_phase(app, id, Phase::Done { ok, failed });
    if pill_on(app) {
        emit_card(app, true);
    }
}
