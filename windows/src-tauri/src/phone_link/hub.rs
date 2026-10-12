// What the phone is told, and what it may decide.
//
// The hub holds the last list of sessions and the one permission request that is
// still waiting, as the island published them (phone_link_publish). It knows
// nothing about sockets or Tauri: connections subscribe to it, and a decision
// from a phone goes back to the app through the `Host` trait. That keeps every
// rule of docs/ANDROID_LINK.md testable without a window.
//
// The rules that matter:
//   * a phone decision is applied only if its fingerprint is the one of the
//     request that is *still* pending (same session, tool, command and request);
//   * only one decision is ever applied per request;
//   * a request older than APPROVAL_TTL is dismissed, whatever the phone says;
//   * nothing here can block the agent: the desktop's own card keeps working,
//     and a phone that never answers changes nothing.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use ring::digest;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::sync::mpsc;

/// The desktop dismisses a request after this long (the phone offers it for 120 s).
pub const APPROVAL_TTL_MS: u64 = 115_000;

const MAX_SESSIONS: usize = 16;
const MAX_COMMAND_CHARS: usize = 500;
const MAX_TEXT_CHARS: usize = 200;
/// Details (cap `details`): at most this many steps per session, each cut at MAX_TEXT_CHARS.
pub const MAX_STEPS: usize = 20;
const MAX_PROJECT_CHARS: usize = 64;
/// A `sessions` line with details stays under this, so it never reaches the 64 KiB limit of a line
/// (16 sessions of 20 steps of 200 characters would be 64 KB of text alone).
pub const DETAILS_LINE_BUDGET: usize = 56 * 1024;

/// File changes (cap `diffs`): the list of files of a session, and a file's lines on request.
pub const MAX_FILES: usize = 20;
const MAX_FILE_NAME_CHARS: usize = 80;
/// One file's diff: at most this many lines, each cut at MAX_DIFF_LINE_CHARS, sent in parts of PART_LINES so
/// no line of the link nears the 64 KiB limit.
pub const MAX_DIFF_LINES: usize = 200;
const MAX_DIFF_LINE_CHARS: usize = 400;
const PART_LINES: usize = 100;
/// A phone may ask for this many diffs in 10 seconds.
const DIFF_ASKS_PER_10S: usize = 20;

/// Service cards (cap `services`): read-only snapshots of what the island's service pills show, one switch per
/// service. These are the only ids the link will ever carry.
pub const SERVICE_IDS: [&str; 7] = [
    "integration_stripe", "integration_github", "integration_vercel", "integration_n8n",
    "integration_resend", "integration_notion", "integration_calcom",
];
const MAX_SERVICE_ITEMS: usize = 3;
const MAX_SERVICE_TITLE_CHARS: usize = 24;
const MAX_SERVICE_HEADLINE_CHARS: usize = 40;
const MAX_SERVICE_REASON_CHARS: usize = 80;
const MAX_SERVICE_ITEM_CHARS: usize = 60;

/// Questions (cap `answers`): a question that does not fit these limits is left to the island, never cut,
/// because the answer must carry the exact text and labels back to the agent.
pub const MAX_QUESTIONS: usize = 4;
pub const MAX_OPTIONS: usize = 8;
const MAX_QUESTION_CHARS: usize = 500;
const MAX_LABEL_CHARS: usize = 120;
const MAX_DESCRIPTION_CHARS: usize = 300;

/// The states the phone draws; anything else is sent as `idle`.
const STATES: &[&str] = &[
    "idle", "working", "thinking", "searching", "approval", "question", "error", "finished",
    "ratelimit", "sleeping", "dizzy",
];

/// How a decision gets back to the agent. The app's implementation answers the
/// waiting `coucou-hook` and closes the card on the island.
pub trait Host: Send + Sync {
    fn decide(&self, request_id: &str, allow: bool);
    /// A phone answered a question Claude Code asked: each question's text mapped to the label picked (a list of
    /// labels for a multi-select), the shape AskUserQuestion takes. Only called for the question still pending.
    /// A phone (connection `sub_id`) asked for a file's diff: the island answers through [`Hub::send_diff`].
    fn get_diff(&self, _sub_id: u64, _pill_id: &str, _file_id: u64) {}

    fn answer(&self, _request_id: &str, _answers: &serde_json::Map<String, serde_json::Value>) {}
}

/// One file a session changed, as the island has it. Only its name (never a path) is kept.
#[derive(Debug, Clone, PartialEq, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct FileIn {
    pub id: u64,
    pub name: String,
    pub added: u32,
    pub removed: u32,
    pub too_large: bool,
    pub is_new: bool,
}

/// One file's diff, as the island answers a phone's request: lines as [kind, text], kind one of "+", "-", " ", "@".
#[derive(Debug, Clone, PartialEq, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct DiffIn {
    pub pill_id: String,
    pub file_id: u64,
    pub name: String,
    pub added: u32,
    pub removed: u32,
    pub too_large: bool,
    /// The island no longer has this diff.
    pub gone: bool,
    pub lines: Vec<(String, String)>,
}

/// One agent session, as the island reports it.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SessionIn {
    pub pill_id: String,
    pub agent: String,
    pub state: String,
    pub status_text: String,
    pub step_index: u32,
    pub step_count: u32,
    /// Details, sent only to phones that asked for and were offered `details`.
    pub steps: Vec<String>,
    pub final_line: Option<String>,
    /// The folder the session runs in; only its last segment is ever kept.
    pub project: Option<String>,
    pub color: Option<String>,
    /// The files this session changed; sent only to phones that asked for and were offered `diffs`.
    pub files: Vec<FileIn>,
}

impl Default for SessionIn {
    fn default() -> Self {
        Self {
            pill_id: String::new(),
            agent: String::new(),
            state: "idle".into(),
            status_text: String::new(),
            step_index: 0,
            step_count: 0,
            steps: Vec::new(),
            final_line: None,
            project: None,
            color: None,
            files: Vec::new(),
        }
    }
}

/// The permission request waiting on the island.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApprovalIn {
    pub request_id: String,
    pub session_id: String,
    pub pill_id: String,
    pub tool: String,
    pub command: String,
}

/// The values the island stores for Mochi's wardrobe ("auto" follows the seasons on the phone's own calendar).
/// Same raw values as the Mac and the PC; anything else is not sent.
pub const OUTFIT_CHOICES: [&str; 13] = [
    "auto", "none", "partyHat", "beanie", "crown", "sunglasses", "roundGlasses",
    "bow", "scarf", "witchHat", "pumpkin", "santaHat", "bunnyEars",
];

fn clean_services(cards: Vec<ServiceIn>) -> Vec<ServiceIn> {
    let mut out: Vec<ServiceIn> = Vec::new();
    for c in cards {
        if !SERVICE_IDS.contains(&c.id.as_str()) || out.iter().any(|o| o.id == c.id) {
            continue;
        }
        let one_line = |s: &str, max: usize| -> String { clip(&s.chars().filter(|c| !c.is_control()).collect::<String>(), max).trim().to_string() };
        out.push(ServiceIn {
            id: c.id,
            title: one_line(&c.title, MAX_SERVICE_TITLE_CHARS),
            headline: one_line(&c.headline, MAX_SERVICE_HEADLINE_CHARS),
            reason: c.reason.as_deref().map(|r| one_line(r, MAX_SERVICE_REASON_CHARS)).filter(|r| !r.is_empty()),
            items: c
                .items
                .iter()
                .map(|i| ServiceItemIn { label: one_line(&i.label, MAX_SERVICE_ITEM_CHARS), detail: one_line(&i.detail, MAX_SERVICE_ITEM_CHARS) })
                .filter(|i| !i.label.is_empty())
                .take(MAX_SERVICE_ITEMS)
                .collect(),
        });
    }
    out
}

/// The `services` line for a phone whose user allowed `allowed`; None when none of the cards is allowed.
fn services_line(cards: &[ServiceIn], allowed: &[String]) -> Option<Arc<str>> {
    let list: Vec<serde_json::Value> = cards
        .iter()
        .filter(|c| allowed.contains(&c.id))
        .map(|c| {
            let mut v = json!({
                "id": c.id, "title": c.title, "headline": c.headline,
                "items": c.items.iter().map(|i| json!({ "label": i.label, "detail": i.detail })).collect::<Vec<_>>(),
            });
            if let Some(r) = &c.reason {
                v["reason"] = json!(r);
            }
            v
        })
        .collect();
    if list.is_empty() {
        return None;
    }
    Some(json!({ "type": "services", "services": list }).to_string().into())
}

fn window_json(w: &WindowIn) -> Option<serde_json::Value> {
    if !w.used_pct.is_finite() || w.resets_at == 0 {
        return None;
    }
    Some(json!({ "pct": w.used_pct.clamp(0.0, 100.0).round() as u32, "resetsAt": w.resets_at }))
}

fn plan_json(p: &PlanIn) -> Option<serde_json::Value> {
    let mut v = json!({});
    if let Some(w) = p.five_hour.as_ref().and_then(window_json) {
        v["fiveHour"] = w;
    }
    if let Some(w) = p.seven_day.as_ref().and_then(window_json) {
        v["sevenDay"] = w;
    }
    if v.as_object().is_some_and(|o| o.is_empty()) {
        return None;
    }
    if let Some(n) = p.reset_credits {
        v["resetCredits"] = json!(n.min(99));
    }
    // "plus", "pro", "max 5x": letters, digits, spaces and dashes only, short.
    if let Some(name) = p.plan_type.as_deref() {
        let clean: String = name.chars().filter(|c| c.is_ascii_alphanumeric() || *c == ' ' || *c == '-').take(20).collect();
        if !clean.trim().is_empty() {
            v["plan"] = json!(clean.trim());
        }
    }
    if p.updated_at > 0 {
        v["updatedAt"] = json!(p.updated_at);
    }
    Some(v)
}

/// None when the island has no number for either plan.
fn usage_line(u: &UsageIn) -> Option<Arc<str>> {
    let claude = u.claude.as_ref().and_then(plan_json);
    let codex = u.codex.as_ref().and_then(plan_json);
    if claude.is_none() && codex.is_none() {
        return None;
    }
    let mut v = json!({ "type": "usage" });
    if let Some(c) = claude {
        v["claude"] = c;
    }
    if let Some(c) = codex {
        v["codex"] = c;
    }
    Some(v.to_string().into())
}

fn prefs_line(outfit: &str) -> String {
    json!({ "type": "prefs", "outfit": outfit }).to_string()
}

/// One window of a plan (5 hours or the week): how much is used and when it resets.
#[derive(Debug, Clone, PartialEq, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct WindowIn {
    pub used_pct: f64,
    /// Epoch milliseconds.
    pub resets_at: u64,
}

/// What the island knows of one plan (Claude or Codex).
#[derive(Debug, Clone, PartialEq, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct PlanIn {
    pub five_hour: Option<WindowIn>,
    pub seven_day: Option<WindowIn>,
    pub reset_credits: Option<u32>,
    pub plan_type: Option<String>,
    /// When the numbers arrived (epoch ms).
    pub updated_at: u64,
}

/// The plan usage the island shows in its header (cap `usage`).
#[derive(Debug, Clone, PartialEq, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct UsageIn {
    pub claude: Option<PlanIn>,
    pub codex: Option<PlanIn>,
}

/// One line of a service card.
#[derive(Debug, Clone, PartialEq, Deserialize, Default)]
#[serde(default)]
pub struct ServiceItemIn {
    pub label: String,
    pub detail: String,
}

/// What one service pill shows, as the island summarises it: a headline, why (optional), up to 3 lines.
#[derive(Debug, Clone, PartialEq, Deserialize, Default)]
#[serde(default)]
pub struct ServiceIn {
    pub id: String,
    pub title: String,
    pub headline: String,
    pub reason: Option<String>,
    pub items: Vec<ServiceItemIn>,
}

/// One option of a question, as the island has it.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct OptionIn {
    pub label: String,
    #[serde(default)]
    pub description: String,
}

/// One question of an AskUserQuestion call.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionItemIn {
    pub question: String,
    pub options: Vec<OptionIn>,
    #[serde(default)]
    pub multi_select: bool,
}

/// The question Claude Code is waiting on, as the island has it (cap `answers`).
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionIn {
    pub request_id: String,
    pub session_id: String,
    pub pill_id: String,
    pub questions: Vec<QuestionItemIn>,
}

struct Question {
    request_id: String,
    fingerprint: String,
    pill_id: String,
    items: Vec<QuestionItemIn>,
    created_at: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct Session {
    pill_id: String,
    agent: String,
    state: String,
    status_text: String,
    step_index: u32,
    step_count: u32,
    updated_at: u64,
    // Not part of the v1 session: added by `detailed_line` for phones that have `details`.
    #[serde(skip)]
    steps: Vec<String>,
    #[serde(skip)]
    final_line: Option<String>,
    #[serde(skip)]
    project: Option<String>,
    #[serde(skip)]
    color: Option<String>,
    #[serde(skip)]
    files: Vec<FileIn>,
}

impl Session {
    fn same_content(&self, other: &Session) -> bool {
        Session { updated_at: 0, ..self.clone() } == Session { updated_at: 0, ..other.clone() }
    }
}

struct Approval {
    request_id: String,
    fingerprint: String,
    pill_id: String,
    tool: String,
    command: String,
    /// The command was longer than [`MAX_COMMAND_CHARS`] and the phone is shown only the start.
    truncated: bool,
    created_at: u64,
}

/// What reaches a connection's writer.
pub enum Out {
    /// One JSON line, without its newline.
    Line(Arc<str>),
    /// Tell the phone why, then close.
    Close { code: &'static str, message: &'static str },
}

struct Sub {
    id: u64,
    tx: mpsc::Sender<Out>,
    /// Set when the hub gives up on a phone that cannot keep up, so its
    /// connection can be closed (and the phone reconnect to a fresh picture)
    /// instead of staying open and silently going stale.
    evicted: Arc<AtomicBool>,
    /// The phone asked for `details` and the user's switch was on when it connected.
    details: bool,
    /// The phone asked for `answers` and the user's switch was on when it connected.
    answers: bool,
    /// The phone asked for `prefs` (the outfit Mochi wears on the computer).
    prefs: bool,
    /// The phone asked for `diffs` and the user's switch was on when it connected.
    diffs: bool,
    /// The phone asked for `usage` and the user's switch was on when it connected.
    usage: bool,
    /// The phone asked for `relay` and the relay switch was on when it connected: it is sent the new access key
    /// when the user rotates it (docs/RELAY_LINK.md section 6).
    relay: bool,
    /// The services this phone may see (the user's ticks when it connected); empty: none.
    services: Vec<String>,
    /// When this phone asked for a diff lately (ms), to keep it from flooding the island.
    diff_asks: Vec<u64>,
}

/// What a connection may have been offered.
#[derive(Debug, Clone, Default)]
pub struct Caps {
    pub details: bool,
    pub answers: bool,
    pub prefs: bool,
    pub diffs: bool,
    pub usage: bool,
    pub relay: bool,
    /// The services the user allowed for the phone (empty: the capability is not offered).
    pub services: Vec<String>,
}

#[derive(Default)]
struct Inner {
    sessions: Vec<Session>,
    approval: Option<Approval>,
    question: Option<Question>,
    /// What Mochi wears on the computer: one of [`OUTFIT_CHOICES`]; None until the island has said.
    outfit: Option<&'static str>,
    /// The last `usage` line (None: the island has nothing to say).
    usage: Option<Arc<str>>,
    /// The service cards the island has, cleaned (all of them: each phone gets only the ones its user allowed).
    services: Vec<ServiceIn>,
    subs: Vec<Sub>,
    next_sub: u64,
}

/// What became of a decision from a phone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Applied,
    /// Not the pending request (another command, or already answered).
    NoMatch,
    /// The request was pending but is older than APPROVAL_TTL.
    Late,
    /// Neither `allow` nor `deny`.
    Invalid,
    /// `allow` for a request whose command was cut to fit the phone: refused, and the request stays pending so it is answered here.
    TooLong,
}

pub struct Hub {
    host: Arc<dyn Host>,
    inner: Mutex<Inner>,
}

impl Hub {
    pub fn new(host: Arc<dyn Host>) -> Arc<Hub> {
        Arc::new(Hub { host, inner: Mutex::new(Inner::default()) })
    }

    /// The island's current picture. Sends the phones only what changed.
    pub fn publish(&self, sessions: Vec<SessionIn>, approval: Option<ApprovalIn>, now: u64) {
        let mut inner = self.inner.lock().unwrap();

        // Sessions: stamp `updatedAt` where something changed.
        let next: Vec<Session> = sessions
            .into_iter()
            .filter(|s| !s.pill_id.is_empty())
            .take(MAX_SESSIONS)
            .map(|s| {
                let mut fresh = Session {
                    state: if STATES.contains(&s.state.as_str()) { s.state } else { "idle".into() },
                    pill_id: s.pill_id,
                    agent: clip(&s.agent, 64),
                    status_text: clip(&s.status_text, MAX_TEXT_CHARS),
                    step_index: s.step_index,
                    step_count: s.step_count,
                    updated_at: now,
                    steps: clean_steps(&s.steps),
                    final_line: s.final_line.as_deref().map(|l| clip(l, MAX_TEXT_CHARS)).filter(|l| !l.trim().is_empty()),
                    project: s.project.as_deref().and_then(project_name),
                    color: s.color.filter(|c| is_color(c)),
                    files: clean_files(&s.files),
                };
                if let Some(old) = inner.sessions.iter().find(|o| o.pill_id == fresh.pill_id) {
                    if old.same_content(&fresh) {
                        fresh.updated_at = old.updated_at;
                    }
                }
                fresh
            })
            .collect();
        let sessions_changed = next != inner.sessions;
        inner.sessions = next;
        if sessions_changed {
            broadcast_sessions(&mut inner);
        }

        // The pending request: a new one replaces the old, none retracts it.
        let same = match (&inner.approval, &approval) {
            (Some(a), Some(b)) => a.request_id == b.request_id,
            (None, None) => true,
            _ => false,
        };
        if same {
            return;
        }
        if let Some(old) = inner.approval.take() {
            let line = resolved_line(&old.fingerprint);
            broadcast(&mut inner, &line);
        }
        if let Some(a) = approval.filter(|a| !a.request_id.is_empty()) {
            let tool = clip(&a.tool, 64);
            let truncated = a.command.chars().count() > MAX_COMMAND_CHARS;
            let command = clip(&a.command, MAX_COMMAND_CHARS);
            let approval = Approval {
                fingerprint: fingerprint(&a.pill_id, &a.session_id, &tool, &command, &a.request_id),
                request_id: a.request_id,
                pill_id: a.pill_id,
                tool,
                command,
                truncated,
                created_at: now,
            };
            let line = approval_line(&approval);
            inner.approval = Some(approval);
            broadcast(&mut inner, &line);
        }
    }

    /// Registers a connection that has authenticated. The returned lines bring it
    /// up to date: the sessions, then the request still waiting, if any.
    #[cfg(test)]
    pub fn subscribe(&self, tx: mpsc::Sender<Out>, now: u64, details: bool) -> (u64, Arc<AtomicBool>) {
        self.subscribe_with(tx, now, Caps { details, ..Caps::default() })
    }

    /// Like [`subscribe`], for a phone that may also have been offered `answers` and `prefs`.
    pub fn subscribe_with(&self, tx: mpsc::Sender<Out>, now: u64, caps: Caps) -> (u64, Arc<AtomicBool>) {
        let Caps { details, answers, prefs, diffs, usage, relay, services } = caps;
        let mut inner = self.inner.lock().unwrap();
        expire(&mut inner, now);
        let id = inner.next_sub;
        inner.next_sub += 1;
        let first = session_line(&inner.sessions, details, diffs);
        let _ = tx.try_send(Out::Line(first.into()));
        if let Some(a) = &inner.approval {
            let _ = tx.try_send(Out::Line(approval_line(a).into()));
        }
        if answers {
            if let Some(q) = &inner.question {
                let _ = tx.try_send(Out::Line(question_line(q).into()));
            }
        }
        if prefs {
            if let Some(o) = inner.outfit {
                let _ = tx.try_send(Out::Line(prefs_line(o).into()));
            }
        }
        if !services.is_empty() {
            if let Some(line) = services_line(&inner.services, &services) {
                let _ = tx.try_send(Out::Line(line));
            }
        }
        if usage {
            if let Some(line) = &inner.usage {
                let _ = tx.try_send(Out::Line(line.clone()));
            }
        }
        let evicted = Arc::new(AtomicBool::new(false));
        inner.subs.push(Sub { id, tx, evicted: evicted.clone(), details, answers, prefs, diffs, usage, relay, services, diff_asks: Vec::new() });
        (id, evicted)
    }

    pub fn unsubscribe(&self, id: u64) {
        self.inner.lock().unwrap().subs.retain(|s| s.id != id);
    }

    /// The access key was rotated: phones that negotiated `relay` are told the new one, inside the authenticated
    /// channel, so they follow without scanning again. Returns how many were told.
    pub fn send_relay_access(&self, access: &str) -> usize {
        let line: Arc<str> = json!({ "type": "relayAccess", "access": access }).to_string().into();
        let mut told = 0;
        self.inner.lock().unwrap().subs.retain(|s| {
            if !s.relay {
                return true;
            }
            let kept = s.tx.try_send(Out::Line(line.clone())).is_ok();
            if kept {
                told += 1;
            } else {
                s.evicted.store(true, Ordering::SeqCst);
            }
            kept
        });
        told
    }

    /// Unpaired or switched off: every connection is told and closed.
    pub fn kick_all(&self, code: &'static str, message: &'static str) {
        let subs = std::mem::take(&mut self.inner.lock().unwrap().subs);
        for s in subs {
            let _ = s.tx.try_send(Out::Close { code, message });
        }
    }

    pub fn clients(&self) -> usize {
        self.inner.lock().unwrap().subs.len()
    }

    /// A phone's answer. Applied only for the request that is still pending.
    pub fn decide(&self, fingerprint: &str, decision: &str, now: u64) -> Outcome {
        let allow = match decision {
            "allow" => true,
            "deny" => false,
            _ => return Outcome::Invalid,
        };
        let request_id = {
            let mut inner = self.inner.lock().unwrap();
            let late = match &inner.approval {
                Some(a) if constant_eq(a.fingerprint.as_bytes(), fingerprint.as_bytes()) => {
                    // A command the phone could not show in full is never allowed from the phone, whatever the phone says.
                    if allow && a.truncated {
                        return Outcome::TooLong;
                    }
                    now.saturating_sub(a.created_at) > APPROVAL_TTL_MS
                }
                _ => return Outcome::NoMatch,
            };
            // Taken in every case: a request is answered once, or dismissed.
            let a = inner.approval.take().expect("checked above");
            let line = resolved_line(&a.fingerprint);
            broadcast(&mut inner, &line);
            if late {
                return Outcome::Late;
            }
            a.request_id
        };
        // Outside the lock: the host answers the agent and touches the island.
        self.host.decide(&request_id, allow);
        Outcome::Applied
    }
}

impl Hub {
    /// What the island's service pills show. Each phone is sent only the services its user allowed, and a phone
    /// whose own cards did not change is sent nothing.
    pub fn publish_services(&self, cards: Vec<ServiceIn>) {
        let cleaned = clean_services(cards);
        let mut inner = self.inner.lock().unwrap();
        if cleaned == inner.services {
            return;
        }
        let old = std::mem::replace(&mut inner.services, cleaned);
        let new = inner.services.clone();
        inner.subs.retain(|s| {
            if s.services.is_empty() {
                return true;
            }
            let before = services_line(&old, &s.services);
            let after = services_line(&new, &s.services);
            if before == after {
                return true;
            }
            // Nothing left to show: an empty list takes the cards away.
            let line = after.unwrap_or_else(|| json!({ "type": "services", "services": [] }).to_string().into());
            let kept = s.tx.try_send(Out::Line(line)).is_ok();
            if !kept {
                s.evicted.store(true, Ordering::SeqCst);
            }
            kept
        });
    }

    /// The plan usage the island shows (percentages and reset times, nothing else). Only phones that have `usage`
    /// hear of it, and a new one at once; two identical pictures are sent once.
    pub fn publish_usage(&self, usage: UsageIn) {
        let line = usage_line(&usage);
        let mut inner = self.inner.lock().unwrap();
        if inner.usage.as_deref() == line.as_deref() {
            return;
        }
        inner.usage = line.clone();
        let shared: Arc<str> = line.unwrap_or_else(|| json!({ "type": "usage" }).to_string().into());
        inner.subs.retain(|s| {
            if !s.usage {
                return true;
            }
            let kept = s.tx.try_send(Out::Line(shared.clone())).is_ok();
            if !kept {
                s.evicted.store(true, Ordering::SeqCst);
            }
            kept
        });
    }

    /// A phone asked for a file's diff. Passed on to the island only if the phone has `diffs` and is not asking too often.
    pub fn request_diff(&self, sub_id: u64, pill_id: &str, file_id: u64, now: u64) {
        {
            let mut inner = self.inner.lock().unwrap();
            let Some(sub) = inner.subs.iter_mut().find(|s| s.id == sub_id && s.diffs) else { return };
            sub.diff_asks.retain(|t| now.saturating_sub(*t) < 10_000);
            if sub.diff_asks.len() >= DIFF_ASKS_PER_10S {
                return;
            }
            sub.diff_asks.push(now);
        }
        // Outside the lock: the host asks the island.
        self.host.get_diff(sub_id, pill_id, file_id);
    }

    /// The island's answer to [`request_diff`]: sent to that phone only (and only if it still has `diffs`), cut to
    /// the limits whatever the island sent, in parts that each fit a line.
    pub fn send_diff(&self, sub_id: u64, diff: DiffIn) {
        let mut inner = self.inner.lock().unwrap();
        let Some(sub) = inner.subs.iter().find(|s| s.id == sub_id && s.diffs) else { return };
        let truncated = diff.lines.len() > MAX_DIFF_LINES;
        let rows: Vec<serde_json::Value> = diff
            .lines
            .iter()
            .take(MAX_DIFF_LINES)
            .map(|(k, text)| {
                let kind = match k.as_str() {
                    "+" | "-" | "@" => k.as_str(),
                    _ => " ",
                };
                json!([kind, clip(text, MAX_DIFF_LINE_CHARS)])
            })
            .collect();
        let parts: Vec<&[serde_json::Value]> = if rows.is_empty() { vec![&[][..]] } else { rows.chunks(PART_LINES).collect() };
        let total = parts.len();
        let name = clean_files(&[FileIn { name: diff.name.clone(), ..FileIn::default() }]).first().map(|f| f.name.clone()).unwrap_or_default();
        let mut ok = true;
        for (i, part) in parts.iter().enumerate() {
            let line = json!({
                "type": "diff", "pillId": clip(&diff.pill_id, 64), "fileId": diff.file_id, "name": name,
                "added": diff.added, "removed": diff.removed, "tooLarge": diff.too_large, "gone": diff.gone,
                "truncated": truncated, "part": i, "parts": total, "lines": part,
            })
            .to_string();
            ok &= sub.tx.try_send(Out::Line(line.into())).is_ok();
        }
        if !ok {
            sub.evicted.store(true, Ordering::SeqCst);
            inner.subs.retain(|s| s.id != sub_id);
        }
    }

    /// What Mochi wears on the computer ("auto" or an outfit, see [`OUTFIT_CHOICES`]); anything else is ignored.
    /// Only phones that have `prefs` hear of it, and a new one at once.
    pub fn publish_outfit(&self, outfit: &str) {
        let Some(choice) = OUTFIT_CHOICES.iter().find(|c| **c == outfit) else { return };
        let mut inner = self.inner.lock().unwrap();
        if inner.outfit == Some(*choice) {
            return;
        }
        inner.outfit = Some(*choice);
        let shared: Arc<str> = prefs_line(choice).into();
        inner.subs.retain(|s| {
            if !s.prefs {
                return true;
            }
            let kept = s.tx.try_send(Out::Line(shared.clone())).is_ok();
            if !kept {
                s.evicted.store(true, Ordering::SeqCst);
            }
            kept
        });
    }

    /// The question waiting on the island (None: none). Only phones that have `answers` hear of it. One that
    /// does not fit the limits, or whose options cannot be told apart, stays on the island.
    pub fn publish_question(&self, question: Option<QuestionIn>, now: u64) {
        let mut inner = self.inner.lock().unwrap();
        let usable = question.filter(|q| !q.request_id.is_empty() && fits_the_limits(&q.questions));
        let same = match (&inner.question, &usable) {
            (Some(a), Some(b)) => a.request_id == b.request_id,
            (None, None) => true,
            _ => false,
        };
        if same {
            return;
        }
        if let Some(old) = inner.question.take() {
            let line = resolved_line(&old.fingerprint);
            broadcast_to_answers(&mut inner, &line);
        }
        if let Some(q) = usable {
            let texts: Vec<&str> = q.questions.iter().map(|i| i.question.as_str()).collect();
            let question = Question {
                fingerprint: fingerprint(&q.pill_id, &q.session_id, "AskUserQuestion", &texts.join("\n"), &q.request_id),
                request_id: q.request_id,
                pill_id: q.pill_id,
                items: q.questions,
                created_at: now,
            };
            let line = question_line(&question);
            inner.question = Some(question);
            broadcast_to_answers(&mut inner, &line);
        }
    }

    /// A phone's answer to the question that is still pending. `picks` has one list of labels per question, in order.
    /// It is applied only if every label is exactly one of that question's options, one label for a single choice and
    /// at least one (each at most once) for a multiple choice; anything else changes nothing.
    pub fn answer(&self, fingerprint: &str, picks: &[Vec<String>], now: u64) -> Outcome {
        let (request_id, answers) = {
            let mut inner = self.inner.lock().unwrap();
            let (late, answers) = match &inner.question {
                Some(q) if constant_eq(q.fingerprint.as_bytes(), fingerprint.as_bytes()) => {
                    let Some(answers) = build_answers(&q.items, picks) else { return Outcome::Invalid };
                    (now.saturating_sub(q.created_at) > APPROVAL_TTL_MS, answers)
                }
                _ => return Outcome::NoMatch,
            };
            // Taken in every case: a question is answered once, or dismissed.
            let q = inner.question.take().expect("checked above");
            let line = resolved_line(&q.fingerprint);
            broadcast_to_answers(&mut inner, &line);
            if late {
                return Outcome::Late;
            }
            (q.request_id, answers)
        };
        self.host.answer(&request_id, &answers);
        Outcome::Applied
    }
}

fn fits_the_limits(items: &[QuestionItemIn]) -> bool {
    !items.is_empty()
        && items.len() <= MAX_QUESTIONS
        && items.iter().all(|i| {
            let labels: Vec<&str> = i.options.iter().map(|o| o.label.as_str()).collect();
            !i.question.trim().is_empty()
                && i.question.chars().count() <= MAX_QUESTION_CHARS
                && !labels.is_empty()
                && labels.len() <= MAX_OPTIONS
                && labels.iter().all(|l| !l.trim().is_empty() && l.chars().count() <= MAX_LABEL_CHARS)
                && i.options.iter().all(|o| o.description.chars().count() <= MAX_DESCRIPTION_CHARS)
                // two options with the same label could not be told apart in an answer
                && labels.iter().enumerate().all(|(n, l)| !labels[..n].contains(l))
        })
}

fn build_answers(items: &[QuestionItemIn], picks: &[Vec<String>]) -> Option<serde_json::Map<String, serde_json::Value>> {
    if picks.len() != items.len() {
        return None;
    }
    let mut out = serde_json::Map::new();
    for (item, chosen) in items.iter().zip(picks) {
        if chosen.is_empty() || chosen.len() > item.options.len() || (!item.multi_select && chosen.len() != 1) {
            return None;
        }
        for (n, label) in chosen.iter().enumerate() {
            if !item.options.iter().any(|o| &o.label == label) || chosen[..n].contains(label) {
                return None;
            }
        }
        let value = if item.multi_select { json!(chosen) } else { json!(chosen[0]) };
        out.insert(item.question.clone(), value);
    }
    Some(out)
}

fn question_line(q: &Question) -> String {
    let questions: Vec<serde_json::Value> = q
        .items
        .iter()
        .map(|i| {
            json!({
                "question": i.question, "multiSelect": i.multi_select,
                "options": i.options.iter().map(|o| json!({ "label": o.label, "description": o.description })).collect::<Vec<_>>(),
            })
        })
        .collect();
    json!({ "type": "question", "pillId": q.pill_id, "fingerprint": q.fingerprint, "createdAt": q.created_at, "questions": questions }).to_string()
}

/// To the phones that have `answers` only: the others never learn a question existed.
fn broadcast_to_answers(inner: &mut Inner, line: &str) {
    let shared: Arc<str> = line.into();
    inner.subs.retain(|s| {
        if !s.answers {
            return true;
        }
        let kept = s.tx.try_send(Out::Line(shared.clone())).is_ok();
        if !kept {
            s.evicted.store(true, Ordering::SeqCst);
        }
        kept
    });
}

fn expire(inner: &mut Inner, now: u64) {
    if inner.question.as_ref().is_some_and(|q| now.saturating_sub(q.created_at) > APPROVAL_TTL_MS) {
        let q = inner.question.take().expect("checked above");
        let line = resolved_line(&q.fingerprint);
        broadcast_to_answers(inner, &line);
    }
    if inner.approval.as_ref().is_some_and(|a| now.saturating_sub(a.created_at) > APPROVAL_TTL_MS) {
        let a = inner.approval.take().expect("checked above");
        let line = resolved_line(&a.fingerprint);
        broadcast(inner, &line);
    }
}

/// Sends one line to every subscriber; one that cannot keep up (a full queue) or
/// has gone is dropped rather than waited for.
fn broadcast(inner: &mut Inner, line: &str) {
    let shared: Arc<str> = line.into();
    inner.subs.retain(|s| {
        let kept = s.tx.try_send(Out::Line(shared.clone())).is_ok();
        if !kept {
            s.evicted.store(true, Ordering::SeqCst);
        }
        kept
    });
}

fn sessions_line(sessions: &[Session]) -> String {
    json!({ "type": "sessions", "sessions": sessions }).to_string()
}

/// The sessions with their details, for a phone that has the capability. Same fields as the v1 line plus
/// `steps`, `finalLine`, `project` and `color` where there is something to say. Steps are dropped from the
/// oldest first (and then from all sessions) until the line fits.
fn detailed_line(sessions: &[Session], details: bool, diffs: bool) -> String {
    let mut keep = MAX_STEPS;
    loop {
        let list: Vec<serde_json::Value> = sessions
            .iter()
            .map(|s| {
                let mut v = serde_json::to_value(s).unwrap_or_default();
                if details {
                    let steps = &s.steps[s.steps.len().saturating_sub(keep)..];
                    if !steps.is_empty() {
                        v["steps"] = json!(steps);
                    }
                    if let Some(l) = &s.final_line {
                        v["finalLine"] = json!(l);
                    }
                    if let Some(p) = &s.project {
                        v["project"] = json!(p);
                    }
                    if let Some(c) = &s.color {
                        v["color"] = json!(c);
                    }
                }
                if diffs && !s.files.is_empty() {
                    v["files"] = json!(s.files.iter().map(file_json).collect::<Vec<_>>());
                }
                v
            })
            .collect();
        let line = json!({ "type": "sessions", "sessions": list }).to_string();
        if line.len() <= DETAILS_LINE_BUDGET || keep == 0 {
            return line;
        }
        keep /= 2;
    }
}

fn file_json(f: &FileIn) -> serde_json::Value {
    let mut v = json!({ "id": f.id, "name": f.name, "added": f.added, "removed": f.removed });
    if f.too_large {
        v["tooLarge"] = json!(true);
    }
    if f.is_new {
        v["isNew"] = json!(true);
    }
    v
}

/// The `sessions` line a phone gets: the v1 line, or the one with what it was offered.
fn session_line(sessions: &[Session], details: bool, diffs: bool) -> String {
    if details || diffs {
        detailed_line(sessions, details, diffs)
    } else {
        sessions_line(sessions)
    }
}

/// Every phone gets the picture it asked for: the v1 line, or the one with details and/or file changes.
fn broadcast_sessions(inner: &mut Inner) {
    let mut lines: std::collections::HashMap<(bool, bool), Arc<str>> = std::collections::HashMap::new();
    let sessions = std::mem::take(&mut inner.sessions);
    for s in &inner.subs {
        lines.entry((s.details, s.diffs)).or_insert_with(|| session_line(&sessions, s.details, s.diffs).into());
    }
    inner.sessions = sessions;
    inner.subs.retain(|s| {
        let line = lines[&(s.details, s.diffs)].clone();
        let kept = s.tx.try_send(Out::Line(line)).is_ok();
        if !kept {
            s.evicted.store(true, Ordering::SeqCst);
        }
        kept
    });
}

/// At most MAX_FILES files with a name; only the file's name, cut, never a path.
fn clean_files(files: &[FileIn]) -> Vec<FileIn> {
    let kept: Vec<FileIn> = files
        .iter()
        .filter_map(|f| {
            let last = f.name.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next().unwrap_or("").trim();
            let name: String = last.chars().filter(|c| !c.is_control()).take(MAX_FILE_NAME_CHARS).collect();
            (!name.is_empty()).then(|| FileIn { name, ..f.clone() })
        })
        .collect();
    kept[kept.len().saturating_sub(MAX_FILES)..].to_vec()
}

/// The last MAX_STEPS non-empty steps, each cut to MAX_TEXT_CHARS.
fn clean_steps(steps: &[String]) -> Vec<String> {
    let kept: Vec<String> = steps.iter().filter(|s| !s.trim().is_empty()).map(|s| clip(s, MAX_TEXT_CHARS)).collect();
    kept[kept.len().saturating_sub(MAX_STEPS)..].to_vec()
}

/// Only the last segment of a folder path: never a path, never anything that could hold a user name or
/// a drive. None when nothing usable is left.
pub fn project_name(path: &str) -> Option<String> {
    let last = path.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next().unwrap_or("");
    let clean: String = last.chars().filter(|c| !c.is_control()).collect();
    let clean = clip(clean.trim(), MAX_PROJECT_CHARS);
    (!clean.is_empty() && clean != "." && clean != "..").then_some(clean)
}

/// "#RRGGBB" only.
fn is_color(c: &str) -> bool {
    c.len() == 7 && c.starts_with('#') && c[1..].bytes().all(|b| b.is_ascii_hexdigit())
}

fn approval_line(a: &Approval) -> String {
    json!({
        "type": "approval", "pillId": a.pill_id, "fingerprint": a.fingerprint,
        "tool": a.tool, "command": a.command, "truncated": a.truncated, "createdAt": a.created_at,
    })
    .to_string()
}

fn resolved_line(fingerprint: &str) -> String {
    json!({ "type": "approvalResolved", "fingerprint": fingerprint }).to_string()
}

/// The first `max` characters, on a character boundary.
fn clip(s: &str, max: usize) -> String {
    match s.char_indices().nth(max) {
        Some((i, _)) => s[..i].to_string(),
        None => s.to_string(),
    }
}

/// The Mac's `ApprovalRelay.fingerprint`: lowercase hex SHA-256 of the fields
/// joined by U+001F. `input_key` is the island's request id, so two requests for
/// the same command still have different fingerprints and a late decision for the
/// first can never answer the second.
pub fn fingerprint(pill_id: &str, session_id: &str, tool: &str, command: &str, input_key: &str) -> String {
    let joined = [pill_id, session_id, tool, command, input_key].join("\u{1f}");
    hex(digest::digest(&digest::SHA256, joined.as_bytes()).as_ref())
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Constant-time equality, so a token or fingerprint cannot be guessed byte by byte.
pub fn constant_eq(a: &[u8], b: &[u8]) -> bool {
    // The length is not secret (tokens and fingerprints have a fixed size).
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex as StdMutex;

    #[derive(Default)]
    struct Recorder(StdMutex<Vec<(String, bool)>>, StdMutex<Vec<(u64, String, u64)>>);
    impl Host for Recorder {
        fn decide(&self, request_id: &str, allow: bool) {
            self.0.lock().unwrap().push((request_id.to_string(), allow));
        }
        fn get_diff(&self, sub_id: u64, pill_id: &str, file_id: u64) {
            self.1.lock().unwrap().push((sub_id, pill_id.to_string(), file_id));
        }
    }

    fn hub() -> (Arc<Hub>, Arc<Recorder>) {
        let rec = Arc::new(Recorder::default());
        (Hub::new(rec.clone()), rec)
    }

    fn approval(request: &str, command: &str) -> ApprovalIn {
        ApprovalIn {
            request_id: request.into(),
            session_id: "s1".into(),
            pill_id: "integration_claude".into(),
            tool: "Bash".into(),
            command: command.into(),
        }
    }

    fn session(state: &str) -> SessionIn {
        SessionIn { pill_id: "integration_claude".into(), agent: "Claude Code".into(), state: state.into(), ..Default::default() }
    }

    fn drain(rx: &mut mpsc::Receiver<Out>) -> Vec<serde_json::Value> {
        let mut v = Vec::new();
        while let Ok(o) = rx.try_recv() {
            if let Out::Line(l) = o {
                v.push(serde_json::from_str(&l).unwrap());
            }
        }
        v
    }

    fn fp_of(hub: &Hub) -> String {
        hub.inner.lock().unwrap().approval.as_ref().unwrap().fingerprint.clone()
    }

    // ── session details (cap `details`) ─────────────────────────────────────────────

    fn rich(pill: &str) -> SessionIn {
        SessionIn {
            pill_id: pill.into(),
            agent: "Claude Code".into(),
            state: "working".into(),
            status_text: "Editing".into(),
            step_index: 1,
            step_count: 3,
            steps: vec!["Read · a.rs".into(), "Edit · a.rs".into()],
            final_line: Some("All done".into()),
            project: Some("/home/me/work/coucou".into()),
            color: Some("#2DD4BF".into()),
            ..Default::default()
        }
    }

    fn first_sessions(rx: &mut mpsc::Receiver<Out>) -> Vec<serde_json::Value> {
        let lines = drain(rx);
        lines[0]["sessions"].as_array().unwrap().clone()
    }

    #[test]
    fn a_phone_without_details_gets_exactly_the_v1_fields() {
        let (hub, _) = hub();
        hub.publish(vec![rich("integration_claude")], None, 1_000);
        let (tx, mut rx) = mpsc::channel(8);
        hub.subscribe(tx, 1_001, false);
        let s = &first_sessions(&mut rx)[0];
        let mut keys: Vec<&str> = s.as_object().unwrap().keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(keys, ["agent", "pillId", "state", "statusText", "stepCount", "stepIndex", "updatedAt"]);
    }

    #[test]
    fn a_phone_with_details_gets_them_and_the_other_phone_does_not() {
        let (hub, _) = hub();
        let (tx1, mut plain) = mpsc::channel(8);
        let (tx2, mut rich_rx) = mpsc::channel(8);
        hub.subscribe(tx1, 0, false);
        hub.subscribe(tx2, 0, true);
        drain(&mut plain);
        drain(&mut rich_rx);
        hub.publish(vec![rich("integration_claude")], None, 1_000);
        let p = &first_sessions(&mut plain)[0];
        let r = &first_sessions(&mut rich_rx)[0];
        assert!(p.get("steps").is_none() && p.get("finalLine").is_none() && p.get("project").is_none() && p.get("color").is_none());
        assert_eq!(r["steps"], json!(["Read · a.rs", "Edit · a.rs"]));
        assert_eq!(r["finalLine"], "All done");
        assert_eq!(r["project"], "coucou");
        assert_eq!(r["color"], "#2DD4BF");
        // and the shared fields are the same for both
        assert_eq!(p["statusText"], r["statusText"]);
    }

    #[test]
    fn a_new_phone_with_details_is_brought_up_to_date_with_them() {
        let (hub, _) = hub();
        hub.publish(vec![rich("integration_claude")], None, 1_000);
        let (tx, mut rx) = mpsc::channel(8);
        hub.subscribe(tx, 1_001, true);
        assert_eq!(first_sessions(&mut rx)[0]["project"], "coucou");
    }

    #[test]
    fn a_change_in_details_alone_is_sent() {
        let (hub, _) = hub();
        let (tx, mut rx) = mpsc::channel(8);
        hub.subscribe(tx, 0, true);
        drain(&mut rx);
        hub.publish(vec![rich("a")], None, 1_000);
        assert_eq!(drain(&mut rx).len(), 1);
        hub.publish(vec![rich("a")], None, 2_000);
        assert!(drain(&mut rx).is_empty(), "same picture: nothing sent");
        let mut changed = rich("a");
        changed.final_line = Some("Another".into());
        hub.publish(vec![changed], None, 3_000);
        assert_eq!(drain(&mut rx).len(), 1);
    }

    #[test]
    fn only_the_last_twenty_steps_are_kept_each_cut_short_and_empties_dropped() {
        let mut s = rich("a");
        s.steps = (0..30).map(|i| format!("step {i}")).chain([String::new(), "   ".into(), "x".repeat(500)]).collect();
        let steps = clean_steps(&s.steps);
        assert_eq!(steps.len(), MAX_STEPS);
        assert_eq!(steps.last().unwrap().chars().count(), MAX_TEXT_CHARS);
        assert_eq!(steps[0], "step 11");
        assert!(clean_steps(&[]).is_empty());
    }

    #[test]
    fn the_project_is_a_folder_name_never_a_path() {
        assert_eq!(project_name("/home/me/work/coucou").as_deref(), Some("coucou"));
        assert_eq!(project_name("/home/me/work/coucou/").as_deref(), Some("coucou"));
        assert_eq!(project_name("C:\\Users\\me\\proj").as_deref(), Some("proj"));
        assert_eq!(project_name("C:\\Users\\me\\proj\\").as_deref(), Some("proj"));
        assert_eq!(project_name("proj").as_deref(), Some("proj"));
        assert_eq!(project_name("/a/b\tc\n").as_deref(), Some("bc"));
        for none in ["", "/", "\\", "..", "/a/..", ".", "   "] {
            assert_eq!(project_name(none), None, "{none:?}");
        }
        let long = project_name(&format!("/x/{}", "é".repeat(200))).unwrap();
        assert_eq!(long.chars().count(), MAX_PROJECT_CHARS);
        for p in ["/home/me/secret/app", "C:\\Users\\me\\app", "relative/dir/app"] {
            let name = project_name(p).unwrap();
            assert!(!name.contains('/') && !name.contains('\\') && name == "app");
        }
    }

    #[test]
    fn only_a_six_digit_hex_colour_is_passed_on() {
        for ok in ["#8AB4F8", "#000000", "#abcdef"] {
            assert!(is_color(ok), "{ok}");
        }
        for bad in ["", "red", "8AB4F8", "#12", "#GGGGGG", "#12345678", "#8AB4F8;", "url(x)"] {
            assert!(!is_color(bad), "{bad}");
        }
        let (hub, _) = hub();
        let mut s = rich("a");
        s.color = Some("red".into());
        hub.publish(vec![s], None, 1_000);
        let (tx, mut rx) = mpsc::channel(8);
        hub.subscribe(tx, 1_001, true);
        assert!(first_sessions(&mut rx)[0].get("color").is_none());
    }

    #[test]
    fn sixteen_sessions_of_full_steps_still_fit_in_one_line() {
        let big = |i: usize| SessionIn {
            steps: (0..30).map(|n| format!("{n}: {}", "é".repeat(300))).collect(),
            final_line: Some("f".repeat(400)),
            ..rich(&format!("agent_{i}"))
        };
        let sessions: Vec<SessionIn> = (0..20).map(big).collect();
        let (hub, _) = hub();
        hub.publish(sessions, None, 1_000);
        let (tx, mut rx) = mpsc::channel(8);
        hub.subscribe(tx, 1_001, true);
        let Out::Line(line) = rx.try_recv().unwrap() else { panic!() };
        assert!(line.len() <= DETAILS_LINE_BUDGET, "{} bytes", line.len());
        assert!(line.len() < 64 * 1024);
        let v: serde_json::Value = serde_json::from_str(&line).unwrap();
        let list = v["sessions"].as_array().unwrap();
        assert_eq!(list.len(), MAX_SESSIONS);
        // the newest steps are the ones kept
        let steps = list[0]["steps"].as_array().unwrap();
        assert!(!steps.is_empty() && steps.len() < MAX_STEPS);
        assert!(steps.last().unwrap().as_str().unwrap().starts_with("29: "));
        // and the short fields are all still there
        assert_eq!(list[15]["project"], "coucou");
    }

    #[test]
    fn the_fingerprint_is_the_macs_derivation() {
        // Computed independently of this code:
        //   printf 'integration_claude\x1fs1\x1fBash\x1fnpm test\x1fr1' | sha256sum
        assert_eq!(
            fingerprint("integration_claude", "s1", "Bash", "npm test", "r1"),
            "fa8a3bd8b520efb235b0d275403779ce580d2acbb934f4874f222f434b639c54"
        );
    }

    #[test]
    fn a_command_longer_than_the_phone_shows_is_flagged_and_cannot_be_allowed_from_the_phone() {
        for len in [MAX_COMMAND_CHARS + 1, 10_000] {
            let (hub, rec) = hub();
            let (tx, mut rx) = mpsc::channel(16);
            hub.subscribe(tx, 0, false);
            drain(&mut rx);
            let command = format!("{}{}", "a".repeat(MAX_COMMAND_CHARS - 1), "é".repeat(len - MAX_COMMAND_CHARS + 1));
            hub.publish(vec![], Some(approval("r1", &command)), 1_000);
            let line = drain(&mut rx).into_iter().find(|l| l["type"] == "approval").expect("the approval is sent");
            assert_eq!(line["truncated"], true, "{len} characters");
            assert_eq!(line["command"].as_str().unwrap().chars().count(), MAX_COMMAND_CHARS);
            let fp = fp_of(&hub);
            // Allow is refused, whatever the phone says; nothing reaches the agent and the request stays pending.
            assert_eq!(hub.decide(&fp, "allow", 2_000), Outcome::TooLong);
            assert!(rec.0.lock().unwrap().is_empty());
            assert_eq!(fp_of(&hub), fp);
            // Deny is always possible, and so is answering on the computer.
            assert_eq!(hub.decide(&fp, "deny", 2_100), Outcome::Applied);
            assert_eq!(*rec.0.lock().unwrap(), vec![("r1".to_string(), false)]);
        }
    }

    #[test]
    fn a_command_that_fits_is_not_flagged_and_can_be_allowed() {
        for len in [0, 1, MAX_COMMAND_CHARS] {
            let (hub, rec) = hub();
            let (tx, mut rx) = mpsc::channel(16);
            hub.subscribe(tx, 0, false);
            drain(&mut rx);
            hub.publish(vec![], Some(approval("r1", &"é".repeat(len))), 1_000);
            let line = drain(&mut rx).into_iter().find(|l| l["type"] == "approval").unwrap();
            assert_eq!(line["truncated"], false, "{len} characters");
            assert_eq!(hub.decide(&fp_of(&hub), "allow", 2_000), Outcome::Applied);
            assert_eq!(rec.0.lock().unwrap().len(), 1);
        }
    }

    #[test]
    fn a_phone_that_connects_later_is_also_told_the_command_is_cut() {
        let (hub, _rec) = hub();
        hub.publish(vec![], Some(approval("r1", &"x".repeat(10_000))), 1_000);
        let (tx, mut rx) = mpsc::channel(16);
        hub.subscribe(tx, 1_001, false);
        let line = drain(&mut rx).into_iter().find(|l| l["type"] == "approval").expect("the pending request is offered");
        assert_eq!(line["truncated"], true);
    }

    #[test]
    fn a_matching_decision_is_applied_once() {
        let (hub, rec) = hub();
        hub.publish(vec![], Some(approval("r1", "npm test")), 1_000);
        let fp = fp_of(&hub);
        assert_eq!(hub.decide(&fp, "allow", 2_000), Outcome::Applied);
        assert_eq!(*rec.0.lock().unwrap(), vec![("r1".to_string(), true)]);
        // The second answer, from the same or another phone, finds nothing pending.
        assert_eq!(hub.decide(&fp, "deny", 2_001), Outcome::NoMatch);
        assert_eq!(rec.0.lock().unwrap().len(), 1);
    }

    #[test]
    fn a_fingerprint_that_does_not_match_changes_nothing() {
        let (hub, rec) = hub();
        hub.publish(vec![], Some(approval("r1", "npm test")), 1_000);
        // The same command asked again later is another request: its fingerprint differs.
        let other = fingerprint("integration_claude", "s1", "Bash", "npm test", "r2");
        assert_eq!(hub.decide(&other, "allow", 1_500), Outcome::NoMatch);
        assert_eq!(hub.decide("", "allow", 1_500), Outcome::NoMatch);
        assert_eq!(hub.decide(&"0".repeat(64), "allow", 1_500), Outcome::NoMatch);
        assert!(rec.0.lock().unwrap().is_empty());
        // The real one is still pending afterwards.
        assert_eq!(hub.decide(&fp_of(&hub), "deny", 1_600), Outcome::Applied);
    }

    #[test]
    fn a_decision_for_a_replaced_request_is_ignored() {
        let (hub, rec) = hub();
        hub.publish(vec![], Some(approval("r1", "rm -rf build")), 1_000);
        let first = fp_of(&hub);
        hub.publish(vec![], Some(approval("r2", "ls")), 2_000);
        assert_eq!(hub.decide(&first, "allow", 2_100), Outcome::NoMatch);
        assert!(rec.0.lock().unwrap().is_empty());
    }

    #[test]
    fn a_decision_after_the_island_answered_is_ignored() {
        let (hub, rec) = hub();
        hub.publish(vec![], Some(approval("r1", "npm test")), 1_000);
        let fp = fp_of(&hub);
        // Answered on the desktop: the island publishes no request any more.
        hub.publish(vec![], None, 3_000);
        assert_eq!(hub.decide(&fp, "allow", 3_500), Outcome::NoMatch);
        assert!(rec.0.lock().unwrap().is_empty());
    }

    #[test]
    fn a_late_decision_is_ignored_and_the_request_dismissed() {
        let (hub, rec) = hub();
        hub.publish(vec![], Some(approval("r1", "npm test")), 1_000);
        let fp = fp_of(&hub);
        assert_eq!(hub.decide(&fp, "allow", 1_000 + APPROVAL_TTL_MS + 1), Outcome::Late);
        assert!(rec.0.lock().unwrap().is_empty());
        assert_eq!(hub.decide(&fp, "allow", 1_000 + APPROVAL_TTL_MS + 2), Outcome::NoMatch);
    }

    #[test]
    fn exactly_at_the_limit_is_still_in_time() {
        let (hub, rec) = hub();
        hub.publish(vec![], Some(approval("r1", "npm test")), 1_000);
        assert_eq!(hub.decide(&fp_of(&hub), "allow", 1_000 + APPROVAL_TTL_MS), Outcome::Applied);
        assert_eq!(rec.0.lock().unwrap().len(), 1);
    }

    #[test]
    fn only_allow_and_deny_exist() {
        let (hub, rec) = hub();
        hub.publish(vec![], Some(approval("r1", "npm test")), 1_000);
        let fp = fp_of(&hub);
        for odd in ["always", "ALLOW", "", "allow ", "yes"] {
            assert_eq!(hub.decide(&fp, odd, 1_100), Outcome::Invalid, "{odd:?}");
        }
        assert!(rec.0.lock().unwrap().is_empty());
        // Still pending after the refused attempts.
        assert_eq!(hub.decide(&fp, "deny", 1_200), Outcome::Applied);
        assert_eq!(rec.0.lock().unwrap()[0], ("r1".to_string(), false));
    }

    #[test]
    fn phones_are_told_what_changed_and_only_that() {
        let (hub, _) = hub();
        let (tx, mut rx) = mpsc::channel(16);
        hub.publish(vec![session("working")], None, 1_000);
        hub.subscribe(tx, 1_001, false);
        let first = drain(&mut rx);
        assert_eq!(first.len(), 1);
        assert_eq!(first[0]["type"], "sessions");
        assert_eq!(first[0]["sessions"][0]["updatedAt"], 1_000);

        // Nothing changed: nothing sent, and `updatedAt` stays.
        hub.publish(vec![session("working")], None, 5_000);
        assert!(drain(&mut rx).is_empty());

        hub.publish(vec![session("finished")], None, 6_000);
        let next = drain(&mut rx);
        assert_eq!(next[0]["sessions"][0]["state"], "finished");
        assert_eq!(next[0]["sessions"][0]["updatedAt"], 6_000);

        hub.publish(vec![session("finished")], Some(approval("r1", "ls")), 7_000);
        let a = drain(&mut rx);
        assert_eq!(a.len(), 1);
        assert_eq!(a[0]["type"], "approval");
        assert_eq!(a[0]["command"], "ls");
        assert_eq!(a[0]["createdAt"], 7_000);
        let fp = a[0]["fingerprint"].as_str().unwrap().to_string();

        hub.publish(vec![session("finished")], None, 8_000);
        let gone = drain(&mut rx);
        assert_eq!(gone[0]["type"], "approvalResolved");
        assert_eq!(gone[0]["fingerprint"], fp);
    }

    #[test]
    fn a_phone_that_connects_late_still_sees_the_pending_request() {
        let (hub, _) = hub();
        hub.publish(vec![session("approval")], Some(approval("r1", "ls")), 1_000);
        let (tx, mut rx) = mpsc::channel(16);
        hub.subscribe(tx, 2_000, false);
        let lines = drain(&mut rx);
        assert_eq!(lines.iter().map(|l| l["type"].as_str().unwrap()).collect::<Vec<_>>(), ["sessions", "approval"]);
        // A request already past its time is not offered.
        let (tx, mut rx) = mpsc::channel(16);
        hub.subscribe(tx, 1_000 + APPROVAL_TTL_MS + 1, false);
        assert_eq!(drain(&mut rx).iter().filter(|l| l["type"] == "approval").count(), 0);
    }

    #[test]
    fn what_the_island_sends_is_bounded_and_cleaned() {
        let (hub, _) = hub();
        let (tx, mut rx) = mpsc::channel(16);
        hub.subscribe(tx, 0, false);
        drain(&mut rx);
        let many: Vec<SessionIn> = (0..40)
            .map(|i| SessionIn { pill_id: format!("agent_{i}"), state: "not-a-state".into(), ..Default::default() })
            .chain([SessionIn::default()]) // no pill id: dropped
            .collect();
        hub.publish(many, Some(approval("r1", &"é".repeat(5_000))), 1_000);
        let lines = drain(&mut rx);
        assert_eq!(lines[0]["sessions"].as_array().unwrap().len(), MAX_SESSIONS);
        assert_eq!(lines[0]["sessions"][0]["state"], "idle");
        assert_eq!(lines[1]["command"].as_str().unwrap().chars().count(), MAX_COMMAND_CHARS);
    }

    #[test]
    fn a_phone_that_cannot_keep_up_is_dropped_not_waited_for() {
        let (hub, _) = hub();
        let (tx, _rx) = mpsc::channel(2); // never read
        hub.subscribe(tx, 0, false);
        assert_eq!(hub.clients(), 1);
        for i in 0..5 {
            hub.publish(vec![session("working")], None, 1_000);
            hub.publish(vec![SessionIn { status_text: format!("{i}"), ..session("working") }], None, 1_000);
        }
        assert_eq!(hub.clients(), 0);
    }

    #[test]
    fn a_phone_that_was_dropped_is_marked_so_its_connection_can_close() {
        let (hub, _) = hub();
        let (tx, _rx) = mpsc::channel(1); // never read
        let (_, evicted) = hub.subscribe(tx, 0, false);
        assert!(!evicted.load(Ordering::SeqCst));
        for i in 0..4 {
            hub.publish(vec![SessionIn { status_text: format!("{i}"), ..session("working") }], None, 1_000);
        }
        assert!(evicted.load(Ordering::SeqCst), "a dropped phone must be told apart from a healthy one");
        // A healthy phone is never marked.
        let (tx, mut rx) = mpsc::channel(16);
        let (_, ok) = hub.subscribe(tx, 0, false);
        hub.publish(vec![session("finished")], None, 2_000);
        drain(&mut rx);
        assert!(!ok.load(Ordering::SeqCst));
    }

    #[test]
    fn kicking_tells_every_phone_why() {
        let (hub, _) = hub();
        let (tx, mut rx) = mpsc::channel(4);
        hub.subscribe(tx, 0, false);
        hub.kick_all("auth", "unpaired");
        assert_eq!(hub.clients(), 0);
        let mut saw = false;
        while let Ok(o) = rx.try_recv() {
            if let Out::Close { code, .. } = o {
                saw = code == "auth";
            }
        }
        assert!(saw);
    }

    #[test]
    fn constant_time_comparison_still_compares() {
        assert!(constant_eq(b"abc", b"abc"));
        assert!(!constant_eq(b"abc", b"abd"));
        assert!(!constant_eq(b"abc", b"abcd"));
        assert!(!constant_eq(b"", b"a"));
    }

    // ── questions (cap `answers`) ───────────────────────────────────────────────────

    #[derive(Default)]
    struct AnswerRecorder(StdMutex<Vec<(String, serde_json::Value)>>);
    impl Host for AnswerRecorder {
        fn decide(&self, _: &str, _: bool) {}
        fn answer(&self, request_id: &str, answers: &serde_json::Map<String, serde_json::Value>) {
            self.0.lock().unwrap().push((request_id.to_string(), serde_json::Value::Object(answers.clone())));
        }
    }

    fn ask(request: &str) -> QuestionIn {
        QuestionIn {
            request_id: request.into(),
            session_id: "s1".into(),
            pill_id: "integration_claude".into(),
            questions: vec![QuestionItemIn {
                question: "Which?".into(),
                options: vec![OptionIn { label: "A".into(), description: String::new() }, OptionIn { label: "B".into(), description: "bee".into() }],
                multi_select: false,
            }],
        }
    }

    fn qhub() -> (Arc<Hub>, Arc<AnswerRecorder>, mpsc::Receiver<Out>) {
        let rec = Arc::new(AnswerRecorder::default());
        let hub = Hub::new(rec.clone());
        let (tx, rx) = mpsc::channel(16);
        hub.subscribe_with(tx, 1_000, Caps { answers: true, ..Caps::default() });
        (hub, rec, rx)
    }

    fn qfp(hub: &Hub) -> String {
        hub.inner.lock().unwrap().question.as_ref().unwrap().fingerprint.clone()
    }

    #[test]
    fn an_answer_older_than_the_limit_is_not_applied() {
        let (hub, rec, mut rx) = qhub();
        hub.publish_question(Some(ask("r1")), 1_000);
        let fp = qfp(&hub);
        assert_eq!(hub.answer(&fp, &[vec!["A".into()]], 1_000 + APPROVAL_TTL_MS + 1), Outcome::Late);
        assert!(rec.0.lock().unwrap().is_empty());
        let lines = drain(&mut rx);
        assert_eq!(lines.last().unwrap()["type"], "approvalResolved");
    }

    #[test]
    fn a_new_question_replaces_the_old_and_none_withdraws_it() {
        let (hub, rec, mut rx) = qhub();
        hub.publish_question(Some(ask("r1")), 1_000);
        let first = qfp(&hub);
        hub.publish_question(Some(ask("r1")), 1_001); // the same request again: nothing new
        hub.publish_question(Some(ask("r2")), 1_002);
        let second = qfp(&hub);
        assert_ne!(first, second);
        assert_eq!(hub.answer(&first, &[vec!["A".into()]], 1_003), Outcome::NoMatch, "the old one cannot be answered any more");
        hub.publish_question(None, 1_004);
        assert_eq!(hub.answer(&second, &[vec!["A".into()]], 1_005), Outcome::NoMatch);
        assert!(rec.0.lock().unwrap().is_empty());
        let types: Vec<String> = drain(&mut rx).iter().map(|l| l["type"].as_str().unwrap().to_string()).collect();
        assert_eq!(types.iter().filter(|t| *t == "question").count(), 2);
        assert_eq!(types.iter().filter(|t| *t == "approvalResolved").count(), 2);
    }

    #[test]
    fn the_question_and_a_permission_request_do_not_disturb_each_other() {
        let (hub, rec, _rx) = qhub();
        hub.publish(vec![], Some(approval("p1", "ls")), 1_000);
        hub.publish_question(Some(ask("r1")), 1_000);
        assert!(hub.inner.lock().unwrap().approval.is_some());
        let fp = qfp(&hub);
        assert_eq!(hub.answer(&fp, &[vec!["B".into()]], 1_001), Outcome::Applied);
        assert!(hub.inner.lock().unwrap().approval.is_some(), "the permission request is untouched");
        assert_eq!(rec.0.lock().unwrap()[0], ("r1".to_string(), json!({ "Which?": "B" })));
    }

    #[test]
    fn a_question_that_waited_too_long_is_gone_for_a_phone_that_connects_now() {
        let (hub, _rec, _rx) = qhub();
        hub.publish_question(Some(ask("r1")), 1_000);
        let (tx, mut rx) = mpsc::channel(16);
        hub.subscribe_with(tx, 1_000 + APPROVAL_TTL_MS + 1, Caps { answers: true, ..Caps::default() });
        assert!(drain(&mut rx).iter().all(|l| l["type"] != "question"));
    }
    // ── prefs (the outfit) ──────────────────────────────────────────────────────────

    #[test]
    fn a_phone_with_prefs_hears_the_outfit_when_it_connects_and_whenever_it_changes() {
        let (hub, _) = hub();
        hub.publish_outfit("beanie");
        let (tx, mut rx) = mpsc::channel(16);
        hub.subscribe_with(tx, 1_000, Caps { prefs: true, ..Caps::default() });
        let first = drain(&mut rx);
        assert!(first.iter().any(|l| l["type"] == "prefs" && l["outfit"] == "beanie"), "{first:?}");
        hub.publish_outfit("crown");
        let next = drain(&mut rx);
        assert_eq!(next.len(), 1);
        assert_eq!(next[0], serde_json::json!({ "type": "prefs", "outfit": "crown" }));
        hub.publish_outfit("crown"); // the same again: nothing new
        assert!(drain(&mut rx).is_empty());
    }

    #[test]
    fn a_phone_without_prefs_never_hears_of_the_outfit() {
        let (hub, _) = hub();
        hub.publish_outfit("scarf");
        let (tx, mut rx) = mpsc::channel(16);
        hub.subscribe_with(tx, 1_000, Caps { details: true, answers: true, ..Caps::default() });
        hub.publish_outfit("bow");
        assert!(drain(&mut rx).iter().all(|l| l["type"] != "prefs"));
    }

    #[test]
    fn only_the_known_wardrobe_values_are_sent() {
        let (hub, _) = hub();
        let (tx, mut rx) = mpsc::channel(16);
        hub.subscribe_with(tx, 1_000, Caps { prefs: true, ..Caps::default() });
        drain(&mut rx);
        for bad in ["", "topHat", "Beanie", "beanie ", "../../etc", "auto\nauto"] {
            hub.publish_outfit(bad);
        }
        assert!(drain(&mut rx).is_empty());
        for ok in OUTFIT_CHOICES {
            hub.publish_outfit(ok);
        }
        assert_eq!(drain(&mut rx).len(), OUTFIT_CHOICES.len());
    }

    #[test]
    fn the_outfit_list_is_the_one_of_the_island() {
        let ts = include_str!("../../../src/mochi/wardrobe.ts");
        let body = ts.split("export const OUTFIT_SELECTIONS = [").nth(1).unwrap().split("] as const").next().unwrap();
        let ids: Vec<&str> = body.split('"').skip(1).step_by(2).collect();
        assert_eq!(ids, OUTFIT_CHOICES.to_vec());
    }
    // ── file changes (cap `diffs`) ──────────────────────────────────────────────────

    fn with_files(files: Vec<FileIn>) -> SessionIn {
        SessionIn { files, ..session("working") }
    }

    fn file(id: u64, name: &str) -> FileIn {
        FileIn { id, name: name.into(), added: 2, removed: 1, ..FileIn::default() }
    }

    fn sub_with(hub: &Hub, caps: Caps) -> (u64, mpsc::Receiver<Out>) {
        let (tx, rx) = mpsc::channel(64);
        let (id, _) = hub.subscribe_with(tx, 1_000, caps);
        (id, rx)
    }

    #[test]
    fn only_phones_that_negotiated_relay_hear_of_a_new_access_key() {
        let (hub, _) = hub();
        let (_, mut with) = sub_with(&hub, Caps { relay: true, ..Caps::default() });
        let (_, mut without) = sub_with(&hub, Caps::default());
        drain(&mut with);
        drain(&mut without);
        let access = "C".repeat(43);
        assert_eq!(hub.send_relay_access(&access), 1);
        let told = drain(&mut with);
        assert_eq!(told, vec![serde_json::json!({ "type": "relayAccess", "access": access })]);
        assert!(drain(&mut without).is_empty(), "a phone that did not ask is never sent it");
    }

    #[test]
    fn the_list_of_files_goes_to_a_phone_with_diffs_and_to_nobody_else() {
        let (hub, _) = hub();
        let (_, mut plain) = sub_with(&hub, Caps::default());
        let (_, mut details) = sub_with(&hub, Caps { details: true, ..Caps::default() });
        let (_, mut diffs) = sub_with(&hub, Caps { diffs: true, ..Caps::default() });
        drain(&mut plain);
        drain(&mut details);
        drain(&mut diffs);
        hub.publish(vec![with_files(vec![file(3, "/home/me/private/proj/src/app.ts"), FileIn { too_large: true, is_new: true, ..file(4, "C:\\Users\\me\\notes.md") }])], None, 1_000);
        let p = &drain(&mut plain)[0]["sessions"][0];
        assert!(p.get("files").is_none(), "{p}");
        assert!(drain(&mut details)[0]["sessions"][0].get("files").is_none());
        let d = &drain(&mut diffs)[0]["sessions"][0];
        assert_eq!(d["files"][0], serde_json::json!({ "id": 3, "name": "app.ts", "added": 2, "removed": 1 }));
        assert_eq!(d["files"][1], serde_json::json!({ "id": 4, "name": "notes.md", "added": 2, "removed": 1, "tooLarge": true, "isNew": true }));
        assert!(d.get("steps").is_none(), "diffs alone brings no details: {d}");
        assert!(!d.to_string().contains("private") && !d.to_string().contains("Users"), "never a path: {d}");
    }

    #[test]
    fn a_phone_with_both_gets_details_and_files_and_a_new_one_is_brought_up_to_date() {
        let (hub, _) = hub();
        hub.publish(vec![SessionIn { steps: vec!["Edit · a.rs".into()], ..with_files(vec![file(1, "a.rs")]) }], None, 1_000);
        let (_, mut rx) = sub_with(&hub, Caps { details: true, diffs: true, ..Caps::default() });
        let first = &drain(&mut rx)[0]["sessions"][0];
        assert_eq!(first["files"][0]["name"], "a.rs");
        assert_eq!(first["steps"][0], "Edit · a.rs");
    }

    #[test]
    fn at_most_twenty_files_each_with_a_cut_name() {
        let (hub, _) = hub();
        let (_, mut rx) = sub_with(&hub, Caps { diffs: true, ..Caps::default() });
        drain(&mut rx);
        let many: Vec<FileIn> = (0..30).map(|i| file(i, &format!("{}{i}.rs", "n".repeat(200)))).collect();
        hub.publish(vec![with_files(many)], None, 1_000);
        let files = drain(&mut rx)[0]["sessions"][0]["files"].as_array().unwrap().clone();
        assert_eq!(files.len(), MAX_FILES);
        assert_eq!(files[0]["id"], 10, "the newest ones are kept");
        assert!(files.iter().all(|f| f["name"].as_str().unwrap().chars().count() <= 80));
    }

    #[test]
    fn a_change_in_the_files_alone_is_sent() {
        let (hub, _) = hub();
        let (_, mut rx) = sub_with(&hub, Caps { diffs: true, ..Caps::default() });
        hub.publish(vec![with_files(vec![file(1, "a.rs")])], None, 1_000);
        drain(&mut rx);
        hub.publish(vec![with_files(vec![file(1, "a.rs"), file(2, "b.rs")])], None, 1_001);
        assert_eq!(drain(&mut rx).len(), 1);
    }

    fn lines(n: usize) -> Vec<(String, String)> {
        (0..n).map(|i| ((if i % 2 == 0 { "+" } else { "-" }).to_string(), format!("line {i}"))).collect()
    }

    fn diff_in(rows: Vec<(String, String)>) -> DiffIn {
        DiffIn { pill_id: "integration_claude".into(), file_id: 3, name: "/x/y/app.ts".into(), added: 5, removed: 4, lines: rows, ..DiffIn::default() }
    }

    #[test]
    fn a_diff_goes_to_the_phone_that_asked_cut_to_the_limits_in_parts() {
        let (hub, _) = hub();
        let (id, mut rx) = sub_with(&hub, Caps { diffs: true, ..Caps::default() });
        let (_, mut other) = sub_with(&hub, Caps { diffs: true, ..Caps::default() });
        drain(&mut rx);
        drain(&mut other);
        let mut rows = lines(250);
        rows[0].1 = "x".repeat(900);
        rows[1].0 = "weird".into();
        hub.send_diff(id, diff_in(rows));
        let parts = drain(&mut rx);
        assert!(drain(&mut other).is_empty(), "only the phone that asked");
        assert_eq!(parts.len(), 2);
        assert_eq!((parts[0]["part"].as_u64(), parts[0]["parts"].as_u64()), (Some(0), Some(2)));
        assert_eq!(parts[0]["lines"].as_array().unwrap().len(), 100);
        assert_eq!(parts[1]["lines"].as_array().unwrap().len(), 100, "200 lines at most");
        assert_eq!(parts[0]["truncated"], true);
        assert_eq!(parts[0]["name"], "app.ts");
        assert_eq!(parts[0]["lines"][0][1].as_str().unwrap().chars().count(), 400);
        assert_eq!(parts[0]["lines"][1][0], " ", "an unknown kind is a context line");
        assert!(parts.iter().all(|p| p.to_string().len() < 60 * 1024));
    }

    #[test]
    fn a_small_diff_is_one_part_and_an_empty_one_still_answers() {
        let (hub, _) = hub();
        let (id, mut rx) = sub_with(&hub, Caps { diffs: true, ..Caps::default() });
        drain(&mut rx);
        hub.send_diff(id, diff_in(lines(3)));
        let one = drain(&mut rx);
        assert_eq!(one.len(), 1);
        assert_eq!(one[0]["truncated"], false);
        hub.send_diff(id, DiffIn { gone: true, ..diff_in(vec![]) });
        let gone = drain(&mut rx);
        assert_eq!(gone.len(), 1);
        assert_eq!((gone[0]["gone"].clone(), gone[0]["parts"].clone()), (serde_json::json!(true), serde_json::json!(1)));
    }

    #[test]
    fn a_phone_without_diffs_is_never_sent_one_and_cannot_ask() {
        let (hub, host) = hub();
        let (id, mut rx) = sub_with(&hub, Caps { details: true, answers: true, prefs: true, ..Caps::default() });
        drain(&mut rx);
        hub.request_diff(id, "integration_claude", 3, 1_000);
        assert!(host.1.lock().unwrap().is_empty());
        hub.send_diff(id, diff_in(lines(3)));
        assert!(drain(&mut rx).is_empty());
    }

    #[test]
    fn a_request_reaches_the_island_with_the_connection_and_is_rate_limited() {
        let (hub, host) = hub();
        let (id, _rx) = sub_with(&hub, Caps { diffs: true, ..Caps::default() });
        for _ in 0..30 {
            hub.request_diff(id, "integration_claude", 3, 5_000);
        }
        assert_eq!(host.1.lock().unwrap().len(), DIFF_ASKS_PER_10S);
        assert_eq!(host.1.lock().unwrap()[0], (id, "integration_claude".to_string(), 3));
        hub.request_diff(id, "integration_claude", 3, 16_000); // ten seconds later: asking is allowed again
        assert_eq!(host.1.lock().unwrap().len(), DIFF_ASKS_PER_10S + 1);
    }

    #[test]
    fn an_answer_for_a_phone_that_left_goes_nowhere() {
        let (hub, _) = hub();
        let (id, rx) = sub_with(&hub, Caps { diffs: true, ..Caps::default() });
        hub.unsubscribe(id);
        drop(rx);
        hub.send_diff(id, diff_in(lines(3))); // must not panic
    }
    // ── plan usage (cap `usage`) ────────────────────────────────────────────────────

    fn win(pct: f64, at: u64) -> Option<WindowIn> {
        Some(WindowIn { used_pct: pct, resets_at: at })
    }

    fn usage_in() -> UsageIn {
        UsageIn {
            claude: Some(PlanIn { five_hour: win(42.4, 1_900_000_000_000), seven_day: win(7.0, 1_900_500_000_000), updated_at: 5, ..PlanIn::default() }),
            codex: Some(PlanIn { seven_day: win(99.6, 1_900_500_000_000), reset_credits: Some(2), plan_type: Some("plus\n<b>".into()), ..PlanIn::default() }),
        }
    }

    #[test]
    fn a_phone_with_usage_gets_rounded_percentages_and_only_those() {
        let (hub, _) = hub();
        let (_, mut rx) = sub_with(&hub, Caps { usage: true, ..Caps::default() });
        let (_, mut other) = sub_with(&hub, Caps { details: true, diffs: true, answers: true, prefs: true, ..Caps::default() });
        drain(&mut rx);
        drain(&mut other);
        hub.publish_usage(usage_in());
        let u = drain(&mut rx);
        assert_eq!(u.len(), 1);
        assert_eq!(u[0]["type"], "usage");
        assert_eq!(u[0]["claude"]["fiveHour"], serde_json::json!({ "pct": 42, "resetsAt": 1_900_000_000_000u64 }));
        assert_eq!(u[0]["claude"]["updatedAt"], 5);
        assert_eq!(u[0]["codex"]["sevenDay"]["pct"], 100);
        assert!(u[0]["codex"].get("fiveHour").is_none());
        assert_eq!(u[0]["codex"]["resetCredits"], 2);
        assert_eq!(u[0]["codex"]["plan"], "plusb", "only letters, digits, spaces and dashes");
        assert!(drain(&mut other).is_empty(), "a phone without usage never hears of it");
    }

    #[test]
    fn a_new_phone_is_brought_up_to_date_and_a_repeat_is_not_sent() {
        let (hub, _) = hub();
        hub.publish_usage(usage_in());
        let (_, mut rx) = sub_with(&hub, Caps { usage: true, ..Caps::default() });
        assert!(drain(&mut rx).iter().any(|l| l["type"] == "usage" && l["claude"].is_object()));
        hub.publish_usage(usage_in());
        assert!(drain(&mut rx).is_empty());
    }

    #[test]
    fn nothing_known_clears_it_and_junk_numbers_are_left_out() {
        let (hub, _) = hub();
        let (_, mut rx) = sub_with(&hub, Caps { usage: true, ..Caps::default() });
        hub.publish_usage(usage_in());
        drain(&mut rx);
        hub.publish_usage(UsageIn::default());
        let cleared = drain(&mut rx);
        assert_eq!(cleared, vec![serde_json::json!({ "type": "usage" })]);
        let junk = UsageIn { claude: Some(PlanIn { five_hour: win(f64::NAN, 5), seven_day: win(10.0, 0), ..PlanIn::default() }), codex: None };
        hub.publish_usage(junk);
        assert!(drain(&mut rx).is_empty(), "nothing usable: still cleared, nothing new to say");
        hub.publish_usage(UsageIn { claude: Some(PlanIn { five_hour: win(-20.0, 7), ..PlanIn::default() }), codex: None });
        assert_eq!(drain(&mut rx)[0]["claude"]["fiveHour"]["pct"], 0);
        let (_, mut late) = sub_with(&hub, Caps { usage: true, ..Caps::default() });
        assert!(drain(&mut late).iter().any(|l| l["claude"]["fiveHour"]["pct"] == 0), "a new phone is told what there is");
        hub.publish_usage(UsageIn::default());
        assert_eq!(drain(&mut late), vec![serde_json::json!({ "type": "usage" })]);
        let (_, mut after) = sub_with(&hub, Caps { usage: true, ..Caps::default() });
        assert!(drain(&mut after).iter().all(|l| l["type"] != "usage"), "after a clear a new phone is told nothing");
    }
    // ── service cards (cap `services`) ──────────────────────────────────────────────

    fn card(id: &str, headline: &str, items: &[(&str, &str)]) -> ServiceIn {
        ServiceIn {
            id: id.into(),
            title: id.trim_start_matches("integration_").into(),
            headline: headline.into(),
            reason: None,
            items: items.iter().map(|(l, d)| ServiceItemIn { label: (*l).into(), detail: (*d).into() }).collect(),
        }
    }

    fn allowed(ids: &[&str]) -> Caps {
        Caps { services: ids.iter().map(|s| s.to_string()).collect(), ..Caps::default() }
    }

    #[test]
    fn a_phone_is_sent_only_the_services_its_user_allowed() {
        let (hub, _) = hub();
        let (_, mut rx) = sub_with(&hub, allowed(&["integration_stripe"]));
        let (_, mut none) = sub_with(&hub, Caps::default());
        drain(&mut rx);
        drain(&mut none);
        hub.publish_services(vec![card("integration_stripe", "12.50 EUR", &[("Payment", "+9.00")]), card("integration_notion", "3 pages", &[("Secret plan", "1h")])]);
        let got = drain(&mut rx);
        assert_eq!(got.len(), 1);
        let list = got[0]["services"].as_array().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0]["id"], "integration_stripe");
        assert!(!got[0].to_string().contains("Secret plan"), "{}", got[0]);
        assert!(drain(&mut none).is_empty());
    }

    #[test]
    fn a_new_phone_is_brought_up_to_date_and_a_change_elsewhere_is_not_sent_to_it() {
        let (hub, _) = hub();
        hub.publish_services(vec![card("integration_stripe", "1", &[]), card("integration_github", "2 stars", &[])]);
        let (_, mut rx) = sub_with(&hub, allowed(&["integration_stripe"]));
        assert!(drain(&mut rx).iter().any(|l| l["type"] == "services"));
        // GitHub changes; this phone only has Stripe: it hears nothing.
        hub.publish_services(vec![card("integration_stripe", "1", &[]), card("integration_github", "3 stars", &[])]);
        assert!(drain(&mut rx).is_empty());
        hub.publish_services(vec![card("integration_stripe", "2", &[]), card("integration_github", "3 stars", &[])]);
        assert_eq!(drain(&mut rx).len(), 1);
    }

    #[test]
    fn when_the_allowed_service_goes_away_the_list_is_emptied() {
        let (hub, _) = hub();
        let (_, mut rx) = sub_with(&hub, allowed(&["integration_stripe"]));
        hub.publish_services(vec![card("integration_stripe", "1", &[])]);
        drain(&mut rx);
        hub.publish_services(vec![]);
        assert_eq!(drain(&mut rx), vec![serde_json::json!({ "type": "services", "services": [] })]);
    }

    #[test]
    fn unknown_ids_are_dropped_and_texts_are_cut_to_one_short_line() {
        let (hub, _) = hub();
        let (_, mut rx) = sub_with(&hub, allowed(&["integration_stripe", "integration_evil"]));
        drain(&mut rx);
        let long = "x".repeat(300);
        hub.publish_services(vec![
            card("integration_evil", "no", &[]),
            ServiceIn { reason: Some(format!("a\nb {long}")), ..card("integration_stripe", &format!("{long}\n"), &[("a", "1"), ("b", "2"), ("c", "3"), ("d", "4"), ("", "empty label")]) },
            card("integration_stripe", "a duplicate", &[]),
        ]);
        let v = &drain(&mut rx)[0]["services"][0];
        assert_eq!(v["headline"].as_str().unwrap().chars().count(), 40);
        assert!(v["reason"].as_str().unwrap().chars().count() <= 80 && !v["reason"].as_str().unwrap().contains('\n'));
        assert_eq!(v["items"].as_array().unwrap().len(), 3);
        assert_eq!(drain(&mut rx).len(), 0);
        assert!(!hub.inner.lock().unwrap().services.iter().any(|s| s.id == "integration_evil"));
    }

    #[test]
    fn the_service_ids_are_those_of_the_pill_catalog() {
        let ts = include_str!("../../../src/core/pills.ts");
        for id in SERVICE_IDS {
            assert!(ts.contains(&format!("\"{id}\"")), "{id}");
        }
    }
}
