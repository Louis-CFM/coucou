// Windows System Notification Listener for the Small Notch (#1055 & Dynamic Island).
// Actively monitors system notifications (WhatsApp Desktop, Telegram, Discord, Slack, Mail, System Alerts)
// and emits "system-notification" events to the webview to morph the small notch.

use serde::{Deserialize, Serialize};
use tauri::AppHandle;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SystemNotificationPayload {
    pub app: String,
    pub title: Option<String>,
    pub body: Option<String>,
    pub color: Option<String>,
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

    let Ok(status_async) = listener.RequestAccessAsync() else {
        return;
    };
    let Ok(status) = status_async.get() else {
        return;
    };

    if status != UserNotificationListenerAccessStatus::Allowed {
        return;
    }

    let mut last_seen_id: u32 = 0;

    loop {
        std::thread::sleep(std::time::Duration::from_millis(1500));

        let Ok(notifs_async) = listener.GetNotificationsAsync(NotificationKinds::Toast) else {
            continue;
        };
        let Ok(notifs) = notifs_async.get() else {
            continue;
        };
        let Ok(size) = notifs.Size() else {
            continue;
        };

        if size == 0 {
            continue;
        }

        if let Ok(latest) = notifs.GetAt(size - 1) {
            if let Ok(id) = latest.Id() {
                if id != last_seen_id {
                    last_seen_id = id;

                    let mut app_name = "System".to_string();
                    let mut title: Option<String> = None;
                    let mut body: Option<String> = None;

                    if let Ok(app_info) = latest.AppInfo() {
                        if let Ok(display_info) = app_info.DisplayInfo() {
                            if let Ok(name) = display_info.DisplayName() {
                                let s = name.to_string();
                                if !s.is_empty() {
                                    app_name = s;
                                }
                            }
                        }
                    }

                    if let Ok(toast) = latest.Notification() {
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
                                        }
                                    }
                                }
                            }
                        }
                    }

                    let payload = SystemNotificationPayload {
                        app: app_name,
                        title,
                        body,
                        color: None,
                    };

                    let _ = app.emit("system-notification", payload);
                }
            }
        }
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
