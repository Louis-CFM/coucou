// Windows System Notification Listener for the Small Notch (#1055 & Dynamic Island).
// Actively monitors system notifications (WhatsApp Desktop, Telegram, Discord, Slack, Mail, System Alerts)
// and emits "system-notification" events to the webview to morph the small notch.
//
// Fix: replaced single last_seen_id tracking with a HashSet so that:
//  1. Cold-start: populate seen_ids from first scan WITHOUT emitting anything (prevents
//     stale Action Center toasts from firing as "new" on every launch).
//  2. Each subsequent poll: iterate ALL items in the collection (not just GetAt(size-1))
//     so notifications are never skipped when multiple arrive in one 1500 ms window.
//  3. HashSet reconciliation: after processing, rebuild seen_ids from the current
//     collection so dismissed notifications are automatically forgotten (prevents the
//     dismissed-item index shift that caused stale re-emission in the original code).

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use tauri::AppHandle;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SystemNotificationPayload {
    pub id: Option<u32>,
    pub app: String,
    pub title: Option<String>,
    pub body: Option<String>,
    pub image: Option<String>,
    pub color: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WhatsAppCallPayload {
    pub id: String,
    pub caller: String,
    pub subtitle: String,
    pub avatar: Option<String>,
    pub state: String,
    pub since: Option<i64>,
}

pub fn is_call_text(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("incoming voice call")
        || lower.contains("incoming video call")
        || lower.contains("incoming call")
        || lower.contains("calling")
        || lower.contains("voice call")
        || lower.contains("video call")
        || lower.contains("appel entrant")
        || lower.contains("appel vocal")
        || lower.contains("appel vidéo")
        || lower.contains("chiamata in arrivo")
        || lower.contains("chiamata vocale")
        || lower.contains("llamada entrante")
        || lower.contains("llamada de voz")
        || lower.contains("videollamada")
        || lower.contains("eingehender anruf")
        || lower.contains("sprachweanruf")
        || lower.contains("videoanruf")
        || lower.contains("inkomende oproep")
        || lower.contains("chamada recebida")
        || lower.contains("входящий звонок")
}

#[cfg(windows)]
pub fn start(app: &AppHandle) {
    let handle = app.clone();
    std::thread::Builder::new()
        .name("coucou-notifications".into())
        .spawn(move || {
            run_listener(handle);
        })
        .ok();
}

#[cfg(not(windows))]
pub fn start(_app: &AppHandle) {}

#[cfg(windows)]
fn run_listener(app: AppHandle) {
    use tauri::Emitter;
    use windows::UI::Notifications::Management::{UserNotificationListener, UserNotificationListenerAccessStatus};
    use windows::UI::Notifications::NotificationKinds;

    let Ok(listener) = UserNotificationListener::Current() else {
        return;
    };

    let mut allowed = false;
    if let Ok(status_async) = listener.RequestAccessAsync() {
        if let Ok(status) = status_async.get() {
            allowed = status == UserNotificationListenerAccessStatus::Allowed;
        }
    }

    // IDs already present at startup — these are pre-existing Action Center toasts,
    // not new arrivals. Populated on the first poll without emitting any events.
    let mut seen_ids: HashSet<u32> = HashSet::new();
    let mut cold_start = true;

    loop {
        std::thread::sleep(std::time::Duration::from_millis(1500));

        if !allowed {
            if let Ok(status) = listener.GetAccessStatus() {
                if status == UserNotificationListenerAccessStatus::Allowed {
                    allowed = true;
                } else {
                    continue;
                }
            } else {
                continue;
            }
        }

        let Ok(notifs_async) = listener.GetNotificationsAsync(NotificationKinds::Toast) else {
            continue;
        };
        let Ok(notifs) = notifs_async.get() else {
            continue;
        };
        let Ok(size) = notifs.Size() else {
            continue;
        };

        // Collect every notification ID currently in Action Center.
        let mut current_ids: HashSet<u32> = HashSet::with_capacity(size as usize);

        for i in 0..size {
            let Ok(notif) = notifs.GetAt(i) else { continue };
            let Ok(id) = notif.Id() else { continue };
            current_ids.insert(id);

            // Cold start: snapshot what is already there — no emission.
            if cold_start {
                continue;
            }

            // Already processed: skip.
            if seen_ids.contains(&id) {
                continue;
            }

            // New notification: extract and emit.
            let mut app_name = "System".to_string();
            let mut title: Option<String> = None;
            let mut body: Option<String> = None;

            if let Ok(app_info) = notif.AppInfo() {
                if let Ok(display_info) = app_info.DisplayInfo() {
                    if let Ok(name) = display_info.DisplayName() {
                        let s = name.to_string();
                        if !s.is_empty() {
                            app_name = s;
                        }
                    }
                }
            }

            let mut image: Option<String> = None;

            if let Ok(toast) = notif.Notification() {
                if let Ok(visual) = toast.Visual() {
                    if let Ok(bindings) = visual.Bindings() {
                        if let Ok(binding_size) = bindings.Size() {
                            if binding_size > 0 {
                                if let Ok(binding) = bindings.GetAt(0) {
                                    if let Ok(texts) = binding.GetTextElements() {
                                        if let Ok(text_count) = texts.Size() {
                                            if text_count > 0 {
                                                if let Ok(t0) = texts.GetAt(0) {
                                                    if let Ok(hstring) = t0.Text() {
                                                        title = Some(hstring.to_string());
                                                    }
                                                }
                                            }
                                            if text_count > 1 {
                                                if let Ok(t1) = texts.GetAt(1) {
                                                    if let Ok(hstring) = t1.Text() {
                                                        body = Some(hstring.to_string());
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    if let Ok(hints) = binding.Hints() {
                                        for key in ["image", "appLogoOverride", "avatar", "icon", "hero"] {
                                            if let Ok(val) = hints.Lookup(&windows::core::HSTRING::from(key)) {
                                                let s = val.to_string();
                                                if !s.is_empty() {
                                                    image = Some(s);
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            let is_wa = app_name.to_lowercase().contains("whatsapp");
            let is_call = is_wa && (
                title.as_deref().map(is_call_text).unwrap_or(false)
                || body.as_deref().map(is_call_text).unwrap_or(false)
            );

            if is_call {
                let caller = title.clone().unwrap_or_else(|| "WhatsApp".to_string());
                let subtitle = body.clone().unwrap_or_else(|| "Incoming WhatsApp call".to_string());
                let call_payload = WhatsAppCallPayload {
                    id: format!("toast_{id}"),
                    caller,
                    subtitle,
                    avatar: image.clone(),
                    state: "ringing".into(),
                    since: None,
                };
                let _ = app.emit("whatsapp-call", call_payload);
            }

            let payload = SystemNotificationPayload { id: Some(id), app: app_name, title, body, image, color: None };
            let _ = app.emit("system-notification", payload);
        }

        // After the first scan completes, we are past cold start.
        if cold_start {
            cold_start = false;
        }

        // Reconcile: replace seen_ids with the current live set.
        // Dismissed notifications drop out automatically; no stale IDs accumulate.
        seen_ids = current_ids;
    }
}

#[tauri::command]
pub fn check_notification_access() -> Result<bool, String> {
    #[cfg(windows)]
    {
        use windows::UI::Notifications::Management::{UserNotificationListener, UserNotificationListenerAccessStatus};
        if let Ok(listener) = UserNotificationListener::Current() {
            if let Ok(status) = listener.GetAccessStatus() {
                return Ok(status == UserNotificationListenerAccessStatus::Allowed);
            }
        }
    }
    Ok(false)
}

#[tauri::command]
pub fn request_notification_access() -> Result<bool, String> {
    #[cfg(windows)]
    {
        use windows::UI::Notifications::Management::{UserNotificationListener, UserNotificationListenerAccessStatus};
        if let Ok(listener) = UserNotificationListener::Current() {
            if let Ok(async_op) = listener.RequestAccessAsync() {
                if let Ok(status) = async_op.get() {
                    return Ok(status == UserNotificationListenerAccessStatus::Allowed);
                }
            }
        }
    }
    Ok(false)
}

#[cfg(windows)]
pub fn decline_call(call_id: &str) -> bool {
    use windows::UI::Notifications::Management::UserNotificationListener;
    if let Ok(listener) = UserNotificationListener::Current() {
        if let Some(id_str) = call_id.strip_prefix("toast_") {
            if let Ok(id) = id_str.parse::<u32>() {
                return listener.RemoveNotification(id).is_ok();
            }
        }
    }
    false
}

#[cfg(not(windows))]
pub fn decline_call(_call_id: &str) -> bool {
    false
}
