// System User Presence Monitor (#1055 & Mochi Companion).
// Uses Windows Win32 GetLastInputInfo to detect when the user steps away from keyboard/mouse
// (10-15+ minutes) and returns, notifying the webview so Mochi greets them warmly in the small notch.

use serde::{Deserialize, Serialize};
use std::time::Instant;
use tauri::{AppHandle, Emitter};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PresenceEvent {
    pub status: String, // "away" | "returned"
    pub away_minutes: u64,
    pub user_name: Option<String>,
}

#[cfg(windows)]
pub fn system_idle_ms() -> u64 {
    use ::windows::Win32::System::SystemInformation::GetTickCount;
    use ::windows::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};

    let mut lii = LASTINPUTINFO {
        cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32,
        dwTime: 0,
    };
    if unsafe { GetLastInputInfo(&mut lii).as_bool() } {
        let now = unsafe { GetTickCount() };
        now.saturating_sub(lii.dwTime) as u64
    } else {
        0
    }
}

#[cfg(not(windows))]
pub fn system_idle_ms() -> u64 {
    0
}

/// Minimum idle time before user is considered "away" (10 minutes = 600,000 ms).
const DEFAULT_AWAY_THRESHOLD_MS: u64 = 10 * 60 * 1000;

pub fn start(app: &AppHandle) {
    let handle = app.clone();
    std::thread::Builder::new()
        .name("coucou-presence".into())
        .spawn(move || {
            run_presence_loop(handle);
        })
        .ok();
}

fn run_presence_loop(app: AppHandle) {
    let mut is_away = false;
    let mut away_start = Instant::now();

    loop {
        std::thread::sleep(std::time::Duration::from_millis(2500));

        let idle_ms = system_idle_ms();

        if !is_away {
            if idle_ms >= DEFAULT_AWAY_THRESHOLD_MS {
                is_away = true;
                away_start = Instant::now();
                let _ = app.emit(
                    "user-presence",
                    PresenceEvent {
                        status: "away".into(),
                        away_minutes: idle_ms / 60000,
                        user_name: crate::identity::first_name().map(String::from),
                    },
                );
            }
        } else {
            // User was away and has now performed input (mouse moved or key pressed)
            if idle_ms < 2000 {
                is_away = false;
                let away_minutes = away_start.elapsed().as_secs() / 60;
                let _ = app.emit(
                    "user-presence",
                    PresenceEvent {
                        status: "returned".into(),
                        away_minutes: away_minutes.max(DEFAULT_AWAY_THRESHOLD_MS / 60000),
                        user_name: crate::identity::first_name().map(String::from),
                    },
                );
            }
        }
    }
}

#[tauri::command]
pub fn get_system_presence() -> Result<PresenceEvent, String> {
    let idle_ms = system_idle_ms();
    let is_away = idle_ms >= DEFAULT_AWAY_THRESHOLD_MS;
    Ok(PresenceEvent {
        status: if is_away { "away".into() } else { "active".into() },
        away_minutes: idle_ms / 60000,
        user_name: crate::identity::first_name().map(String::from),
    })
}
