// Notifications in the island: your iPhone's calls and messages through
// Microsoft Phone Link, and any other app's toasts. Windows only.
//
// Reading other apps' notifications needs the user's Allow (Windows asks once).
// Current Windows 11 lets a desktop app ask without a package identity; where
// it can't, the listener isn't created: this module logs it once and does nothing.
//
// Nothing is stored or sent anywhere: a new toast is shown in the island and
// forgotten. Only its id is remembered, so it is shown once.

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

use serde::Serialize;
use tauri::{AppHandle, Emitter};
use windows::UI::Notifications::Management::{UserNotificationListener, UserNotificationListenerAccessStatus};
use windows::UI::Notifications::{KnownNotificationBindings, NotificationKinds};

static APP: OnceLock<AppHandle> = OnceLock::new();
static ON: AtomicBool = AtomicBool::new(false);
static RUNNING: AtomicBool = AtomicBool::new(false);
/// A desktop app gets no NotificationChanged event, so the list is read again.
// ponytail: 2 s poll while the setting is on; NotificationChanged works only for packaged background tasks.
const EVERY: std::time::Duration = std::time::Duration::from_secs(2);

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Toast {
    /// The notification's id: a call's card stays until this one is gone.
    pub id: u32,
    /// "call", "message" (Phone Link) or "app".
    pub kind: &'static str,
    /// Who: the caller for a call, else the title.
    pub who: String,
    pub app: String,
    pub title: String,
    pub body: String,
}

/// The caller's name among a call toast's lines: the first one that isn't
/// Phone Link's own wording ("Incoming call", "iPhone", the app's name).
pub fn caller(texts: &[String], app: &str) -> String {
    const GENERIC: [&str; 9] = ["incoming call", "incoming", "calling", "call", "phone link", "iphone", "mobile", "answer", "decline"];
    let generic = |s: &str| {
        let l = s.trim().to_lowercase();
        l.is_empty() || l == app.to_lowercase() || GENERIC.iter().any(|g| l == *g || l.starts_with("incoming call"))
    };
    texts.iter().find(|t| !generic(t)).or_else(|| texts.first()).cloned().unwrap_or_else(|| app.to_string())
}

/// What a toast is, from the app that sent it and its first lines.
pub fn classify(app: &str, title: &str, body: &str) -> &'static str {
    let phone = app.to_lowercase().contains("phone link") || app.contains("YourPhone");
    if !phone {
        return "app";
    }
    let all = format!("{title} {body}").to_lowercase();
    if ["incoming call", "calling", "call from", "missed call", "appel entrant"].iter().any(|w| all.contains(w)) {
        "call"
    } else {
        "message"
    }
}

pub fn start(app: &AppHandle, on: bool) {
    let _ = APP.set(app.clone());
    apply(on);
}

pub fn apply(on: bool) {
    ON.store(on, Ordering::Relaxed);
    if on && !RUNNING.swap(true, Ordering::SeqCst) {
        let _ = std::thread::Builder::new().name("coucou-notify".into()).spawn(|| {
            if let Err(e) = run() {
                crate::log::line(format!("notifications: {e}"));
            }
            RUNNING.store(false, Ordering::SeqCst);
        });
    }
}

fn run() -> windows::core::Result<()> {
    let listener = UserNotificationListener::Current()?;
    let mut access = listener.GetAccessStatus()?;
    if access != UserNotificationListenerAccessStatus::Allowed {
        access = listener.RequestAccessAsync()?.get()?;
    }
    if access != UserNotificationListenerAccessStatus::Allowed {
        crate::log::line(format!("notifications: access {access:?}"));
        return Ok(());
    }
    crate::log::line("notifications: listening");
    let generic = KnownNotificationBindings::ToastGeneric()?;
    let mut seen: HashSet<u32> = HashSet::new();
    // Calls on screen: their card goes when Phone Link takes the toast away
    // (answered, declined, missed).
    let mut calls: HashSet<u32> = HashSet::new();
    let mut first = true;
    while ON.load(Ordering::Relaxed) {
        if let Ok(list) = listener.GetNotificationsAsync(NotificationKinds::Toast).and_then(|op| op.get()) {
            let present: HashSet<u32> = list.clone().into_iter().filter_map(|n| n.Id().ok()).collect();
            for gone in calls.iter().copied().filter(|id| !present.contains(id)).collect::<Vec<_>>() {
                calls.remove(&gone);
                if let Some(h) = APP.get() {
                    let _ = h.emit_to(crate::island::WINDOW_LABEL, "toast-gone", gone);
                }
            }
            for n in list {
                let Ok(id) = n.Id() else { continue };
                if !seen.insert(id) || first {
                    continue;
                }
                let app = n.AppInfo().and_then(|a| a.DisplayInfo()).and_then(|d| d.DisplayName()).map(|h| h.to_string()).unwrap_or_default();
                // Coucou's own toasts are already in the island.
                if app.eq_ignore_ascii_case("coucou") {
                    continue;
                }
                let texts: Vec<String> = n
                    .Notification()
                    .and_then(|x| x.Visual())
                    .and_then(|v| v.GetBinding(&generic))
                    .and_then(|b| b.GetTextElements())
                    .map(|els| els.into_iter().filter_map(|t| t.Text().ok()).map(|h| h.to_string()).collect())
                    .unwrap_or_default();
                let title = texts.first().cloned().unwrap_or_default();
                let body = texts.get(1..).map(|r| r.join(" ")).unwrap_or_default();
                if title.is_empty() && body.is_empty() {
                    continue;
                }
                let kind = classify(&app, &title, &body);
                let who = if kind == "call" { caller(&texts, &app) } else { title.clone() };
                if kind == "call" {
                    calls.insert(id);
                }
                if let Some(h) = APP.get() {
                    let _ = h.emit_to(crate::island::WINDOW_LABEL, "toast", Toast { id, kind, who, app, title, body });
                }
            }
            first = false;
        }
        std::thread::sleep(EVERY);
    }
    Ok(())
}

/// Phone Link in front: its call window answers or declines.
#[tauri::command]
pub fn open_phone_link() -> bool {
    crate::platform::no_console(&mut std::process::Command::new("explorer.exe"))
        .arg("shell:AppsFolder\\Microsoft.YourPhone_8wekyb3d8bbwe!App")
        .spawn()
        .is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_caller_is_the_line_that_is_not_phone_links_wording() {
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        assert_eq!(caller(&s(&["Phone Link", "Rahul", "Incoming call"]), "Phone Link"), "Rahul");
        assert_eq!(caller(&s(&["Incoming call", "Mom ❤️"]), "Phone Link"), "Mom ❤️");
        assert_eq!(caller(&s(&["+91 98765 43210", "Incoming call"]), "Phone Link"), "+91 98765 43210");
        assert_eq!(caller(&s(&["Incoming call"]), "Phone Link"), "Incoming call");
    }

    #[test]
    fn phone_link_calls_and_messages_are_told_apart() {
        assert_eq!(classify("Phone Link", "Mom", "Incoming call"), "call");
        assert_eq!(classify("Phone Link", "Missed call", "Rahul"), "call");
        assert_eq!(classify("Phone Link", "Rahul", "where are you?"), "message");
        assert_eq!(classify("WhatsApp", "Rahul", "Incoming call"), "app");
    }
}
