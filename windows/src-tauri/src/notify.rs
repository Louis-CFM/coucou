// Notifications in the island: your iPhone's calls and messages through
// Microsoft Phone Link, and any other app's toasts. Windows only.
//
// Reading other apps' notifications needs a package identity with the
// userNotificationListener capability (identity/AppxManifest.xml, registered by
// identity/make-identity.ps1) and the user's Allow. Without the identity the
// listener can't even be created: this module logs it once and does nothing.
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
    /// "call", "message" (Phone Link) or "app".
    pub kind: &'static str,
    pub app: String,
    pub title: String,
    pub body: String,
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
    let mut first = true;
    while ON.load(Ordering::Relaxed) {
        if let Ok(list) = listener.GetNotificationsAsync(NotificationKinds::Toast).and_then(|op| op.get()) {
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
                if let Some(h) = APP.get() {
                    let _ = h.emit_to(crate::island::WINDOW_LABEL, "toast", Toast { kind, app, title, body });
                }
            }
            first = false;
        }
        std::thread::sleep(EVERY);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phone_link_calls_and_messages_are_told_apart() {
        assert_eq!(classify("Phone Link", "Mom", "Incoming call"), "call");
        assert_eq!(classify("Phone Link", "Missed call", "Rahul"), "call");
        assert_eq!(classify("Phone Link", "Rahul", "where are you?"), "message");
        assert_eq!(classify("WhatsApp", "Rahul", "Incoming call"), "app");
    }
}
