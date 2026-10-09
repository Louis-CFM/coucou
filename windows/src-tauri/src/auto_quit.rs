//! Session lifetime is independent of pills, focus, Stop and idle timers.
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager};

const DELAY: Duration = Duration::from_secs(10 * 60);
const RETRY: Duration = Duration::from_secs(60);
const MAX_SESSIONS: usize = 1024;

struct Session {
    last_event: u64,
    started: Option<u64>,
    uncertain: bool,
    ended: bool,
}

#[derive(Default)]
struct Tracker {
    enabled: bool,
    sessions: HashMap<(String, String), Session>,
    uncertain: bool,
    revision: u64,
    ended_at: Option<Instant>,
    deadline: Option<Instant>,
    delay: Option<Duration>,
    proposal: Option<(u64, Instant)>,
    ticket: u64,
}

fn wall_time() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_micros() as u64
}

fn identifier(s: &str) -> bool {
    !s.is_empty() && s.len() <= 256 && !s.chars().any(char::is_control)
}

/// Only adapters whose end signal is a lifetime boundary may release a session.
fn reliable_end(agent: &str, p: &Value) -> bool {
    match agent {
        "codex" => p["reason"] == "other",
        "claude-code" | "claude-desktop" => matches!(
            p["reason"].as_str(),
            Some("clear" | "resume" | "logout" | "prompt_input_exit" | "other")
        ),
        "opencode" => true, // The installed plugin maps only session.deleted to SessionEnd.
        "hermes" => p["coucou_lifecycle"] == "finalize",
        _ => false,
    }
}

fn safe_busy_reason(reason: Option<&str>) -> &str {
    match reason {
        Some(
            reason @ ("chat_history" | "chat_draft" | "chat_open" | "expanded" | "hover" | "drag"
            | "upload" | "permission" | "popup" | "pinned" | "active_view"
            | "recent_activity" | "disabled"),
        ) => reason,
        _ => "other",
    }
}

impl Tracker {
    fn diagnostic(&self, now: Instant) -> String {
        let mut open = [0; 6];
        for ((agent, _), session) in &self.sessions {
            if !session.ended {
                open[match agent.as_str() {
                    "codex" => 0,
                    "hermes" => 1,
                    "claude-code" | "claude-desktop" => 2,
                    "opencode" => 3,
                    "antigravity" => 4,
                    _ => 5,
                }] += 1;
            }
        }
        let deadline = self.deadline.map_or("none".to_owned(), |d| {
            if d >= now {
                format!("+{}", d.duration_since(now).as_secs())
            } else {
                format!("-{}", now.duration_since(d).as_secs())
            }
        });
        format!(
            "enabled={} minutes={} sessions={} open_codex={} open_hermes={} open_claude={} open_opencode={} open_antigravity={} open_other={} uncertain={} deadline_seconds={deadline} revision={}",
            self.enabled, self.delay.unwrap_or(DELAY).as_secs() / 60, self.sessions.len(),
            open[0], open[1], open[2], open[3], open[4], open[5],
            self.uncertain || self.sessions.values().any(|s| s.uncertain), self.revision
        )
    }

    fn refresh(&mut self, now: Instant) {
        let eligible = self.enabled
            && !self.uncertain
            && !self.sessions.is_empty()
            && self.sessions.values().all(|s| s.ended);
        if eligible {
            let ended_at = *self.ended_at.get_or_insert(now);
            self.deadline = Some(ended_at + self.delay.unwrap_or(DELAY));
        } else {
            self.ended_at = None;
            self.deadline = None;
        }
        self.proposal = None;
        self.revision += 1;
    }

    fn configure(&mut self, enabled: bool, minutes: u8, now: Instant) {
        let delay = Duration::from_secs(u64::from(minutes) * 60);
        if self.enabled != enabled || self.delay != Some(delay) {
            self.enabled = enabled;
            self.delay = Some(delay);
            self.refresh(now);
        }
    }

    fn observe(&mut self, p: &Value, now: Instant, wall: u64) -> &'static str {
        let event = p["hook_event_name"].as_str().unwrap_or_default();
        if !matches!(
            event,
            "SessionStart"
                | "SessionEnd"
                | "UserPromptSubmit"
                | "PreToolUse"
                | "PostToolUse"
                | "PostToolUseFailure"
                | "PermissionRequest"
                | "Stop"
                | "StopFailure"
                | "Interrupt"
                | "SubagentStart"
                | "SubagentStop"
                | "Notification"
        ) {
            return "ignored_event";
        }
        let agent = p
            .get("coucou_agent")
            .and_then(Value::as_str)
            .unwrap_or("claude-code");
        let sid = p["session_id"].as_str().unwrap_or_default();
        if !identifier(agent) || !identifier(sid) {
            self.uncertain = true;
            self.refresh(now);
            return "invalid_identifier";
        }
        let key = (agent.to_owned(), sid.to_owned());
        // Old relays still monitor normally, but cannot prove event ordering for a quit.
        let stamp = p["coucou_event_time_us"]
            .as_u64()
            .filter(|t| *t > 0 && *t <= wall && wall - *t <= 60_000_000);
        if event == "SessionEnd" {
            let Some(s) = self.sessions.get_mut(&key) else {
                return "orphan_end";
            };
            if s.ended {
                return "duplicate_end";
            }
            if s.uncertain {
                return "uncertain_session_end";
            }
            if !reliable_end(agent, p) {
                return "unreliable_end";
            }
            let Some(stamp) = stamp.filter(|t| *t > s.last_event) else {
                return "stale_or_unstamped_end";
            };
            s.last_event = stamp;
            s.ended = true;
        } else {
            if !self.sessions.contains_key(&key) && self.sessions.len() >= MAX_SESSIONS {
                self.uncertain = true;
                self.refresh(now);
                return "session_limit";
            }
            let s = self.sessions.entry(key).or_insert(Session {
                last_event: 0,
                started: None,
                uncertain: false,
                ended: false,
            });
            if stamp.is_some_and(|t| t < s.last_event) {
                return "out_of_order_activity";
            }
            if event == "SessionStart" {
                // A reused identity has no generation token: a late end could belong to the old run.
                if s.started.is_some() && s.started != stamp {
                    s.uncertain = true;
                }
                s.started = stamp;
            }
            s.uncertain |= stamp.is_none() || s.ended;
            s.ended = false;
            s.last_event = stamp.unwrap_or(s.last_event);
        }
        self.refresh(now);
        if event == "SessionEnd" {
            "accepted_end"
        } else {
            "activity"
        }
    }

    fn propose(&mut self, revision: u64, now: Instant) -> Option<u64> {
        if self.revision != revision || !self.deadline.is_some_and(|d| now >= d) {
            return None;
        }
        self.ticket += 1;
        self.proposal = Some((self.ticket, now));
        Some(self.ticket)
    }

    fn can_quit(&self, ticket: u64, now: Instant, busy: bool) -> bool {
        !busy
            && self.enabled
            && self.deadline.is_some_and(|d| now >= d)
            && self.proposal.is_some_and(|(id, p)| {
                id == ticket && now.duration_since(p) <= Duration::from_secs(5)
            })
    }
}

#[derive(Default)]
struct Control {
    tracker: Tracker,
    timer: Option<tauri::async_runtime::JoinHandle<()>>,
    #[cfg(debug_assertions)]
    test_offset: Duration,
}

impl Control {
    fn now(&self) -> Instant {
        #[cfg(debug_assertions)]
        {
            return Instant::now() + self.test_offset;
        }
        #[cfg(not(debug_assertions))]
        {
            Instant::now()
        }
    }

    fn wait(&self) -> Option<Duration> {
        self.tracker
            .deadline
            .map(|d| d.saturating_duration_since(self.now()))
    }
}

#[derive(Default)]
pub struct AutoQuit(Mutex<Control>);

fn update(
    app: &AppHandle,
    cause: &'static str,
    change: impl FnOnce(&mut Control, Instant) -> &'static str,
) {
    let state = app.state::<AutoQuit>();
    let mut control = state.0.lock().unwrap();
    let previous = control.tracker.revision;
    let old_deadline = control.tracker.deadline;
    let old_sessions = control.tracker.sessions.len();
    let now = control.now();
    let outcome = change(&mut control, now);
    if outcome != "ignored_event"
        && (outcome != "activity"
            || old_deadline != control.tracker.deadline
            || old_sessions != control.tracker.sessions.len())
    {
        if previous != control.tracker.revision || outcome != "configured" {
            crate::log::line(format!(
                "auto_quit cause={cause} outcome={outcome} {}",
                control.tracker.diagnostic(control.now())
            ));
        }
    }
    if control.tracker.revision == previous {
        return;
    }
    if let Some(timer) = control.timer.take() {
        timer.abort();
    }
    if control.tracker.deadline.is_none() {
        return;
    }
    let revision = control.tracker.revision;
    let wait = control.wait().unwrap_or_default();
    #[cfg(debug_assertions)]
    let retry = if test_allowed().is_ok() {
        Duration::from_secs(1)
    } else {
        RETRY
    };
    #[cfg(not(debug_assertions))]
    let retry = RETRY;
    let app = app.clone();
    control.timer = Some(tauri::async_runtime::spawn(async move {
        tokio::time::sleep(wait).await;
        loop {
            let proposed = {
                let state = app.state::<AutoQuit>();
                let mut control = state.0.lock().unwrap();
                let now = control.now();
                control.tracker.propose(revision, now)
            };
            let Some(ticket) = proposed else { return };
            crate::log::line(format!(
                "auto_quit check_sent ticket={ticket} revision={revision}"
            ));
            // No frontend response (including a hung webview) means no quit.
            if app
                .emit_to(crate::island::WINDOW_LABEL, "auto-quit-check", ticket)
                .is_err()
            {
                crate::log::line(format!("auto_quit check_emit_failed ticket={ticket}"));
            }
            tokio::time::sleep(retry).await;
        }
    }));
}

pub fn configure(app: &AppHandle, enabled: bool, minutes: u8) {
    update(app, "settings", |control, now| {
        control.tracker.configure(enabled, minutes, now);
        "configured"
    });
}

pub fn observe(app: &AppHandle, payload: &Value) {
    let agent = match payload["coucou_agent"].as_str().unwrap_or("claude-code") {
        "codex" => "codex",
        "hermes" => "hermes",
        "claude-code" => "claude-code",
        "claude-desktop" => "claude-desktop",
        "opencode" => "opencode",
        "antigravity" => "antigravity",
        _ => "other",
    };
    update(app, agent, |control, now| {
        control.tracker.observe(payload, now, wall_time())
    });
}

#[tauri::command]
pub fn auto_quit_confirm(app: AppHandle, ticket: u64, busy: bool, busy_reason: Option<String>) {
    let state = app.state::<AutoQuit>();
    let control = state.0.lock().unwrap();
    let settings_open = app
        .get_webview_window("settings")
        .is_some_and(|w| w.is_visible().unwrap_or(true));
    let permission = !app
        .state::<crate::pipe::Pending>()
        .0
        .lock()
        .unwrap()
        .is_empty();
    let focused = [crate::island::WINDOW_LABEL, crate::desktop::LABEL]
        .iter()
        .filter_map(|label| app.get_webview_window(label))
        .any(|window| window.is_focused().unwrap_or(true));
    let can_quit = control.tracker.can_quit(
        ticket,
        control.now(),
        busy || settings_open || permission || focused,
    );
    let frontend_reason = safe_busy_reason(busy_reason.as_deref());
    let reason = if can_quit {
        "ready"
    } else if settings_open {
        "settings_open"
    } else if permission {
        "permission_pending"
    } else if focused {
        "window_focused"
    } else if busy {
        frontend_reason
    } else {
        "stale_ticket_or_deadline"
    };
    crate::log::line(format!(
        "auto_quit check_result ticket={ticket} reason={reason}"
    ));
    if can_quit {
        crate::quit_app(app.clone());
    }
}

#[cfg(debug_assertions)]
fn test_allowed() -> Result<(), &'static str> {
    if std::env::var("COUCOU_AUTO_QUIT_TEST").as_deref() == Ok("1") {
        Ok(())
    } else {
        Err("Auto-Quit test mode is disabled")
    }
}

#[cfg(debug_assertions)]
#[tauri::command]
pub fn test_advance(app: AppHandle, seconds: u64) -> Result<(), &'static str> {
    test_allowed()?;
    if seconds > 7200 {
        return Err("test advance exceeds two hours");
    }
    update(&app, "test_clock", |control, now| {
        let advance = Duration::from_secs(seconds);
        control.test_offset += advance;
        control.tracker.refresh(now + advance);
        "advanced"
    });
    Ok(())
}

#[cfg(debug_assertions)]
#[tauri::command]
pub fn test_event(
    app: AppHandle,
    agent: String,
    session: u8,
    event: String,
) -> Result<(), &'static str> {
    test_allowed()?;
    if !matches!(
        agent.as_str(),
        "codex" | "hermes" | "claude-code" | "opencode" | "antigravity"
    ) || !(1..=4).contains(&session)
        || !matches!(
            event.as_str(),
            "SessionStart" | "SessionEnd" | "UserPromptSubmit"
        )
    {
        return Err("unsupported test event");
    }
    let payload = serde_json::json!({
        "hook_event_name": event, "coucou_agent": agent, "session_id": format!("wdio-{session}"),
        "coucou_event_time_us": wall_time(), "reason": "other", "coucou_lifecycle": "finalize"
    });
    observe(&app, &payload);
    let _ = app.emit_to(crate::island::WINDOW_LABEL, "hook", payload);
    Ok(())
}

#[cfg(debug_assertions)]
#[tauri::command]
pub fn test_status(app: AppHandle) -> Result<String, &'static str> {
    test_allowed()?;
    let state = app.state::<AutoQuit>();
    let control = state.0.lock().unwrap();
    Ok(control.tracker.diagnostic(control.now()))
}

#[cfg(debug_assertions)]
#[tauri::command]
pub fn test_hide_settings(app: AppHandle) -> Result<(), &'static str> {
    test_allowed()?;
    app.get_webview_window("settings")
        .ok_or("settings window missing")?
        .hide()
        .map_err(|_| "could not hide settings")?;
    app.get_webview_window(crate::island::WINDOW_LABEL)
        .ok_or("island window missing")?
        .hide()
        .map_err(|_| "could not hide island")
}

#[cfg(test)]
#[path = "auto_quit_tests.rs"]
mod tests;
